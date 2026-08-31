-- ============================================================
-- Verificacion v29 - Anticipos y descuentos
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v29 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.anticipos') is not null as anticipos_ok,
  to_regclass('public.descuentos_programados') is not null as descuentos_ok,
  to_regclass('public.descuento_programado_cuotas') is not null as cuotas_ok,
  to_regclass('public.descuento_aplicacion_lotes') is not null as lotes_ok,
  to_regclass('public.descuento_aplicaciones') is not null as aplicaciones_ok,
  to_regclass('public.vista_anticipos_v29') is not null as vista_anticipos_ok,
  to_regclass('public.vista_descuentos_programados_v29') is not null
    as vista_descuentos_ok;

select
  to_regprocedure('public.registrar_descuento_programado_v29(uuid,uuid,text,uuid,text,numeric,integer,date,uuid,integer,uuid)') is not null
    as registrar_descuento_ok,
  to_regprocedure('public.solicitar_anticipo_v29(uuid,uuid,date,numeric,text,integer,date,uuid,uuid)') is not null
    as solicitar_anticipo_ok,
  to_regprocedure('public.resolver_anticipo_v29(uuid,boolean,text,uuid)') is not null
    as resolver_anticipo_ok,
  to_regprocedure('public.desembolsar_anticipo_v29(uuid,text,text,uuid)') is not null
    as desembolsar_anticipo_ok,
  to_regprocedure('public.anular_anticipo_v29(uuid,text,uuid)') is not null
    as anular_anticipo_ok,
  to_regprocedure('public.resolver_descuento_programado_v29(uuid,text,text,uuid)') is not null
    as resolver_descuento_ok,
  to_regprocedure('public.registrar_descuento_multa_v29(uuid,integer,date,uuid,uuid)') is not null
    as registrar_multa_ok,
  to_regprocedure('public.revertir_descuento_multa_v29(uuid,text,uuid)') is not null
    as revertir_multa_ok,
  to_regprocedure('public.aplicar_descuentos_periodo_v29(uuid,integer,integer,numeric,numeric,uuid,uuid)') is not null
    as motor_descuentos_ok,
  to_regprocedure('public.revertir_aplicacion_descuentos_v29(uuid,text,uuid)') is not null
    as reversa_motor_ok;

select exists (
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'nomina_parametros'
    and column_name = 'tope_retencion_empleador_pct'
) as tope_retencion_empleador_ok;

select c.conname, pg_get_constraintdef(c.oid) as definicion
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and c.conname in (
    'anticipos_descuento_programado_fkey',
    'novedades_empleado_descuento_id_fkey'
  )
order by c.conname;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'anticipos', 'descuentos_programados', 'descuento_programado_cuotas',
    'descuento_aplicacion_lotes', 'descuento_aplicaciones'
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
  and c.relname in ('vista_anticipos_v29', 'vista_descuentos_programados_v29')
order by c.relname;

select
  has_function_privilege(
    'authenticated',
    'public.solicitar_anticipo_v29(uuid,uuid,date,numeric,text,integer,date,uuid,uuid)',
    'execute'
  ) as solicitar_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.registrar_descuento_multa_v29(uuid,integer,date,uuid,uuid)',
    'execute'
  ) as multa_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.registrar_descuento_multa_v29(uuid,integer,date,uuid,uuid)',
    'execute'
  ) as multa_anon_debe_ser_true,
  not has_function_privilege(
    'authenticated',
    'public.crear_programa_descuento_v29(uuid,uuid,text,uuid,text,numeric,integer,date,uuid,integer,uuid)',
    'execute'
  ) as constructor_interno_debe_ser_true,
  not has_function_privilege(
    'authenticated',
    'public.aplicar_descuentos_periodo_v29(uuid,integer,integer,numeric,numeric,uuid,uuid)',
    'execute'
  ) as motor_interno_debe_ser_true,
  not has_table_privilege('authenticated', 'public.anticipos', 'insert')
    as insert_directo_anticipos_debe_ser_true,
  not has_table_privilege('authenticated', 'public.descuentos_programados', 'update')
    as update_directo_descuentos_debe_ser_true;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  case when p.proname = 'aplicar_descuentos_periodo_v29'
    then position('categoria_tope = ''judicial''' in pg_get_functiondef(p.oid)) > 0
    else null end as prioriza_judicial_si_corresponde,
  case when p.proname = 'aplicar_descuentos_periodo_v29'
    then position('tope_retencion_empleador_pct' in pg_get_functiondef(p.oid)) > 0
    else null end as controla_tope_empleador_si_corresponde,
  case when p.proname = 'revertir_descuento_multa_v29'
    then position('monto_aplicado > 0' in pg_get_functiondef(p.oid)) > 0
    else null end as bloquea_multa_ya_aplicada_si_corresponde
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'registrar_descuento_programado_v29', 'solicitar_anticipo_v29',
    'resolver_anticipo_v29', 'desembolsar_anticipo_v29',
    'registrar_descuento_multa_v29', 'revertir_descuento_multa_v29',
    'aplicar_descuentos_periodo_v29', 'revertir_aplicacion_descuentos_v29'
  )
order by p.proname;

-- Todos los siguientes resultados deben ser cero.

select count(*) as anticipos_desembolsados_sin_descuento_debe_ser_cero
from public.anticipos a
left join public.descuentos_programados d on d.id = a.descuento_programado_id
where a.estado = 'desembolsado'
  and (
    d.id is null or d.origen <> 'anticipo' or d.origen_id <> a.id
    or d.empleado_id <> a.empleado_id
    or d.empresa_acreedora_id <> a.empresa_pagadora_id
    or d.monto_total <> a.monto
  );

select count(*) as descuentos_con_cuotas_inconsistentes_debe_ser_cero
from public.descuentos_programados d
left join lateral (
  select count(*)::integer total_cuotas,
         count(*) filter (where c.estado = 'aplicada')::integer pagadas,
         coalesce(sum(c.monto), 0)::numeric(14,2) monto,
         coalesce(sum(c.monto_aplicado), 0)::numeric(14,2) aplicado,
         min(c.fecha_prevista) inicio,
         max(c.fecha_prevista) fin
  from public.descuento_programado_cuotas c
  where c.descuento_programado_id = d.id
) x on true
where x.total_cuotas <> d.cuotas_total
   or x.pagadas <> d.cuotas_pagadas
   or x.monto <> d.monto_total
   or x.aplicado <> d.monto_aplicado
   or x.inicio <> d.fecha_inicio
   or x.fin <> d.fecha_fin;

select count(*) as secuencias_cuotas_invalidas_debe_ser_cero
from (
  select c.descuento_programado_id,
         min(c.numero) minimo, max(c.numero) maximo, count(*) total,
         count(distinct c.fecha_prevista) fechas_distintas
  from public.descuento_programado_cuotas c
  group by c.descuento_programado_id
) s
where s.minimo <> 1 or s.maximo <> s.total or s.fechas_distintas <> s.total;

select count(*) as saldos_descuento_invalidos_debe_ser_cero
from public.descuentos_programados
where saldo < 0
   or monto_aplicado + monto_condonado + saldo <> monto_total
   or (estado in ('pagado', 'condonado') and saldo <> 0);

select count(*) as fuentes_activas_duplicadas_debe_ser_cero
from (
  select origen, origen_id
  from public.descuentos_programados
  where origen_id is not null and estado <> 'anulado'
  group by origen, origen_id
  having count(*) > 1
) duplicadas;

select count(*) as multas_enlazadas_inconsistentes_debe_ser_cero
from public.novedades_empleado n
join public.descuentos_programados d on d.id = n.descuento_id
where not n.genera_descuento
   or n.tipo <> 'sancion_economica'
   or d.origen <> 'multa'
   or d.origen_id <> n.id
   or d.empleado_id <> n.empleado_id
   or d.empresa_acreedora_id <> n.empresa_id
   or d.monto_total <> n.monto_descuento
   or d.estado = 'anulado';

select count(*) as lotes_con_totales_inconsistentes_debe_ser_cero
from public.descuento_aplicacion_lotes l
left join lateral (
  select
    coalesce(sum(a.monto_aplicado), 0)::numeric(14,2) total,
    coalesce(sum(a.monto_diferido), 0)::numeric(14,2) diferido,
    coalesce(sum(a.monto_aplicado) filter (
      where a.categoria_tope = 'judicial'
    ), 0)::numeric(14,2) judicial,
    coalesce(sum(a.monto_aplicado) filter (
      where a.categoria_tope = 'iess'
    ), 0)::numeric(14,2) iess,
    coalesce(sum(a.monto_aplicado) filter (
      where a.categoria_tope = 'empleador'
    ), 0)::numeric(14,2) empleador,
    coalesce(sum(a.monto_aplicado) filter (
      where d.origen = 'multa'
    ), 0)::numeric(14,2) multas
  from public.descuento_aplicaciones a
  join public.descuentos_programados d on d.id = a.descuento_programado_id
  where a.lote_id = l.id and a.estado = 'aplicada'
) x on true
where l.estado = 'aplicado'
  and (
    l.total_aplicado <> x.total or l.total_diferido <> x.diferido
    or l.total_judicial <> x.judicial or l.total_iess <> x.iess
    or l.total_empleador <> x.empleador or l.total_multas <> x.multas
  );

select count(*) as lotes_fuera_de_topes_debe_ser_cero
from public.descuento_aplicacion_lotes
where estado = 'aplicado'
  and (
    total_aplicado > neto_disponible_inicial
    or total_iess + total_empleador > tope_global
    or total_empleador > tope_empleador
    or total_multas > tope_multas
  );

select count(*) as aplicaciones_inconsistentes_debe_ser_cero
from public.descuento_aplicaciones a
join public.descuento_programado_cuotas c on c.id = a.cuota_id
where c.descuento_programado_id <> a.descuento_programado_id
   or a.monto_aplicado + a.monto_diferido <> a.monto_pendiente
   or (a.monto_diferido > 0 and btrim(coalesce(a.motivo_diferimiento, '')) = '');

select count(*) as lotes_revertidos_con_aplicaciones_vigentes_debe_ser_cero
from public.descuento_aplicacion_lotes l
join public.descuento_aplicaciones a on a.lote_id = l.id
where l.estado = 'revertido' and a.estado <> 'revertida';

select count(*) as eventos_v29_sin_control_debe_ser_cero
from public.nomina_eventos
where entidad in ('anticipo', 'descuento', 'descuento_aplicacion')
  and (usuario_id is null or idempotency_key is null
    or btrim(coalesce(tipo, '')) = '');

-- Panorama informativo.
select
  count(*) filter (where estado = 'solicitado') as anticipos_solicitados,
  count(*) filter (where estado = 'aprobado') as anticipos_aprobados,
  count(*) filter (where estado = 'desembolsado') as anticipos_desembolsados,
  coalesce(sum(monto) filter (where estado = 'desembolsado'), 0)
    as monto_desembolsado
from public.anticipos;

select
  origen,
  count(*) filter (where estado in ('vigente', 'suspendido')) as obligaciones_abiertas,
  coalesce(sum(saldo) filter (where estado in ('vigente', 'suspendido')), 0)
    as saldo_pendiente,
  coalesce(sum(monto_aplicado), 0) as total_descontado
from public.descuentos_programados
group by origen
order by origen;

select count(*) as multas_v28_pendientes_de_programar
from public.vista_multas_pendientes_v28;
