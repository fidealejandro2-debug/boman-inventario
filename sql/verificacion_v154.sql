-- Verificacion v154. Solo lectura; ejecutar despues de la migracion.

select to_regclass('public.novedades_operativas_v154') is not null as tabla_novedades_ok;
select to_regclass('public.novedad_operativa_eventos_v154') is not null as tabla_eventos_ok;
select to_regclass('public.novedad_operativa_evidencias_v154') is not null as tabla_evidencias_ok;
select to_regclass('public.novedad_evidencia_pendientes_v154') is not null as tabla_pendientes_ok;
select to_regclass('public.vista_novedades_operativas_v154') is not null as vista_ok;

select
  to_regprocedure('public._crear_novedad_operativa_v154(uuid,text,uuid,uuid,date,text,numeric,text,uuid,uuid)') is not null as rpc_interna_ok,
  to_regprocedure('public.crear_novedad_operativa_v154(jsonb,uuid)') is not null as rpc_crear_ok,
  to_regprocedure('public.asignar_novedad_operativa_v154(uuid,uuid,date,text,uuid)') is not null as rpc_asignar_ok,
  to_regprocedure('public.agregar_comentario_novedad_v154(uuid,text,uuid)') is not null as rpc_comentar_ok,
  to_regprocedure('public.resolver_novedad_operativa_v154(uuid,text,uuid)') is not null as rpc_resolver_ok,
  to_regprocedure('public.anular_novedad_operativa_v154(uuid,text,uuid)') is not null as rpc_anular_ok,
  to_regprocedure('public.preparar_evidencia_novedad_v154(uuid,text,text,bigint,uuid)') is not null as rpc_preparar_evidencia_ok,
  to_regprocedure('public.agregar_evidencia_novedad_v154(uuid,uuid,text,uuid)') is not null as rpc_agregar_evidencia_ok;

select exists(select 1 from storage.buckets where id='novedades-evidencia' and not public) as bucket_privado_ok;

select exists(
  select 1 from public.permisos_sistema where codigo='operativas.novedades.gestionar' and activo
) as permiso_existe;

-- control, gerencia y supervisor deben tenerlo encendido; el resto apagado.
select rol, permitido from public.rol_permisos
where permiso_codigo = 'operativas.novedades.gestionar'
order by rol::text;

-- La funcion interna NO debe ser ejecutable por authenticated ni anon.
select
  not has_function_privilege('authenticated','public._crear_novedad_operativa_v154(uuid,text,uuid,uuid,date,text,numeric,text,uuid,uuid)','execute') as interna_bloqueada_authenticated,
  not has_function_privilege('anon','public._crear_novedad_operativa_v154(uuid,text,uuid,uuid,date,text,numeric,text,uuid,uuid)','execute') as interna_bloqueada_anon;

select
  has_function_privilege('authenticated','public.crear_novedad_operativa_v154(jsonb,uuid)','execute') as crear_ejecutable_ok,
  has_table_privilege('authenticated','public.novedades_operativas_v154','select') as leer_ok,
  not has_table_privilege('anon','public.novedades_operativas_v154','select') as anon_bloqueado,
  not has_table_privilege('authenticated','public.novedades_operativas_v154','insert') as insert_directo_bloqueado_ok;

-- Confirma que cerrar_caja_franquicia_v49 conserva su firma vigente (no debe
-- haber cambiado de parametros al agregar la deteccion de descuadre).
select to_regprocedure('public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid)') is not null as cerrar_caja_firma_intacta;
