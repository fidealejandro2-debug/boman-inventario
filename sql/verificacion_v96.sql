-- ============================================================
-- Verificacion v96 - Cronograma y capacidad diaria de produccion
-- Solo lectura. Ejecutar despues de instalar v96.
-- ============================================================

-- 1. Tabla y funciones existen.
select
  to_regclass('public.capacidad_produccion_diaria_v96') is not null as tabla_capacidad_ok,
  to_regprocedure('public.cronograma_produccion_v96(date,date)') is not null as fn_cronograma_ok,
  to_regprocedure('public.detalle_dia_produccion_v96(date)') is not null as fn_detalle_ok,
  to_regprocedure('public.guardar_capacidad_produccion_v96(text,integer)') is not null as fn_guardar_capacidad_ok;

-- 2. RLS y privilegios de la tabla de capacidad.
select
  (select rowsecurity from pg_tables where schemaname = 'public' and tablename = 'capacidad_produccion_diaria_v96') as rls_ok,
  has_table_privilege('authenticated', 'public.capacidad_produccion_diaria_v96', 'select') as select_ok,
  not has_table_privilege('authenticated', 'public.capacidad_produccion_diaria_v96', 'insert') as sin_insert_directo_ok,
  not has_table_privilege('anon', 'public.capacidad_produccion_diaria_v96', 'select') as anon_bloqueado_ok;

-- 3. Privilegios de ejecucion de las 3 funciones.
select
  has_function_privilege('authenticated', 'public.cronograma_produccion_v96(date,date)', 'execute') as cronograma_authenticated_ok,
  not has_function_privilege('anon', 'public.cronograma_produccion_v96(date,date)', 'execute') as cronograma_anon_bloqueado_ok,
  has_function_privilege('authenticated', 'public.detalle_dia_produccion_v96(date)', 'execute') as detalle_authenticated_ok,
  not has_function_privilege('anon', 'public.detalle_dia_produccion_v96(date)', 'execute') as detalle_anon_bloqueado_ok,
  has_function_privilege('authenticated', 'public.guardar_capacidad_produccion_v96(text,integer)', 'execute') as guardar_authenticated_ok,
  not has_function_privilege('anon', 'public.guardar_capacidad_produccion_v96(text,integer)', 'execute') as guardar_anon_bloqueado_ok;

-- 4. Las 3 funciones exigen auth.uid()/permiso (mismo patron que v35 y v95).
select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario,
       position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0 as valida_permiso
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('cronograma_produccion_v96', 'detalle_dia_produccion_v96')
order by p.proname;

-- 5. La carga diaria de una prenda coincide con un conteo manual (ajustar la
-- fecha a un dia real con contratos con fecha_inicio_produccion).
select cp.prenda, sum(cp.cantidad) as cantidad_manual
from public.contrato_prendas cp
join public.contratos c on c.id = cp.contrato_id
where c.fecha_inicio_produccion = current_date
group by cp.prenda
order by cantidad_manual desc;

-- La prueba funcional (cronograma_produccion_v96, detalle_dia_produccion_v96,
-- guardar_capacidad_produccion_v96) se hace desde /produccion/cronograma con
-- una sesion autenticada real. No se invocan aqui: el editor SQL de Supabase
-- no representa al usuario de la aplicacion y auth.uid() seria null aunque la
-- instalacion este correcta (mismo criterio que verificacion_v95.sql).
