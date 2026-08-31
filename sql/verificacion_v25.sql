-- ============================================================
-- Verificacion v25 - Rutas, etapas y lotes de produccion
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v25 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.rutas_produccion') is not null as rutas_ok,
  to_regclass('public.ruta_produccion_etapas') is not null as etapas_ruta_ok,
  to_regclass('public.formula_rutas_produccion') is not null as formula_rutas_ok,
  to_regclass('public.orden_produccion_etapas') is not null as etapas_orden_ok,
  to_regclass('public.orden_produccion_etapa_eventos') is not null as eventos_etapa_ok,
  to_regclass('public.lotes_produccion') is not null as lotes_ok;

select
  to_regprocedure('public.guardar_ruta_produccion_v25(uuid,uuid,text,text,text,jsonb)') is not null
    as guardar_ruta_ok,
  to_regprocedure('public.resolver_ruta_produccion_v25(uuid,boolean,text)') is not null
    as resolver_ruta_ok,
  to_regprocedure('public.asignar_ruta_formula_v25(uuid,uuid,text)') is not null
    as asignar_formula_ok,
  to_regprocedure('public.iniciar_etapa_produccion_v25(uuid,uuid,uuid,text,uuid)') is not null
    as iniciar_etapa_ok,
  to_regprocedure('public.completar_etapa_produccion_v25(uuid,integer,integer,numeric,text,uuid)') is not null
    as completar_etapa_ok,
  to_regprocedure('public.omitir_etapa_produccion_v25(uuid,text)') is not null
    as omitir_etapa_ok;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'ordenes_produccion'
  and column_name in (
    'ruta_id', 'ruta_codigo', 'ruta_version',
    'costo_etapas_estimado', 'costo_etapas_real'
  )
order by column_name;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'rutas_produccion', 'ruta_produccion_etapas',
    'formula_rutas_produccion', 'ruta_produccion_eventos',
    'orden_produccion_etapas', 'orden_produccion_etapa_eventos',
    'lotes_produccion'
  )
order by tablename;

select trigger_name, event_object_table, action_timing
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name in (
    'trg_normalizar_costo_estimado_orden_v25',
    'trg_preparar_etapas_orden_v25',
    'trg_validar_cierre_etapas_v25',
    'trg_generar_lote_produccion_v25'
  )
order by trigger_name;

select
  has_function_privilege(
    'authenticated',
    'public.guardar_ruta_produccion_v25(uuid,uuid,text,text,text,jsonb)',
    'execute'
  ) as guardar_ruta_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.iniciar_etapa_produccion_v25(uuid,uuid,uuid,text,uuid)',
    'execute'
  ) as iniciar_authenticated_ok,
  has_function_privilege(
    'anon',
    'public.completar_etapa_produccion_v25(uuid,integer,integer,numeric,text,uuid)',
    'execute'
  ) as completar_anon_debe_ser_false,
  has_function_privilege(
    'authenticated',
    'public.sembrar_etapas_orden_v25(uuid)',
    'execute'
  ) as sembrar_directo_authenticated_debe_ser_false;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  case when p.proname in (
    'iniciar_etapa_produccion_v25', 'completar_etapa_produccion_v25'
  ) then position('idempotencia es obligatoria' in pg_get_functiondef(p.oid)) > 0
  else null end as valida_idempotencia_si_corresponde
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'guardar_ruta_produccion_v25', 'resolver_ruta_produccion_v25',
    'asignar_ruta_formula_v25', 'iniciar_etapa_produccion_v25',
    'completar_etapa_produccion_v25', 'omitir_etapa_produccion_v25'
  )
order by p.proname;

-- Todos los siguientes resultados deben ser cero.
select count(*) as ordenes_sin_etapas_debe_ser_cero
from public.ordenes_produccion o
where not exists (
  select 1 from public.orden_produccion_etapas e where e.orden_id = o.id
);

select count(*) as ordenes_completadas_con_etapas_abiertas_debe_ser_cero
from public.ordenes_produccion o
where o.estado = 'completada' and exists (
  select 1 from public.orden_produccion_etapas e
  where e.orden_id = o.id and e.estado in ('pendiente', 'en_proceso')
);

select count(*) as ordenes_completadas_sin_lote_debe_ser_cero
from public.ordenes_produccion o
where o.estado = 'completada' and not exists (
  select 1 from public.lotes_produccion l where l.orden_id = o.id
);

select count(*) as lotes_sin_orden_completada_debe_ser_cero
from public.lotes_produccion l
join public.ordenes_produccion o on o.id = l.orden_id
where o.estado <> 'completada'
   or l.producto_id <> o.producto_resultado_id
   or l.empresa_id <> o.empresa_id
   or l.almacen_id <> o.almacen_terminado_id
   or l.cantidad_conforme <> o.cantidad_conforme
   or l.cantidad_no_conforme <> o.cantidad_no_conforme;

select count(*) as rutas_activas_duplicadas_debe_ser_cero
from (
  select grupo_id, codigo
  from public.rutas_produccion
  where estado = 'activa'
  group by grupo_id, codigo having count(*) > 1
) duplicadas;

select count(*) as rutas_activas_sin_etapas_debe_ser_cero
from public.rutas_produccion r
where r.estado = 'activa' and not exists (
  select 1 from public.ruta_produccion_etapas e where e.ruta_id = r.id
);

select count(*) as secuencias_ruta_incompletas_debe_ser_cero
from (
  select ruta_id, min(secuencia) minimo, max(secuencia) maximo, count(*) total
  from public.ruta_produccion_etapas group by ruta_id
) s
where s.minimo <> 1 or s.maximo <> s.total;

select count(*) as formulas_con_ruta_de_otro_grupo_debe_ser_cero
from public.formula_rutas_produccion fr
join public.formulas_produccion f on f.id = fr.formula_id
join public.rutas_produccion r on r.id = fr.ruta_id
where f.grupo_id <> r.grupo_id;

select count(*) as etapas_iniciadas_fuera_de_secuencia_debe_ser_cero
from public.orden_produccion_etapas e
where e.estado in ('en_proceso', 'completada') and exists (
  select 1 from public.orden_produccion_etapas anterior
  where anterior.orden_id = e.orden_id and anterior.secuencia < e.secuencia
    and anterior.estado not in ('completada', 'omitida')
);

select count(*) as etapas_completadas_sin_evento_debe_ser_cero
from public.orden_produccion_etapas e
where e.estado = 'completada' and e.ruta_etapa_id is not null
  and not exists (
    select 1 from public.orden_produccion_etapa_eventos ev
    where ev.etapa_id = e.id and ev.tipo = 'completada'
  );

select count(*) as etapas_con_cantidades_invalidas_debe_ser_cero
from public.orden_produccion_etapas e
join public.ordenes_produccion o on o.id = e.orden_id
where e.cantidad_no_conforme < 0
   or e.cantidad_no_conforme > coalesce(e.cantidad_procesada, 0)
   or coalesce(e.cantidad_procesada, 0) > o.cantidad_planificada;

select count(*) as costos_estimados_sin_etapas_debe_ser_cero
from public.ordenes_produccion
where costo_total_estimado <> round(
  costo_materiales_estimado + costo_mano_obra_estimado
    + costo_indirecto_estimado + costo_etapas_estimado, 6
);

select count(*) as costos_reales_sin_etapas_debe_ser_cero
from public.ordenes_produccion
where estado = 'completada' and costo_total_real <> round(
  coalesce(costo_materiales_real, 0) + coalesce(costo_mano_obra_real, 0)
    + coalesce(costo_indirecto_real, 0) + coalesce(costo_etapas_real, 0), 6
);

select
  count(*) filter (where estado = 'pendiente') as etapas_pendientes,
  count(*) filter (where estado = 'en_proceso') as etapas_en_proceso,
  count(*) filter (where estado = 'completada') as etapas_completadas,
  count(*) filter (where estado = 'omitida') as etapas_omitidas,
  coalesce(sum(costo_real), 0) as costo_real_etapas
from public.orden_produccion_etapas;

select
  count(*) as lotes_generados,
  coalesce(sum(cantidad_conforme), 0) as unidades_liberadas,
  coalesce(sum(cantidad_no_conforme), 0) as unidades_cuarentena
from public.lotes_produccion;

select numero, empresa_codigo, resultado_sku, resultado_producto, estado,
       ruta_codigo, ruta_version, etapas_total, etapas_completadas,
       etapas_omitidas, etapas_en_proceso, secuencia_actual,
       costo_etapas_real, lote_codigo, lote_estado_calidad
from public.vista_seguimiento_produccion_v25
order by created_at desc;
