-- ============================================================
-- Verificacion v68 - Infraestructura de planes por cliente
-- Solo lectura: ejecutar despues de instalar v68.
-- ============================================================

-- 1. Catalogo instalado.
select codigo, nombre, orden, activo from public.planes order by orden;
select codigo, modulo, nombre, orden, activo from public.capacidades_sistema order by orden;
select plan_codigo, capacidad_codigo, incluida from public.plan_capacidades order by plan_codigo, capacidad_codigo;

select count(*) = 3 as tres_planes_ok from public.planes where activo;
select count(*) = 3 as tres_capacidades_ok from public.capacidades_sistema where activo;

-- 2. Cada perfil activo quedo con un grupo. Si esto no es cero, hay usuarios
-- (probablemente admin/gerencia sin almacen, en un escenario multi-grupo) que
-- necesitan que se les asigne el grupo a mano.
select count(*) as perfiles_activos_sin_grupo_debe_ser_cero
from public.perfiles where activo and grupo_id is null;

-- 3. Objetos instalados.
select
  to_regprocedure('public.grupo_tiene_capacidad_v68(uuid,text)') is not null as grupo_capacidad_ok,
  to_regprocedure('public.usuario_tiene_capacidad_v68(text)') is not null as usuario_capacidad_ok,
  to_regprocedure('public.mi_plan_v68()') is not null as mi_plan_ok,
  to_regprocedure('public.admin_cambiar_plan_grupo_v68(uuid,text,text)') is not null as cambiar_plan_ok,
  to_regclass('public.vista_matriz_planes_v68') is not null as matriz_ok;

-- 4. CRITICO: mi_plan_v68() tiene que devolver datos aunque quien consulta NO
-- sea admin, porque planes/plan_capacidades/capacidades_sistema son de lectura
-- admin-only. Si esto sale null para un usuario normal, la funcion no esta
-- saltandose el RLS de esas tablas como deberia (revisar que sea security
-- definer, ver punto 6).
select public.mi_plan_v68() as mi_plan;

-- 5. Solo admin puede cambiar el plan de un cliente, y solo con motivo.
select
  not has_function_privilege('anon','public.admin_cambiar_plan_grupo_v68(uuid,text,text)','execute')
    as cambiar_plan_anon_bloqueado,
  has_function_privilege('authenticated','public.admin_cambiar_plan_grupo_v68(uuid,text,text)','execute')
    as cambiar_plan_disponible;

-- 6. Las funciones son definer con search_path fijo (asi es como
-- usuario_tiene_capacidad_v68 y mi_plan_v68 pueden leer el catalogo aunque el
-- usuario que llama no tenga permiso directo sobre esas tablas).
select p.proname, p.prosecdef as security_definer, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('grupo_tiene_capacidad_v68', 'usuario_tiene_capacidad_v68',
                    'mi_plan_v68', 'admin_cambiar_plan_grupo_v68')
order by p.proname;

-- 7. v58 (comprobantes de compra) ya exige el plan, no solo el rol.
select pg_get_functiondef(p.oid) like '%usuario_tiene_capacidad_v68%' as v58_registrar_gated
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'registrar_comprobante_compra_v58';

select pg_get_functiondef(p.oid) like '%usuario_tiene_capacidad_v68%' as v58_anular_gated
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'anular_comprobante_compra_v58';

-- Y el importador de XML de compras (v65), que llama a la misma RPC, hereda el
-- candado automaticamente sin que nadie haya tenido que tocar su codigo.
select pg_get_functiondef(p.oid) like '%registrar_comprobante_compra_v58%' as v65_usa_la_rpc_gateada
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'procesar_compra_xml_v65';

-- 8. Informativo: plan de cada cliente y su matriz completa.
select g.nombre, g.plan_codigo, pl.nombre as plan_nombre
from public.grupos_economicos g join public.planes pl on pl.codigo = g.plan_codigo
order by g.nombre;

select * from public.vista_matriz_planes_v68 order by plan_orden, capacidad_orden;
