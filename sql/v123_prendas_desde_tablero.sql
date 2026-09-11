-- ============================================================
-- BOMAN INVENTARIO - v123: corregir cantidades de prendas desde el tablero
--
-- Equivale a editarPrendasDesdeTablero de Codigo.gs, y existe por el mismo
-- motivo: hay contratos que llegan digitados a mano (los que vienen en Word)
-- con un desglose aproximado, y corregir "camisetas: 22" no deberia obligar a
-- abrir el asistente completo.
--
-- EL PELIGRO, que es real y ya mordio en la hoja: este editor trabaja con
-- cantidades SIN talla. Aplicarlo sobre un contrato que si tiene el desglose
-- por talla y genero lo reemplaza por un total plano y ese detalle se pierde;
-- el taller cortaria a ciegas. Por eso:
--
--   * si el contrato tiene tallas de verdad, la funcion NO escribe: devuelve
--     requiere_confirmar y el mensaje de lo que se perderia. Recien con
--     p_confirmar => true procede.
--   * las filas planas se guardan con talla 'General', que es la convencion
--     que v79 ya definio para lo que no lleva talla (bolsos). No se inventa un
--     centinela nuevo que despues haya que reconocer en cada consulta.
--
-- Permiso: contratos.editar_contenido, el mismo de v120. Esto reescribe
-- contrato_prendas, no corrige un dato suelto.
--
-- Ejecutar despues de v120.
-- ============================================================
begin;
select pg_advisory_xact_lock(1231142026);

do $$begin
  if to_regprocedure('public.actualizar_contrato_v120(uuid,jsonb,text,uuid)') is null then
    raise exception 'Falta v120_editar_contenido_contrato.sql antes de v123';
  end if;
end$$;

-- ¿El contrato tiene desglose real por talla, o solo totales planos?
create or replace function public.tiene_tallas_detalladas_v123(p_contrato_id uuid)
returns boolean language sql stable security definer set search_path='' as $v123$
  select exists(select 1 from public.contrato_prendas cp
                 where cp.contrato_id = p_contrato_id and btrim(cp.talla) <> 'General');
$v123$;

-- Las cantidades actuales, para precargar el editor. Va aparte del tablero a
-- proposito: solo se pide al abrir el editor de UN contrato, en vez de engordar
-- el payload de las cientos de filas que nadie va a editar.
create or replace function public.prendas_contrato_v123(p_contrato_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $v123$
declare v_r jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar produccion';
  end if;
  select jsonb_build_object(
    'detalladas', public.tiene_tallas_detalladas_v123(p_contrato_id),
    'filas', coalesce((
      select jsonb_agg(jsonb_build_object('prenda',q.prenda,'calidad',q.calidad,'cantidad',q.total)
             order by q.total desc, q.prenda)
      from (select cp.prenda, cp.calidad, sum(cp.cantidad)::integer total
              from public.contrato_prendas cp where cp.contrato_id = p_contrato_id
             group by cp.prenda, cp.calidad) q
    ), '[]'::jsonb)
  ) into v_r;
  return v_r;
end;$v123$;

create or replace function public.editar_prendas_tablero_v123(
  p_contrato_id uuid, p_filas jsonb, p_confirmar boolean, p_idempotency_key uuid
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $v123$
declare
  v_uid uuid := auth.uid();
  v_antes public.contratos%rowtype;
  v_total integer := 0;
  v_txt text;
  v_quien text;
  v_item jsonb;
  v_resultado jsonb;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar_contenido') then
    raise exception 'No tienes permiso para cambiar las prendas de un contrato';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if jsonb_typeof(coalesce(p_filas,'null'::jsonb)) <> 'array' or jsonb_array_length(p_filas) = 0 then
    raise exception 'Agrega al menos una prenda con cantidad';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,123));
  select resultado into v_resultado from public.contrato_actualizaciones_v120
  where idempotency_key = p_idempotency_key;
  if found and v_resultado is not null then return v_resultado || jsonb_build_object('duplicado',true); end if;

  select * into v_antes from public.contratos where id = p_contrato_id for update;
  if not found then raise exception 'El contrato no existe'; end if;

  for v_item in select value from jsonb_array_elements(p_filas) loop
    if length(btrim(coalesce(v_item->>'prenda',''))) = 0
       or coalesce((v_item->>'cantidad')::integer,0) <= 0 then
      raise exception 'Hay una linea sin prenda o sin cantidad';
    end if;
    v_total := v_total + (v_item->>'cantidad')::integer;
  end loop;

  -- El aviso ANTES de tocar nada: quien esta corrigiendo un total no espera
  -- borrar el desglose por talla, y aqui es donde se entera.
  if not coalesce(p_confirmar,false) and public.tiene_tallas_detalladas_v123(p_contrato_id) then
    return jsonb_build_object('ok', false, 'requiere_confirmar', true,
      'mensaje', 'El contrato ' || v_antes.numero || ' tiene el desglose por talla y género. '
        || 'Si guardas estas cantidades, ese detalle se reemplaza por totales planos y el taller '
        || 'pierde de qué talla es cada prenda. Para conservarlo, edítalo desde el expediente.');
  end if;

  delete from public.contrato_prendas where contrato_id = p_contrato_id;
  insert into public.contrato_prendas(contrato_id,prenda,calidad,detalle,genero,talla,cantidad)
  select p_contrato_id, btrim(x.prenda), btrim(coalesce(x.calidad,'')), '', 'H', 'General', x.cantidad
  from jsonb_to_recordset(p_filas) as x(prenda text, calidad text, cantidad integer);

  select string_agg(btrim(x.prenda) || ' x' || x.cantidad, ', ' order by x.cantidad desc)
    into v_txt
  from jsonb_to_recordset(p_filas) as x(prenda text, cantidad integer);

  update public.contratos
     set total_prendas = v_total, prendas_txt = v_txt, actualizado_por = v_uid
   where id = p_contrato_id;

  select coalesce(nombre_completo,v_uid::text) into v_quien from public.perfiles where id = v_uid;
  insert into public.contrato_eventos(contrato_id,campo,valor_anterior,valor_nuevo,quien,perfil_id,motivo_gestion_v99)
  values(p_contrato_id,'Prendas corregidas',
    v_antes.total_prendas::text || ' prendas', v_total::text || ' prendas · ' || coalesce(v_txt,''),
    v_quien,v_uid,'Corrección de cantidades desde el tablero de producción');

  v_resultado := jsonb_build_object('ok',true,'duplicado',false,'contrato_id',p_contrato_id,
    'numero',v_antes.numero,'total_prendas',v_total,'prendas_txt',v_txt);
  insert into public.contrato_actualizaciones_v120(contrato_id,datos,motivo,usuario_id,idempotency_key,resultado)
  values(p_contrato_id,jsonb_build_object('prendas_planas',p_filas),
    'Corrección de cantidades desde el tablero de producción',v_uid,p_idempotency_key,v_resultado);
  return v_resultado;
end;
$v123$;

alter function public.tiene_tallas_detalladas_v123(uuid) owner to postgres;
alter function public.editar_prendas_tablero_v123(uuid,jsonb,boolean,uuid) owner to postgres;
revoke all on function public.tiene_tallas_detalladas_v123(uuid) from public, anon;
revoke all on function public.editar_prendas_tablero_v123(uuid,jsonb,boolean,uuid) from public, anon;
revoke all on function public.prendas_contrato_v123(uuid) from public, anon;
grant execute on function public.prendas_contrato_v123(uuid) to authenticated;
grant execute on function public.tiene_tallas_detalladas_v123(uuid) to authenticated;
grant execute on function public.editar_prendas_tablero_v123(uuid,jsonb,boolean,uuid) to authenticated;

commit;
