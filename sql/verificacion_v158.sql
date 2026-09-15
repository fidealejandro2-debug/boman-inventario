select
 exists(select 1 from public.permisos_sistema where codigo='contratos.asignar_vendedor'and activo)permiso_ok,
 to_regclass('public.contrato_asignaciones_v158')is not null auditoria_ok,
 to_regprocedure('public.catalogo_asignacion_vendedores_v158()')is not null catalogo_ok,
 to_regprocedure('public.asignar_vendedor_contratos_v158(uuid,text,uuid,text,uuid)')is not null asignar_ok,
 to_regprocedure('public.listar_centro_contratos_v158(text,boolean,integer,integer)')is not null listar_ok,
 to_regprocedure('public.obtener_centro_contrato_v158(uuid)')is not null detalle_ok,
 exists(select 1 from public.schema_migrations_boman where id='v158')registro_ok;

select
 count(*)filter(where vendedor_perfil_id is null)contratos_sin_usuario,
 count(*)filter(where vendedor_perfil_id is not null)contratos_asignados
from public.contratos;
