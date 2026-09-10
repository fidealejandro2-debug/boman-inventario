-- ============================================================
-- Verificacion v118 - Datos comerciales editables desde el expediente
-- Solo lectura. Ejecutar despues de instalar v118.
-- ============================================================

-- 1) La funcion sigue existiendo con la misma firma (la ruta y la pantalla no
--    cambian: v118 la reemplaza, no crea una nueva).
select to_regprocedure('public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)') is not null as funcion_ok;

-- 2) Los cuatro campos nuevos estan en la lista blanca y las finanzas NO.
--    Presupuesto y abono se tocan por ajustar_finanzas_contrato_v100.
select
  position('nombre_contrato_v115' in pg_get_functiondef(p.oid)) > 0 as nombre_ok,
  position('''cliente''' in pg_get_functiondef(p.oid)) > 0 as cliente_ok,
  position('''vendedor''' in pg_get_functiondef(p.oid)) > 0 as vendedor_ok,
  position('''canal''' in pg_get_functiondef(p.oid)) > 0 as canal_ok,
  position('presupuesto' in pg_get_functiondef(p.oid)) = 0 as finanzas_fuera_ok
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='guardar_gestion_contrato_v99';

-- 3) Sigue siendo security definer y pidiendo el permiso correcto.
select p.prosecdef as security_definer,
       position('contratos.editar' in pg_get_functiondef(p.oid)) > 0 as controla_permiso
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='guardar_gestion_contrato_v99';

-- 4) Privilegios: authenticated si, anon no.
select
  has_function_privilege('authenticated','public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)','execute') as auth_ok,
  not has_function_privilege('anon','public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)','execute') as anon_bloqueado_ok;

-- 5) La via de las finanzas sigue en pie y protegida.
select
  to_regprocedure('public.ajustar_finanzas_contrato_v100(uuid,numeric,numeric,text,uuid)') is not null as ajuste_ok,
  exists(select 1 from pg_trigger where tgname='trg_proteger_finanzas_contrato_v102') as trigger_ok;

-- 6) Cambios comerciales ya auditados (vacio hasta que se use la pantalla).
select campo, count(*) as veces, max(created_at) as ultimo
  from public.contrato_eventos
 where campo in ('nombre_contrato_v115','cliente','vendedor','canal')
 group by campo
 order by veces desc;
