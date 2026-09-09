-- ============================================================
-- Verificacion v107 - Permisos por persona y marca blanca
-- Solo lectura. Ejecutar despues de instalar v107.
-- ============================================================

-- 1. Tablas, vista y funciones existen.
select
  to_regclass('public.perfil_permisos') is not null as tabla_perfil_permisos_ok,
  to_regclass('public.permisos_usuario_eventos') is not null as tabla_eventos_ok,
  to_regclass('public.configuracion_sistema') is not null as tabla_config_ok,
  to_regclass('public.vista_matriz_permisos_usuario_v107') is not null as vista_ok,
  to_regprocedure('public.admin_guardar_permisos_usuario_v107(uuid,jsonb,text,uuid)') is not null as fn_guardar_usuario_ok,
  to_regprocedure('public.admin_actualizar_configuracion_sistema_v107(boolean,text)') is not null as fn_toggle_ok,
  to_regprocedure('public.modo_boman_especifico_activo()') is not null as fn_modo_boman_ok;

-- 2. Existe exactamente una fila de configuracion, activa por defecto.
select
  count(*) = 1 as una_sola_fila_config_ok,
  bool_and(es_boman_especifico_activo) as default_activo_ok
from public.configuracion_sistema;

-- 3. Permisos de contratos/franquicia quedaron marcados como especificos de
-- Boman; franquicia.caja (caja de tienda generica) NO.
select bool_and(es_boman_especifico) as contratos_franquicia_marcados_ok
from public.permisos_sistema
where codigo in (
  'contratos.acceder','contratos.editar','contratos.marcar_etapa',
  'contratos.finanzas.ver','contratos.finanzas.editar',
  'franquicia.acceder','franquicia.ventas','franquicia.inventario',
  'franquicia.reposicion','franquicia.precio_libre','franquicia.descuento',
  'franquicia.consolidado','franquicia.turnos','franquicia.cobros','franquicia.devoluciones'
);
select not es_boman_especifico as franquicia_caja_generico_ok
from public.permisos_sistema where codigo = 'franquicia.caja';

-- 4. RLS habilitado y privilegios correctos en las tablas nuevas.
select
  (select rowsecurity from pg_tables where tablename = 'perfil_permisos') as rls_perfil_permisos_ok,
  (select rowsecurity from pg_tables where tablename = 'permisos_usuario_eventos') as rls_eventos_ok,
  (select rowsecurity from pg_tables where tablename = 'configuracion_sistema') as rls_config_ok,
  not has_table_privilege('authenticated', 'public.perfil_permisos', 'insert') as sin_insert_directo_ok,
  not has_table_privilege('anon', 'public.perfil_permisos', 'select') as anon_bloqueado_ok;

-- 5. Privilegios de ejecucion de las funciones nuevas.
select
  has_function_privilege('authenticated', 'public.admin_guardar_permisos_usuario_v107(uuid,jsonb,text,uuid)', 'execute') as guardar_authenticated_ok,
  not has_function_privilege('anon', 'public.admin_guardar_permisos_usuario_v107(uuid,jsonb,text,uuid)', 'execute') as guardar_anon_bloqueado_ok,
  has_function_privilege('authenticated', 'public.modo_boman_especifico_activo()', 'execute') as modo_boman_authenticated_ok;

-- 6. usuario_tiene_permiso_v35 / permisos_usuario_actual_v35 siguen siendo
-- security definer de postgres y ya referencian perfil_permisos y
-- modo_boman_especifico_activo (se compusieron, no se reemplazaron).
select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('perfil_permisos' in pg_get_functiondef(p.oid)) > 0 as usa_overrides_ok,
  position('modo_boman_especifico_activo' in pg_get_functiondef(p.oid)) > 0 as usa_marca_blanca_ok
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('permisos_usuario_actual_v35', 'usuario_tiene_permiso_v35');

-- 7. Prueba funcional real (no se puede desde el editor SQL: auth.uid()
-- saldria null aunque todo este bien instalado -mismo criterio que
-- verificacion_v95.sql). Verificar manualmente con sesiones reales:
--   a) Override permitido=false sobre un permiso que el rol de un usuario de
--      prueba SI tiene por defecto -> desaparece de su menu y la RPC
--      protegida por ese codigo lo rechaza.
--   b) Override permitido=true sobre uno que el rol NO tiene -> aparece y la
--      RPC lo acepta.
--   c) Apagar es_boman_especifico_activo -> el modulo Franquicias y las 3
--      opciones de administracion de BomanSport desaparecen incluso con
--      sesion admin.
--   d) admin_guardar_permisos_usuario_v107 contra un perfil con rol='admin'
--      debe fallar con la excepcion explicita.
