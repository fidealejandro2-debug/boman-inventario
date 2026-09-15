-- Verificacion v153. Solo lectura; ejecutar despues de la migracion.

select to_regclass('public.almacen_configuracion_operativa_v153') is not null as tabla_ok;
select to_regprocedure('public.guardar_configuracion_operativa_v153(uuid,time,numeric)') is not null as rpc_ok;

select exists(
  select 1 from public.permisos_sistema where codigo='operativas.cierres.configurar' and activo
) as permiso_existe;

-- Debe estar en false para TODOS los roles (delegable, nadie lo tiene por defecto).
select count(*) as roles_con_permiso_encendido_debe_ser_cero
from public.rol_permisos
where permiso_codigo='operativas.cierres.configurar' and permitido;

-- Debe haber una fila por cada almacen activo (backfill de la migracion).
select
  (select count(*) from public.almacenes where activo) as almacenes_activos,
  (select count(*) from public.almacen_configuracion_operativa_v153) as filas_config;

select
  has_table_privilege('authenticated','public.almacen_configuracion_operativa_v153','select') as select_ok,
  not has_table_privilege('anon','public.almacen_configuracion_operativa_v153','select') as anon_bloqueado,
  not has_table_privilege('authenticated','public.almacen_configuracion_operativa_v153','insert') as insert_bloqueado_ok;
