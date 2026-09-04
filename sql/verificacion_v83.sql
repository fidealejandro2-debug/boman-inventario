-- ============================================================
-- Verificacion v83 - Admin registra depositos/ajustes de caja
-- Solo lectura. Ejecutar despues de instalar v83.
-- ============================================================

-- 1. La funcion existe con la firma nueva (9 parametros).
select to_regprocedure(
  'public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid,uuid)'
) is not null as firma_nueva_ok;

-- 2. La firma vieja de 8 parametros ya no existe (create or replace la
-- reemplazo, no quedaron las dos firmas conviviendo).
select to_regprocedure(
  'public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid)'
) is null as firma_vieja_no_existe;

-- 3. El cuerpo admite admin y sigue exigiendo el permiso de caja para los
-- roles operativos.
select
  pg_get_functiondef(p.oid) like '%v_rol = ''admin''%' as admite_admin,
  pg_get_functiondef(p.oid) like '%franquicia.caja%' as sigue_exigiendo_permiso
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'registrar_caja_franquicia_v42';

-- 4. Privilegios.
select
  has_function_privilege('authenticated',
    'public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid,uuid)',
    'execute') as authenticated_ok,
  not has_function_privilege('anon',
    'public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid,uuid)',
    'execute') as anon_bloqueado_ok;

-- 5. Los movimientos historicos de admin (si ya se uso) quedan con
-- almacen_id siempre presente y franquicia_id coherente con el almacen.
select count(*) as movimientos_admin_sin_almacen_debe_ser_cero
from public.franquicia_caja_movimientos m
join public.perfiles p on p.id = m.creado_por
where p.rol::text = 'admin' and m.almacen_id is null;
