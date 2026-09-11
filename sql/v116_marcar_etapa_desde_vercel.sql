-- ============================================================
-- BOMAN INVENTARIO - v116: marcar etapas de produccion desde Vercel
--
-- Hasta ahora el tablero de Vercel era un ESPEJO: tablero_produccion_v102
-- leia contrato_etapas, el permiso contratos.marcar_etapa existia desde v79,
-- pero no habia ninguna funcion que escribiera. Marcar seguia siendo cosa del
-- tablero de Apps Script, y desde Vercel no habia forma de mover un contrato.
--
-- Aqui se abre esa puerta. Dos cuidados que no son opcionales:
--
--  1. El estado del contrato SOLO AVANZA, igual que marcarEtapaCore_ en
--     Codigo.gs. Marcar una etapa anterior deja constancia en la bitacora pero
--     no retrocede el contrato: el taller trabaja como checklist, no en orden.
--
--  2. Una etapa no se puede marcar dos veces. El legado ya lo rechaza y aqui
--     tambien: (contrato, area, etapa) es unico. Ademas de evitar el doble
--     clic, es lo que permite que la marca viaje a la hoja y VUELVA en la
--     siguiente sincronizacion sin duplicarse.
--
-- Ejecutar despues de v102 y nunca en paralelo con otra migracion.
-- ============================================================
begin;
select pg_advisory_xact_lock(1161142026);
lock table public.contrato_etapas in access exclusive mode;

do $$begin
  if to_regclass('public.contrato_etapas') is null
     or to_regprocedure('public.tablero_produccion_v102()') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Faltan v79 o v102 antes de v116';
  end if;
end$$;

-- De donde salio la marca. La sincronizacion sigue insertando con el valor por
-- defecto, asi que las filas historicas no cambian de significado.
alter table public.contrato_etapas add column if not exists origen text not null default 'sheet';
alter table public.contrato_etapas add column if not exists idempotency_key uuid;
alter table public.contrato_etapas add column if not exists marcado_por uuid references public.perfiles(id) on delete set null;

create unique index if not exists contrato_etapas_idempotency_v116
  on public.contrato_etapas(idempotency_key) where idempotency_key is not null;

-- Clave real de una marca. Sin este indice, la marca hecha en Vercel se
-- duplicaria al volver de la hoja en la siguiente corrida del sincronizador.
-- Se crea de forma tolerante: si la tabla YA arrastra duplicados de importaciones
-- viejas, el indice no se puede crear y la migracion no debe caerse por eso
-- -se avisa y se sigue, porque el resto de v116 funciona igual.
do $$begin
  begin
    create unique index if not exists contrato_etapas_marca_unica_v116
      on public.contrato_etapas(contrato_id, area, etapa);
  exception when unique_violation then
    raise warning 'v116: contrato_etapas ya tiene marcas repetidas; el indice unico no se creo. Limpialas y vuelve a crearlo a mano.';
  end;
end$$;

-- Orden canonico de las etapas: el mismo de ESTADOS_PRODUCCION en Codigo.gs y
-- de tablero_produccion_v102. Vive en una funcion para no repetirlo en cada
-- comparacion de "esto avanza o retrocede".
create or replace function public.orden_etapa_v116(p_etapa text)
returns integer language sql immutable set search_path='' as $v116$
  select case btrim(coalesce(p_etapa,''))
    when 'Ingresado' then 1 when 'Por imprimir' then 2 when 'Impreso' then 3
    when 'Sublimación' then 4 when 'Cortado' then 5 when 'En costura o maquila' then 6
    when 'Estampado' then 7 when 'Terminado' then 8 when 'Estampado final' then 9
    when 'Pendiente entrega' then 10 when 'Entregado' then 11 else 0 end;
$v116$;

create or replace function public.marcar_etapa_contrato_v116(
  p_numero text, p_area text, p_etapa text, p_operario text,
  p_no_aplica boolean, p_nota text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $v116$
declare
  v_uid uuid := auth.uid();
  v_id uuid; v_estado text; v_area text := btrim(coalesce(p_area,''));
  v_etapa text := btrim(coalesce(p_etapa,'')); v_previa text;
  v_orden integer; v_orden_actual integer; v_avanzo boolean := false;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.marcar_etapa') then
    raise exception 'No tienes permiso para marcar etapas de produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if v_area = '' then raise exception 'Falta el area que marca'; end if;

  v_orden := public.orden_etapa_v116(v_etapa);
  if v_orden = 0 then raise exception 'La etapa "%" no existe', v_etapa; end if;

  -- Mismo idioma que el resto de escrituras: reintentar no duplica.
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 116));
  select contrato_id into v_id from public.contrato_etapas where idempotency_key = p_idempotency_key;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'repetida', true);
  end if;

  select id, estado into v_id, v_estado from public.contratos where numero = btrim(p_numero);
  if v_id is null then raise exception 'No existe el contrato %', p_numero; end if;

  if exists(select 1 from public.contrato_etapas
            where contrato_id = v_id and area = v_area and etapa = v_etapa) then
    raise exception 'Ese contrato ya estaba marcado como "%" por %', v_etapa, v_area;
  end if;

  v_previa := v_estado;
  insert into public.contrato_etapas(
    contrato_id, area, etapa, etapa_anterior, operario, no_aplica, nota,
    origen, idempotency_key, marcado_por)
  values (v_id, v_area, v_etapa, v_previa, btrim(coalesce(p_operario,'')),
          coalesce(p_no_aplica,false), nullif(btrim(coalesce(p_nota,'')),''),
          'vercel', p_idempotency_key, v_uid);

  -- El estado solo avanza. "No aplica" nunca avanza: deja constancia de que esa
  -- parte no existe en el contrato, no de que se haya trabajado.
  v_orden_actual := public.orden_etapa_v116(v_estado);
  if not coalesce(p_no_aplica,false) and v_orden > v_orden_actual then
    update public.contratos set estado = v_etapa, updated_at = now() where id = v_id;
    v_avanzo := true;
  end if;

  return jsonb_build_object('ok', true, 'contrato_id', v_id, 'etapa', v_etapa,
                            'estado_anterior', v_previa, 'avanzo', v_avanzo);
end;$v116$;

-- Quitar una marca. Marcar de mas es inevitable y sin esto no habria como
-- deshacerlo desde Vercel. Si la etapa que se quita ERA el estado actual del
-- contrato, el estado se recalcula al maximo que siga marcado -igual que
-- recomputarEstadoDesdeBitacora_ en Codigo.gs- en vez de quedarse mintiendo.
create or replace function public.desmarcar_etapa_contrato_v116(
  p_numero text, p_area text, p_etapa text, p_motivo text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $v116$
declare
  v_uid uuid := auth.uid(); v_id uuid; v_estado text; v_borradas integer;
  v_area text := btrim(coalesce(p_area,'')); v_etapa text := btrim(coalesce(p_etapa,''));
  v_nuevo text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.marcar_etapa') then
    raise exception 'No tienes permiso para marcar etapas de produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo,''))) < 10 then
    raise exception 'El motivo debe tener al menos 10 caracteres';
  end if;

  select id, estado into v_id, v_estado from public.contratos where numero = btrim(p_numero);
  if v_id is null then raise exception 'No existe el contrato %', p_numero; end if;

  delete from public.contrato_etapas
   where contrato_id = v_id and area = v_area and etapa = v_etapa;
  get diagnostics v_borradas = row_count;
  if v_borradas = 0 then raise exception 'Esa marca no existe'; end if;

  insert into public.contrato_eventos(contrato_id, campo, valor_nuevo, quien, created_at)
  values (v_id, 'Etapa desmarcada', v_area || ' · ' || v_etapa || ' — ' || btrim(p_motivo),
          coalesce((select nombre_completo from public.perfiles where id = v_uid), ''), now());

  if public.orden_etapa_v116(v_estado) = public.orden_etapa_v116(v_etapa) then
    select e.etapa into v_nuevo
      from public.contrato_etapas e
     where e.contrato_id = v_id and not e.no_aplica
     order by public.orden_etapa_v116(e.etapa) desc limit 1;
    update public.contratos
       set estado = coalesce(v_nuevo, 'Ingresado'), updated_at = now()
     where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'borradas', v_borradas);
end;$v116$;

revoke all on function public.marcar_etapa_contrato_v116(text,text,text,text,boolean,text,uuid) from public, anon;
revoke all on function public.desmarcar_etapa_contrato_v116(text,text,text,text,uuid) from public, anon;
revoke all on function public.orden_etapa_v116(text) from public, anon;
grant execute on function public.marcar_etapa_contrato_v116(text,text,text,text,boolean,text,uuid) to authenticated;
grant execute on function public.desmarcar_etapa_contrato_v116(text,text,text,text,uuid) to authenticated;
grant execute on function public.orden_etapa_v116(text) to authenticated;

commit;
