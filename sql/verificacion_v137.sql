-- ============================================================
-- Verificacion v137 - Perfil de navegacion rapido
-- Solo lectura. Ejecutar despues de v137.
-- ============================================================

select
  to_regprocedure('public.perfil_navegacion_v137()') is not null
    as perfil_navegacion_ok,
  has_function_privilege(
    'authenticated', 'public.perfil_navegacion_v137()', 'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon', 'public.perfil_navegacion_v137()', 'execute'
  ) as anon_sin_execute_ok;

select
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('permisos_usuario_actual_v35' in pg_get_functiondef(p.oid)) > 0
    as incluye_permisos,
  position('modo_boman_especifico_activo' in pg_get_functiondef(p.oid)) > 0
    as incluye_modo,
  position('estaciones_usuario_actual_v117' in pg_get_functiondef(p.oid)) > 0
    as incluye_estaciones,
  position('clave_temporal_desde' in pg_get_functiondef(p.oid)) > 0
    as incluye_control_clave_temporal
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'perfil_navegacion_v137';

select count(*) as registro_migracion_debe_ser_uno
from public.schema_migrations_boman
where id = 'v137' and archivo = 'v137_perfil_navegacion_rapida.sql';
