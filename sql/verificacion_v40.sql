-- ============================================================
-- Verificacion v40 - Integridad de permisos y vinculos de nomina
-- Solo lectura: ejecutar despues de instalar v40.
-- ============================================================

select
  to_regprocedure('public.usuario_puede_empresa(uuid,boolean)') is not null
    as acceso_empresa_ok,
  to_regprocedure('public.validar_integridad_vinculo_nomina_v40()') is not null
    as control_vinculos_ok,
  to_regprocedure('public.calcular_aportes_capacitacion_v40()') is not null
    as calculo_iece_secap_ok;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'nomina_rol_lineas'
  and column_name in ('aporte_iece', 'aporte_secap')
order by column_name;

select
  position(
    'public.usuario_puede_nomina(false)' in pg_get_functiondef(
      'public.usuario_puede_empresa(uuid,boolean)'::regprocedure
    )
  ) > 0 as lectura_sigue_permiso_nomina_ok,
  position(
    'not p_escritura' in pg_get_functiondef(
      'public.usuario_puede_empresa(uuid,boolean)'::regprocedure
    )
  ) > 0 as permiso_nomina_solo_lectura_ok;

select trigger_name, event_object_table, action_timing
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name in (
    'trg_aportes_capacitacion_v40',
    'trg_integridad_compensacion_v40',
    'trg_integridad_afiliacion_v40'
  )
order by trigger_name;

select
  has_function_privilege(
    'authenticated', 'public.usuario_puede_empresa(uuid,boolean)', 'execute'
  ) as acceso_empresa_authenticated_ok,
  not has_function_privilege(
    'anon', 'public.usuario_puede_empresa(uuid,boolean)', 'execute'
  ) as acceso_empresa_anon_bloqueado_ok,
  not has_function_privilege(
    'authenticated', 'public.validar_integridad_vinculo_nomina_v40()', 'execute'
  ) as trigger_no_ejecutable_directamente_ok;

-- Valores esperados para la configuracion estandar del sector privado en
-- 2026. Confirmar cualquier regimen o exencion particular con Contabilidad.
select
  exists (
    select 1 from public.nomina_parametros where anio = 2026
  ) as parametros_2026_existen,
  coalesce((
    select salario_basico_unificado = 482
    from public.nomina_parametros where anio = 2026
  ), false) as sbu_2026_es_482,
  coalesce((
    select pct_aporte_personal = 9.45 and pct_aporte_patronal = 11.15
    from public.nomina_parametros where anio = 2026
  ), false) as aportes_iess_2026_ok,
  coalesce((
    select pct_iece = 0.50 and pct_secap = 0.50
    from public.nomina_parametros where anio = 2026
  ), false) as iece_secap_2026_ok;

-- Todos los siguientes resultados deben ser cero.

select count(*) as compensaciones_con_empresa_de_otro_grupo_debe_ser_cero
from public.empleado_compensacion c
join public.empleados e on e.id = c.empleado_id
join public.empresas ep on ep.id = c.empresa_pagadora_id
where ep.grupo_id <> e.grupo_id;

select count(*) as afiliaciones_con_empresa_de_otro_grupo_debe_ser_cero
from public.empleado_afiliaciones a
join public.empleados e on e.id = a.empleado_id
join public.empresas ep on ep.id = a.empresa_id
where a.afiliado and ep.grupo_id <> e.grupo_id;

select count(*) as compensaciones_con_respaldo_ajeno_debe_ser_cero
from public.empleado_compensacion c
join public.empleado_documentos d on d.id = c.documento_respaldo_id
where d.empleado_id <> c.empleado_id;

select count(*) as afiliaciones_con_respaldo_ajeno_debe_ser_cero
from public.empleado_afiliaciones a
join public.empleado_documentos d on d.id = a.documento_respaldo_id
where d.empleado_id <> a.empleado_id;

-- Debe ser cero para todo periodo calculado DESPUES de instalar v40. Si
-- aparece un periodo que ya estaba calculado antes, reabrelo y recalculalo.
-- Los cerrados se informan abajo y no se modifican automaticamente.
select count(*) as roles_calculados_sin_iece_secap_debe_ser_cero
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.nomina_parametros prm on prm.anio = p.anio
where p.estado = 'calculado'
  and (
    l.aporte_iece <> round(l.base_aportacion_declarada * prm.pct_iece / 100, 2)
    or l.aporte_secap <> round(l.base_aportacion_declarada * prm.pct_secap / 100, 2)
  );

-- Informativo: no tocar automaticamente un rol cerrado. Si devuelve filas,
-- Nomina debe conciliar el historico antes de decidir un ajuste compensatorio.
select p.anio, p.mes, count(*) as roles_cerrados_anteriores,
       coalesce(sum(l.base_aportacion_declarada), 0) as base_declarada,
       prm.pct_iece,
       coalesce(sum(round(
         l.base_aportacion_declarada * prm.pct_iece / 100, 2
       )), 0) as iece_no_desglosado,
       prm.pct_secap,
       coalesce(sum(round(
         l.base_aportacion_declarada * prm.pct_secap / 100, 2
       )), 0) as secap_no_desglosado,
       coalesce(sum(
         round(l.base_aportacion_declarada * prm.pct_iece / 100, 2)
         + round(l.base_aportacion_declarada * prm.pct_secap / 100, 2)
       ), 0) as aporte_no_desglosado
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id and p.estado = 'cerrado'
join public.nomina_parametros prm on prm.anio = p.anio
where l.aporte_iece = 0 and l.aporte_secap = 0
  and l.base_aportacion_declarada > 0
group by p.anio, p.mes, prm.pct_iece, prm.pct_secap
order by p.anio, p.mes;
