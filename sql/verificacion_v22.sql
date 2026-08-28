-- ============================================================
-- Verificacion v22 - Bloqueo y concurrencia de conteos
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v22 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.conteo_responsable_eventos') is not null as auditoria_responsable_ok,
  to_regprocedure('public.abrir_edicion_conteo_v22(uuid,boolean,text)') is not null
    as abrir_edicion_ok,
  to_regprocedure('public.guardar_conteo_inventario_v22(uuid,jsonb,boolean,text,integer)') is not null
    as guardar_protegido_ok;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'documentos_inventario'
  and column_name in ('conteo_responsable_id', 'conteo_actividad_at', 'version')
order by column_name;

select trigger_name, event_object_table
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name = 'trg_inicializar_responsable_conteo_v22';

select
  has_function_privilege(
    'authenticated',
    'public.abrir_edicion_conteo_v22(uuid,boolean,text)', 'execute'
  ) as abrir_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.guardar_conteo_inventario_v22(uuid,jsonb,boolean,text,integer)', 'execute'
  ) as guardar_v22_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.guardar_conteo_inventario(uuid,jsonb,boolean,text)', 'execute'
  ) as guardar_anterior_debe_ser_false,
  has_function_privilege(
    'anon',
    'public.abrir_edicion_conteo_v22(uuid,boolean,text)', 'execute'
  ) as abrir_anon_debe_ser_false;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('p_version <> d.version' in pg_get_functiondef(p.oid)) > 0
    as controla_version,
  position('conteo_responsable_id' in pg_get_functiondef(p.oid)) > 0
    as controla_responsable
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('abrir_edicion_conteo_v22', 'guardar_conteo_inventario_v22')
order by p.proname;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'conteo_responsable_eventos';

-- Debe ser cero: todo conteo abierto tiene un responsable exclusivo.
select count(*) as conteos_abiertos_sin_responsable_debe_ser_cero
from public.documentos_inventario
where tipo = 'conteo' and estado = 'en_conteo'
  and conteo_responsable_id is null;

-- Informativo: actividad reciente indica que el responsable trabajo en los
-- ultimos 30 minutos; no libera la responsabilidad ni permite sobrescrituras.
select d.numero, a.nombre as almacen, p.nombre_completo as responsable,
       d.conteo_actividad_at,
       d.conteo_actividad_at >= now() - interval '30 minutes' as edicion_reciente,
       d.version
from public.documentos_inventario d
left join public.almacenes a on a.id = d.origen_id
left join public.perfiles p on p.id = d.conteo_responsable_id
where d.tipo = 'conteo' and d.estado = 'en_conteo'
order by d.updated_at desc;

select count(*) as tomas_control_auditadas
from public.conteo_responsable_eventos;
