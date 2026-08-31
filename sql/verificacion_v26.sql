-- ============================================================
-- Verificacion v26 - Nomina: personal y expediente
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v26 y nunca en paralelo con la migracion.
-- ============================================================

-- 1. Tablas creadas
select
  to_regclass('public.empleados') is not null as empleados_ok,
  to_regclass('public.empleado_afiliaciones') is not null as afiliaciones_ok,
  to_regclass('public.empleado_compensacion') is not null as compensacion_ok,
  to_regclass('public.empleado_documentos') is not null as documentos_ok,
  to_regclass('public.nomina_parametros') is not null as parametros_ok,
  to_regclass('public.nomina_eventos') is not null as eventos_ok,
  to_regclass('public.vista_personal_vigente') is not null as vista_personal_ok,
  to_regclass('public.vista_documentos_por_vencer') is not null as vista_vencer_ok;

-- 2. El rol 'nomina' quedo agregado en el PASO 1
select exists (
  select 1 from pg_enum e
  join pg_type t on t.oid = e.enumtypid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'rol_usuario'
    and e.enumlabel = 'nomina'
) as rol_nomina_ok;

-- 3. Funciones instaladas
select
  to_regprocedure('public.usuario_puede_nomina(boolean)') is not null
    as usuario_puede_nomina_ok,
  to_regprocedure('public.es_cedula_ecuatoriana(text)') is not null
    as es_cedula_ok,
  to_regprocedure('public.guardar_empleado_v26(uuid,uuid,text,text,text,text,date,text,date,text,text,text,text,text,text,text,text,text,text,text,text,text)') is not null
    as guardar_empleado_ok,
  to_regprocedure('public.dar_baja_empleado_v26(uuid,date,text)') is not null
    as dar_baja_ok,
  to_regprocedure('public.registrar_afiliacion_v26(uuid,boolean,uuid,date,numeric,date,text,uuid)') is not null
    as registrar_afiliacion_ok,
  to_regprocedure('public.registrar_compensacion_v26(uuid,uuid,numeric,date,text,uuid)') is not null
    as registrar_compensacion_ok,
  to_regprocedure('public.registrar_documento_empleado_v26(uuid,text,text,text,text,bigint,date,date)') is not null
    as registrar_documento_ok,
  to_regprocedure('public.archivar_documento_empleado_v26(uuid,text)') is not null
    as archivar_documento_ok,
  to_regprocedure('public.registrar_consulta_expediente_v26(uuid)') is not null
    as consulta_expediente_ok,
  to_regprocedure('public.guardar_nomina_parametros_v26(integer,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric)') is not null
    as guardar_parametros_ok;

-- 4. Validador de cedula: todas las columnas deben dar true
select
  public.es_cedula_ecuatoriana('1710034065') as valida_debe_ser_true,
  not public.es_cedula_ecuatoriana('1710034064') as digito_malo_debe_ser_true,
  not public.es_cedula_ecuatoriana('9910034065') as provincia_mala_debe_ser_true,
  not public.es_cedula_ecuatoriana('1760034065') as tercer_digito_debe_ser_true,
  not public.es_cedula_ecuatoriana('171003406')  as corta_debe_ser_true,
  not public.es_cedula_ecuatoriana('17100340AB') as no_numerica_debe_ser_true,
  not public.es_cedula_ecuatoriana(null)         as nula_debe_ser_true;

-- 5. RLS activa en todas las tablas del modulo
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'empleados', 'empleado_afiliaciones', 'empleado_compensacion',
    'empleado_documentos', 'nomina_parametros', 'nomina_eventos'
  )
order by tablename;

-- 6. Indices unicos parciales: una sola afiliacion y una sola compensacion
--    vigentes por empleado, una sola firma y una sola foto activas.
select indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and indexname in (
    'uq_empleado_afiliacion_vigente',
    'uq_empleado_compensacion_vigente',
    'uq_empleado_documento_unico_vigente'
  )
order by indexname;

-- 6b. Las vistas deben respetar el RLS de las tablas base.
--     Sin security_invoker cualquier autenticado leeria sueldos reales.
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
  and c.relname in ('vista_personal_vigente', 'vista_documentos_por_vencer')
order by c.relname;

-- 7. Permisos: anon nunca ejecuta nada de nomina
select
  has_function_privilege(
    'authenticated',
    'public.guardar_empleado_v26(uuid,uuid,text,text,text,text,date,text,date,text,text,text,text,text,text,text,text,text,text,text,text,text)',
    'execute'
  ) as guardar_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.guardar_empleado_v26(uuid,uuid,text,text,text,text,date,text,date,text,text,text,text,text,text,text,text,text,text,text,text,text)',
    'execute'
  ) as guardar_anon_debe_ser_true,
  not has_function_privilege(
    'anon',
    'public.registrar_afiliacion_v26(uuid,boolean,uuid,date,numeric,date,text,uuid)',
    'execute'
  ) as afiliacion_anon_debe_ser_true,
  not has_function_privilege(
    'authenticated',
    'public.registrar_evento_nomina_v26(text,uuid,uuid,text,text)',
    'execute'
  ) as evento_solo_interno_debe_ser_true;

-- 8. Todas security definer y propiedad de postgres
select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'usuario_puede_nomina', 'guardar_empleado_v26', 'dar_baja_empleado_v26',
    'registrar_afiliacion_v26', 'registrar_compensacion_v26',
    'registrar_documento_empleado_v26', 'archivar_documento_empleado_v26',
    'guardar_nomina_parametros_v26'
  )
order by p.proname;

-- 9. El bucket del expediente existe y es privado
select id, public as debe_ser_false
from storage.buckets
where id = 'expedientes';

-- 10. Politicas del bucket: lectura, carga y actualizacion, nunca borrado
select policyname, cmd
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and policyname like '%expedientes_v26'
order by policyname;

-- ------------------------------------------------------------
-- Consistencia de datos. Todos los conteos deben ser cero.
-- ------------------------------------------------------------

-- Empleados activos sin afiliacion vigente registrada
select count(*) as activos_sin_afiliacion_debe_ser_cero
from public.empleados e
where e.estado = 'activo'
  and not exists (
    select 1 from public.empleado_afiliaciones a
    where a.empleado_id = e.id and a.fecha_hasta is null
  );

-- Empleados activos sin sueldo real vigente
select count(*) as activos_sin_compensacion_debe_ser_cero
from public.empleados e
where e.estado = 'activo'
  and not exists (
    select 1 from public.empleado_compensacion c
    where c.empleado_id = e.id and c.fecha_hasta is null
  );

-- Afiliaciones incoherentes con el ingreso real
select count(*) as afiliacion_antes_del_ingreso_debe_ser_cero
from public.empleado_afiliaciones a
join public.empleados e on e.id = a.empleado_id
where a.fecha_afiliacion is not null
  and a.fecha_afiliacion < e.fecha_ingreso_real;

-- Historial solapado: dos vigencias abiertas a la vez
select count(*) as afiliaciones_solapadas_debe_ser_cero
from (
  select empleado_id from public.empleado_afiliaciones
  where fecha_hasta is null
  group by empleado_id having count(*) > 1
) t;

select count(*) as compensaciones_solapadas_debe_ser_cero
from (
  select empleado_id from public.empleado_compensacion
  where fecha_hasta is null
  group by empleado_id having count(*) > 1
) t;

-- Documentos cuyo path no apunta a la carpeta de su propio empleado
select count(*) as documentos_con_ruta_ajena_debe_ser_cero
from public.empleado_documentos
where storage_path <> 'empleados/' || empleado_id::text || '/'
                      || split_part(storage_path, '/', 3);

-- ------------------------------------------------------------
-- Panorama del personal cargado (informativo, no es una prueba)
-- ------------------------------------------------------------
select
  count(*) as total_activos,
  count(*) filter (where afiliado) as afiliados,
  count(*) filter (where afiliado is not true) as no_afiliados,
  count(*) filter (where paga_otro_ruc) as paga_otro_ruc,
  count(*) filter (where dias_entre_ingreso_y_afiliacion > 0) as afiliados_despues_de_ingresar,
  sum(brecha_sueldo) as brecha_total
from public.vista_personal_vigente
where estado = 'activo';

select
  empresa_afiliacion,
  count(*) as personas,
  sum(sueldo_declarado) as total_declarado,
  sum(sueldo_real) as total_real
from public.vista_personal_vigente
where estado = 'activo'
group by empresa_afiliacion
order by empresa_afiliacion nulls last;
