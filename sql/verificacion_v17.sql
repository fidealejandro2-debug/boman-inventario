-- ============================================================
-- Verificación v17 - Rectificación auditada de recepciones
-- Solo lectura: no modifica datos.
-- ============================================================

select
  to_regclass('public.rectificaciones_recepcion') is not null as tabla_rectificaciones_ok,
  to_regprocedure('public.admin_rectificar_recepcion_transferencia(uuid,text,uuid)') is not null
    as rpc_rectificacion_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'rectificaciones_recepcion';

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('rol_usuario_actual() <> ''admin''' in pg_get_functiondef(p.oid)) > 0
    as exclusiva_admin,
  position('movimientos posteriores' in pg_get_functiondef(p.oid)) > 0
    as bloqueo_movimientos_posteriores,
  position('conteo abierto' in pg_get_functiondef(p.oid)) > 0
    as bloqueo_conteo_abierto
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'admin_rectificar_recepcion_transferencia';

select
  has_function_privilege(
    'authenticated',
    'public.admin_rectificar_recepcion_transferencia(uuid,text,uuid)',
    'execute'
  ) as rpc_autenticados_ok,
  has_function_privilege(
    'authenticated',
    'public.cerrar_incidencia_transferencia(uuid,text)',
    'execute'
  ) as cierre_legado_debe_ser_false;

-- Ambos resultados deben ser cero.
select count(*) as rectificaciones_sin_snapshot_debe_ser_cero
from public.rectificaciones_recepcion
where jsonb_typeof(clasificacion_anterior) <> 'array'
   or jsonb_array_length(clasificacion_anterior) = 0;

select count(*) as incidencias_rectificadas_sin_cierre_debe_ser_cero
from public.rectificaciones_recepcion r
join public.incidencias_transferencia i on i.id = r.incidencia_id
where i.estado <> 'resuelta' or i.cierre_tipo <> 'rectificacion';
