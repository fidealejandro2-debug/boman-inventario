-- Verificacion v156. Solo lectura; ejecutar despues de la migracion.

select to_regprocedure('public.ranking_locales_v156(date,date)') is not null as rpc_ok;

select
  has_function_privilege('authenticated','public.ranking_locales_v156(date,date)','execute') as ejecutable_authenticated,
  not has_function_privilege('anon','public.ranking_locales_v156(date,date)','execute') as bloqueada_anon;

-- El RPC valida permiso por auth.uid() en su cuerpo (no solo por GRANT), asi
-- que ejecutarlo desde el SQL Editor sin sesion real siempre lanza "No
-- tienes permiso...". Se valida la fuente en su lugar, sin simular sesion.
select
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('franquicia.consolidado' in pg_get_functiondef(p.oid)) > 0 as valida_permiso,
  position('America/Guayaquil' in pg_get_functiondef(p.oid)) > 0 as usa_fecha_ecuador
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'ranking_locales_v156';
