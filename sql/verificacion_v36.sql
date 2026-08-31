-- ============================================================
-- Verificacion v36 - Cargas familiares
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v36 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.empleado_cargas_familiares') is not null as cargas_ok,
  to_regclass('public.vista_cargas_familiares_v36') is not null as vista_ok;

select
  to_regprocedure('public.carga_familiar_elegible_utilidades_v36(uuid,integer)') is not null
    as elegibilidad_ok,
  to_regprocedure('public.contar_cargas_utilidades_v36(uuid,integer)') is not null
    as contador_ok,
  to_regprocedure('public.guardar_carga_familiar_v36(uuid,uuid,text,text,text,text,text,date,boolean,numeric,date,date,uuid,uuid,text,uuid)') is not null
    as guardar_ok,
  to_regprocedure('public.cerrar_carga_familiar_v36(uuid,date,text,uuid)') is not null
    as cerrar_ok;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'empleado_cargas_familiares'
  and column_name in (
    'empleado_id', 'tipo', 'identificacion', 'fecha_nacimiento',
    'tiene_discapacidad', 'porcentaje_discapacidad',
    'fecha_desde', 'fecha_hasta', 'fecha_acreditacion',
    'documento_parentesco_id', 'documento_discapacidad_id'
  )
order by column_name;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'empleado_cargas_familiares';

select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_cargas_familiares_v36';

select
  has_function_privilege(
    'authenticated',
    'public.guardar_carga_familiar_v36(uuid,uuid,text,text,text,text,text,date,boolean,numeric,date,date,uuid,uuid,text,uuid)',
    'execute'
  ) as guardar_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.cerrar_carga_familiar_v36(uuid,date,text,uuid)',
    'execute'
  ) as cerrar_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.guardar_carga_familiar_v36(uuid,uuid,text,text,text,text,text,date,boolean,numeric,date,date,uuid,uuid,text,uuid)',
    'execute'
  ) as guardar_anon_debe_ser_true,
  not has_table_privilege(
    'authenticated', 'public.empleado_cargas_familiares', 'insert'
  ) as insert_directo_debe_ser_true,
  not has_table_privilege(
    'authenticated', 'public.empleado_cargas_familiares', 'update'
  ) as update_directo_debe_ser_true;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  case when p.proname = 'guardar_carga_familiar_v36'
    then position('documento de respaldo' in pg_get_functiondef(p.oid)) > 0
    else null end as exige_respaldo_discapacidad,
  case when p.proname = 'carga_familiar_elegible_utilidades_v36'
    then position('interval ''18 years''' in pg_get_functiondef(p.oid)) > 0
    else null end as controla_mayoria_edad
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'carga_familiar_elegible_utilidades_v36',
    'contar_cargas_utilidades_v36',
    'guardar_carga_familiar_v36',
    'cerrar_carga_familiar_v36'
  )
order by p.proname;

-- Todos los siguientes resultados deben ser cero.
select count(*) as cargas_sin_respaldo_parentesco_debe_ser_cero
from public.empleado_cargas_familiares c
left join public.empleado_documentos d on d.id = c.documento_parentesco_id
where d.id is null or d.empleado_id <> c.empleado_id;

select count(*) as discapacidades_sin_respaldo_debe_ser_cero
from public.empleado_cargas_familiares c
left join public.empleado_documentos d on d.id = c.documento_discapacidad_id
where c.tiene_discapacidad
  and (d.id is null or d.empleado_id <> c.empleado_id);

select count(*) as hijos_sin_nacimiento_debe_ser_cero
from public.empleado_cargas_familiares
where tipo = 'hijo' and fecha_nacimiento is null;

select count(*) as vigencias_invalidas_debe_ser_cero
from public.empleado_cargas_familiares
where fecha_desde > current_date
   or fecha_acreditacion < fecha_desde
   or fecha_acreditacion > current_date
   or fecha_hasta < fecha_desde;

select count(*) as parejas_vigentes_duplicadas_debe_ser_cero
from (
  select empleado_id
  from public.empleado_cargas_familiares
  where fecha_hasta is null
    and tipo in ('conyuge', 'conviviente_union_hecho')
  group by empleado_id having count(*) > 1
) x;

select count(*) as eventos_v36_incompletos_debe_ser_cero
from public.nomina_eventos
where entidad = 'carga_familiar'
  and (empleado_id is null or usuario_id is null or idempotency_key is null
    or btrim(coalesce(detalle, '')) = '');

-- Informativo: hijos que dejaran de ser carga para utilidades dentro de los
-- proximos 120 dias, salvo que tengan discapacidad acreditada.
select empleado_nombre, apellidos, nombres, cumple_18_at
from public.vista_cargas_familiares_v36
where vigente_hoy and tipo = 'hijo' and not tiene_discapacidad
  and cumple_18_at::date between current_date and current_date + 120
order by cumple_18_at;

select
  count(*) filter (where vigente_hoy) as cargas_vigentes,
  count(*) filter (where elegible_utilidades_ejercicio_actual)
    as elegibles_utilidades_ejercicio_actual,
  count(*) filter (where vigente_hoy and tipo = 'hijo') as hijos_vigentes,
  count(*) filter (where vigente_hoy and tiene_discapacidad)
    as cargas_con_discapacidad
from public.vista_cargas_familiares_v36;
