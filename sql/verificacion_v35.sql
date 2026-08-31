-- ============================================================
-- Verificacion v35 - Permisos y calidad de nomina
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v35 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.permisos_sistema') is not null as catalogo_ok,
  to_regclass('public.rol_permisos') is not null as matriz_ok,
  to_regclass('public.permisos_roles_eventos') is not null as auditoria_ok,
  to_regclass('public.vista_matriz_permisos_v35') is not null as vista_ok;

select
  to_regprocedure('public.usuario_tiene_permiso_v35(text)') is not null
    as evaluar_permiso_ok,
  to_regprocedure('public.permisos_usuario_actual_v35()') is not null
    as permisos_actuales_ok,
  to_regprocedure('public.admin_guardar_permisos_rol_v35(text,jsonb,text,uuid)') is not null
    as guardar_matriz_ok,
  to_regprocedure('public.guardar_empleado_v35(uuid,jsonb,uuid,text,uuid)') is not null
    as editar_empleado_justificado_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'permisos_sistema', 'rol_permisos', 'permisos_roles_eventos'
  )
order by tablename;

select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_matriz_permisos_v35';

select
  has_function_privilege(
    'authenticated', 'public.permisos_usuario_actual_v35()', 'execute'
  ) as consulta_authenticated_ok,
  has_function_privilege(
    'authenticated', 'public.usuario_puede_nomina(boolean)', 'execute'
  ) as acceso_nomina_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.admin_guardar_permisos_rol_v35(text,jsonb,text,uuid)', 'execute'
  ) as guardar_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.admin_guardar_permisos_rol_v35(text,jsonb,text,uuid)', 'execute'
  ) as guardar_anon_debe_ser_true,
  not has_function_privilege(
    'anon', 'public.usuario_puede_nomina(boolean)', 'execute'
  ) as acceso_nomina_anon_debe_ser_true,
  not has_table_privilege('authenticated', 'public.rol_permisos', 'update')
    as update_directo_debe_ser_true,
  not has_function_privilege(
    'authenticated',
    'public.guardar_empleado_v26(uuid,uuid,text,text,text,text,date,text,date,text,text,text,text,text,text,text,text,text,text,text,text,text)',
    'execute'
  ) as editor_v26_directo_revocado_debe_ser_true,
  has_function_privilege(
    'authenticated',
    'public.guardar_empleado_v35(uuid,jsonb,uuid,text,uuid)', 'execute'
  ) as editor_v35_authenticated_ok;

select
  position('p_motivo' in pg_get_functiondef(p.oid)) > 0 as exige_motivo,
  position('set_config(''nomina.motivo''' in pg_get_functiondef(p.oid)) > 0
    as propaga_motivo_al_trigger,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'guardar_empleado_v35';

select
  position('if tg_op = ''INSERT''' in pg_get_functiondef(p.oid)) > 0
    as resume_altas,
  position('''(alta)''' in pg_get_functiondef(p.oid)) > 0
    as marca_resumen_alta
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'auditar_cambios_nomina_v32';

-- Todos los siguientes resultados deben ser cero.
select count(*) as roles_sin_matriz_completa_debe_ser_cero
from (
  select r.rol, count(rp.permiso_codigo) total,
         (select count(*) from public.permisos_sistema where activo) esperado
  from (values
    ('bodega'), ('logistica'), ('gerencia'),
    ('tienda'), ('control'), ('nomina')
  ) r(rol)
  left join public.rol_permisos rp on rp.rol::text = r.rol
  group by r.rol
) x
where x.total <> x.esperado;

select count(*) as permisos_huerfanos_debe_ser_cero
from public.rol_permisos rp
left join public.permisos_sistema ps on ps.codigo = rp.permiso_codigo
where ps.codigo is null;

select count(*) as eventos_incompletos_debe_ser_cero
from public.permisos_roles_eventos
where usuario_id is null or idempotency_key is null
   or btrim(coalesce(detalle, '')) = '';

select count(*) as permisos_admin_persistidos_innecesarios_debe_ser_cero
from public.rol_permisos where rol::text = 'admin';

-- Tras v35 cada alta nueva genera una sola fila resumen. Las filas antiguas
-- se conservan porque la auditoria es inmutable.
select count(*) as altas_resumidas_desde_v35
from public.nomina_cambios
where operacion = 'alta' and campo = '(alta)';

select rol, modulo,
       count(*) filter (where permitido) as permitidos,
       count(*) as permisos_modulo
from public.vista_matriz_permisos_v35
group by rol, modulo
order by rol, modulo;

-- Debe ser true: el rol administrador conserva acceso inmutable a todo.
select bool_and(permitido and not configurable)
  as administrador_completo_e_inmutable
from public.vista_matriz_permisos_v35
where rol = 'admin';
