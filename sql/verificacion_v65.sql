-- ============================================================
-- Verificacion v65 - Importador XML de compras
-- Solo lectura: no modifica datos ni exige una sesion simulada.
-- Ejecutar despues de instalar v65.
-- ============================================================

select
  to_regclass('public.compras_xml_lotes') is not null as lotes_ok,
  to_regclass('public.compras_xml_importaciones') is not null as importaciones_ok,
  to_regclass('public.compras_xml_importacion_lineas') is not null as lineas_ok,
  to_regclass('public.proveedor_producto_homologaciones') is not null as homologaciones_ok,
  to_regclass('public.compras_xml_eventos') is not null as eventos_ok,
  to_regclass('public.vista_compras_xml_pendientes_v65') is not null as vista_ok;

select
  to_regprocedure('public.usuario_puede_compra_xml_v65(uuid,boolean)') is not null
    as acceso_ok,
  to_regprocedure('public.cargar_xml_compras_v65(jsonb,text,uuid)') is not null
    as cargar_ok,
  to_regprocedure('public.homologar_lineas_compra_xml_v65(uuid,jsonb,text,uuid)') is not null
    as homologar_ok,
  to_regprocedure('public.procesar_compra_xml_v65(uuid,text,text,uuid)') is not null
    as procesar_ok,
  to_regprocedure('public.descartar_compra_xml_v65(uuid,text,uuid)') is not null
    as descartar_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'compras_xml_lotes', 'compras_xml_importaciones',
    'compras_xml_importacion_lineas',
    'proveedor_producto_homologaciones', 'compras_xml_eventos'
  )
order by tablename;

select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'vista_compras_xml_pendientes_v65';

select
  has_function_privilege(
    'authenticated', 'public.cargar_xml_compras_v65(jsonb,text,uuid)', 'execute'
  ) as cargar_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.homologar_lineas_compra_xml_v65(uuid,jsonb,text,uuid)', 'execute'
  ) as homologar_authenticated_ok,
  not has_function_privilege(
    'anon', 'public.cargar_xml_compras_v65(jsonb,text,uuid)', 'execute'
  ) as cargar_anon_debe_ser_true,
  not has_table_privilege(
    'authenticated', 'public.compras_xml_importaciones', 'insert'
  ) as insert_directo_debe_ser_true,
  not has_table_privilege(
    'authenticated', 'public.compras_xml_importacion_lineas', 'update'
  ) as update_directo_debe_ser_true;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  (position('compras.acceder' in pg_get_functiondef(p.oid)) > 0
    or position('usuario_puede_compra_xml_v65' in pg_get_functiondef(p.oid)) > 0)
    as comprueba_permiso_si_corresponde,
  case when p.proname = 'cargar_xml_compras_v65'
    then position('v_recibidos > 200' in pg_get_functiondef(p.oid)) > 0
    else null end as limita_lote_si_corresponde,
  case when p.proname = 'procesar_compra_xml_v65'
    then position('registrar_comprobante_compra_v58' in pg_get_functiondef(p.oid)) > 0
    else null end as reutiliza_motor_v58_si_corresponde
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'usuario_puede_compra_xml_v65', 'cargar_xml_compras_v65',
    'homologar_lineas_compra_xml_v65', 'procesar_compra_xml_v65',
    'descartar_compra_xml_v65'
  )
order by p.proname;

-- Todos los siguientes resultados deben ser cero.
select count(*) as importaciones_sin_lineas_debe_ser_cero
from public.compras_xml_importaciones i
where not exists (
  select 1 from public.compras_xml_importacion_lineas l
  where l.importacion_id = i.id
);

select count(*) as contadores_lineas_inconsistentes_debe_ser_cero
from public.compras_xml_importaciones i
left join lateral (
  select count(*)::integer total,
         count(*) filter (where l.producto_id is not null)::integer homologadas
  from public.compras_xml_importacion_lineas l
  where l.importacion_id = i.id
) x on true
where i.lineas_total <> x.total or i.lineas_homologadas <> x.homologadas;

select count(*) as listos_incompletos_debe_ser_cero
from public.compras_xml_importaciones
where estado = 'listo'
  and (proveedor_id is null or lineas_total <> lineas_homologadas);

select count(*) as procesados_sin_comprobante_debe_ser_cero
from public.compras_xml_importaciones i
left join public.comprobantes_compra c on c.id = i.comprobante_id
where i.estado = 'procesado' and c.id is null;

select count(*) as comprobantes_con_clave_distinta_debe_ser_cero
from public.compras_xml_importaciones i
join public.comprobantes_compra c on c.id = i.comprobante_id
where i.clave_acceso <> c.clave_acceso
   or i.empresa_id <> c.empresa_id
   or i.proveedor_id <> c.proveedor_id;

select count(*) as homologaciones_huerfanas_debe_ser_cero
from public.proveedor_producto_homologaciones h
left join public.productos p on p.id = h.producto_id
where p.id is null;

select count(*) as eventos_incompletos_debe_ser_cero
from public.compras_xml_eventos
where usuario_id is null or idempotency_key is null
   or btrim(coalesce(detalle, '')) = '';

select estado, count(*) as comprobantes, coalesce(sum(total), 0) as total
from public.compras_xml_importaciones
group by estado
order by estado;
