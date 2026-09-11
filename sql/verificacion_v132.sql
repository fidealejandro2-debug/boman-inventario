-- ============================================================
-- Verificacion v132 - Inicio atomico del importador
-- Solo lectura. Ejecutar despues de v132.
-- ============================================================

select
  to_regprocedure('public.iniciar_importacion_bomansport_v132(text,uuid)') is not null
    as inicio_atomico_ok,
  not has_function_privilege(
    'authenticated', 'public.iniciar_importacion_bomansport_v132(text,uuid)', 'execute'
  ) as authenticated_revocado_ok,
  has_function_privilege(
    'service_role', 'public.iniciar_importacion_bomansport_v132(text,uuid)', 'execute'
  ) as service_role_ok;

select
  position('pg_advisory_xact_lock' in pg_get_functiondef(p.oid)) > 0 as bloqueo_ok,
  position('interval ''10 minutes''' in pg_get_functiondef(p.oid)) > 0 as recupera_abandonadas_ok,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'iniciar_importacion_bomansport_v132';

-- Debe ser cero en operacion normal.
select count(*) as importaciones_frescas_simultaneas_debe_ser_cero
from (
  select count(*) as total
  from public.bomansport_importaciones
  where estado = 'en_curso' and iniciado_en > now() - interval '10 minutes'
) x
where x.total > 1;
