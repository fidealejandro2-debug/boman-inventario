-- ============================================================
-- BOMAN INVENTARIO - v119: el cronograma avisa lo que falta asignar
--
-- El bloque "Mockups pendientes de aprobar" salia de contratos.aprobo_mockup,
-- un campo del flujo viejo donde el cliente aprobaba el arte y Lili lo marcaba
-- en la hoja. Ese flujo ya no se usa, asi que el campo nunca pasa a true y el
-- bloque listaba TODOS los contratos del rango -una vez por cada mockup, ademas,
-- porque el join a contrato_archivos multiplica las filas. Cero informacion.
--
-- Se cambia por la pregunta que si se hace todos los dias: que contratos van a
-- entrar a produccion sin diseñador asignado. Y la pantalla deja asignarlo ahi
-- mismo, con guardar_gestion_contrato_v99, que ya audita el cambio.
--
-- Ejecutar despues de v96.
-- ============================================================
begin;
select pg_advisory_xact_lock(1191142026);

do $$begin
  if to_regprocedure('public.cronograma_produccion_v96(date,date)') is null then
    raise exception 'Falta v96_cronograma_produccion.sql antes de v119';
  end if;
end$$;

-- Copia de v96 con UN cambio: la ultima clave del jsonb. El resto es identico.
create or replace function public.cronograma_produccion_v96(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_capacidad_defecto constant integer := 100;
  v_resultado jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar el cronograma de produccion';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El rango de fechas no es valido';
  end if;
  if p_hasta - p_desde > 92 then
    raise exception 'El rango no puede superar 92 dias';
  end if;

  with rango as materialized (
    select c.id, c.fecha_inicio_produccion as dia
    from public.contratos c
    where c.fecha_inicio_produccion between p_desde and p_hasta
      and lower(c.estado) <> 'entregado'
  ),
  carga_prenda as (
    select r.dia, cp.prenda, sum(cp.cantidad)::bigint cantidad
    from rango r
    join public.contrato_prendas cp on cp.contrato_id = r.id
    where lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
    group by r.dia, cp.prenda
  ),
  carga_prenda_capacidad as (
    select cpr.dia, cpr.prenda, cpr.cantidad,
      coalesce(cap.capacidad_dia, v_capacidad_defecto) as capacidad
    from carga_prenda cpr
    left join public.capacidad_produccion_diaria_v96 cap on cap.prenda = cpr.prenda
  ),
  dias as (
    select r.dia,
      count(distinct r.id)::bigint as contratos,
      coalesce(sum(cpc.cantidad), 0)::bigint as total_prendas,
      bool_or(cpc.cantidad > cpc.capacidad) as excede_algun_prenda
    from rango r
    left join carga_prenda_capacidad cpc on cpc.dia = r.dia
    group by r.dia
  )
  select jsonb_build_object(
    'generado_at', now(),
    'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'capacidad_defecto', v_capacidad_defecto,
    'dias', coalesce((
      select jsonb_agg(jsonb_build_object(
        'fecha', d.dia, 'contratos', d.contratos, 'total_prendas', d.total_prendas,
        'excede', coalesce(d.excede_algun_prenda, false),
        'prendas', coalesce((
          select jsonb_agg(jsonb_build_object(
            'prenda', cpc.prenda, 'cantidad', cpc.cantidad, 'capacidad', cpc.capacidad,
            'excede', cpc.cantidad > cpc.capacidad
          ) order by cpc.cantidad desc, cpc.prenda)
          from carga_prenda_capacidad cpc where cpc.dia = d.dia
        ), '[]'::jsonb)
      ) order by d.dia)
      from dias d
    ), '[]'::jsonb),
    'capacidades', coalesce((
      select jsonb_agg(jsonb_build_object('prenda', prenda, 'capacidad_dia', capacidad_dia) order by prenda)
      from public.capacidad_produccion_diaria_v96
    ), '[]'::jsonb),
    -- v119: reemplaza a 'mockups_pendientes'. Se usa el mismo eje que el resto
    -- de la pantalla (fecha de inicio de produccion), no la de entrega: la
    -- pregunta es quien va a diseñar lo que entra al taller en este rango.
    'sin_disenador', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'numero', c.numero, 'cliente', c.cliente,
        'vendedor', coalesce(c.vendedor, ''), 'estado', c.estado,
        'total_prendas', c.total_prendas,
        'fecha_inicio_produccion', c.fecha_inicio_produccion,
        'fecha_entrega', c.fecha_entrega
      ) order by c.fecha_inicio_produccion, c.numero)
      from public.contratos c
      join rango r on r.id = c.id
      where nullif(btrim(coalesce(c.disenador, '')), '') is null
    ), '[]'::jsonb),
    -- Para el desplegable de la pantalla. `disenador` es texto libre, asi que
    -- la lista se saca de lo ya usado en vez de mantener un catalogo aparte
    -- que se desincronizaria con la hoja.
    'disenadores', coalesce((
      select jsonb_agg(d.nombre order by d.nombre)
      from (
        select distinct btrim(c.disenador) as nombre
        from public.contratos c
        where nullif(btrim(coalesce(c.disenador, '')), '') is not null
      ) d
    ), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$fn$;

alter function public.cronograma_produccion_v96(date,date) owner to postgres;
revoke all on function public.cronograma_produccion_v96(date,date) from public, anon;
grant execute on function public.cronograma_produccion_v96(date,date) to authenticated;

commit;
