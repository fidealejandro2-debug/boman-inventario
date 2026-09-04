-- ============================================================
-- Verificacion v84 - Franquiciado aprueba su propio conteo
-- Solo lectura. Ejecutar despues de instalar v84.
-- ============================================================

-- 1. Las dos funciones incluyen los roles de franquicia.
select p.proname,
       pg_get_functiondef(p.oid) like '%franquiciado%'
       and pg_get_functiondef(p.oid) like '%vendedor_franquicia%' as incluye_roles_franquicia
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('guardar_reconteo_inventario', 'resolver_conteo_inventario')
order by p.proname;

-- 2. Ambas exigen usuario_puede_almacen para el rol de franquicia (limite
-- que admin/control no necesitan, pero franquicia si).
select p.proname,
       pg_get_functiondef(p.oid) like '%usuario_puede_almacen(d.origen_id, true)%' as limita_por_almacen
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('guardar_reconteo_inventario', 'resolver_conteo_inventario')
order by p.proname;

-- 3. La regla de integridad de datos sigue intacta: diferencias sin
-- segundo conteo bloquean la aprobacion, sea quien sea que la ejecute.
select pg_get_functiondef(p.oid) like '%Las diferencias requieren un segundo conteo antes de aprobar%'
  as regla_diferencias_intacta
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resolver_conteo_inventario';

-- 4. Privilegios sin cambios de superficie.
select
  has_function_privilege('authenticated', 'public.guardar_reconteo_inventario(uuid,jsonb,text)', 'execute') as guardar_authenticated_ok,
  has_function_privilege('authenticated', 'public.resolver_conteo_inventario(uuid,boolean,text)', 'execute') as resolver_authenticated_ok;

-- 5. Historico: ningun conteo aprobado por un franquiciado quedo aplicado
-- sobre un almacen que no fuera el suyo (deberia ser siempre cero, salvo
-- reasignaciones legitimas de perfil_almacenes que ya no aplican hoy).
select count(*) as conteos_franquicia_fuera_de_su_almacen_revisar
from public.documentos_inventario d
join public.perfiles p on p.id = d.aprobado_por
where d.tipo = 'conteo' and d.estado = 'aplicado'
  and p.rol::text in ('franquiciado', 'vendedor_franquicia')
  and not exists (
    select 1 from public.perfil_almacenes pa
    where pa.perfil_id = p.id and pa.almacen_id = d.origen_id
  );
