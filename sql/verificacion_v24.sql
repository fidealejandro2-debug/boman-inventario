-- ============================================================
-- Verificacion v24 - Ordenes y ejecucion de produccion
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v24 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.ordenes_produccion') is not null as ordenes_ok,
  to_regclass('public.orden_produccion_materiales') is not null as materiales_ok,
  to_regclass('public.entregas_materiales_produccion') is not null as entregas_ok,
  to_regclass('public.entrega_materiales_produccion_lineas') is not null as entrega_lineas_ok,
  to_regclass('public.orden_produccion_eventos') is not null as eventos_ok;

select
  to_regprocedure('public.puede_ver_orden_produccion_v24(uuid)') is not null
    as lectura_rls_ok,
  to_regprocedure('public.crear_orden_produccion_v24(uuid,uuid,uuid,uuid,integer,date,text,text,uuid)') is not null
    as crear_orden_ok,
  to_regprocedure('public.resolver_orden_produccion_v24(uuid,boolean,text)') is not null
    as resolver_orden_ok,
  to_regprocedure('public.entregar_materiales_produccion_v24(uuid,jsonb,text,boolean,uuid)') is not null
    as entregar_materiales_ok,
  to_regprocedure('public.finalizar_orden_produccion_v24(uuid,jsonb,integer,integer,numeric,numeric,text,uuid)') is not null
    as finalizar_orden_ok,
  to_regprocedure('public.cancelar_orden_produccion_v24(uuid,text,boolean,uuid)') is not null
    as cancelar_orden_ok;

select e.enumlabel, true as instalado
from pg_enum e
join pg_type t on t.oid = e.enumtypid
join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public' and t.typname = 'tipo_movimiento'
  and e.enumlabel in (
    'produccion_salida_material', 'produccion_retorno_material',
    'produccion_ingreso_terminado'
  )
order by e.enumlabel;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'ordenes_produccion', 'orden_produccion_materiales',
    'entregas_materiales_produccion',
    'entrega_materiales_produccion_lineas', 'orden_produccion_eventos'
  )
order by tablename;

select
  has_function_privilege(
    'authenticated',
    'public.crear_orden_produccion_v24(uuid,uuid,uuid,uuid,integer,date,text,text,uuid)',
    'execute'
  ) as crear_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.finalizar_orden_produccion_v24(uuid,jsonb,integer,integer,numeric,numeric,text,uuid)',
    'execute'
  ) as finalizar_authenticated_ok,
  has_function_privilege(
    'anon',
    'public.finalizar_orden_produccion_v24(uuid,jsonb,integer,integer,numeric,numeric,text,uuid)',
    'execute'
  ) as finalizar_anon_debe_ser_false,
  has_function_privilege(
    'authenticated',
    'public.aplicar_movimiento_stock_v20(uuid,uuid,uuid,public.tipo_movimiento,integer,uuid,text,text,uuid,uuid,uuid)',
    'execute'
  ) as motor_directo_authenticated_debe_ser_false;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  case when p.proname in (
    'crear_orden_produccion_v24', 'entregar_materiales_produccion_v24',
    'finalizar_orden_produccion_v24', 'cancelar_orden_produccion_v24'
  ) then position('idempotencia es obligatoria' in pg_get_functiondef(p.oid)) > 0
  else null end as valida_idempotencia_si_corresponde
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'crear_orden_produccion_v24', 'resolver_orden_produccion_v24',
    'entregar_materiales_produccion_v24', 'finalizar_orden_produccion_v24',
    'cancelar_orden_produccion_v24'
  )
order by p.proname;

select position(
  'produccion_salida_material' in pg_get_functiondef(p.oid)
) > 0 as capacidad_productiva_en_trigger_ok
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'validar_capacidad_movimiento_v20';

select to_regprocedure('public.validar_tipo_componente_formula_v24()') is not null
    as filtro_materiales_formula_ok,
  exists (
    select 1 from information_schema.triggers
    where trigger_schema = 'public'
      and trigger_name = 'trg_validar_tipo_componente_formula_v24'
  ) as trigger_filtro_materiales_ok;

-- Todos los siguientes resultados deben ser cero.
select count(*) as ordenes_sin_materiales_debe_ser_cero
from public.ordenes_produccion o
where not exists (
  select 1 from public.orden_produccion_materiales m where m.orden_id = o.id
);

select count(*) as componentes_no_productivos_en_formula_debe_ser_cero
from public.formula_produccion_componentes c
join public.productos p on p.id = c.producto_id
where p.tipo_inventario not in (
  'materia_prima', 'insumo', 'empaque', 'subproducto'
);

select count(*) as materiales_sobreclasificados_debe_ser_cero
from public.orden_produccion_materiales
where cantidad_consumida + cantidad_merma + cantidad_devuelta > cantidad_entregada;

select count(*) as ordenes_completadas_con_wip_debe_ser_cero
from public.ordenes_produccion o
join public.orden_produccion_materiales m on m.orden_id = o.id
where o.estado in ('completada', 'cancelada')
  and m.cantidad_entregada <> m.cantidad_consumida + m.cantidad_merma + m.cantidad_devuelta;

select count(*) as entregas_sin_movimiento_debe_ser_cero
from public.entrega_materiales_produccion_lineas l
left join public.movimientos m on m.id = l.movimiento_id
where m.id is null or m.tipo::text <> 'produccion_salida_material';

select count(*) as entregas_sin_lineas_debe_ser_cero
from public.entregas_materiales_produccion e
where not exists (
  select 1 from public.entrega_materiales_produccion_lineas l
  where l.entrega_id = e.id
);

select count(*) as saldos_entregados_inconsistentes_debe_ser_cero
from public.orden_produccion_materiales m
left join lateral (
  select coalesce(sum(l.cantidad), 0)::integer entregado
  from public.entrega_materiales_produccion_lineas l
  where l.orden_material_id = m.id
) e on true
where m.cantidad_entregada <> e.entregado;

select count(*) as ingresos_terminados_sin_orden_debe_ser_cero
from public.movimientos m
where m.tipo::text = 'produccion_ingreso_terminado'
  and not exists (
    select 1 from public.ordenes_produccion o
    where o.id = m.grupo_id and o.estado = 'completada'
  );

select count(*) as resultados_conformes_sin_movimiento_debe_ser_cero
from public.ordenes_produccion o
left join lateral (
  select coalesce(sum(m.cantidad), 0)::integer ingresado
  from public.movimientos m
  where m.grupo_id = o.id and m.tipo::text = 'produccion_ingreso_terminado'
    and not coalesce(m.anulado, false)
) r on true
where o.estado = 'completada' and o.cantidad_conforme <> r.ingresado;

select count(*) as ordenes_completadas_sin_costo_debe_ser_cero
from public.ordenes_produccion
where estado = 'completada'
  and (costo_total_real is null or costo_unitario_real is null);

select count(*) as ordenes_completadas_sin_evento_debe_ser_cero
from public.ordenes_produccion o
where o.estado = 'completada' and not exists (
  select 1 from public.orden_produccion_eventos e
  where e.orden_id = o.id and e.tipo = 'completada'
);

select
  count(*) filter (where estado = 'pendiente_aprobacion') as pendientes_aprobacion,
  count(*) filter (where estado = 'aprobada') as aprobadas,
  count(*) filter (where estado = 'en_proceso') as en_proceso,
  count(*) filter (where estado = 'completada') as completadas,
  count(*) filter (where estado in ('rechazada', 'cancelada')) as cerradas_sin_produccion,
  coalesce(sum(cantidad_planificada) filter (
    where estado not in ('rechazada', 'cancelada')
  ), 0) as unidades_planificadas_vigentes
from public.ordenes_produccion;

select numero, empresa_codigo, resultado_sku, resultado_producto, estado,
       cantidad_planificada, cantidad_conforme, cantidad_no_conforme,
       unidades_base_planificadas, unidades_base_entregadas,
       unidades_base_en_proceso, costo_total_estimado,
       costo_total_real, costo_unitario_real
from public.vista_ordenes_produccion_v24
order by created_at desc;
