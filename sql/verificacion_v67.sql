-- ============================================================
-- Verificacion v67 - Creacion de SKU desde homologacion
-- Solo lectura: ejecutar despues de instalar v67.
-- ============================================================

select
  to_regclass('public.sku_abreviaturas_v67') is not null as abreviaturas_ok,
  to_regclass('public.productos_sku_creaciones_v67') is not null as auditoria_ok,
  to_regprocedure('public.registrar_abreviatura_sku_v67(uuid,text,text,text,uuid)') is not null
    as registro_interno_ok,
  to_regprocedure('public.crear_producto_desde_homologacion_v67(uuid,uuid,jsonb,text,uuid)') is not null
    as creacion_desde_homologacion_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('sku_abreviaturas_v67', 'productos_sku_creaciones_v67')
order by tablename;

select
  has_function_privilege(
    'authenticated',
    'public.crear_producto_desde_homologacion_v67(uuid,uuid,jsonb,text,uuid)',
    'execute'
  ) as creacion_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.crear_producto_desde_homologacion_v67(uuid,uuid,jsonb,text,uuid)',
    'execute'
  ) as creacion_anon_revocada,
  not has_function_privilege(
    'authenticated',
    'public.registrar_abreviatura_sku_v67(uuid,text,text,text,uuid)',
    'execute'
  ) as catalogo_interno_revocado,
  not has_table_privilege('authenticated', 'public.sku_abreviaturas_v67', 'insert')
    as insert_directo_abreviatura_revocado,
  not has_table_privilege('authenticated', 'public.productos_sku_creaciones_v67', 'insert')
    as insert_directo_auditoria_revocado;

select tipo, codigo, nombre
from public.sku_abreviaturas_v67
where codigo in ('CAM', 'GUA', 'BUZ', 'CTR', 'MAC', 'MAN', 'BOM',
                 'ADS', 'GOL', 'PRI', 'ALT', 'ARQ', 'PRF', 'SEM', 'NAC')
order by tipo, codigo;

-- Todos los siguientes resultados deben ser cero.
select count(*) as abreviaturas_activas_duplicadas_debe_ser_cero
from (
  select grupo_id, tipo, codigo
  from public.sku_abreviaturas_v67 where activo
  group by grupo_id, tipo, codigo having count(*) > 1
) duplicadas;

select count(*) as nombres_activos_con_dos_codigos_debe_ser_cero
from (
  select grupo_id, tipo, nombre_normalizado
  from public.sku_abreviaturas_v67 where activo
  group by grupo_id, tipo, nombre_normalizado
  having count(distinct codigo) > 1
) duplicados;

select count(*) as sku_creados_fuera_del_estandar_debe_ser_cero
from public.productos_sku_creaciones_v67 c
join public.productos p on p.id = c.producto_id
where (
    c.categoria_codigo = 'CTR'
    and p.sku <> 'CTR-' || c.entidad_codigo || '-UN'
  ) or (
    c.categoria_codigo <> 'CTR'
    and p.sku <> c.categoria_codigo || '-' || c.entidad_codigo || '-'
      || c.variante_codigo || '-' || c.anio_codigo
      || case when c.talla_codigo is null then '' else '-' || c.talla_codigo end
  );

select count(*) as creaciones_sin_homologacion_debe_ser_cero
from public.productos_sku_creaciones_v67 c
join public.compras_xml_importaciones i on i.id = c.importacion_id
join public.compras_xml_importacion_lineas l on l.id = c.importacion_linea_id
left join public.proveedor_producto_homologaciones h
  on h.grupo_id = c.grupo_id and h.proveedor_ruc = i.proveedor_ruc
 and h.codigo_proveedor = coalesce(l.codigo_proveedor, l.codigo_auxiliar)
where l.producto_id <> c.producto_id
   or h.producto_id is distinct from c.producto_id
   or not coalesce(h.activo, false);

select count(*) as eventos_creacion_incompletos_debe_ser_cero
from public.productos_sku_creaciones_v67
where creado_por is null or idempotency_key is null
   or length(btrim(motivo)) < 10;

-- Panorama informativo.
select p.sku, p.nombre, p.tipo_inventario, p.unidad_medida,
       c.motivo, c.created_at
from public.productos_sku_creaciones_v67 c
join public.productos p on p.id = c.producto_id
order by c.created_at desc;
