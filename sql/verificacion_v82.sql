-- ============================================================
-- Verificacion v82 - Conteo fisico desde el panel de franquicia
-- Solo lectura. Ejecutar despues de instalar v82.
-- ============================================================

-- 1. Las cuatro funciones existen con la firma esperada.
select
  to_regprocedure('public.crear_conteo_inventario(uuid,uuid[],text,uuid)') is not null as crear_ok,
  to_regprocedure('public.guardar_conteo_inventario(uuid,jsonb,boolean,text)') is not null as guardar_interno_ok,
  to_regprocedure('public.abrir_edicion_conteo_v22(uuid,boolean,text)') is not null as abrir_ok,
  to_regprocedure('public.guardar_conteo_inventario_v22(uuid,jsonb,boolean,text,integer)') is not null as guardar_v22_ok;

-- 2. Los cuatro guards de rol ahora incluyen franquiciado y vendedor_franquicia.
select p.proname,
       pg_get_functiondef(p.oid) like '%franquiciado%'
       and pg_get_functiondef(p.oid) like '%vendedor_franquicia%' as incluye_roles_franquicia
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('crear_conteo_inventario', 'guardar_conteo_inventario',
                     'abrir_edicion_conteo_v22', 'guardar_conteo_inventario_v22')
order by p.proname;

-- 3. Las RPC de resolucion NO deben tocarse: siguen exclusivas de admin/control
-- (el vendedor cuenta, pero no se aprueba a si mismo).
select p.proname,
       pg_get_functiondef(p.oid) like '%franquiciado%'
       or pg_get_functiondef(p.oid) like '%vendedor_franquicia%' as debe_ser_false
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('guardar_reconteo_inventario', 'resolver_conteo_inventario')
order by p.proname;

-- 4. Privilegios: authenticated puede ejecutar las cuatro RPC de conteo,
-- pero NO la interna guardar_conteo_inventario (solo via perform desde v22).
select
  has_function_privilege('authenticated', 'public.crear_conteo_inventario(uuid,uuid[],text,uuid)', 'execute') as crear_authenticated_ok,
  has_function_privilege('authenticated', 'public.abrir_edicion_conteo_v22(uuid,boolean,text)', 'execute') as abrir_authenticated_ok,
  has_function_privilege('authenticated', 'public.guardar_conteo_inventario_v22(uuid,jsonb,boolean,text,integer)', 'execute') as guardar_v22_authenticated_ok,
  not has_function_privilege('authenticated', 'public.guardar_conteo_inventario(uuid,jsonb,boolean,text)', 'execute') as guardar_interno_bloqueado_ok;

-- 5. RLS de lectura ya alcanzaba a franquicias sin cambios (usuario_puede_almacen
-- via perfil_almacenes); esto solo confirma que la politica sigue intacta.
select tablename, rowsecurity from pg_tables
where schemaname = 'public'
  and tablename in ('documentos_inventario', 'documento_inventario_lineas');
