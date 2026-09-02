-- ============================================================
-- Verificacion v53 - Centro general de notificaciones
-- Solo lectura: ejecutar despues de instalar v53.
-- ============================================================

select
  to_regclass('public.notificaciones_comunicados') is not null as comunicados_ok,
  to_regclass('public.notificacion_usuario_estados') is not null as estados_ok,
  to_regprocedure('public.listar_notificaciones_v53(boolean,boolean)') is not null as listar_ok,
  to_regprocedure('public.resumen_notificaciones_v53()') is not null as resumen_ok,
  to_regprocedure('public.marcar_notificaciones_v53(text[],text)') is not null as marcar_ok,
  to_regprocedure('public.publicar_notificacion_v53(jsonb,uuid)') is not null as publicar_ok;

select codigo, modulo, activo
from public.permisos_sistema
where codigo in ('notificaciones.acceder', 'notificaciones.publicar')
order by codigo;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('notificaciones_comunicados', 'notificacion_usuario_estados')
order by tablename;

select
  has_function_privilege('authenticated',
    'public.listar_notificaciones_v53(boolean,boolean)', 'execute') as listar_authenticated_ok,
  has_function_privilege('authenticated',
    'public.marcar_notificaciones_v53(text[],text)', 'execute') as marcar_authenticated_ok,
  not has_function_privilege('anon',
    'public.listar_notificaciones_v53(boolean,boolean)', 'execute') as listar_anon_debe_ser_true,
  not has_table_privilege('authenticated',
    'public.notificaciones_comunicados', 'insert') as insert_directo_debe_ser_true,
  not has_table_privilege('authenticated',
    'public.notificacion_usuario_estados', 'update') as update_directo_debe_ser_true;

-- Todos deben ser cero.
select count(*) as comunicados_invalidos_debe_ser_cero
from public.notificaciones_comunicados
where btrim(titulo) = '' or btrim(mensaje) = '' or href not like '/%'
   or (vigente_hasta is not null and vigente_hasta <= vigente_desde);

select count(*) as estados_huerfanos_debe_ser_cero
from public.notificacion_usuario_estados e
left join public.perfiles p on p.id = e.usuario_id
where p.id is null;

select count(*) as permisos_roles_incompletos_debe_ser_cero
from (
  select r.rol::text, count(rp.permiso_codigo) as total
  from unnest(enum_range(null::public.rol_usuario)) r(rol)
  left join public.rol_permisos rp on rp.rol = r.rol
    and rp.permiso_codigo in ('notificaciones.acceder', 'notificaciones.publicar')
  where r.rol::text <> 'admin'
  group by r.rol
) x
where total <> 2;

-- No se ejecuta listar_notificaciones_v53 aqui: deriva identidad y alcance de
-- auth.uid(), por lo que debe probarse desde la aplicacion con una sesion real.
-- Estas comprobaciones validan el contrato sin suplantar a ningun usuario.
select
  position('auth.uid()' in pg_get_functiondef(p.oid)) > 0 as deriva_usuario_sesion,
  position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0
    as controla_permiso,
  position('usuario_puede_empresa' in pg_get_functiondef(p.oid)) > 0
    as limita_empresa,
  position('usuario_puede_almacen' in pg_get_functiondef(p.oid)) > 0
    as limita_almacen,
  position('''no_leidas''' in pg_get_functiondef(p.oid)) > 0
    and position('''items''' in pg_get_functiondef(p.oid)) > 0
    as devuelve_contrato_panel
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'listar_notificaciones_v53';

-- Panorama global de instalacion; no representa la bandeja de un usuario.
select
  count(*) filter (where activo and vigente_desde <= now()
    and (vigente_hasta is null or vigente_hasta > now())) as comunicados_vigentes,
  count(*) filter (where not activo
    or (vigente_hasta is not null and vigente_hasta <= now())) as comunicados_cerrados
from public.notificaciones_comunicados;
