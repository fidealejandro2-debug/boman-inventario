  -- ============================================================
  -- Verificacion v30 - Periodos y calculo de nomina
  -- Solo lectura: no modifica datos.
  -- Compatible con Supabase SQL Editor (no usa comandos de psql).
  -- Ejecutar despues de instalar v30 y nunca en paralelo con la migracion.
  -- ============================================================

  select
    to_regclass('public.nomina_periodos') is not null as periodos_ok,
    to_regclass('public.nomina_rol_lineas') is not null as roles_ok,
    to_regclass('public.nomina_rubros') is not null as rubros_ok,
    to_regclass('public.nomina_rol_rubros') is not null as detalle_rubros_ok,
    to_regclass('public.nomina_eventos') is not null as eventos_compartidos_ok,
    to_regclass('public.vista_rol_real') is not null as vista_real_ok,
    to_regclass('public.vista_rol_declarado') is not null as vista_declarada_ok,
    to_regclass('public.vista_brecha_nomina') is not null as vista_brecha_ok,
    to_regclass('public.vista_costo_empleador_por_empresa') is not null
      as vista_costos_ok,
    to_regclass('public.vista_pagos_por_empresa') is not null as vista_pagos_ok;

  select
    to_regprocedure('public.obtener_parametro_nomina_v30(integer,text)') is not null
      as obtener_parametro_ok,
    to_regprocedure('public.configurar_beneficios_empleado_v30(uuid,boolean,boolean,boolean,text,uuid)') is not null
      as configurar_beneficios_ok,
    to_regprocedure('public.abrir_periodo_nomina_v30(uuid,integer,integer,uuid)') is not null
      as abrir_periodo_ok,
    to_regprocedure('public.guardar_novedades_rol_v30(uuid,jsonb,integer,uuid)') is not null
      as guardar_novedades_ok,
    to_regprocedure('public.calcular_rol_v30(uuid,uuid)') is not null
      as calcular_rol_ok,
    to_regprocedure('public.reabrir_periodo_nomina_v30(uuid,text,uuid)') is not null
      as reabrir_periodo_ok,
    to_regprocedure('public.cerrar_periodo_nomina_v30(uuid,text,uuid)') is not null
      as cerrar_periodo_ok;

  select table_name, column_name
  from information_schema.columns
  where table_schema = 'public'
    and (table_name, column_name) in (
      ('empleado_compensacion', 'mensualiza_decimo_tercero'),
      ('empleado_compensacion', 'mensualiza_decimo_cuarto'),
      ('empleado_compensacion', 'paga_fondos_reserva_mensual'),
      ('nomina_periodos', 'idempotency_key'),
      ('nomina_periodos', 'version'),
      ('nomina_rol_lineas', 'empresa_afiliacion_id'),
      ('nomina_rol_lineas', 'empresa_pagadora_id'),
      ('nomina_rol_lineas', 'sueldo_declarado'),
      ('nomina_rol_lineas', 'sueldo_real'),
      ('nomina_rol_lineas', 'tipo_contrato'),
      ('nomina_rol_lineas', 'afiliacion_desde'),
      ('nomina_rol_lineas', 'dias_afiliados'),
      ('nomina_rol_lineas', 'descuento_lote_id'),
      ('nomina_rol_lineas', 'provision_fondos_reserva_declarada'),
      ('nomina_rol_lineas', 'neto_real'),
      ('nomina_rol_lineas', 'neto_declarado'),
      ('nomina_rol_lineas', 'brecha'),
      ('nomina_eventos', 'idempotency_key')
    )
  order by table_name, column_name;

  select c.conname, pg_get_constraintdef(c.oid) as definicion
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public'
    and c.conname = 'descuento_lotes_rol_linea_fkey_v30';

  select tablename, rowsecurity
  from pg_tables
  where schemaname = 'public'
    and tablename in (
      'nomina_periodos', 'nomina_rol_lineas',
      'nomina_rubros', 'nomina_rol_rubros'
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
    and c.relname in (
      'vista_rol_real', 'vista_rol_declarado', 'vista_brecha_nomina',
      'vista_costo_empleador_por_empresa', 'vista_pagos_por_empresa'
    )
  order by c.relname;

  select trigger_name, event_object_table, action_timing
  from information_schema.triggers
  where trigger_schema = 'public'
    and trigger_name in (
      'trg_proteger_nomina_rol_v30',
      'trg_proteger_nomina_rubros_v30',
      'trg_proteger_periodo_cerrado_v30'
    )
  order by trigger_name;

  select
    has_function_privilege(
      'authenticated',
      'public.abrir_periodo_nomina_v30(uuid,integer,integer,uuid)', 'execute'
    ) as abrir_authenticated_ok,
    has_function_privilege(
      'authenticated', 'public.calcular_rol_v30(uuid,uuid)', 'execute'
    ) as calcular_authenticated_ok,
    has_function_privilege(
      'authenticated',
      'public.reabrir_periodo_nomina_v30(uuid,text,uuid)', 'execute'
    ) as reabrir_authenticated_ok,
    not has_function_privilege(
      'anon', 'public.calcular_rol_v30(uuid,uuid)', 'execute'
    ) as calcular_anon_debe_ser_true,
    not has_function_privilege(
      'authenticated',
      'public.registrar_evento_nomina_v30(text,uuid,uuid,text,text,text,text,jsonb,uuid)',
      'execute'
    ) as auditor_interno_debe_ser_true,
    not has_table_privilege('authenticated', 'public.nomina_periodos', 'insert')
      as insert_directo_periodos_debe_ser_true,
    not has_table_privilege('authenticated', 'public.nomina_rol_lineas', 'update')
      as update_directo_roles_debe_ser_true;

  select
    p.proname,
    p.prosecdef as security_definer,
    pg_get_userbyid(p.proowner) as propietario,
    case when p.proname in (
      'abrir_periodo_nomina_v30', 'guardar_novedades_rol_v30',
      'calcular_rol_v30', 'reabrir_periodo_nomina_v30',
      'cerrar_periodo_nomina_v30'
    ) then position('idempotencia' in lower(pg_get_functiondef(p.oid))) > 0
    else null end as valida_idempotencia_si_corresponde,
    case when p.proname = 'calcular_rol_v30'
      then position('aplicar_descuentos_periodo_v29' in pg_get_functiondef(p.oid)) > 0
      else null end as integra_descuentos_v29,
    case when p.proname = 'reabrir_periodo_nomina_v30'
      then position('revertir_aplicacion_descuentos_v29' in pg_get_functiondef(p.oid)) > 0
      else null end as reversion_compensatoria_v29
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'configurar_beneficios_empleado_v30', 'abrir_periodo_nomina_v30',
      'guardar_novedades_rol_v30', 'calcular_rol_v30',
      'reabrir_periodo_nomina_v30', 'cerrar_periodo_nomina_v30'
    )
  order by p.proname;

  -- Todos los siguientes resultados deben ser cero.

  select count(*) as periodos_con_fechas_o_estado_invalidos_debe_ser_cero
  from public.nomina_periodos
  where fecha_desde <> make_date(anio, mes, 1)
    or fecha_hasta <> (make_date(anio, mes, 1) + interval '1 month - 1 day')::date
    or (estado = 'abierto' and cerrado_at is not null)
    or (estado in ('calculado', 'cerrado')
        and (calculado_at is null or calculado_por is null))
    or (estado = 'cerrado'
        and (cerrado_at is null or cerrado_por is null
          or btrim(coalesce(motivo_cierre, '')) = ''));

  select count(*) as periodos_sin_lineas_debe_ser_cero
  from public.nomina_periodos p
  where not exists (
    select 1 from public.nomina_rol_lineas l where l.periodo_id = p.id
  );

  select count(*) as roles_con_empleado_de_otro_grupo_debe_ser_cero
  from public.nomina_rol_lineas l
  join public.nomina_periodos p on p.id = l.periodo_id
  join public.empleados e on e.id = l.empleado_id
  where e.grupo_id <> p.grupo_id;

  select count(*) as servicios_profesionales_en_rol_debe_ser_cero
  from public.nomina_rol_lineas
  where tipo_contrato = 'servicios_profesionales';

  select count(*) as roles_con_empresas_de_otro_grupo_debe_ser_cero
  from public.nomina_rol_lineas l
  join public.nomina_periodos p on p.id = l.periodo_id
  join public.empresas pag on pag.id = l.empresa_pagadora_id
  left join public.empresas afi on afi.id = l.empresa_afiliacion_id
  where pag.grupo_id <> p.grupo_id
    or (afi.id is not null and afi.grupo_id <> p.grupo_id);

  select count(*) as roles_con_totales_inconsistentes_debe_ser_cero
  from public.nomina_rol_lineas
  where total_descuentos_programados < 0
    or dias_laborados + dias_vacaciones + dias_ausencia_con_sueldo
        + dias_ausencia_sin_sueldo > dias_periodo
    or dias_afiliados > dias_periodo
    or (not afiliado and dias_afiliados <> 0)
    or total_descuentos_programados <>
        anticipos_cuota + multas + prestamos_iess + prestamos_empresa
          + retencion_judicial + otros_descuentos
    or total_egresos <> aporte_personal + total_descuentos_programados
    or neto_real <> greatest(total_ingresos_real - total_egresos, 0)
    or neto_declarado <> case when afiliado
        then greatest(total_ingresos_declarado - total_egresos, 0) else 0 end
    or costo_empleador_real <> round(
        total_ingresos_real + aporte_patronal + provision_decimo_tercero
          + provision_decimo_cuarto + provision_vacaciones
          + provision_fondos_reserva, 2
    )
    or costo_empleador_declarado <> case when afiliado then round(
        total_ingresos_declarado + aporte_patronal
          + provision_decimo_tercero_declarada
          + provision_decimo_cuarto_declarada
          + provision_vacaciones_declarada
          + provision_fondos_reserva_declarada, 2
        ) else 0 end;

  select count(*) as roles_calculados_sin_lote_v29_debe_ser_cero
  from public.nomina_rol_lineas l
  join public.nomina_periodos p on p.id = l.periodo_id
  where p.estado in ('calculado', 'cerrado')
    and (l.calculado_at is null or l.descuento_lote_id is null);

  select count(*) as lotes_v29_desvinculados_del_rol_debe_ser_cero
  from public.nomina_rol_lineas l
  join public.nomina_periodos p on p.id = l.periodo_id
  join public.descuento_aplicacion_lotes d on d.id = l.descuento_lote_id
  where p.estado in ('calculado', 'cerrado')
    and (d.estado <> 'aplicado' or d.nomina_rol_linea_id <> l.id
      or d.empleado_id <> l.empleado_id or d.anio <> p.anio or d.mes <> p.mes);

  select count(*) as descuentos_del_rol_inconsistentes_debe_ser_cero
  from public.nomina_rol_lineas l
  join public.nomina_periodos p on p.id = l.periodo_id
  left join lateral (
    select coalesce(sum(a.monto_aplicado), 0)::numeric(14,2) aplicado
    from public.descuento_aplicaciones a
    where a.lote_id = l.descuento_lote_id and a.estado = 'aplicada'
  ) x on true
  where p.estado in ('calculado', 'cerrado')
    and l.total_descuentos_programados <> x.aplicado;

  select count(*) as rubros_descuento_sin_fuente_debe_ser_cero
  from public.nomina_rol_rubros rr
  join public.nomina_rubros r on r.id = rr.rubro_id
  where r.origen = 'descuento_v29'
    and (rr.fuente_tipo <> 'descuento_aplicacion' or rr.fuente_id is null);

  select count(*) as periodos_cerrados_sin_evento_debe_ser_cero
  from public.nomina_periodos p
  where p.estado = 'cerrado' and not exists (
    select 1 from public.nomina_eventos e
    where e.entidad = 'nomina_periodo' and e.entidad_id = p.id
      and e.tipo = 'periodo_cerrado' and e.estado_nuevo = 'cerrado'
  );

  select count(*) as eventos_v30_sin_control_debe_ser_cero
  from public.nomina_eventos
  where entidad in ('nomina_periodo', 'nomina_rol')
    and (usuario_id is null or idempotency_key is null
      or btrim(coalesce(tipo, '')) = '');

  -- Panorama informativo.
  select
    count(*) filter (where estado = 'abierto') as periodos_abiertos,
    count(*) filter (where estado = 'calculado') as periodos_calculados,
    count(*) filter (where estado = 'cerrado') as periodos_cerrados
  from public.nomina_periodos;

  select
    p.anio, p.mes, p.estado,
    count(l.id)::integer as empleados,
    coalesce(sum(l.total_ingresos_real), 0)::numeric(16,2) as ingresos_reales,
    coalesce(sum(l.neto_real), 0)::numeric(16,2) as neto_real,
    coalesce(sum(l.neto_declarado), 0)::numeric(16,2) as neto_declarado,
    coalesce(sum(l.brecha), 0)::numeric(16,2) as brecha,
    coalesce(sum(l.costo_empleador_real), 0)::numeric(16,2) as costo_real
  from public.nomina_periodos p
  left join public.nomina_rol_lineas l on l.periodo_id = p.id
  group by p.id
  order by p.anio desc, p.mes desc;
