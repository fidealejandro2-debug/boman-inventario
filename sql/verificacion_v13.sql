-- ============================================================
-- Verificación de instalación v13 - Ventas XML
-- Solo lectura: no modifica datos.
-- ============================================================

select
  to_regclass('public.emisores_facturacion') is not null as emisores_ok,
  to_regclass('public.establecimiento_almacen_facturacion') is not null as establecimientos_ok,
  to_regclass('public.producto_codigos_facturacion') is not null as equivalencias_ok,
  to_regclass('public.documentos_venta_xml') is not null as documentos_ok,
  to_regclass('public.documento_venta_xml_lineas') is not null as lineas_ok,
  to_regclass('public.documento_venta_xml_asignaciones') is not null as asignaciones_ok;

select exists (
  select 1
  from pg_enum e
  join pg_type t on t.oid = e.enumtypid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'tipo_movimiento' and e.enumlabel = 'venta_xml'
) as tipo_venta_xml_ok;

select
  to_regprocedure('public.aplicar_factura_venta_xml(jsonb,uuid,jsonb,text)') is not null
    as rpc_aplicar_ok,
  to_regprocedure('public.puede_ver_documento_venta_xml(uuid)') is not null
    as rpc_lectura_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'emisores_facturacion', 'establecimiento_almacen_facturacion',
    'producto_codigos_facturacion', 'documentos_venta_xml',
    'documento_venta_xml_lineas', 'documento_venta_xml_asignaciones'
  )
order by tablename;

