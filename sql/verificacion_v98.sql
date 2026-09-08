-- ============================================================
-- Verificacion v98 - Reportes de produccion
-- Solo lectura. Ejecutar despues de instalar v98.
-- ============================================================

-- 1. La funcion existe.
select to_regprocedure('public.reporte_produccion_v98(date,date,text)') is not null as fn_ok;

-- 2. Privilegios de ejecucion.
select
  has_function_privilege('authenticated', 'public.reporte_produccion_v98(date,date,text)', 'execute') as authenticated_ok,
  not has_function_privilege('anon', 'public.reporte_produccion_v98(date,date,text)', 'execute') as anon_bloqueado_ok;

-- 3. Exige auth.uid()/permiso (mismo patron que v35, v95 y v96).
select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario,
       position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0 as valida_permiso
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'reporte_produccion_v98';

-- 4. Conteo manual de prendas del rango, para comparar contra la fila
-- correspondiente del reporte agrupado por prenda una vez probado desde la app.
select cp.prenda, sum(cp.cantidad) as cantidad_manual
from public.contrato_prendas cp
join public.contratos c on c.id = cp.contrato_id
where c.fecha_entrega between current_date - 30 and current_date
  and lower(c.estado) <> 'entregado'
group by cp.prenda
order by cantidad_manual desc
limit 10;

-- La prueba funcional (las 4 agrupaciones de reporte_produccion_v98, y que su
-- total_prendas por 'prenda' coincida con los KPI de /produccion/dashboard
-- para el mismo rango) se hace desde /produccion/reportes con una sesion
-- autenticada real. No se invoca aqui la RPC: el editor SQL de Supabase no
-- representa al usuario de la aplicacion y auth.uid() seria null aunque la
-- instalacion este correcta (mismo criterio que verificacion_v95.sql).
