-- ============================================================
-- Verificacion v18 - Grupo economico y multiempresa
-- Solo lectura: no modifica datos.
-- ============================================================

select
  to_regclass('public.grupos_economicos') is not null as grupos_ok,
  to_regclass('public.empresas') is not null as empresas_ok,
  to_regclass('public.empresa_almacenes') is not null as empresa_almacenes_ok,
  to_regclass('public.perfil_empresas') is not null as perfil_empresas_ok,
  to_regclass('public.configuracion_multiempresa_eventos') is not null as auditoria_ok;

select
  to_regprocedure('public.usuario_puede_empresa(uuid,boolean)') is not null as acceso_empresa_ok,
  to_regprocedure('public.admin_guardar_empresa(uuid,uuid,text,text,text,text,text,boolean,boolean)') is not null as guardar_empresa_ok,
  to_regprocedure('public.admin_configurar_empresa_almacenes(uuid,jsonb)') is not null as asignar_almacenes_ok,
  to_regprocedure('public.admin_asignar_empresas_perfil(uuid,jsonb)') is not null as asignar_usuarios_ok,
  to_regprocedure('public.admin_guardar_empresa_completa(uuid,uuid,text,text,text,text,text,boolean,boolean,jsonb)') is not null as guardado_atomico_ok;

select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and (table_name, column_name) in (
    ('emisores_facturacion', 'empresa_id'),
    ('documentos_venta_xml', 'empresa_id'),
    ('documentos_inventario', 'empresa_responsable_id'),
    ('movimientos', 'empresa_id')
  )
order by table_name;

-- Diagnostico complementario: si resulta false, v14 no fue instalada completa.
-- No bloquea v18, pero debe corregirse antes de usar anulacion de ventas XML.
select exists (
  select 1
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'documentos_venta_xml'
    and column_name = 'anulado'
) as columna_anulado_v14_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'grupos_economicos', 'empresas', 'empresa_almacenes',
    'perfil_empresas', 'configuracion_multiempresa_eventos'
  )
order by tablename;

select * from public.vista_pendientes_multiempresa order by tipo;

-- Debe ser cero: una tienda/bodega nunca puede tener dos operadoras principales.
select count(*) as almacenes_con_doble_operadora_debe_ser_cero
from (
  select almacen_id
  from public.empresa_almacenes
  where es_operadora_principal
  group by almacen_id
  having count(*) > 1
) duplicados;

select
  e.codigo,
  e.ruc,
  e.razon_social,
  e.tipo,
  e.activo,
  r.almacenes_asignados,
  r.almacenes_principales,
  r.usuarios_asignados,
  r.facturas_xml,
  r.stock_fisico_operado
from public.empresas e
join public.vista_resumen_multiempresa r on r.empresa_id = e.id
order by e.razon_social;
