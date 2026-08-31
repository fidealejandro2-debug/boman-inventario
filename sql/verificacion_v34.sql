-- ============================================================
-- Verificacion v34 - Departamentos de nomina
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v34 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.departamentos_nomina') is not null as departamentos_ok,
  to_regclass('public.vista_departamentos_nomina_v34') is not null as vista_ok,
  to_regprocedure('public.guardar_departamento_nomina_v34(uuid,uuid,text,text,text,boolean,uuid)') is not null
    as guardar_departamento_ok,
  to_regprocedure('public.asignar_departamento_empleado_v34(uuid,uuid,text,uuid)') is not null
    as asignar_empleado_ok,
  to_regprocedure('public.crear_empleado_completo_v34(jsonb,uuid,jsonb,jsonb,uuid)') is not null
    as alta_atomica_ok,
  to_regprocedure('public.validar_departamento_empleado_v34()') is not null
    as trigger_funcion_ok,
  to_regprocedure('public.crear_vinculo_inicial_empleado_v34()') is not null
    as vinculo_nuevas_altas_ok;

select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and (table_name, column_name) in (
    ('empleados', 'departamento_id'),
    ('departamentos_nomina', 'grupo_id'),
    ('departamentos_nomina', 'codigo'),
    ('departamentos_nomina', 'nombre'),
    ('departamentos_nomina', 'activo')
  )
order by table_name, column_name;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'departamentos_nomina';

select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('vista_departamentos_nomina_v34', 'vista_personal_vigente')
order by c.relname;

select
  has_function_privilege(
    'authenticated',
    'public.guardar_departamento_nomina_v34(uuid,uuid,text,text,text,boolean,uuid)',
    'execute'
  ) as guardar_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.crear_empleado_completo_v34(jsonb,uuid,jsonb,jsonb,uuid)',
    'execute'
  ) as alta_atomica_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.guardar_departamento_nomina_v34(uuid,uuid,text,text,text,boolean,uuid)',
    'execute'
  ) as guardar_anon_debe_ser_true,
  not has_function_privilege(
    'authenticated', 'public.validar_departamento_empleado_v34()', 'execute'
  ) as trigger_directo_debe_ser_true,
  not has_table_privilege(
    'authenticated', 'public.departamentos_nomina', 'insert'
  ) as insert_directo_debe_ser_true;

select trigger_name, event_object_table, action_timing
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name in (
    'trg_validar_departamento_empleado_v34',
    'trg_crear_vinculo_inicial_empleado_v34'
  )
order by trigger_name;

-- Todos los siguientes resultados deben ser cero.
select count(*) as codigos_duplicados_debe_ser_cero
from (
  select grupo_id, codigo
  from public.departamentos_nomina
  group by grupo_id, codigo having count(*) > 1
) duplicados;

select count(*) as nombres_duplicados_debe_ser_cero
from (
  select grupo_id, lower(btrim(nombre)) nombre
  from public.departamentos_nomina
  group by grupo_id, lower(btrim(nombre)) having count(*) > 1
) duplicados;

select count(*) as empleados_en_departamento_otro_grupo_debe_ser_cero
from public.empleados e
join public.departamentos_nomina d on d.id = e.departamento_id
where e.grupo_id <> d.grupo_id;

select count(*) as nombres_desincronizados_debe_ser_cero
from public.empleados e
join public.departamentos_nomina d on d.id = e.departamento_id
where e.area is distinct from d.nombre;

select count(*) as departamentos_inactivos_con_personal_activo_debe_ser_cero
from public.departamentos_nomina d
where not d.activo and exists (
  select 1 from public.empleados e
  where e.departamento_id = d.id and e.estado = 'activo'
);

select count(*) as empleados_sin_vinculo_debe_ser_cero
from public.empleados e
where not exists (
  select 1 from public.empleado_vinculos v where v.empleado_id = e.id
);

select count(*) as eventos_departamento_incompletos_debe_ser_cero
from public.nomina_eventos
where entidad = 'departamento'
  and (usuario_id is null or idempotency_key is null
    or btrim(coalesce(tipo, '')) = '' or btrim(coalesce(detalle, '')) = '');

-- Informativo: estos empleados deben asignarse desde Nomina > Departamentos.
select count(*) as empleados_activos_pendientes_de_departamento
from public.empleados
where estado = 'activo' and departamento_id is null;

select identificacion, nombre_completo, cargo, area
from public.vista_personal_vigente
where estado = 'activo' and departamento_id is null
order by nombre_completo;

select codigo, nombre, activo, empleados_activos, empleados_total
from public.vista_departamentos_nomina_v34
order by activo desc, nombre;
