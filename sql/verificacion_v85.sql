-- ============================================================
-- Verificacion v85 - Recuperar conteo tras toma de control admin
-- Solo lectura. Ejecutar despues de instalar v85.
-- ============================================================

-- 1. La funcion incluye la rama de recuperacion (responsable actual
-- admin/control) ademas de la rama de admin forzando.
select pg_get_functiondef(p.oid) like '%v_responsable_rol%'
  and pg_get_functiondef(p.oid) like '%''admin'', ''control''%' as incluye_recuperacion
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'abrir_edicion_conteo_v22';

-- 2. Sigue exigiendo motivo para cualquier toma de control (en cualquier
-- direccion).
select pg_get_functiondef(p.oid) like '%La toma de control requiere un motivo%'
  as exige_motivo
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'abrir_edicion_conteo_v22';

-- 3. Privilegios sin cambios de superficie.
select
  has_function_privilege('authenticated', 'public.abrir_edicion_conteo_v22(uuid,boolean,text)', 'execute') as authenticated_ok,
  not has_function_privilege('anon', 'public.abrir_edicion_conteo_v22(uuid,boolean,text)', 'execute') as anon_bloqueado_ok;

-- 4. Historico: cada evento de toma de control tiene motivo no vacio,
-- sin importar la direccion (admin->vendedor o vendedor<-admin).
select count(*) as eventos_sin_motivo_debe_ser_cero
from public.conteo_responsable_eventos
where btrim(coalesce(motivo, '')) = '';
