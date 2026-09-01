-- ============================================================
-- Verificacion v41 - Antiguedad acumulada para fondos de reserva
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v41 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regprocedure('public.dias_servicio_fondo_reserva_v41(uuid,uuid,date)') is not null
    as acumulador_ok,
  to_regprocedure('public.dias_requeridos_fondo_reserva_v41(uuid,uuid)') is not null
    as umbral_calendario_ok,
  to_regprocedure('public.cumple_fondo_reserva_v41(uuid,uuid,date)') is not null
    as evaluador_ok,
  to_regclass('public.vista_antiguedad_fondo_reserva_v41') is not null
    as vista_control_ok;

select
  position(
    'cumple_fondo_reserva_v41(l.empleado_id, l.empresa_afiliacion_id, p.fecha_hasta)'
    in pg_get_functiondef(p.oid)
  ) > 0 as calculo_usa_antiguedad_acumulada,
  position(
    'p.fecha_hasta >= (l.fecha_afiliacion + interval ''1 year'')::date'
    in pg_get_functiondef(p.oid)
  ) = 0 as calculo_ya_no_reinicia_fecha
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'calcular_rol_v30';

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
  and c.relname = 'vista_antiguedad_fondo_reserva_v41';

select
  has_function_privilege(
    'authenticated',
    'public.cumple_fondo_reserva_v41(uuid,uuid,date)', 'execute'
  ) as evaluador_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.cumple_fondo_reserva_v41(uuid,uuid,date)', 'execute'
  ) as evaluador_anon_debe_ser_true,
  has_function_privilege(
    'authenticated', 'public.calcular_rol_v30(uuid,uuid)', 'execute'
  ) as calcular_rol_authenticated_ok,
  not has_function_privilege(
    'anon', 'public.calcular_rol_v30(uuid,uuid)', 'execute'
  ) as calcular_rol_anon_debe_ser_true;

-- Todos los siguientes resultados deben ser cero.

-- Las afiliaciones historizadas no deben solaparse: un solapamiento podria
-- contar dos veces el mismo dia. El acumulador se protege fusionandolos,
-- pero este resultado permite corregir la causa.
select count(*) as afiliaciones_mismo_ruc_solapadas_debe_ser_cero
from public.empleado_afiliaciones a
join public.empleado_afiliaciones b
  on b.empleado_id = a.empleado_id
 and b.empresa_id = a.empresa_id
 and b.id > a.id
where a.afiliado and b.afiliado
  and daterange(a.fecha_desde, coalesce(a.fecha_hasta, 'infinity'::date), '[]')
      && daterange(b.fecha_desde, coalesce(b.fecha_hasta, 'infinity'::date), '[]');

-- Un vinculo laboral debe corresponder a un solo empleador. Si aparecen dos
-- RUC distintos, Nomina debe decidir si hubo una correccion o si faltaba
-- registrar una salida y un nuevo vinculo.
select count(*) as vinculos_con_mas_de_un_ruc_debe_ser_cero
from (
  select v.id
  from public.empleado_vinculos v
  join public.empleado_afiliaciones a
    on a.empleado_id = v.empleado_id
   and a.afiliado
   and a.fecha_desde <= coalesce(v.fecha_salida, current_date)
   and coalesce(a.fecha_hasta, current_date) >= v.fecha_ingreso
  group by v.id
  having count(distinct a.empresa_id) > 1
) ambiguos;

select count(*) as vinculos_sin_ruc_empleador_debe_ser_cero
from public.empleado_vinculos v
where not exists (
  select 1
  from public.empleado_afiliaciones a
  where a.empleado_id = v.empleado_id
    and a.afiliado
    and a.fecha_desde <= coalesce(v.fecha_salida, current_date)
    and coalesce(a.fecha_hasta, current_date) >= v.fecha_ingreso
)
and not exists (
  select 1
  from public.empleado_compensacion c
  where c.empleado_id = v.empleado_id
    and c.fecha_desde <= coalesce(v.fecha_salida, current_date)
    and coalesce(c.fecha_hasta, current_date) >= v.fecha_ingreso
);

select count(*) as acumulados_invalidos_debe_ser_cero
from public.vista_antiguedad_fondo_reserva_v41
where dias_acumulados < 0
   or dias_requeridos not in (365, 366)
   or derecho_adquirido <> (dias_acumulados >= dias_requeridos);

-- Informativo: roles ya calculados con la regla anterior que deben revisarse.
-- Un periodo abierto o calculado se puede reabrir/recalcular; uno cerrado
-- requiere una rectificacion controlada y nunca se altera silenciosamente.
select count(*) as roles_historicos_con_derecho_omitido_para_revisar
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
where l.calculado_at is not null
  and l.afiliado
  and l.sueldo_proporcional_real + l.valor_horas_extra
      + l.comisiones + l.bonos > 0
  and public.cumple_fondo_reserva_v41(
    l.empleado_id, l.empresa_afiliacion_id, p.fecha_hasta
  )
  and (
    (l.paga_fondos_reserva_mensual and l.fondos_reserva_pagados = 0)
    or (not l.paga_fondos_reserva_mensual and l.provision_fondos_reserva = 0)
  );

-- Informativo: personas cuyo historial tiene mas de un segmento en el mismo
-- RUC. Incluye reingresos y cambios de sueldo/afiliacion historizados.
select identificacion, nombre_completo, ruc, empresa,
       segmentos_historial, dias_acumulados, dias_requeridos,
       derecho_adquirido, vigente_en_ruc
from public.vista_antiguedad_fondo_reserva_v41
where segmentos_historial > 1
order by nombre_completo, ruc;
