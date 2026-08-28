-- ============================================================
-- Verificacion v21 - Compras multiempresa
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v21 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.proveedores') is not null as proveedores_ok,
  to_regclass('public.proveedor_empresas') is not null as proveedor_empresas_ok,
  to_regclass('public.ordenes_compra') is not null as ordenes_ok,
  to_regclass('public.orden_compra_lineas') is not null as lineas_ok,
  to_regclass('public.recepciones_compra') is not null as recepciones_ok,
  to_regclass('public.recepcion_compra_lineas') is not null as recepcion_lineas_ok,
  to_regclass('public.recepcion_compra_no_conformidad_acciones') is not null as disposiciones_nc_ok,
  to_regclass('public.rectificaciones_recepcion_compra') is not null as rectificaciones_ok,
  to_regclass('public.orden_compra_eventos') is not null as eventos_ok;

select
  to_regprocedure('public.guardar_proveedor_v21(uuid,uuid,text,text,text,text,text,text,text,boolean)') is not null
    as guardar_proveedor_ok,
  to_regprocedure('public.crear_orden_compra_v21(uuid,uuid,uuid,jsonb,date,text,text,uuid)') is not null
    as crear_orden_ok,
  to_regprocedure('public.resolver_orden_compra_v21(uuid,boolean,text)') is not null
    as resolver_orden_ok,
  to_regprocedure('public.cerrar_saldo_orden_compra_v21(uuid,text)') is not null
    as cerrar_saldo_ok,
  to_regprocedure('public.recibir_orden_compra_v21(uuid,jsonb,text,text,uuid)') is not null
    as recibir_compra_ok,
  to_regprocedure('public.resolver_no_conformidad_compra_v21(uuid,text,integer,text,uuid)') is not null
    as resolver_no_conformidad_ok,
  to_regprocedure('public.admin_rectificar_recepcion_compra_v21(uuid,text,uuid)') is not null
    as rectificar_recepcion_ok;

select e.enumlabel, true as instalado
from pg_enum e
join pg_type t on t.oid = e.enumtypid
join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public' and t.typname = 'tipo_movimiento'
  and e.enumlabel in ('compra_recepcion', 'compra_recepcion_reversa')
order by e.enumlabel;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'proveedores', 'proveedor_empresas', 'ordenes_compra',
    'orden_compra_lineas', 'recepciones_compra',
    'recepcion_compra_lineas', 'recepcion_compra_no_conformidad_acciones',
    'rectificaciones_recepcion_compra',
    'orden_compra_eventos'
  )
order by tablename;

select
  has_function_privilege(
    'authenticated',
    'public.crear_orden_compra_v21(uuid,uuid,uuid,jsonb,date,text,text,uuid)',
    'execute'
  ) as crear_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.recibir_orden_compra_v21(uuid,jsonb,text,text,uuid)',
    'execute'
  ) as recibir_authenticated_ok,
  has_function_privilege(
    'anon',
    'public.recibir_orden_compra_v21(uuid,jsonb,text,text,uuid)',
    'execute'
  ) as recibir_anon_debe_ser_false,
  has_function_privilege(
    'anon',
    'public.admin_rectificar_recepcion_compra_v21(uuid,text,uuid)',
    'execute'
  ) as rectificar_anon_debe_ser_false;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'guardar_proveedor_v21', 'crear_orden_compra_v21',
    'resolver_orden_compra_v21', 'recibir_orden_compra_v21',
    'admin_rectificar_recepcion_compra_v21'
  )
order by p.proname;

-- Todos deben ser cero.
select count(*) as lineas_sobre_recibidas_debe_ser_cero
from public.orden_compra_lineas
where cantidad_recibida + cantidad_no_conforme > cantidad_ordenada;

select count(*) as ordenes_totales_inconsistentes_debe_ser_cero
from public.ordenes_compra o
left join lateral (
  select coalesce(sum(l.subtotal), 0) subtotal,
         coalesce(sum(l.descuento), 0) descuento,
         coalesce(sum(l.impuesto), 0) impuesto,
         coalesce(sum(l.total), 0) total
  from public.orden_compra_lineas l where l.orden_id = o.id
) t on true
where o.subtotal <> t.subtotal or o.descuento <> t.descuento
   or o.impuesto <> t.impuesto or o.total <> t.total;

select count(*) as recepciones_sin_lineas_debe_ser_cero
from public.recepciones_compra r
where not exists (
  select 1 from public.recepcion_compra_lineas l where l.recepcion_id = r.id
);

select count(*) as movimientos_compra_sin_documento_debe_ser_cero
from public.movimientos m
where m.tipo::text in ('compra_recepcion', 'compra_recepcion_reversa')
  and (m.grupo_id is null or m.documento_tipo is null
    or m.saldo_anterior is null or m.saldo_posterior is null);

select count(*) as recepciones_activas_sin_movimiento_debe_ser_cero
from public.recepcion_compra_lineas l
join public.recepciones_compra r on r.id = l.recepcion_id and r.estado = 'aplicada'
where l.cantidad_conforme > 0
  and not exists (
    select 1 from public.movimientos m
    where m.grupo_id = r.id and m.producto_id = l.producto_id
      and m.tipo::text = 'compra_recepcion'
  );

select count(*) as no_conformidades_sobreresueltas_debe_ser_cero
from public.recepcion_compra_lineas l
join lateral (
  select coalesce(sum(a.cantidad), 0) resuelto
  from public.recepcion_compra_no_conformidad_acciones a
  where a.recepcion_linea_id = l.id
) r on true
where r.resuelto > l.cantidad_no_conforme;

select
  count(*) filter (where estado = 'pendiente_aprobacion') as pendientes_aprobacion,
  count(*) filter (where estado in ('aprobada', 'parcial')) as pendientes_recepcion,
  count(*) filter (where estado = 'recibida') as recibidas,
  coalesce(sum(total) filter (where estado not in ('rechazada', 'anulada')), 0)
    as valor_ordenado_vigente
from public.ordenes_compra;

select
  count(*) as recepciones_aplicadas,
  coalesce(sum(l.cantidad_conforme), 0) as unidades_conformes,
  coalesce(sum(l.cantidad_no_conforme), 0) as unidades_en_cuarentena
from public.recepciones_compra r
join public.recepcion_compra_lineas l on l.recepcion_id = r.id
where r.estado = 'aplicada';
