-- Verificacion v150. Solo lectura; ejecutar despues de la migracion.

select exists(
  select 1 from public.permisos_sistema where codigo='franquicia.comprobantes.auditar_todo' and activo
) as permiso_existe;

-- Debe estar en false para TODOS los roles (nadie lo tiene por defecto).
select count(*) as roles_con_permiso_encendido_debe_ser_cero
from public.rol_permisos
where permiso_codigo='franquicia.comprobantes.auditar_todo' and permitido;

select to_regclass('public.vista_comprobantes_venta_pendientes_v150') is not null as vista_ok;

select
  has_table_privilege('authenticated','public.vista_comprobantes_venta_pendientes_v150','select') as vista_select_ok,
  not has_table_privilege('anon','public.vista_comprobantes_venta_pendientes_v150','select') as vista_anon_bloqueada;

-- Muestreo (puede venir vacio si aun no hay transferencias registradas).
select origen, count(*) from public.vista_comprobantes_venta_pendientes_v150 group by origen;
