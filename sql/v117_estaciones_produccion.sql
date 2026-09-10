-- ============================================================
-- BOMAN INVENTARIO - v117: estaciones de produccion
--
-- Objetivo: que un operario del taller entre a Vercel con su propia cuenta,
-- vea SOLO la cola de su estacion y no pueda tocar nada mas.
--
-- Antes de esto faltaba la pieza de abajo del todo: en Supabase una etapa no
-- sabia que estacion la marca. tablero_produccion_v102 devolvia 'area':''
-- para las once etapas, asi que:
--   * no habia forma de agrupar el tablero por estacion, y
--   * al marcar desde Vercel se enviaba a la hoja la ETIQUETA en vez del area
--     ("Costura", "Sublimado", "Por entregar"), nombres que AREAS_TALLER de
--     Codigo.gs no reconoce -> la marca se guardaba en Supabase y la hoja la
--     rechazaba con "Area no reconocida". El desfase existia desde v116.
--
-- Aqui se arregla eso y se construye encima:
--   1. area_etapa_v117: cada etapa dice que estacion la marca, con los MISMOS
--      nombres que AREAS_TALLER en Codigo.gs (si cambian alla, cambian aqui).
--   2. perfiles.estaciones: a que estacion(es) pertenece una cuenta.
--   3. El encierro: una cuenta CON estaciones asignadas pierde todo permiso
--      que no sea el de su estacion. No se arma a mano toggle por toggle (eso
--      se olvida y deja una puerta abierta): se calcula.
--   4. marcar/desmarcar rechazan un area que no sea la suya.
--
-- Ejecutar despues de v102 y v116.
-- ============================================================
begin;
select pg_advisory_xact_lock(1171142026);

do $$begin
  if to_regprocedure('public.tablero_produccion_v102()') is null
     or to_regprocedure('public.marcar_etapa_contrato_v116(text,text,text,text,boolean,text,uuid)') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Faltan v102 o v116 antes de v117';
  end if;
end$$;

-- ------------------------------------------------------------
-- 1. Catalogo de estaciones y mapa etapa -> estacion
-- ------------------------------------------------------------

-- Los nombres son los de AREAS_TALLER en Codigo.gs, literales. La marca viaja
-- a la hoja con este texto, asi que un acento de diferencia la tumba.
-- "Exteriores" existe en el taller pero NO esta aqui: es una vista paralela
-- sobre etapas que ya tienen dueno (por imprimir/impreso/cortado de chompas),
-- y el tablero de Supabase no la desglosa todavia. Asignarsela a alguien le
-- daria una pantalla vacia.
create or replace function public.estaciones_produccion_v117()
returns text[] language sql immutable set search_path='' as $fn$
  select array['Diseño','Corte','Sublimado y costura','Sellos',
               'Terminado y entrega','Estampado']::text[];
$fn$;

-- 'Ingresado' devuelve '' a proposito: no lo marca el taller, lo pone ventas
-- al crear el contrato. Esa columna no pertenece a ninguna estacion.
create or replace function public.area_etapa_v117(p_etapa text)
returns text language sql immutable set search_path='' as $fn$
  select case btrim(coalesce(p_etapa,''))
    when 'Por imprimir'         then 'Diseño'
    when 'Impreso'              then 'Diseño'
    when 'Cortado'              then 'Corte'
    when 'Sublimación'          then 'Sublimado y costura'
    when 'En costura o maquila' then 'Sublimado y costura'
    when 'Estampado'            then 'Sellos'
    when 'Terminado'            then 'Terminado y entrega'
    when 'Pendiente entrega'    then 'Terminado y entrega'
    when 'Entregado'            then 'Terminado y entrega'
    when 'Estampado final'      then 'Estampado'
    else '' end;
$fn$;

-- ------------------------------------------------------------
-- 2. A que estacion pertenece una cuenta
-- ------------------------------------------------------------

-- Vacio = sin restriccion (jefes, admin, produccion completa). Con contenido =
-- operario de esa(s) estacion(es), y entonces manda el encierro del punto 3.
alter table public.perfiles add column if not exists estaciones text[] not null default '{}';

comment on column public.perfiles.estaciones is
  'Estaciones de taller de esta cuenta (nombres de estaciones_produccion_v117). '
  'Vacio = cuenta normal. Con valores = operario: solo ve y marca su estacion.';

create or replace function public.estaciones_usuario_actual_v117()
returns text[] language sql stable security definer set search_path='' as $fn$
  select coalesce((select p.estaciones from public.perfiles p
                    where p.id = auth.uid() and p.activo), array[]::text[]);
$fn$;

create or replace function public.es_operario_estacion_v117()
returns boolean language sql stable security definer set search_path='' as $fn$
  select coalesce(array_length(public.estaciones_usuario_actual_v117(), 1), 0) > 0;
$fn$;

-- ------------------------------------------------------------
-- 3. El encierro
-- ------------------------------------------------------------

insert into public.permisos_sistema as p (codigo, modulo, nombre, descripcion, orden)
values ('produccion.estacion', 'Produccion', 'Mi estacion de produccion',
        'Ver y marcar unicamente la cola de la estacion asignada a la cuenta.', 206)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

-- Especifico de Boman: el taller y sus estaciones no existen fuera de este
-- cliente, igual que contratos.* (ver v107).
update public.permisos_sistema set es_boman_especifico = true
 where codigo = 'produccion.estacion';

-- En false para todos los roles a proposito: este permiso no se hereda del
-- rol, lo concede el encierro de mas abajo a quien tiene estaciones asignadas.
insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.codigo = 'produccion.estacion'
on conflict (rol, permiso_codigo) do nothing;

-- Se concede por el encierro, no por el rol: quien tiene estaciones asignadas
-- lo recibe aunque su rol lo tenga en false, y quien no las tiene no lo recibe
-- aunque sea admin (un admin no necesita esta pantalla, tiene el tablero).
--
-- El encierro NO consulta el interruptor de marca blanca de v107. Es a
-- proposito: un operario de taller solo existe en la operacion de Boman, asi
-- que apagar lo especifico de Boman deberia ser quitarle las estaciones, no
-- dejarlo con una cuenta que no puede entrar a ningun lado.
--
-- OJO: las dos funciones de abajo son las de v35/v107 con un unico case nuevo
-- delante. El cuerpo original se conserva palabra por palabra; si v107 se
-- vuelve a ejecutar despues de esto, hay que volver a correr v117.
create or replace function public.usuario_tiene_permiso_v35(p_permiso_codigo text)
returns boolean language sql stable security definer set search_path='' as $fn$
  select case when public.es_operario_estacion_v117()
    then p_permiso_codigo in ('produccion.estacion','contratos.marcar_etapa','notificaciones.acceder')
    else exists (
      select 1
      from public.perfiles p
      join public.permisos_sistema ps
        on ps.codigo = p_permiso_codigo and ps.activo
      left join public.rol_permisos rp
        on rp.rol = p.rol and rp.permiso_codigo = p_permiso_codigo
      left join public.perfil_permisos pp
        on pp.perfil_id = p.id and pp.permiso_codigo = p_permiso_codigo
      where p.id = auth.uid() and p.activo
        and (not ps.es_boman_especifico or public.modo_boman_especifico_activo())
        and coalesce(
          pp.permitido,
          p.rol::text = 'admin' or coalesce(rp.permitido, false)
        )
    )
  end;
$fn$;

create or replace function public.permisos_usuario_actual_v35()
returns text[] language sql stable security definer set search_path='' as $fn$
  select case when public.es_operario_estacion_v117()
    then array['produccion.estacion','contratos.marcar_etapa','notificaciones.acceder']::text[]
    else coalesce((
      select array_agg(x.codigo order by x.orden)
      from (
        select ps.codigo, ps.orden
        from public.perfiles p
        join public.permisos_sistema ps on ps.activo
        left join public.rol_permisos rp
          on rp.rol = p.rol and rp.permiso_codigo = ps.codigo
        left join public.perfil_permisos pp
          on pp.perfil_id = p.id and pp.permiso_codigo = ps.codigo
        where p.id = auth.uid() and p.activo
          and (not ps.es_boman_especifico or public.modo_boman_especifico_activo())
          and coalesce(
            pp.permitido,
            p.rol::text = 'admin' or coalesce(rp.permitido, false)
          )
      ) x
    ), array[]::text[])
  end;
$fn$;

-- Leer las estaciones de OTRA cuenta: la pantalla de administracion lo
-- necesita y la RLS de perfiles no deja mirar filas ajenas desde el cliente.
create or replace function public.estaciones_de_perfil_v117(p_perfil_id uuid)
returns text[] language sql stable security definer set search_path='' as $fn$
  select case when public.rol_usuario_actual() = 'admin'
    then coalesce((select p.estaciones from public.perfiles p where p.id = p_perfil_id), array[]::text[])
    else null end;
$fn$;

-- Asignar estaciones ES quitar permisos, asi que solo admin. Y nunca sobre un
-- admin: seria la forma mas facil de dejar el sistema sin nadie que entre.
create or replace function public.admin_asignar_estaciones_v117(
  p_perfil_id uuid, p_estaciones text[])
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_rol text; v_limpias text[]; v_invalida text;
begin
  if auth.uid() is null or public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo un administrador puede asignar estaciones';
  end if;
  select p.rol::text into v_rol from public.perfiles p where p.id = p_perfil_id;
  if v_rol is null then raise exception 'No existe esa cuenta'; end if;
  if v_rol = 'admin' then
    raise exception 'Un administrador no puede quedar encerrado en una estacion';
  end if;

  select coalesce(array_agg(distinct btrim(e)), array[]::text[]) into v_limpias
    from unnest(coalesce(p_estaciones, array[]::text[])) e where btrim(e) <> '';

  select e into v_invalida from unnest(v_limpias) e
   where not (e = any(public.estaciones_produccion_v117())) limit 1;
  if v_invalida is not null then
    raise exception 'La estacion "%" no existe', v_invalida;
  end if;

  update public.perfiles set estaciones = v_limpias where id = p_perfil_id;
  return jsonb_build_object('ok', true, 'estaciones', to_jsonb(v_limpias));
end;$fn$;

-- ------------------------------------------------------------
-- 4. El tablero reparte por estacion y el operario puede leerlo
-- ------------------------------------------------------------

-- Copia literal de v102 con DOS cambios, marcados abajo: la puerta acepta
-- tambien al operario de estacion, y cada etapa dice de que area es.
create or replace function public.tablero_produccion_v102()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_resultado jsonb;
begin
 -- CAMBIO 1: el operario de estacion tambien lee el tablero (su pantalla sale
 -- de aqui). Lo que ve se recorta en la UI; lo que puede MARCAR se recorta en
 -- marcar_etapa_contrato_v116, que es donde importa.
 if auth.uid() is null or not (public.usuario_tiene_permiso_v35('produccion.acceder')
                               or public.usuario_tiene_permiso_v35('produccion.estacion'))
   then raise exception 'No tienes permiso para consultar produccion';end if;
 with etapas(orden,nombre,etiqueta,emoji,bg,fg) as(values
 (1,'Ingresado','Ingresado','📥','#BDD7EE','#1F4E78'),(2,'Por imprimir','Por imprimir','🖨️','#FFE599','#7A5C00'),
 (3,'Impreso','Impreso','📄','#FFD966','#7A4F00'),(4,'Sublimación','Sublimado','🎨','#EA9999','#7B1E1E'),
 (5,'Cortado','Cortado','✂️','#F9CB9C','#783F04'),(6,'En costura o maquila','Costura','🧵','#D9D2E9','#4A1870'),
 (7,'Estampado','Estampado','🏷️','#C9DAF8','#1C4587'),(8,'Terminado','Terminado','✅','#A4C2F4','#1E3A8A'),
 (9,'Estampado final','Estampado final','🔖','#EAD1DC','#741B47'),(10,'Pendiente entrega','Por entregar','📦','#B6D7A8','#1A4731'),
 (11,'Entregado','Entregado','🚚','#E2EFDA','#365F23')
 ), activos as materialized(select c.*,case c.estado when'Ingresado'then 1 when'Por imprimir'then 2 when'Impreso'then 3 when'Sublimación'then 4 when'Cortado'then 5 when'En costura o maquila'then 6 when'Estampado'then 7 when'Terminado'then 8 when'Estampado final'then 9 when'Pendiente entrega'then 10 when'Entregado'then 11 else 0 end rango from public.contratos c where lower(c.estado)<>'entregado'),
 -- CAMBIO 2: 'area' deja de ser '' y trae la estacion que marca esa etapa.
 etapas_json as(select jsonb_agg(jsonb_build_object('nombre',e.nombre,'etiqueta',e.etiqueta,'emoji',e.emoji,'bg',e.bg,'fg',e.fg,'area',public.area_etapa_v117(e.nombre),'sub','','hechos',(select count(*) from activos a where a.rango>=e.orden or exists(select 1 from public.contrato_etapas ce where ce.contrato_id=a.id and ce.etapa=e.nombre)))order by e.orden) valor from etapas e),
 filas as(select jsonb_build_object('numero',a.numero,'corto',right(a.numero,4),'cliente',a.cliente,'vendedor',a.vendedor,'mks',coalesce((select jsonb_agg(jsonb_build_object('i',ca.drive_id,'d',ca.descripcion)order by ca.orden)from public.contrato_archivos ca where ca.contrato_id=a.id and ca.tipo='mockup' and ca.drive_id is not null),'[]'::jsonb),'prendas',a.total_prendas,'prendasTxt',coalesce(a.prendas_txt,''),'calidad',coalesce((select jsonb_agg(q.calidad order by q.calidad)from(select distinct cp.calidad from public.contrato_prendas cp where cp.contrato_id=a.id and btrim(cp.calidad)<>'')q),'[]'::jsonb),'urgente',lower(a.prioridad)='urgente','atrasado',a.fecha_entrega<(now()at time zone'America/Guayaquil')::date,'esExterior',lower(coalesce(a.prendas_txt,''))~'(chompa|rompeviento)','ingreso',to_char(a.fecha_ingreso at time zone'America/Guayaquil','DD/MM'),'entrega',to_char(a.fecha_entrega,'DD/MM'),'entregaMs',coalesce(extract(epoch from a.fecha_entrega::timestamp)*1000,0),'inicio',to_char(a.fecha_inicio_produccion,'DD/MM'),'disenador',coalesce(a.disenador,''),'autorMockup',coalesce(a.autor_mockup,''),'fabrica',case when lower(coalesce(a.disenador,''))like'%marco%'then 2 else 1 end,'obs',coalesce(a.observacion,''),'maquila',coalesce(a.maquila,''),'marca',coalesce((select ce.operario||' · '||to_char(ce.marcado_en at time zone'America/Guayaquil','DD/MM HH24:MI')from public.contrato_etapas ce where ce.contrato_id=a.id order by ce.marcado_en desc limit 1),''),'muestras',jsonb_build_object('tpu',a.muestras_tpu_faltan,'dtf',a.muestras_dtf_faltan),'hechas',(select jsonb_agg((a.rango>=e.orden or exists(select 1 from public.contrato_etapas ce where ce.contrato_id=a.id and ce.etapa=e.nombre))order by e.orden)from etapas e))fila,a.fecha_entrega,a.numero from activos a)
 select jsonb_build_object('etapas',(select valor from etapas_json),'filas',coalesce((select jsonb_agg(fila order by fecha_entrega nulls last,numero)from filas),'[]'::jsonb),'total',(select count(*)from activos),'hora',to_char(now()at time zone'America/Guayaquil','DD/MM/YYYY HH24:MI'))into v_resultado;
 return v_resultado;
end;$fn$;

-- ------------------------------------------------------------
-- 5. Marcar solo lo propio
-- ------------------------------------------------------------

-- Acepta el area exacta ("Sellos") y tambien la sub-etapa de la hoja
-- ("Sellos · TPU"), porque la bitacora del taller guarda las dos formas.
create or replace function public.puede_marcar_area_v117(p_area text)
returns boolean language sql stable security definer set search_path='' as $fn$
  select case when not public.es_operario_estacion_v117() then true
    else exists(
      select 1 from unnest(public.estaciones_usuario_actual_v117()) e
       where e = btrim(coalesce(p_area,''))
          or e = split_part(btrim(coalesce(p_area,'')), ' · ', 1))
  end;
$fn$;

-- v116 con el control de area agregado. El resto es identico.
create or replace function public.marcar_etapa_contrato_v116(
  p_numero text, p_area text, p_etapa text, p_operario text,
  p_no_aplica boolean, p_nota text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
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
  -- NUEVO en v117: un operario de estacion no marca trabajo de otra.
  if not public.puede_marcar_area_v117(v_area) then
    raise exception 'Tu cuenta solo puede marcar: %',
      array_to_string(public.estaciones_usuario_actual_v117(), ', ');
  end if;

  v_orden := public.orden_etapa_v116(v_etapa);
  if v_orden = 0 then raise exception 'La etapa "%" no existe', v_etapa; end if;

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

  v_orden_actual := public.orden_etapa_v116(v_estado);
  if not coalesce(p_no_aplica,false) and v_orden > v_orden_actual then
    update public.contratos set estado = v_etapa, updated_at = now() where id = v_id;
    v_avanzo := true;
  end if;

  return jsonb_build_object('ok', true, 'contrato_id', v_id, 'etapa', v_etapa,
                            'estado_anterior', v_previa, 'avanzo', v_avanzo);
end;$fn$;

create or replace function public.desmarcar_etapa_contrato_v116(
  p_numero text, p_area text, p_etapa text, p_motivo text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
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
  -- NUEVO en v117: quitar la marca de otra estacion tampoco.
  if not public.puede_marcar_area_v117(v_area) then
    raise exception 'Tu cuenta solo puede marcar: %',
      array_to_string(public.estaciones_usuario_actual_v117(), ', ');
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
end;$fn$;

-- ------------------------------------------------------------
-- 6. Privilegios
-- ------------------------------------------------------------
revoke all on function public.estaciones_produccion_v117() from public, anon;
revoke all on function public.area_etapa_v117(text) from public, anon;
revoke all on function public.estaciones_usuario_actual_v117() from public, anon;
revoke all on function public.es_operario_estacion_v117() from public, anon;
revoke all on function public.puede_marcar_area_v117(text) from public, anon;
revoke all on function public.admin_asignar_estaciones_v117(uuid,text[]) from public, anon;
revoke all on function public.estaciones_de_perfil_v117(uuid) from public, anon;
grant execute on function public.estaciones_de_perfil_v117(uuid) to authenticated;
grant execute on function public.estaciones_produccion_v117() to authenticated;
grant execute on function public.area_etapa_v117(text) to authenticated;
grant execute on function public.estaciones_usuario_actual_v117() to authenticated;
grant execute on function public.es_operario_estacion_v117() to authenticated;
grant execute on function public.puede_marcar_area_v117(text) to authenticated;
grant execute on function public.admin_asignar_estaciones_v117(uuid,text[]) to authenticated;

commit;
