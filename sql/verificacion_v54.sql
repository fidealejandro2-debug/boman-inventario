-- ============================================================
-- Verificacion v54 - Mantenimiento de maquinaria y activos
-- Solo lectura: ejecutar despues de instalar v54.
-- ============================================================

select
  to_regclass('public.activos_mantenimiento') is not null as activos_ok,
  to_regclass('public.ordenes_mantenimiento') is not null as ordenes_ok,
  to_regclass('public.mantenimiento_eventos') is not null as eventos_ok,
  to_regclass('public.vista_activos_mantenimiento_v54') is not null as vista_activos_ok,
  to_regclass('public.vista_ordenes_mantenimiento_v54') is not null as vista_ordenes_ok;

select
  to_regprocedure('public.puede_ver_activo_mantenimiento_v54(uuid,boolean)') is not null as alcance_ok,
  to_regprocedure('public.guardar_activo_mantenimiento_v54(uuid,jsonb,text,uuid)') is not null as guardar_ok,
  to_regprocedure('public.crear_orden_mantenimiento_v54(uuid,text,text,date,text,uuid,numeric,uuid)') is not null as crear_orden_ok,
  to_regprocedure('public.cambiar_estado_orden_mantenimiento_v54(uuid,text,jsonb,text,uuid)') is not null as flujo_ok,
  to_regprocedure('public.sincronizar_alertas_mantenimiento_v54()') is not null as alertas_ok,
  to_regprocedure('public.resumen_mantenimiento_v54()') is not null as resumen_ok;

select codigo, activo
from public.permisos_sistema
where codigo in ('notificaciones.acceder', 'notificaciones.publicar',
  'mantenimiento.acceder', 'mantenimiento.editar')
order by codigo;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('activos_mantenimiento', 'ordenes_mantenimiento', 'mantenimiento_eventos')
order by tablename;

select c.relname,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
    where option_name = 'security_invoker'), 'false') as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('vista_activos_mantenimiento_v54', 'vista_ordenes_mantenimiento_v54')
order by c.relname;

select
  has_function_privilege('authenticated',
    'public.resumen_mantenimiento_v54()', 'execute') as resumen_authenticated_ok,
  not has_function_privilege('anon',
    'public.guardar_activo_mantenimiento_v54(uuid,jsonb,text,uuid)', 'execute')
    as guardar_anon_debe_ser_true,
  not has_table_privilege('authenticated', 'public.activos_mantenimiento', 'insert')
    as insert_directo_activos_debe_ser_true,
  not has_table_privilege('authenticated', 'public.ordenes_mantenimiento', 'update')
    as update_directo_ordenes_debe_ser_true;

-- Todos los siguientes resultados deben ser cero.
select count(*) as activos_fuera_de_empresa_debe_ser_cero
from public.activos_mantenimiento a
join public.empresas e on e.id = a.empresa_id
where a.grupo_id <> e.grupo_id
  or (a.almacen_id is not null and not exists (
    select 1 from public.empresa_almacenes ea
    where ea.empresa_id = a.empresa_id and ea.almacen_id = a.almacen_id
  ));

select count(*) as ordenes_fuera_de_activo_debe_ser_cero
from public.ordenes_mantenimiento o
join public.activos_mantenimiento a on a.id = o.activo_id
where o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
  and (o.empresa_id <> a.empresa_id
   or o.almacen_id is distinct from a.almacen_id);

select count(*) as activos_con_multiples_ordenes_abiertas_debe_ser_cero
from (
  select activo_id
  from public.ordenes_mantenimiento
  where estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
  group by activo_id having count(*) > 1
) x;

select count(*) as ordenes_cerradas_incompletas_debe_ser_cero
from public.ordenes_mantenimiento
where (estado = 'completada' and (
    fin_at is null or btrim(coalesce(trabajo_realizado, '')) = '' or costo_real is null
  )) or (estado = 'cancelada' and (
    fin_at is null or btrim(coalesce(cancelacion_motivo, '')) = ''
  ));

select count(*) as ordenes_activas_sin_notificacion_debe_ser_cero
from public.ordenes_mantenimiento o
where o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
  and not exists (
    select 1 from public.notificaciones_comunicados n
    where n.origen_clave = 'mantenimiento:orden:' || o.id::text and n.activo
  );

select count(*) as eventos_incompletos_debe_ser_cero
from public.mantenimiento_eventos
where usuario_id is null or idempotency_key is null
  or btrim(coalesce(detalle, '')) = '';

-- No se ejecuta resumen_mantenimiento_v54 aqui: respeta permisos y alcance de
-- auth.uid(). Se valida su definicion y se muestra un panorama global neutro.
select
  position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0
    as controla_permiso,
  position('puede_ver_activo_mantenimiento_v54' in pg_get_functiondef(p.oid)) > 0
    as controla_alcance,
  position('''ordenes_atrasadas''' in pg_get_functiondef(p.oid)) > 0
    as devuelve_contrato_panel
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resumen_mantenimiento_v54';

select
  count(*) filter (where activo and estado <> 'baja') as activos_vigentes,
  count(*) filter (where activo and estado in ('detenido', 'fuera_servicio'))
    as activos_detenidos,
  count(*) filter (where activo and estado <> 'baja'
    and proximo_mantenimiento_fecha <
      (now() at time zone 'America/Guayaquil')::date) as mantenimientos_vencidos
from public.activos_mantenimiento;

select
  count(*) filter (where estado in (
    'solicitada', 'programada', 'en_proceso', 'en_espera'
  )) as ordenes_abiertas,
  count(*) filter (where estado in ('solicitada', 'programada')
    and fecha_programada <
      (now() at time zone 'America/Guayaquil')::date) as ordenes_atrasadas,
  coalesce(sum(costo_real) filter (where estado = 'completada'), 0)
    as costo_real_acumulado
from public.ordenes_mantenimiento;
