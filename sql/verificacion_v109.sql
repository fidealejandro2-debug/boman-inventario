-- ============================================================
-- Verificacion v109 - Creacion de productos por franquicia
-- Solo lectura. Ejecutar despues de instalar v109.
-- ============================================================

-- 1. Tabla y funciones existen.
select
  to_regclass('public.productos_creados_franquicia_v109') is not null as tabla_ok,
  to_regprocedure('public.sku_abreviaturas_disponibles_v109()') is not null as fn_listar_ok,
  to_regprocedure('public.crear_producto_franquicia_v109(jsonb,uuid)') is not null as fn_crear_ok,
  to_regprocedure('public.marcar_revisado_producto_franquicia_v109(uuid)') is not null as fn_marcar_ok;

-- 2. RLS habilitado.
select rowsecurity as rls_ok
from pg_tables where tablename = 'productos_creados_franquicia_v109';

-- 3. Privilegios: authenticated solo lee la tabla; anon no tiene nada.
select
  has_table_privilege('authenticated', 'public.productos_creados_franquicia_v109', 'select') as select_ok,
  not has_table_privilege('authenticated', 'public.productos_creados_franquicia_v109', 'insert') as sin_insert_directo_ok,
  not has_table_privilege('anon', 'public.productos_creados_franquicia_v109', 'select') as anon_bloqueado_ok;

-- 4. Privilegios de ejecucion de las 3 funciones.
select
  has_function_privilege('authenticated', 'public.crear_producto_franquicia_v109(jsonb,uuid)', 'execute') as crear_authenticated_ok,
  not has_function_privilege('anon', 'public.crear_producto_franquicia_v109(jsonb,uuid)', 'execute') as crear_anon_bloqueado_ok,
  has_function_privilege('authenticated', 'public.sku_abreviaturas_disponibles_v109()', 'execute') as listar_authenticated_ok;

-- 5. El permiso quedo sembrado solo para los roles de franquicia (y admin,
-- que no se guarda en rol_permisos porque tiene bypass propio).
select rol, permitido
from public.rol_permisos
where permiso_codigo = 'productos.crear'
order by rol;
-- Se espera: franquiciado=true, vendedor_franquicia=true, el resto=false.

-- 6. Invariantes (deben ser cero).
select count(*) as auditoria_sin_producto_debe_ser_cero
from public.productos_creados_franquicia_v109 c
left join public.productos p on p.id = c.producto_id
where p.id is null;

select count(*) as sku_no_coincide_formula_debe_ser_cero
from public.productos_creados_franquicia_v109 c
join public.productos p on p.id = c.producto_id
where p.sku <> c.sku;

select count(*) as revisado_sin_quien_debe_ser_cero
from public.productos_creados_franquicia_v109
where revisado_at is not null and revisado_por is null;

-- 7. Panorama informativo (vacio hasta la primera creacion real, es normal).
select c.sku, p.nombre, c.creado_por, a.nombre as almacen, c.created_at, c.revisado_at
from public.productos_creados_franquicia_v109 c
join public.productos p on p.id = c.producto_id
left join public.almacenes a on a.id = c.almacen_id
order by c.created_at desc
limit 20;

-- La prueba funcional real (crear un producto como franquiciado, ver la
-- alerta como admin en /notificaciones, marcarlo revisado en /productos) se
-- hace con sesiones reales: el editor SQL no representa al usuario de la
-- aplicacion y auth.uid() seria null aunque la instalacion este correcta
-- (mismo criterio que verificacion_v95.sql).
