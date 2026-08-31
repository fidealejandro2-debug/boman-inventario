-- ============================================================
-- Verificacion v27 - Ausencias y vacaciones
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v27 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.feriados_anios') is not null as calendarios_ok,
  to_regclass('public.feriados') is not null as feriados_ok,
  to_regclass('public.vacaciones_periodos') is not null as periodos_ok,
  to_regclass('public.ausencias') is not null as ausencias_ok,
  to_regclass('public.ausencia_vacaciones_aplicaciones') is not null
    as aplicaciones_fifo_ok,
  to_regclass('public.nomina_eventos') is not null as eventos_compartidos_ok,
  to_regclass('public.vista_saldos_vacaciones_v27') is not null as vista_saldos_ok,
  to_regclass('public.vista_ausencias_v27') is not null as vista_ausencias_ok;

select
  to_regprocedure('public.usuario_puede_nomina(boolean)') is not null
    as acceso_nomina_ok,
  to_regprocedure('public.calcular_dias_habiles_v27(uuid,date,date,uuid)') is not null
    as calculo_habiles_ok,
  to_regprocedure('public.configurar_feriados_v27(uuid,integer,jsonb,boolean,text,uuid)') is not null
    as configurar_feriados_ok,
  to_regprocedure('public.generar_periodos_vacaciones_v27(uuid,date,uuid)') is not null
    as generar_periodos_ok,
  to_regprocedure('public.solicitar_ausencia_v27(uuid,text,date,date,numeric,uuid,uuid,text,uuid)') is not null
    as solicitar_ausencia_ok,
  to_regprocedure('public.resolver_ausencia_v27(uuid,boolean,text,uuid)') is not null
    as resolver_ausencia_ok,
  to_regprocedure('public.anular_ausencia_v27(uuid,text,uuid)') is not null
    as anular_ausencia_ok;

select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and (table_name, column_name) in (
    ('feriados', 'anio'),
    ('feriados', 'almacen_id'),
    ('vacaciones_periodos', 'dias_saldo'),
    ('ausencias', 'dias_calendario'),
    ('ausencias', 'dias_habiles'),
    ('ausencias', 'vacaciones_periodo_id'),
    ('ausencias', 'documento_respaldo_id'),
    ('ausencias', 'idempotency_key'),
    ('ausencia_vacaciones_aplicaciones', 'orden_fifo'),
    ('ausencia_vacaciones_aplicaciones', 'estado'),
    ('nomina_eventos', 'estado_anterior'),
    ('nomina_eventos', 'estado_nuevo'),
    ('nomina_eventos', 'datos'),
    ('nomina_eventos', 'idempotency_key')
  )
order by table_name, column_name;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'feriados_anios', 'feriados', 'vacaciones_periodos', 'ausencias',
    'ausencia_vacaciones_aplicaciones', 'nomina_eventos'
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
where n.nspname = 'public'
  and c.relname in ('vista_saldos_vacaciones_v27', 'vista_ausencias_v27')
order by c.relname;

select indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and indexname in (
    'uq_feriados_nacionales_v27', 'uq_feriados_locales_v27',
    'uq_nomina_eventos_idempotency_v27'
  )
order by indexname;

select
  has_function_privilege(
    'authenticated',
    'public.solicitar_ausencia_v27(uuid,text,date,date,numeric,uuid,uuid,text,uuid)',
    'execute'
  ) as solicitar_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.resolver_ausencia_v27(uuid,boolean,text,uuid)',
    'execute'
  ) as resolver_authenticated_ok,
  has_function_privilege(
    'anon',
    'public.resolver_ausencia_v27(uuid,boolean,text,uuid)',
    'execute'
  ) as resolver_anon_debe_ser_false,
  has_function_privilege(
    'authenticated',
    'public.asegurar_periodos_vacaciones_v27(uuid,date)',
    'execute'
  ) as generador_interno_authenticated_debe_ser_false,
  has_table_privilege('authenticated', 'public.ausencias', 'insert')
    as insert_directo_ausencias_debe_ser_false,
  has_table_privilege('authenticated', 'public.vacaciones_periodos', 'update')
    as update_directo_saldos_debe_ser_false;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  case when p.proname = 'resolver_ausencia_v27'
    then position('order by vp.periodo_desde' in lower(pg_get_functiondef(p.oid))) > 0
    else null end as fifo_por_periodo_antiguo,
  case when p.proname = 'anular_ausencia_v27'
    then position('dias_restituidos' in pg_get_functiondef(p.oid)) > 0
    else null end as reversion_compensatoria,
  case when p.proname = 'solicitar_ausencia_v27'
    then position('documento de respaldo' in pg_get_functiondef(p.oid)) > 0
    else null end as exige_respaldo_si_corresponde
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'configurar_feriados_v27', 'generar_periodos_vacaciones_v27',
    'solicitar_ausencia_v27', 'resolver_ausencia_v27',
    'anular_ausencia_v27'
  )
order by p.proname;

-- Todos los siguientes resultados deben ser cero.

-- Un calendario confirmado vacio permitiria calcular dias habiles falsos.
select count(*) as calendarios_confirmados_sin_feriados_nacionales_debe_ser_cero
from public.feriados_anios fa
where fa.estado = 'confirmado' and not exists (
  select 1 from public.feriados f
  where f.feriados_anio_id = fa.id and f.tipo = 'nacional' and f.activo
);

select count(*) as feriados_fuera_de_calendario_debe_ser_cero
from public.feriados f
join public.feriados_anios fa on fa.id = f.feriados_anio_id
where f.grupo_id <> fa.grupo_id or f.anio <> fa.anio
   or extract(year from f.fecha)::integer <> f.anio
   or (f.tipo = 'nacional' and f.almacen_id is not null)
   or (f.tipo = 'local' and f.almacen_id is null);

select count(*) as periodos_con_saldo_invalido_debe_ser_cero
from public.vacaciones_periodos
where dias_tomados < 0 or dias_pagados < 0 or dias_saldo < 0
   or dias_saldo <> dias_derecho - dias_tomados - dias_pagados
   or (estado = 'agotado' and dias_saldo <> 0);

select count(*) as periodos_fuera_de_aniversario_debe_ser_cero
from public.vacaciones_periodos vp
join public.empleados e on e.id = vp.empleado_id
where vp.periodo_desde < e.fecha_ingreso_real
   or vp.periodo_desde <>
      (e.fecha_ingreso_real + make_interval(years => vp.anos_servicio - 1))::date
   or vp.periodo_hasta <>
      (e.fecha_ingreso_real + make_interval(years => vp.anos_servicio))::date - 1;

select count(*) as servicios_profesionales_con_vacaciones_debe_ser_cero
from public.vacaciones_periodos vp
join public.empleados e on e.id = vp.empleado_id
where e.tipo_contrato = 'servicios_profesionales';

select count(*) as vacaciones_aprobadas_a_servicios_profesionales_debe_ser_cero
from public.ausencias a
join public.empleados e on e.id = a.empleado_id
where a.tipo = 'vacaciones' and a.estado = 'aprobada'
  and e.tipo_contrato = 'servicios_profesionales';

-- dias_tomados debe provenir exclusivamente de aplicaciones FIFO vigentes.
select count(*) as periodos_con_tomados_sin_aplicacion_debe_ser_cero
from public.vacaciones_periodos vp
left join lateral (
  select coalesce(sum(a.dias_aplicados), 0)::numeric(7,2) aplicado
  from public.ausencia_vacaciones_aplicaciones a
  where a.vacaciones_periodo_id = vp.id and a.estado = 'aplicada'
) x on true
where vp.dias_tomados <> x.aplicado;

select count(*) as vacaciones_aprobadas_sin_fifo_completo_debe_ser_cero
from public.ausencias a
left join lateral (
  select coalesce(sum(av.dias_aplicados), 0)::numeric(7,2) aplicado
  from public.ausencia_vacaciones_aplicaciones av
  where av.ausencia_id = a.id and av.estado = 'aplicada'
) x on true
where a.tipo = 'vacaciones' and a.estado = 'aprobada'
  and (x.aplicado <> a.dias_calendario or a.vacaciones_periodo_id is null);

select count(*) as aplicaciones_en_ausencias_no_vacacionales_debe_ser_cero
from public.ausencia_vacaciones_aplicaciones av
join public.ausencias a on a.id = av.ausencia_id
where a.tipo <> 'vacaciones';

select count(*) as aplicaciones_fifo_con_empleado_ajeno_debe_ser_cero
from public.ausencia_vacaciones_aplicaciones av
join public.ausencias a on a.id = av.ausencia_id
join public.vacaciones_periodos vp on vp.id = av.vacaciones_periodo_id
where a.empleado_id <> vp.empleado_id;

-- El orden guardado debe avanzar siempre del periodo mas antiguo al nuevo.
-- Se valida la instantanea de la ausencia porque una anulacion posterior
-- puede restituir saldo en un periodo que era el mas antiguo.
select count(*) as aplicaciones_fuera_de_fifo_debe_ser_cero
from (
  select av.ausencia_id, av.orden_fifo, vp.periodo_desde,
         lag(vp.periodo_desde) over (
           partition by av.ausencia_id order by av.orden_fifo
         ) as periodo_anterior
  from public.ausencia_vacaciones_aplicaciones av
  join public.vacaciones_periodos vp on vp.id = av.vacaciones_periodo_id
  where av.estado = 'aplicada'
) secuencia
where periodo_anterior is not null and periodo_desde <= periodo_anterior;

select count(*) as ausencias_aprobadas_superpuestas_debe_ser_cero
from public.ausencias a
join public.ausencias b on b.empleado_id = a.empleado_id and b.id > a.id
where a.estado = 'aprobada' and b.estado = 'aprobada'
  and daterange(a.fecha_desde, a.fecha_hasta, '[]')
      && daterange(b.fecha_desde, b.fecha_hasta, '[]');

select count(*) as respaldos_de_otro_empleado_debe_ser_cero
from public.ausencias a
join public.empleado_documentos d on d.id = a.documento_respaldo_id
where d.empleado_id <> a.empleado_id;

select count(*) as ausencias_obligatorias_sin_respaldo_debe_ser_cero
from public.ausencias
where tipo in (
  'enfermedad_iess', 'enfermedad_particular', 'maternidad',
  'paternidad', 'calamidad_domestica', 'suspension_disciplinaria'
) and documento_respaldo_id is null;

select count(*) as anulaciones_vacacionales_sin_reversa_debe_ser_cero
from public.ausencias a
where a.tipo = 'vacaciones' and a.estado = 'anulada'
  and exists (
    select 1 from public.ausencia_vacaciones_aplicaciones av
    where av.ausencia_id = a.id and av.estado = 'aplicada'
  );

select count(*) as eventos_v27_sin_control_debe_ser_cero
from public.nomina_eventos
where entidad in ('calendario_feriados', 'periodos_vacaciones', 'ausencia')
  and (usuario_id is null or btrim(coalesce(detalle, '')) = ''
    or idempotency_key is null);

-- Informativo: mas de tres periodos con saldo requiere decision de Nomina;
-- el sistema alerta, pero nunca extingue automaticamente un derecho laboral.
select empleado_id, identificacion, apellidos, nombres, dias_saldo,
       periodos_con_saldo, saldo_mas_antiguo_desde
from public.vista_saldos_vacaciones_v27
where alerta_mas_tres_periodos
order by apellidos, nombres;

select
  count(*) filter (where estado = 'solicitada') as ausencias_solicitadas,
  count(*) filter (where estado = 'aprobada') as ausencias_aprobadas,
  count(*) filter (where estado = 'rechazada') as ausencias_rechazadas,
  count(*) filter (where estado = 'anulada') as ausencias_anuladas,
  coalesce(sum(dias_calendario) filter (
    where tipo = 'vacaciones' and estado = 'aprobada'
  ), 0) as dias_vacaciones_aprobados
from public.ausencias;

select
  count(*) as empleados_con_periodos,
  coalesce(sum(dias_derecho), 0) as dias_generados,
  coalesce(sum(dias_tomados), 0) as dias_tomados,
  coalesce(sum(dias_pagados), 0) as dias_pagados,
  coalesce(sum(dias_saldo), 0) as dias_pendientes
from public.vacaciones_periodos;
