-- ============================================================
-- Verificacion v39 - El rol nomina puede leer las empresas
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v39.
-- ============================================================

-- 1. La funcion contempla al rol nomina para lectura
select
  position('''gerencia'', ''nomina''' in pg_get_functiondef(
    'public.usuario_puede_empresa(uuid,boolean)'::regprocedure
  )) > 0 as nomina_incluida_ok,
  -- y NO le da escritura: sigue detras de not p_escritura
  position('not p_escritura and p.rol::text in (''gerencia'', ''nomina'')' in pg_get_functiondef(
    'public.usuario_puede_empresa(uuid,boolean)'::regprocedure
  )) > 0 as nomina_solo_lectura_ok;

-- 2. Sigue siendo security definer y de postgres
select
  p.prosecdef as security_definer_ok,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'usuario_puede_empresa';

-- 3. anon no la ejecuta
select
  has_function_privilege('authenticated', 'public.usuario_puede_empresa(uuid,boolean)', 'execute')
    as authenticated_ok,
  not has_function_privilege('anon', 'public.usuario_puede_empresa(uuid,boolean)', 'execute')
    as anon_debe_ser_true;

-- 4. La politica de lectura de empresas sigue apoyada en ella
select policyname, cmd, qual
from pg_policies
where schemaname = 'public' and tablename = 'empresas' and policyname = 'leer_empresas';

-- ------------------------------------------------------------
-- Prueba con usuarios reales (informativo)
-- ------------------------------------------------------------
-- Cuantas empresas activas hay en total
select count(*) as empresas_activas from public.empresas where activo;

-- Usuarios de nomina que deberian verlas todas a partir de ahora
select id, nombre_completo, rol
from public.perfiles
where rol::text = 'nomina' and activo;

-- Comprobacion final: ejecutar ESTA consulta con la sesion de un usuario de
-- nomina (desde la app, no desde el editor SQL, que corre como postgres).
-- Debe devolver las empresas activas y ya no un conjunto vacio:
--   select id, razon_social from public.empresas where activo order by razon_social;
