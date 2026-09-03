-- ============================================================
-- Verificacion v74 - Novedades de calidad de produccion
-- Solo lectura: ejecutar despues de instalar v74.
-- ============================================================

select
  to_regclass('public.novedades_calidad_produccion') is not null as novedades_ok,
  to_regclass('public.novedad_calidad_evidencias') is not null as evidencias_ok,
  to_regclass('public.novedad_calidad_eventos') is not null as eventos_ok,
  to_regclass('public.vista_novedades_calidad_v74') is not null as vista_ok;

select
  to_regprocedure('public.usuario_puede_calidad_v74(uuid,text)') is not null
    as acceso_ok,
  to_regprocedure('public.listar_empleados_calidad_v74()') is not null
    as empleados_ok,
  to_regprocedure('public.registrar_novedad_calidad_v74(jsonb,uuid)') is not null
    as registrar_ok,
  to_regprocedure('public.resolver_novedad_calidad_v74(uuid,jsonb,uuid)') is not null
    as resolver_ok,
  to_regprocedure('public.agregar_evidencia_calidad_v74(uuid,text,text,text,uuid)') is not null
    as evidencia_ok,
  to_regprocedure('public.anular_novedad_calidad_v74(uuid,text,uuid)') is not null
    as anular_ok,
  to_regprocedure('public.generar_novedad_laboral_calidad_v74(uuid,uuid,text,text,uuid)') is not null
    as derivar_nomina_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'novedades_calidad_produccion', 'novedad_calidad_evidencias',
    'novedad_calidad_eventos'
  )
order by tablename;

select exists (
  select 1 from information_schema.columns
  where table_schema = 'public'
    and table_name = 'novedades_calidad_produccion'
    and column_name = 'formato'
) as formato_prenda_ok;

select c.relname,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
    where option_name = 'security_invoker'), 'false')
    as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_novedades_calidad_v74';

select
  has_function_privilege(
    'authenticated', 'public.registrar_novedad_calidad_v74(jsonb,uuid)', 'execute'
  ) as registrar_authenticated_ok,
  not has_function_privilege(
    'anon', 'public.registrar_novedad_calidad_v74(jsonb,uuid)', 'execute'
  ) as registrar_anon_revocado,
  not has_table_privilege(
    'authenticated', 'public.novedades_calidad_produccion', 'insert'
  ) as insert_directo_revocado,
  not has_table_privilege(
    'authenticated', 'public.novedades_calidad_produccion', 'update'
  ) as update_directo_revocado;

select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'usuario_puede_calidad_v74', 'listar_empleados_calidad_v74',
  'registrar_novedad_calidad_v74', 'resolver_novedad_calidad_v74',
  'agregar_evidencia_calidad_v74', 'anular_novedad_calidad_v74',
  'generar_novedad_laboral_calidad_v74'
)
order by p.proname;

-- Todos los siguientes resultados deben ser cero.
select count(*) as etapas_de_otra_orden_debe_ser_cero
from public.novedades_calidad_produccion n
join public.orden_produccion_etapas e on e.id = n.etapa_id
where e.orden_id <> n.orden_id;

select count(*) as ordenes_de_otro_grupo_o_empresa_debe_ser_cero
from public.novedades_calidad_produccion n
join public.ordenes_produccion o on o.id = n.orden_id
where o.grupo_id <> n.grupo_id or o.empresa_id <> n.empresa_id
   or o.producto_resultado_id <> n.producto_id;

select count(*) as lotes_de_otra_orden_debe_ser_cero
from public.novedades_calidad_produccion n
join public.lotes_produccion l on l.id = n.lote_id
where l.orden_id <> n.orden_id;

select count(*) as responsables_internos_ajenos_debe_ser_cero
from public.novedades_calidad_produccion n
join public.perfiles p on p.id = n.responsable_perfil_id
where p.grupo_id <> n.grupo_id;

select count(*) as empleados_descuento_ajenos_debe_ser_cero
from public.novedades_calidad_produccion n
join public.empleados e on e.id = n.empleado_responsable_id
where e.grupo_id <> n.grupo_id;

select count(*) as solicitudes_descuento_incompletas_debe_ser_cero
from public.novedades_calidad_produccion
where solicita_descuento and (
  empleado_responsable_id is null
  or coalesce(monto_descuento_solicitado, 0) <= 0
  or length(btrim(coalesce(motivo_descuento, ''))) < 10
);

select count(*) as descuentos_sin_solicitud_debe_ser_cero
from public.novedades_calidad_produccion
where novedad_empleado_id is not null and not solicita_descuento;

select count(*) as novedades_laborales_inconsistentes_debe_ser_cero
from public.novedades_calidad_produccion q
join public.novedades_empleado n on n.id = q.novedad_empleado_id
where n.empleado_id <> q.empleado_responsable_id
   or n.tipo <> 'sancion_economica'
   or not n.genera_descuento
   or n.monto_descuento <> q.monto_descuento_solicitado;

select count(*) as cierres_incompletos_debe_ser_cero
from public.novedades_calidad_produccion
where estado = 'cerrada' and (
  length(btrim(coalesce(causa_raiz, ''))) < 10
  or length(btrim(coalesce(accion_correctiva, ''))) < 10
  or disposicion is null or costo_real is null
  or cerrado_por is null or cerrado_at is null
);

select count(*) as eventos_incompletos_debe_ser_cero
from public.novedad_calidad_eventos
where usuario_id is null or idempotency_key is null
   or length(btrim(detalle)) < 5;

select count(*) as abiertas_sin_alerta_activa_debe_ser_cero
from public.novedades_calidad_produccion n
where n.estado not in ('cerrada', 'anulada') and not exists (
  select 1 from public.notificaciones_comunicados c
  where c.origen_clave = 'calidad:resolver:' || n.id::text and c.activo
);

select count(*) as descuentos_cerrados_sin_alerta_debe_ser_cero
from public.novedades_calidad_produccion n
where n.estado = 'cerrada' and n.solicita_descuento
  and n.novedad_empleado_id is null and not exists (
    select 1 from public.notificaciones_comunicados c
    where c.origen_clave = 'calidad:descuento:' || n.id::text and c.activo
  );

select estado, prioridad, count(*) as novedades,
       coalesce(sum(cantidad_afectada), 0) as unidades_afectadas,
       coalesce(sum(costo_real), 0) as costo_real
from public.novedades_calidad_produccion
group by estado, prioridad
order by estado, prioridad;

select tipo, count(*) as novedades,
       coalesce(sum(cantidad_afectada), 0) as unidades_afectadas,
       coalesce(sum(costo_real), 0) as costo_real
from public.novedades_calidad_produccion
where estado <> 'anulada'
group by tipo
order by novedades desc, tipo;
