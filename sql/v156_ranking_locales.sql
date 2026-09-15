-- ============================================================
-- v156 - Ranking de locales: ingresos/egresos, ticket promedio, medios de
-- pago y comparacion contra el periodo anterior, normalizado por dias con
-- actividad y area del local (no solo venta total).
--
-- Usa el mismo permiso de v62 (franquicia.consolidado) -no crea uno nuevo-
-- y es puramente de lectura sobre datos ya existentes: no agrega tablas.
--
-- Ejecutar despues de v153 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v156', 0));

do $requisitos$
begin
  if to_regclass('public.almacen_configuracion_operativa_v153') is null then
    raise exception 'Falta v153: instala primero la configuracion operativa por almacen';
  end if;
  if to_regprocedure('public.resumen_consolidado_franquicias_v62(date,date)') is null then
    raise exception 'Falta v62: instala primero el consolidado de franquicias (trae el permiso franquicia.consolidado)';
  end if;
end;
$requisitos$;

create or replace function public.ranking_locales_v156(
  p_desde date default null,
  p_hasta date default null
) returns table (
  almacen_id uuid,
  nombre text,
  tipo text,
  ingresos_total numeric,
  egresos_total numeric,
  resultado_operativo numeric,
  num_ventas bigint,
  ticket_promedio numeric,
  pct_efectivo numeric,
  pct_transferencia numeric,
  pct_tarjeta numeric,
  pct_otros numeric,
  dias_con_actividad bigint,
  area_m2 numeric,
  venta_por_dia_abierto numeric,
  venta_por_m2 numeric,
  ingresos_periodo_anterior numeric,
  variacion_pct numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $v156$
declare
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_desde date;
  v_hasta date;
  v_dias integer;
  v_desde_ant date;
  v_hasta_ant date;
begin
  if not public.usuario_tiene_permiso_v35('franquicia.consolidado') then
    raise exception 'No tienes permiso para consultar el ranking de locales';
  end if;

  v_desde := coalesce(p_desde, date_trunc('month', v_hoy)::date);
  v_hasta := coalesce(p_hasta, v_hoy);
  if v_desde > v_hasta then
    raise exception 'La fecha desde no puede ser posterior a la fecha hasta';
  end if;
  if v_hasta - v_desde > 366 then
    raise exception 'El ranking admite un rango maximo de 367 dias';
  end if;

  v_dias := v_hasta - v_desde + 1;
  v_hasta_ant := v_desde - 1;
  v_desde_ant := v_desde - v_dias;

  return query
  with locales as (
    select f.almacen_id, f.nombre, 'franquicia'::text as tipo
    from public.franquicias f
    where f.activo
    union all
    select a.id, a.nombre, 'tienda'::text
    from public.almacenes a
    where a.activo and a.tipo = 'tienda'
      and not exists (
        select 1 from public.franquicias f where f.almacen_id = a.id and f.activo
      )
  ),
  movs as (
    select
      m.almacen_id,
      coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0) as ingresos,
      coalesce(sum(m.monto) filter (where m.tipo = 'egreso'), 0) as egresos,
      coalesce(sum(m.monto) filter (
        where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'
      ), 0) as efectivo,
      coalesce(sum(m.monto) filter (
        where m.tipo = 'ingreso' and m.medio_pago = 'transferencia'
      ), 0) as transferencia,
      coalesce(sum(m.monto) filter (
        where m.tipo = 'ingreso' and m.medio_pago = 'tarjeta'
      ), 0) as tarjeta,
      coalesce(sum(m.monto) filter (
        where m.tipo = 'ingreso' and m.medio_pago not in ('efectivo', 'transferencia', 'tarjeta')
      ), 0) as otros,
      -- categoria 'venta'/'venta_rapida' es la que usan los flujos reales de
      -- venta (factura franquicia/XML, venta rapida de tienda); el resto de
      -- ingresos (abonos, cobros de credito, etc.) no cuenta como "ventas".
      count(*) filter (
        where m.tipo = 'ingreso' and m.categoria in ('venta', 'venta_rapida')
      ) as ventas,
      coalesce(sum(m.monto) filter (
        where m.tipo = 'ingreso' and m.categoria in ('venta', 'venta_rapida')
      ), 0) as vendido,
      count(distinct m.fecha) as dias_actividad
    from public.franquicia_caja_movimientos m
    where m.fecha between v_desde and v_hasta
      and m.estado = 'vigente' and m.reversa_de_id is null
    group by m.almacen_id
  ),
  movs_ant as (
    select m.almacen_id,
      coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0) as ingresos
    from public.franquicia_caja_movimientos m
    where m.fecha between v_desde_ant and v_hasta_ant
      and m.estado = 'vigente' and m.reversa_de_id is null
    group by m.almacen_id
  )
  select
    l.almacen_id, l.nombre, l.tipo,
    coalesce(mv.ingresos, 0),
    coalesce(mv.egresos, 0),
    coalesce(mv.ingresos, 0) - coalesce(mv.egresos, 0),
    coalesce(mv.ventas, 0),
    case when coalesce(mv.ventas, 0) > 0 then round(mv.vendido / mv.ventas, 2) else 0 end,
    case when coalesce(mv.ingresos, 0) > 0 then round(mv.efectivo / mv.ingresos * 100, 1) else 0 end,
    case when coalesce(mv.ingresos, 0) > 0 then round(mv.transferencia / mv.ingresos * 100, 1) else 0 end,
    case when coalesce(mv.ingresos, 0) > 0 then round(mv.tarjeta / mv.ingresos * 100, 1) else 0 end,
    case when coalesce(mv.ingresos, 0) > 0 then round(mv.otros / mv.ingresos * 100, 1) else 0 end,
    coalesce(mv.dias_actividad, 0),
    co.area_m2,
    case when coalesce(mv.dias_actividad, 0) > 0
      then round(coalesce(mv.ingresos, 0) / mv.dias_actividad, 2) else 0 end,
    case when co.area_m2 is not null and co.area_m2 > 0
      then round(coalesce(mv.ingresos, 0) / co.area_m2, 2) else null end,
    coalesce(ma.ingresos, 0),
    case when coalesce(ma.ingresos, 0) > 0
      then round((coalesce(mv.ingresos, 0) - ma.ingresos) / ma.ingresos * 100, 1)
      else null end
  from locales l
  left join movs mv on mv.almacen_id = l.almacen_id
  left join movs_ant ma on ma.almacen_id = l.almacen_id
  left join public.almacen_configuracion_operativa_v153 co on co.almacen_id = l.almacen_id
  order by coalesce(mv.ingresos, 0) desc, l.nombre;
end;
$v156$;

alter function public.ranking_locales_v156(date,date) owner to postgres;
revoke execute on function public.ranking_locales_v156(date,date) from public, anon;
grant execute on function public.ranking_locales_v156(date,date) to authenticated;

comment on function public.ranking_locales_v156(date,date) is
  'Ranking financiero de franquicias y tiendas propias para un rango: ticket promedio, medios de pago, venta por dia con actividad y por m2, y variacion contra el periodo anterior de igual longitud.';

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v156', 156, 'v156_ranking_locales.sql',
  'Ranking de locales: ticket promedio, medios de pago, venta/dia y venta/m2, comparacion contra periodo anterior.'
)
on conflict (id) do update set version=excluded.version, archivo=excluded.archivo,
  notas=excluded.notas, aplicada_at=now();

notify pgrst, 'reload schema';
commit;
