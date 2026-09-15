-- Ejecutar despues de v151.
select
 to_regprocedure('public.puede_editar_fotos_producto_v89(uuid)')is not null as autorizacion_fotos_ok,
 exists(select 1 from public.schema_migrations_boman where id='v151')as migracion_registrada_ok,
 position('''tienda'''in pg_get_functiondef('public.puede_editar_fotos_producto_v89(uuid)'::regprocedure))>0 as rol_tienda_incluido,
 position('producto_almacen_config'in pg_get_functiondef('public.puede_editar_fotos_producto_v89(uuid)'::regprocedure))>0 as alcance_por_local_ok;
