-- ============================================================
-- Verificacion v33 - Reingreso de personal
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v33 y nunca en paralelo con la migracion.
-- ============================================================

-- 1. Objetos creados
select
  to_regclass('public.empleado_vinculos') is not null as vinculos_ok,
  to_regclass('public.vista_vinculos_empleado_v33') is not null as vista_vinculos_ok,
  to_regclass('public.vista_reingresables_v33') is not null as vista_reingresables_ok;

-- 2. Funciones instaladas
select
  to_regprocedure('public.antiguedad_desde_v33(uuid,date)') is not null as antiguedad_ok,
  to_regprocedure('public.vinculo_vigente_v33(uuid)') is not null as vinculo_vigente_ok,
  to_regprocedure('public.registrar_salida_v33(uuid,date,text,text,boolean,uuid)') is not null
    as salida_ok,
  to_regprocedure('public.registrar_reingreso_v33(uuid,date,boolean,text,text,uuid)') is not null
    as reingreso_ok,
  to_regprocedure('public.generar_periodos_vacaciones_v33(uuid,date,uuid)') is not null
    as generar_periodos_ok;

-- 3. vacaciones_periodos quedo ligada al vinculo
select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'vacaciones_periodos'
      and column_name = 'vinculo_id'
  ) as columna_vinculo_ok,
  exists (
    select 1 from pg_indexes where schemaname = 'public'
      and indexname = 'uq_vacaciones_periodo_vinculo_anio_v33'
  ) as unicidad_nueva_ok,
  not exists (
    select 1 from pg_constraint
    where conname = 'vacaciones_periodos_empleado_id_anos_servicio_key'
  ) as unicidad_vieja_eliminada_debe_ser_true;

-- 4. Las versiones que contaban contra fecha_ingreso_real quedan revocadas
select
  not has_function_privilege(
    'authenticated', 'public.generar_periodos_vacaciones_v27(uuid,date,uuid)', 'execute'
  ) as v27_generar_revocada_debe_ser_true,
  not has_function_privilege(
    'authenticated', 'public.dar_baja_empleado_v26(uuid,date,text)', 'execute'
  ) as v26_baja_revocada_debe_ser_true,
  has_function_privilege(
    'authenticated', 'public.generar_periodos_vacaciones_v33(uuid,date,uuid)', 'execute'
  ) as v33_generar_disponible_ok,
  not has_function_privilege(
    'anon', 'public.registrar_reingreso_v33(uuid,date,boolean,text,text,uuid)', 'execute'
  ) as reingreso_anon_debe_ser_true;

-- 5. RLS y security_invoker
select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'empleado_vinculos';

select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname like 'vista_%_v33'
order by c.relname;

-- ------------------------------------------------------------
-- Backfill e integridad. Todos los conteos deben ser cero.
-- ------------------------------------------------------------

-- Todo empleado debe tener al menos un vinculo
select count(*) as empleados_sin_vinculo_debe_ser_cero
from public.empleados e
where not exists (
  select 1 from public.empleado_vinculos v where v.empleado_id = e.id
);

-- Nadie puede tener dos vinculos abiertos a la vez
select count(*) as vinculos_abiertos_duplicados_debe_ser_cero
from (
  select empleado_id from public.empleado_vinculos
  where fecha_salida is null
  group by empleado_id having count(*) > 1
) t;

-- Vinculos solapados en el tiempo
select count(*) as vinculos_solapados_debe_ser_cero
from public.empleado_vinculos a
join public.empleado_vinculos b
  on b.empleado_id = a.empleado_id and b.secuencia > a.secuencia
where a.fecha_salida is null or b.fecha_ingreso <= a.fecha_salida;

-- La antiguedad nunca puede empezar despues del vinculo
select count(*) as antiguedad_posterior_al_ingreso_debe_ser_cero
from public.empleado_vinculos
where antiguedad_desde > fecha_ingreso;

-- Un finiquito pagado cierra la antiguedad: el siguiente vinculo no puede
-- ser de continuidad
select count(*) as continuidad_sobre_liquidado_debe_ser_cero
from public.empleado_vinculos nuevo
join public.empleado_vinculos previo
  on previo.empleado_id = nuevo.empleado_id
 and previo.secuencia = nuevo.secuencia - 1
where nuevo.tipo_vinculo = 'reingreso_continuidad'
  and previo.liquidado;

-- Toda liquidacion debe tener su acta
select count(*) as liquidados_sin_acta_debe_ser_cero
from public.empleado_vinculos
where liquidado and documento_finiquito_id is null
  and tipo_vinculo <> 'inicial';

-- El empleado activo debe coincidir con su vinculo abierto
select count(*) as estado_incoherente_debe_ser_cero
from public.empleados e
join public.empleado_vinculos v on v.empleado_id = e.id and v.fecha_salida is null
where e.estado <> 'activo';

-- fecha_ingreso_real debe reflejar el vinculo vigente: v30 prorratea con ella
select count(*) as ingreso_desalineado_debe_ser_cero
from public.empleados e
join public.empleado_vinculos v on v.empleado_id = e.id and v.fecha_salida is null
where e.fecha_ingreso_real <> v.fecha_ingreso;

-- Ningun periodo de vacaciones puede quedar huerfano de vinculo
select count(*) as periodos_sin_vinculo_debe_ser_cero
from public.vacaciones_periodos where vinculo_id is null;

-- Un periodo no puede pertenecer al vinculo de otra persona
select count(*) as periodos_de_otro_empleado_debe_ser_cero
from public.vacaciones_periodos vp
join public.empleado_vinculos v on v.id = vp.vinculo_id
where v.empleado_id <> vp.empleado_id;

-- ------------------------------------------------------------
-- Panorama (informativo)
-- ------------------------------------------------------------

-- Cuanta gente ha vuelto y como se le reconocio la antiguedad
select tipo_vinculo, count(*) as vinculos
from public.empleado_vinculos
group by tipo_vinculo
order by vinculos desc;

-- Personal que salio: candidatos a reingreso antes de crear una ficha nueva
select nombre_completo, cargo, ultima_salida, tipo_salida, liquidado,
       dias_fuera, puede_conservar_antiguedad
from public.vista_reingresables_v33
order by ultima_salida desc
limit 20;

-- Quienes volvieron conservando antiguedad y cuanta se les reconocio
select nombre_completo, secuencia, fecha_ingreso, antiguedad_desde,
       dias_antiguedad_reconocida, anios_antiguedad
from public.vista_vinculos_empleado_v33
where tipo_vinculo = 'reingreso_continuidad'
order by fecha_ingreso desc;

-- Salidas registradas de forma retroactiva sobre un periodo ya cerrado
select created_at, detalle
from public.nomina_eventos
where tipo = 'salida_registrada_retroactiva'
order by created_at desc;
