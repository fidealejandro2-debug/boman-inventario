-- ============================================================
-- Verificación v15 - Excepción admin para conteos propios
-- Solo lectura: no modifica datos.
-- ============================================================

select
  to_regprocedure('public.guardar_reconteo_inventario(uuid,jsonb,text)') is not null
    as rpc_reconteo_ok,
  to_regprocedure('public.resolver_conteo_inventario(uuid,boolean,text)') is not null
    as rpc_resolver_ok;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position(
    'v_rol <> ''admin''' in pg_get_functiondef(p.oid)
  ) > 0 as excepcion_admin_instalada
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('guardar_reconteo_inventario', 'resolver_conteo_inventario')
order by p.proname;

