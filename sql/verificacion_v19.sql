-- ============================================================
-- Verificacion v19 - Establecimientos por RUC
-- Solo lectura: no modifica datos.
-- ============================================================

select
  to_regclass('public.empresa_establecimientos') is not null as establecimientos_ok,
  to_regclass('public.empresa_puntos_emision') is not null as puntos_emision_ok,
  to_regclass('public.empresa_equivalencias_facturacion') is not null as equivalencias_ok,
  to_regclass('public.vista_establecimientos_empresa') is not null as vista_ok,
  to_regclass('public.vista_equivalencias_facturacion') is not null as vista_equivalencias_ok;

select
  to_regprocedure('public.admin_guardar_establecimientos_empresa(uuid,jsonb)') is not null
    as guardar_establecimientos_ok,
  to_regprocedure('public.admin_guardar_empresa_completa_v19(uuid,uuid,text,text,text,text,text,boolean,boolean,jsonb,jsonb)') is not null
    as guardado_atomico_v19_ok,
  to_regprocedure('public.sincronizar_establecimiento_facturacion()') is not null
    as sincronizacion_xml_ok,
  to_regprocedure('public.aplicar_factura_venta_xml_v19(jsonb,uuid,jsonb,text,boolean,text)') is not null
    as aplicar_xml_validado_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'empresa_establecimientos', 'empresa_puntos_emision',
    'empresa_equivalencias_facturacion'
  )
order by tablename;

select
  has_function_privilege(
    'authenticated',
    'public.admin_guardar_establecimientos_empresa(uuid,jsonb)',
    'execute'
  ) as guardar_establecimientos_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.admin_guardar_empresa_completa_v19(uuid,uuid,text,text,text,text,text,boolean,boolean,jsonb,jsonb)',
    'execute'
  ) as guardado_atomico_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.aplicar_factura_venta_xml_v19(jsonb,uuid,jsonb,text,boolean,text)',
    'execute'
  ) as aplicar_xml_validado_authenticated_ok;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'documentos_venta_xml'
  and column_name in (
    'empresa_establecimiento_id', 'empresa_punto_emision_id',
    'empresa_equivalencia_id', 'codigo_facturacion_no_estandar',
    'codigo_facturacion_confirmado_por', 'codigo_facturacion_confirmado_at',
    'codigo_facturacion_nota'
  )
order by column_name;

-- Debe ser cero: solo una matriz activa por RUC.
select count(*) as empresas_con_doble_matriz_debe_ser_cero
from (
  select empresa_id
  from public.empresa_establecimientos
  where es_matriz and activo
  group by empresa_id
  having count(*) > 1
) duplicados;

-- Debe ser cero cuando todos los mapeos XML de emisores clasificados tengan
-- establecimiento y punto de emision normalizados.
select count(*) as mapeos_xml_clasificados_sin_estructura_debe_ser_cero
from public.establecimiento_almacen_facturacion m
join public.emisores_facturacion ef on ef.ruc = m.emisor_ruc
where ef.empresa_id is not null
  and (m.empresa_establecimiento_id is null or m.empresa_punto_emision_id is null);

-- Diagnosticos operativos: conviene que sean cero antes de importar XML.
select count(*) as establecimientos_activos_sin_almacen
from public.empresa_establecimientos
where activo and almacen_id is null;

select count(*) as puntos_activos_sin_mapeo_xml
from public.empresa_puntos_emision pe
join public.empresa_establecimientos ee on ee.id = pe.establecimiento_id
join public.empresas e on e.id = ee.empresa_id
where pe.activo and ee.activo and ee.almacen_id is not null
  and not exists (
    select 1
    from public.establecimiento_almacen_facturacion m
    where m.emisor_ruc = e.ruc
      and m.establecimiento = ee.codigo
      and m.punto_emision = pe.codigo
      and m.almacen_id = ee.almacen_id
  );

select
  razon_social,
  ruc,
  codigo,
  nombre,
  almacen,
  es_matriz,
  activo,
  puntos_emision
from public.vista_establecimientos_empresa
order by razon_social, codigo;

select
  emisor_ruc,
  establecimiento_xml || '-' || punto_emision_xml as codigo_xml,
  establecimiento_oficial || '-' || punto_emision_oficial as codigo_oficial,
  establecimiento_nombre,
  almacen,
  motivo,
  activo
from public.vista_equivalencias_facturacion
order by emisor_ruc, codigo_xml;
