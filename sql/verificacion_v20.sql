-- ============================================================
-- Verificacion v20 - Integridad de stock y reversiones
-- Solo lectura: no modifica datos.
-- Ejecutar unicamente cuando la ejecucion de v20 haya terminado; no correr
-- en paralelo con la migracion porque sus lecturas participan en bloqueos.
-- ============================================================

select
  to_regclass('public.devoluciones_venta_xml') is not null as devoluciones_ok,
  to_regclass('public.devolucion_venta_xml_lineas') is not null as lineas_devolucion_ok,
  to_regclass('public.reversiones_tecnicas_venta_xml') is not null as reversiones_ok,
  to_regclass('public.inventario_cuarentena_movimientos') is not null as kardex_cuarentena_ok;

select
  to_regprocedure('public.usuario_puede_capacidad_empresa(uuid,uuid,text)') is not null
    as capacidad_empresa_ok,
  to_regprocedure('public.clasificar_contexto_empresa()') is not null
    as clasificador_empresa_ok,
  to_regprocedure('public.admin_guardar_almacen_v20(uuid,text,text,text,boolean,uuid,boolean,boolean,boolean)') is not null
    as guardar_almacen_ok,
  to_regprocedure('public.admin_reclasificar_pendientes_multiempresa()') is not null
    as reclasificar_pendientes_ok,
  to_regprocedure('public.aplicar_movimiento_stock_v20(uuid,uuid,uuid,public.tipo_movimiento,integer,uuid,text,text,uuid,uuid,uuid)') is not null
    as motor_stock_ok,
  to_regprocedure('public.consultar_saldo_devolucion_venta_xml(uuid)') is not null
    as saldo_devolucion_ok,
  to_regprocedure('public.registrar_devolucion_venta_xml(uuid,jsonb,text,uuid)') is not null
    as registrar_devolucion_ok,
  to_regprocedure('public.admin_revertir_importacion_venta_xml(uuid,text,uuid)') is not null
    as reversion_tecnica_ok,
  to_regprocedure('public.aplicar_factura_venta_xml_v20(jsonb,uuid,jsonb,text,boolean,text)') is not null
    as aplicar_v20_ok,
  to_regprocedure('public.control_anular_movimiento(uuid,text)') is not null
    as anulacion_manual_ok;

select e.enumlabel, true as instalado
from pg_enum e
join pg_type t on t.oid = e.enumtypid
join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public' and t.typname = 'tipo_movimiento'
  and e.enumlabel in (
    'devolucion_venta', 'venta_xml_reversa',
    'transferencia_retorno', 'cuarentena_liberacion',
    'movimiento_manual_reversa'
  )
order by e.enumlabel;

select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and (table_name, column_name) in (
    ('movimientos', 'saldo_anterior'),
    ('movimientos', 'saldo_posterior'),
    ('movimientos', 'movimiento_reversa_id'),
    ('movimientos', 'idempotency_key'),
    ('movimientos', 'documento_tipo'),
    ('documentos_venta_xml', 'anulacion_stock_estado'),
    ('documentos_venta_xml', 'ultima_devolucion_at')
  )
order by table_name, column_name;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'devoluciones_venta_xml', 'devolucion_venta_xml_lineas',
    'reversiones_tecnicas_venta_xml', 'inventario_cuarentena_movimientos'
  )
order by tablename;

select trigger_name, event_object_table, action_timing
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name in (
    'trg_validar_capacidad_movimiento_v20',
    'trg_clasificar_retorno_incidencia_v20',
    'trg_auditar_saldo_cuarentena_v20'
  )
order by trigger_name;

select
  has_function_privilege(
    'authenticated',
    'public.registrar_devolucion_venta_xml(uuid,jsonb,text,uuid)', 'execute'
  ) as devolucion_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.admin_revertir_importacion_venta_xml(uuid,text,uuid)', 'execute'
  ) as reversion_authenticated_ok,
  has_function_privilege(
    'anon',
    'public.admin_revertir_importacion_venta_xml(uuid,text,uuid)', 'execute'
  ) as reversion_anon_debe_ser_false,
  has_function_privilege(
    'authenticated',
    'public.aplicar_movimiento_stock_v20(uuid,uuid,uuid,public.tipo_movimiento,integer,uuid,text,text,uuid,uuid,uuid)',
    'execute'
  ) as motor_directo_authenticated_debe_ser_false;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('El stock no cambio' in pg_get_functiondef(p.oid)) > 0
    as anulacion_fiscal_sin_stock,
  position('movimientos posteriores' in pg_get_functiondef(p.oid)) > 0
    as bloqueo_movimientos_posteriores
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_anular_factura_venta_xml',
    'admin_revertir_importacion_venta_xml'
  )
order by p.proname;

-- Debe ser cero: ninguna devolucion aplicada puede superar lo vendido.
select count(*) as productos_sobredevueltos_debe_ser_cero
from (
  select dv.documento_venta_id, dl.producto_id, sum(dl.cantidad) devuelto
  from public.devoluciones_venta_xml dv
  join public.devolucion_venta_xml_lineas dl on dl.devolucion_id = dv.id
  where dv.estado = 'aplicada'
  group by dv.documento_venta_id, dl.producto_id
) r
left join lateral (
  select coalesce(sum(a.cantidad), 0) vendido
  from public.documento_venta_xml_lineas l
  join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
  where l.documento_id = r.documento_venta_id and l.afecta_inventario
    and a.producto_id = r.producto_id
) v on true
where r.devuelto > v.vendido;

-- Debe ser cero: el kardex de cuarentena nunca puede contener saldos negativos
-- ni operaciones aritmeticamente incoherentes.
select count(*) as kardex_cuarentena_inconsistente_debe_ser_cero
from public.inventario_cuarentena_movimientos
where saldo_anterior < 0 or saldo_posterior < 0
   or (direccion = 'entrada' and saldo_posterior <> saldo_anterior + cantidad)
   or (direccion = 'salida' and saldo_posterior <> saldo_anterior - cantidad);

select
  (select count(*) from public.devoluciones_venta_xml where estado = 'aplicada')
    as devoluciones_aplicadas,
  (select coalesce(sum(cantidad), 0) from public.devolucion_venta_xml_lineas)
    as unidades_devueltas,
  (select count(*) from public.reversiones_tecnicas_venta_xml)
    as reversiones_tecnicas,
  (select count(*) from public.inventario_cuarentena_movimientos)
    as movimientos_cuarentena;

-- Estos dos contadores deben llegar a cero después de usar Administración >
-- Tiendas y bodegas y pulsar "Reclasificar históricos".
select count(*) as almacenes_activos_sin_operadora
from public.almacenes a
where a.activo and not exists (
  select 1 from public.empresa_almacenes ea
  where ea.almacen_id = a.id and ea.es_operadora_principal
);

select a.id, a.codigo, a.nombre, a.tipo
from public.almacenes a
where a.activo and not exists (
  select 1 from public.empresa_almacenes ea
  where ea.almacen_id = a.id and ea.es_operadora_principal
)
order by a.nombre;

select count(*) as documentos_operativos_sin_empresa
from public.documentos_inventario
where empresa_responsable_id is null;

select d.id, d.numero, d.tipo, d.estado,
       origen.nombre as origen, destino.nombre as destino
from public.documentos_inventario d
left join public.almacenes origen on origen.id = d.origen_id
left join public.almacenes destino on destino.id = d.destino_id
where d.empresa_responsable_id is null
order by d.created_at;

-- Debe ser cero: toda reversa manual apunta al movimiento que compensa.
select count(*) as reversas_manuales_sin_origen_debe_ser_cero
from public.movimientos
where tipo::text = 'movimiento_manual_reversa'
  and movimiento_reversa_id is null;
