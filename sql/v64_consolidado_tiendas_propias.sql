-- ============================================================
-- BOMAN INVENTARIO - v64
-- Consolidado de tiendas propias
-- Ejecutar despues de v63 y antes de verificacion_v64.sql.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.resumen_consolidado_franquicias_v62(date,date)') is null
     or to_regclass('public.documentos_venta_xml') is null
     or to_regclass('public.vista_stock_operativo') is null
     or to_regclass('public.devoluciones_venta_xml') is null then
    raise exception 'Faltan dependencias. Instala y valida hasta v63 antes de v64';
  end if;
end $$;

-- Usa el mismo permiso del panel consolidado: habilita la comparacion de
-- locales, pero no concede capacidad de operar ni modificar esas tiendas.
create or replace function public.resumen_consolidado_tiendas_v64(
  p_desde date default null,
  p_hasta date default null
) returns table (
  almacen_id uuid,
  almacen_codigo text,
  almacen_nombre text,
  empresa_codigo text,
  empresa_nombre text,
  facturas_registradas bigint,
  facturas_anuladas bigint,
  unidades_facturadas bigint,
  importe_facturado numeric,
  unidades_devueltas bigint,
  stock_unidades bigint,
  stock_disponible bigint,
  valor_inventario numeric,
  productos_bajo_minimo bigint,
  productos_sin_stock bigint,
  unidades_sugeridas_reponer bigint,
  solicitudes_pendientes bigint,
  transferencias_pendientes_recepcion bigint,
  transferencias_pendientes_despacho bigint,
  conteos_pendientes_revision bigint,
  ultima_factura date,
  ultimo_movimiento timestamptz,
  ultimo_conteo timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_desde date;
  v_hasta date;
begin
  if not public.usuario_tiene_permiso_v35('franquicia.consolidado') then
    raise exception 'No tienes permiso para consultar el consolidado de locales';
  end if;

  v_desde := coalesce(p_desde, date_trunc('month', v_hoy)::date);
  v_hasta := coalesce(p_hasta, v_hoy);
  if v_desde > v_hasta then
    raise exception 'La fecha desde no puede ser posterior a la fecha hasta';
  end if;
  if v_hasta - v_desde > 366 then
    raise exception 'El consolidado admite un rango maximo de 367 dias';
  end if;

  return query
  select
    a.id,
    a.codigo,
    a.nombre,
    e.codigo,
    coalesce(e.nombre_comercial, e.razon_social),
    coalesce(v.registradas, 0),
    coalesce(v.anuladas, 0),
    coalesce(v.unidades, 0),
    coalesce(v.importe, 0::numeric),
    coalesce(dev.unidades, 0),
    coalesce(st.unidades, 0),
    coalesce(st.disponible, 0),
    coalesce(st.valor, 0::numeric),
    coalesce(st.bajo_minimo, 0),
    coalesce(st.sin_stock, 0),
    coalesce(st.sugerido, 0),
    coalesce(op.solicitudes, 0),
    coalesce(op.por_recibir, 0),
    coalesce(op.por_despachar, 0),
    coalesce(op.conteos_revision, 0),
    v.ultima,
    mov.ultimo,
    op.ultimo_conteo
  from public.almacenes a
  left join public.empresa_almacenes ea
    on ea.almacen_id = a.id and ea.es_operadora_principal
  left join public.empresas e on e.id = ea.empresa_id and e.activo
  left join lateral (
    select
      count(*) filter (where not coalesce(d.anulado, false)) as registradas,
      count(*) filter (where coalesce(d.anulado, false)) as anuladas,
      coalesce(sum(d.unidades_inventario) filter (
        where not coalesce(d.anulado, false)
      ), 0)::bigint as unidades,
      coalesce(sum(d.importe_total) filter (
        where not coalesce(d.anulado, false)
      ), 0) as importe,
      max(d.fecha_emision) filter (
        where not coalesce(d.anulado, false)
      ) as ultima
    from public.documentos_venta_xml d
    where d.almacen_id = a.id
      and d.fecha_emision between v_desde and v_hasta
  ) v on true
  left join lateral (
    select coalesce(sum(dl.cantidad), 0)::bigint as unidades
    from public.devoluciones_venta_xml dv
    join public.devolucion_venta_xml_lineas dl on dl.devolucion_id = dv.id
    where dv.almacen_id = a.id and dv.estado = 'aplicada'
      and (dv.created_at at time zone 'America/Guayaquil')::date
          between v_desde and v_hasta
  ) dev on true
  left join lateral (
    select
      coalesce(sum(s.stock_fisico), 0)::bigint as unidades,
      coalesce(sum(s.stock_disponible), 0)::bigint as disponible,
      coalesce(sum(s.stock_fisico * coalesce(s.precio, 0)), 0) as valor,
      count(*) filter (where s.bajo_minimo) as bajo_minimo,
      count(*) filter (where s.stock_fisico = 0) as sin_stock,
      coalesce(sum(s.sugerido_reponer), 0)::bigint as sugerido
    from public.vista_stock_operativo s
    where s.almacen_id = a.id
  ) st on true
  left join lateral (
    select
      count(*) filter (
        where d.tipo = 'solicitud_reposicion' and d.estado = 'solicitado'
          and d.destino_id = a.id
      ) as solicitudes,
      count(*) filter (
        where d.tipo = 'transferencia'
          and d.estado in ('despachado', 'en_transito') and d.destino_id = a.id
      ) as por_recibir,
      count(*) filter (
        where d.tipo = 'transferencia'
          and d.estado in ('aprobado', 'preparando') and d.origen_id = a.id
      ) as por_despachar,
      count(*) filter (
        where d.tipo = 'conteo' and d.estado = 'pendiente_revision'
          and d.origen_id = a.id
      ) as conteos_revision,
      max(d.updated_at) filter (
        where d.tipo = 'conteo' and d.origen_id = a.id
      ) as ultimo_conteo
    from public.documentos_inventario d
    where d.origen_id = a.id or d.destino_id = a.id
  ) op on true
  left join lateral (
    select max(m.created_at) as ultimo
    from public.movimientos m
    where m.entidad_id = a.id or m.entidad_destino_id = a.id
  ) mov on true
  where a.activo and a.tipo = 'tienda'
    and not exists (
      select 1 from public.franquicias f
      where f.almacen_id = a.id and f.activo
    )
  order by coalesce(v.importe, 0) desc, a.nombre;
end;
$fn$;

alter function public.resumen_consolidado_tiendas_v64(date,date)
  owner to postgres;

revoke execute on function public.resumen_consolidado_tiendas_v64(date,date)
  from public, anon;
grant execute on function public.resumen_consolidado_tiendas_v64(date,date)
  to authenticated;

comment on function public.resumen_consolidado_tiendas_v64(date,date) is
  'Comparativo de tiendas propias; facturacion y devoluciones respetan el rango, inventario y pendientes reflejan el estado actual.';

commit;

notify pgrst, 'reload schema';
