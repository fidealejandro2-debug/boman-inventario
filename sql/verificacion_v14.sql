-- ============================================================
-- Verificación de instalación v14 - Anulación de Ventas XML
-- Solo lectura: no modifica datos.
-- ============================================================

select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'documentos_venta_xml'
      and column_name = 'anulado'
  ) as columna_anulado_ok,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'documentos_venta_xml'
      and column_name = 'motivo_anulacion'
  ) as columna_motivo_ok,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'documentos_venta_xml'
      and column_name = 'anulado_por'
  ) as columna_usuario_ok,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'documentos_venta_xml'
      and column_name = 'anulado_at'
  ) as columna_fecha_ok;

select
  to_regprocedure('public.admin_anular_factura_venta_xml(uuid,text)') is not null
    as rpc_anulacion_admin_ok;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_anular_factura_venta_xml';

