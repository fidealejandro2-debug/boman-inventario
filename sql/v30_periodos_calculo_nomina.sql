-- ============================================================
-- BOMAN INVENTARIO - Periodos y calculo de nomina v30
-- Congela el contexto laboral mensual, calcula rol real/declarado y consume
-- atomica e idempotentemente el motor de descuentos de v29.
-- Ejecutar una sola vez DESPUES de v29.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Recuperacion segura del borrador v30 incompatible
-- ------------------------------------------------------------
-- El borrador anterior podia crear cuatro tablas y fallar luego al intentar
-- indexar nomina_eventos.periodo_id. Solo se limpian esos objetos si siguen
-- vacios. Si contienen datos, la migracion se detiene para revisarlos.
do $$
declare
  v_tiene_datos boolean;
begin
  if to_regclass('public.nomina_periodos') is not null then
    execute 'select exists (select 1 from public.nomina_periodos)'
      into v_tiene_datos;
    if v_tiene_datos then
      raise exception 'Existe una instalacion v30 con periodos. No se limpiara automaticamente';
    end if;
  end if;
  if to_regclass('public.nomina_rol_lineas') is not null then
    execute 'select exists (select 1 from public.nomina_rol_lineas)'
      into v_tiene_datos;
    if v_tiene_datos then
      raise exception 'Existe una instalacion v30 con roles. No se limpiara automaticamente';
    end if;
  end if;
  if to_regclass('public.nomina_rubros') is not null then
    execute 'select exists (select 1 from public.nomina_rubros)'
      into v_tiene_datos;
    if v_tiene_datos then
      raise exception 'Existe una instalacion v30 con rubros. No se limpiara automaticamente';
    end if;
  end if;
  if to_regclass('public.nomina_rol_rubros') is not null then
    execute 'select exists (select 1 from public.nomina_rol_rubros)'
      into v_tiene_datos;
    if v_tiene_datos then
      raise exception 'Existe una instalacion v30 con detalle de roles. No se limpiara automaticamente';
    end if;
  end if;
end;
$$;

-- Una reejecucion de esta version puede encontrar la FK agregada por un
-- intento anterior. Se retira antes de reconstruir las tablas vacias.
alter table if exists public.descuento_aplicacion_lotes
  drop constraint if exists descuento_lotes_rol_linea_fkey_v30;

drop view if exists public.vista_rol_real;
drop view if exists public.vista_rol_declarado;
drop view if exists public.vista_brecha_nomina;
drop view if exists public.vista_costo_empleador_por_empresa;
drop view if exists public.vista_pagos_por_empresa;
drop view if exists public.vista_rol_real_v31;
drop view if exists public.vista_rol_declarado_v31;
drop view if exists public.vista_brecha_nomina_v31;
drop view if exists public.vista_costo_empleador_por_empresa_v31;
drop view if exists public.vista_pagos_por_empresa_pagadora_v31;
drop view if exists public.vista_planilla_iess_v31;
drop view if exists public.vista_resumen_periodo_nomina_v31;
drop view if exists public.vista_rol_impresion_v31;
drop view if exists public.vista_rol_rubros_v31;

drop function if exists public.abrir_periodo_nomina_v30(uuid, integer, integer);
drop function if exists public.calcular_rol_v30(uuid);
drop function if exists public.cerrar_periodo_nomina_v30(uuid, text);
drop function if exists public.obtener_parametro_nomina_v30(uuid, integer, text);
drop function if exists public.contar_dias_habiles_v30(date, date, uuid);
drop function if exists public.registrar_evento_nomina_v30(text, uuid, uuid, uuid, text);
drop function if exists public.valor_hora_ordinaria_v30(numeric, integer);
drop function if exists public.aplicar_descuento_con_tope_v30(numeric, numeric, numeric);

drop table if exists public.nomina_rol_rubros;
drop table if exists public.nomina_rubros;
drop table if exists public.nomina_rol_lineas;
drop table if exists public.nomina_periodos;

-- ------------------------------------------------------------
-- 0.1 Funcion de calculo (sus relaciones se resuelven al ejecutarla)
-- ------------------------------------------------------------
create or replace function public.calcular_rol_v30(
  p_periodo_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- record permite crear la funcion antes de reconstruir las tablas v30;
  -- las sentencias se resuelven al ejecutarla, cuando el esquema ya existe.
  p record;
  prm record;
  l record;
  v_evento_id uuid;
  v_horas_dia numeric;
  v_dias_base numeric;
  v_vacaciones numeric;
  v_con_sueldo numeric;
  v_sin_sueldo numeric;
  v_dias_laborados numeric;
  v_dias_pagados numeric;
  v_dias_afiliacion_base numeric;
  v_dias_afiliados numeric;
  v_sin_sueldo_afiliado numeric;
  v_hora_real numeric;
  v_hora_declarada numeric;
  v_extra_real numeric;
  v_extra_declarado numeric;
  v_sueldo_real numeric;
  v_sueldo_declarado numeric;
  v_base_real numeric;
  v_base_declarada numeric;
  v_d13_real numeric;
  v_d13_declarado numeric;
  v_d14_real numeric;
  v_d14_declarado numeric;
  v_fondos_real numeric;
  v_fondos_declarado numeric;
  v_aporte_personal numeric;
  v_aporte_patronal numeric;
  v_prov_d13 numeric;
  v_prov_d14 numeric;
  v_prov_vac numeric;
  v_prov_fondos numeric;
  v_prov_d13_declarada numeric;
  v_prov_d14_declarada numeric;
  v_prov_vac_declarada numeric;
  v_prov_fondos_declarada numeric;
  v_total_real numeric;
  v_total_declarado numeric;
  v_costo_real numeric;
  v_costo_declarado numeric;
  v_desc jsonb;
  v_lote_id uuid;
  v_anticipo numeric;
  v_multas numeric;
  v_iess numeric;
  v_empresa numeric;
  v_judicial numeric;
  v_otros numeric;
  v_total_desc numeric;
  v_total_egresos numeric;
  v_neto_real numeric;
  v_neto_declarado numeric;
  v_total_roles integer := 0;
  v_total_neto numeric := 0;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede calcular roles';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_evento_id from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into p from public.nomina_periodos where id = p_periodo_id for update;
  if not found then raise exception 'El periodo no existe'; end if;
  if p.estado <> 'abierto' then
    raise exception 'Solo un periodo abierto puede calcularse; usa reabrir para recalcular';
  end if;
  select * into prm from public.nomina_parametros where anio = p.anio;
  if not found then raise exception 'Faltan parametros del anio %', p.anio; end if;
  v_horas_dia := prm.horas_jornada_semanal / 5;

  for l in
    select * from public.nomina_rol_lineas
    where periodo_id = p.id order by empleado_id for update
  loop
    v_dias_base := case
      when l.fecha_ingreso_real <= p.fecha_desde
        and (l.fecha_salida is null or l.fecha_salida >= p.fecha_hasta) then 30
      else least(30, greatest(
        least(coalesce(l.fecha_salida, p.fecha_hasta), p.fecha_hasta)
          - greatest(l.fecha_ingreso_real, p.fecha_desde) + 1, 0
      ))::numeric
    end;

    select
      coalesce(sum(case when a.tipo = 'vacaciones' then
        case when a.horas is not null then a.horas / v_horas_dia
          else least(a.fecha_hasta, p.fecha_hasta)
            - greatest(a.fecha_desde, p.fecha_desde) + 1 end else 0 end), 0),
      coalesce(sum(case when a.tipo in (
        'enfermedad_iess', 'enfermedad_particular', 'permiso_con_sueldo',
        'maternidad', 'paternidad', 'lactancia', 'calamidad_domestica'
      ) then case when a.horas is not null then a.horas / v_horas_dia
          else least(a.fecha_hasta, p.fecha_hasta)
            - greatest(a.fecha_desde, p.fecha_desde) + 1 end else 0 end), 0),
      coalesce(sum(case when a.tipo in (
        'permiso_sin_sueldo', 'falta_injustificada', 'suspension_disciplinaria'
      ) then case when a.horas is not null then a.horas / v_horas_dia
          else least(a.fecha_hasta, p.fecha_hasta)
            - greatest(a.fecha_desde, p.fecha_desde) + 1 end else 0 end), 0)
    into v_vacaciones, v_con_sueldo, v_sin_sueldo
    from public.ausencias a
    where a.empleado_id = l.empleado_id and a.estado = 'aprobada'
      and daterange(a.fecha_desde, a.fecha_hasta, '[]')
        && daterange(p.fecha_desde, p.fecha_hasta, '[]');

    v_vacaciones := round(least(v_vacaciones, v_dias_base), 2);
    v_con_sueldo := round(least(
      v_con_sueldo, greatest(v_dias_base - v_vacaciones, 0)
    ), 2);
    v_sin_sueldo := round(least(
      v_sin_sueldo,
      greatest(v_dias_base - v_vacaciones - v_con_sueldo, 0)
    ), 2);
    v_dias_laborados := round(greatest(
      v_dias_base - v_vacaciones - v_con_sueldo - v_sin_sueldo, 0
    ), 2);
    v_dias_pagados := round(greatest(v_dias_base - v_sin_sueldo, 0), 2);
    v_dias_afiliacion_base := 0;
    v_sin_sueldo_afiliado := 0;
    if l.afiliado then
      v_dias_afiliacion_base := case
        when greatest(l.afiliacion_desde, l.fecha_afiliacion) <= p.fecha_desde
          and (l.afiliacion_hasta is null or l.afiliacion_hasta >= p.fecha_hasta)
          and l.fecha_ingreso_real <= p.fecha_desde
          and (l.fecha_salida is null or l.fecha_salida >= p.fecha_hasta)
        then 30
        else least(30, greatest(
          least(coalesce(l.afiliacion_hasta, p.fecha_hasta), p.fecha_hasta,
            coalesce(l.fecha_salida, p.fecha_hasta))
          - greatest(l.afiliacion_desde, l.fecha_afiliacion,
              p.fecha_desde, l.fecha_ingreso_real) + 1,
          0
        ))::numeric
      end;
      if v_dias_afiliacion_base > 0 then
        select coalesce(sum(case when a.horas is not null
          then a.horas / v_horas_dia
          else least(a.fecha_hasta, p.fecha_hasta,
                 coalesce(l.afiliacion_hasta, p.fecha_hasta))
               - greatest(a.fecha_desde, p.fecha_desde,
                   l.afiliacion_desde, l.fecha_afiliacion) + 1
          end), 0)
        into v_sin_sueldo_afiliado
        from public.ausencias a
        where a.empleado_id = l.empleado_id and a.estado = 'aprobada'
          and a.tipo in (
            'permiso_sin_sueldo', 'falta_injustificada',
            'suspension_disciplinaria'
          )
          and daterange(a.fecha_desde, a.fecha_hasta, '[]') && daterange(
            greatest(p.fecha_desde, l.afiliacion_desde, l.fecha_afiliacion),
            least(p.fecha_hasta, coalesce(l.afiliacion_hasta, p.fecha_hasta)),
            '[]'
          );
      end if;
      v_sin_sueldo_afiliado := round(least(
        v_sin_sueldo_afiliado, v_dias_afiliacion_base
      ), 2);
    end if;
    v_dias_afiliados := round(greatest(
      v_dias_afiliacion_base - v_sin_sueldo_afiliado, 0
    ), 2);
    v_sueldo_real := round(l.sueldo_real * v_dias_pagados / 30, 2);
    v_sueldo_declarado := case when l.afiliado
      then round(l.sueldo_declarado * v_dias_afiliados / 30, 2) else 0 end;
    v_hora_real := l.sueldo_real / (prm.horas_jornada_semanal * 6);
    v_hora_declarada := case when l.afiliado
      then l.sueldo_declarado / (prm.horas_jornada_semanal * 6) else 0 end;
    v_extra_real := round(v_hora_real * (l.horas_extra_50 * 1.5 + l.horas_extra_100 * 2), 2);
    v_extra_declarado := round(v_hora_declarada * (l.horas_extra_50 * 1.5 + l.horas_extra_100 * 2), 2);
    v_base_real := round(v_sueldo_real + v_extra_real + l.comisiones + l.bonos, 2);
    v_base_declarada := case when l.afiliado
      then round(v_sueldo_declarado + v_extra_declarado + l.comisiones + l.bonos, 2)
      else 0 end;
    v_d13_real := case when l.mensualiza_decimo_tercero
      then round(v_base_real / 12, 2) else 0 end;
    v_d13_declarado := case when l.afiliado and l.mensualiza_decimo_tercero
      then round(v_base_declarada / 12, 2) else 0 end;
    v_d14_real := case when l.mensualiza_decimo_cuarto
      then round(prm.salario_basico_unificado / 12 * v_dias_pagados / 30, 2) else 0 end;
    v_d14_declarado := case when l.afiliado and l.mensualiza_decimo_cuarto
      then round(prm.salario_basico_unificado / 12
        * v_dias_afiliados / 30, 2) else 0 end;
    v_fondos_real := 0;
    v_fondos_declarado := 0;
    if l.afiliado and l.fecha_afiliacion is not null
       and p.fecha_hasta >= (l.fecha_afiliacion + interval '1 year')::date
       and l.paga_fondos_reserva_mensual then
      v_fondos_real := round(v_base_real * prm.pct_fondos_reserva / 100, 2);
      v_fondos_declarado := round(v_base_declarada * prm.pct_fondos_reserva / 100, 2);
    end if;
    v_total_real := round(v_base_real + l.vacaciones_pagadas + l.otros_ingresos
      + v_d13_real + v_d14_real + v_fondos_real, 2);
    v_total_declarado := case when l.afiliado then round(v_base_declarada
      + l.vacaciones_pagadas + l.otros_ingresos + v_d13_declarado
      + v_d14_declarado + v_fondos_declarado, 2) else 0 end;
    v_aporte_personal := case when l.afiliado
      then round(v_base_declarada * prm.pct_aporte_personal / 100, 2) else 0 end;
    v_aporte_patronal := case when l.afiliado
      then round(v_base_declarada * prm.pct_aporte_patronal / 100, 2) else 0 end;
    v_prov_d13 := case when l.mensualiza_decimo_tercero then 0 else round(v_base_real / 12, 2) end;
    v_prov_d14 := case when l.mensualiza_decimo_cuarto then 0
      else round(prm.salario_basico_unificado / 12 * v_dias_pagados / 30, 2) end;
    v_prov_vac := round(v_base_real / 24, 2);
    v_prov_fondos := case
      when l.afiliado and l.fecha_afiliacion is not null
        and p.fecha_hasta >= (l.fecha_afiliacion + interval '1 year')::date
        and not l.paga_fondos_reserva_mensual
      then round(v_base_real * prm.pct_fondos_reserva / 100, 2) else 0 end;
    v_prov_d13_declarada := case
      when not l.afiliado or l.mensualiza_decimo_tercero then 0
      else round(v_base_declarada / 12, 2) end;
    v_prov_d14_declarada := case
      when not l.afiliado or l.mensualiza_decimo_cuarto then 0
      else round(prm.salario_basico_unificado / 12
        * v_dias_afiliados / 30, 2) end;
    v_prov_vac_declarada := case when l.afiliado
      then round(v_base_declarada / 24, 2) else 0 end;
    v_prov_fondos_declarada := case
      when l.afiliado and l.fecha_afiliacion is not null
        and p.fecha_hasta >= (l.fecha_afiliacion + interval '1 year')::date
        and not l.paga_fondos_reserva_mensual
      then round(v_base_declarada * prm.pct_fondos_reserva / 100, 2) else 0 end;

    v_desc := public.aplicar_descuentos_periodo_v29(
      l.empleado_id, p.anio, p.mes, v_sueldo_real,
      greatest(v_total_real - v_aporte_personal, 0), l.id,
      md5('v30-descuentos-' || p.id::text || '-' || l.id::text
        || '-' || p.version::text)::uuid
    );
    v_lote_id := (v_desc->>'lote_id')::uuid;
    select
      coalesce(sum(a.monto_aplicado) filter (where d.origen = 'anticipo'), 0),
      coalesce(sum(a.monto_aplicado) filter (where d.origen = 'multa'), 0),
      coalesce(sum(a.monto_aplicado) filter (where d.origen in (
        'prestamo_iess', 'prestamo_quirografario', 'prestamo_hipotecario')), 0),
      coalesce(sum(a.monto_aplicado) filter (where d.origen in (
        'prestamo_empresa', 'uniforme', 'consumo_interno')), 0),
      coalesce(sum(a.monto_aplicado) filter (where d.origen = 'judicial'), 0),
      coalesce(sum(a.monto_aplicado) filter (where d.origen = 'otro'), 0)
    into v_anticipo, v_multas, v_iess, v_empresa, v_judicial, v_otros
    from public.descuento_aplicaciones a
    join public.descuentos_programados d on d.id = a.descuento_programado_id
    where a.lote_id = v_lote_id and a.estado = 'aplicada';

    v_total_desc := round(v_anticipo + v_multas + v_iess + v_empresa + v_judicial + v_otros, 2);
    v_total_egresos := round(v_aporte_personal + v_total_desc, 2);
    v_neto_real := round(greatest(v_total_real - v_total_egresos, 0), 2);
    v_neto_declarado := case when l.afiliado
      then round(greatest(v_total_declarado - v_total_egresos, 0), 2) else 0 end;
    v_costo_real := round(v_total_real + v_aporte_patronal + v_prov_d13
      + v_prov_d14 + v_prov_vac + v_prov_fondos, 2);
    v_costo_declarado := case when l.afiliado then round(
      v_total_declarado + v_aporte_patronal + v_prov_d13_declarada
      + v_prov_d14_declarada + v_prov_vac_declarada
      + v_prov_fondos_declarada, 2)
      else 0 end;

    update public.nomina_rol_lineas
    set dias_laborados = v_dias_laborados, dias_afiliados = v_dias_afiliados,
        dias_vacaciones = v_vacaciones,
        dias_ausencia_con_sueldo = v_con_sueldo, dias_ausencia_sin_sueldo = v_sin_sueldo,
        sueldo_proporcional_real = v_sueldo_real,
        sueldo_proporcional_declarado = v_sueldo_declarado,
        valor_horas_extra = v_extra_real, valor_horas_extra_declarado = v_extra_declarado,
        decimo_tercero_mensualizado = v_d13_real,
        decimo_tercero_declarado = v_d13_declarado,
        decimo_cuarto_mensualizado = v_d14_real,
        decimo_cuarto_declarado = v_d14_declarado,
        fondos_reserva_pagados = v_fondos_real,
        fondos_reserva_declarados = v_fondos_declarado,
        base_aportacion_declarada = v_base_declarada,
        total_ingresos_real = v_total_real, total_ingresos_declarado = v_total_declarado,
        aporte_personal = v_aporte_personal,
        anticipos_cuota = v_anticipo, multas = v_multas, prestamos_iess = v_iess,
        prestamos_empresa = v_empresa, retencion_judicial = v_judicial,
        otros_descuentos = v_otros, total_descuentos_programados = v_total_desc,
        total_egresos = v_total_egresos, descuento_lote_id = v_lote_id,
        aporte_patronal = v_aporte_patronal,
        provision_decimo_tercero = v_prov_d13,
        provision_decimo_cuarto = v_prov_d14,
        provision_vacaciones = v_prov_vac,
        provision_fondos_reserva = v_prov_fondos,
        provision_decimo_tercero_declarada = v_prov_d13_declarada,
        provision_decimo_cuarto_declarada = v_prov_d14_declarada,
        provision_vacaciones_declarada = v_prov_vac_declarada,
        provision_fondos_reserva_declarada = v_prov_fondos_declarada,
        neto_real = v_neto_real, neto_declarado = v_neto_declarado,
        costo_empleador_real = v_costo_real,
        costo_empleador_declarado = v_costo_declarado,
        calculado_at = now(), version = version + 1, updated_at = now()
    where id = l.id;

    delete from public.nomina_rol_rubros where rol_linea_id = l.id;
    insert into public.nomina_rol_rubros(
      rol_linea_id, rubro_id, valor_real, valor_declarado, cantidad, descripcion
    )
    select l.id, r.id, x.real, x.declarado, x.cantidad, x.descripcion
    from (values
      ('SUELDO', v_sueldo_real, v_sueldo_declarado, v_dias_pagados, 'Dias pagados'),
      ('HE50', round(v_hora_real * l.horas_extra_50 * 1.5, 2), round(v_hora_declarada * l.horas_extra_50 * 1.5, 2), l.horas_extra_50, null),
      ('HE100', round(v_hora_real * l.horas_extra_100 * 2, 2), round(v_hora_declarada * l.horas_extra_100 * 2, 2), l.horas_extra_100, null),
      ('COMISION', l.comisiones, case when l.afiliado then l.comisiones else 0 end, 1::numeric, null),
      ('BONO', l.bonos, case when l.afiliado then l.bonos else 0 end, 1::numeric, null),
      ('VAC_PAGADA', l.vacaciones_pagadas, case when l.afiliado then l.vacaciones_pagadas else 0 end, 1::numeric, null),
      ('D13', v_d13_real, v_d13_declarado, 1::numeric, null),
      ('D14', v_d14_real, v_d14_declarado, 1::numeric, null),
      ('FONDOS', v_fondos_real, v_fondos_declarado, 1::numeric, null),
      ('OTRO_ING', l.otros_ingresos, case when l.afiliado then l.otros_ingresos else 0 end, 1::numeric, l.nota_novedades),
      ('APORTE_PERSONAL', v_aporte_personal, v_aporte_personal, 1::numeric, null),
      ('APORTE_PATRONAL', v_aporte_patronal, v_aporte_patronal, 1::numeric, null),
      ('PROV_D13', v_prov_d13, v_prov_d13_declarada, 1::numeric, null),
      ('PROV_D14', v_prov_d14, v_prov_d14_declarada, 1::numeric, null),
      ('PROV_VAC', v_prov_vac, v_prov_vac_declarada, 1::numeric, null),
      ('PROV_FONDOS', v_prov_fondos, v_prov_fondos_declarada, 1::numeric, null)
    ) x(codigo, real, declarado, cantidad, descripcion)
    join public.nomina_rubros r on r.grupo_id = p.grupo_id and r.codigo = x.codigo
    where x.real <> 0 or x.declarado <> 0;

    insert into public.nomina_rol_rubros(
      rol_linea_id, rubro_id, valor_real, valor_declarado, cantidad,
      descripcion, fuente_tipo, fuente_id
    )
    select l.id, r.id, a.monto_aplicado, a.monto_aplicado, 1,
           d.descripcion || ' - cuota ' || c.numero::text,
           'descuento_aplicacion', a.id
    from public.descuento_aplicaciones a
    join public.descuentos_programados d on d.id = a.descuento_programado_id
    join public.descuento_programado_cuotas c on c.id = a.cuota_id
    join public.nomina_rubros r on r.grupo_id = p.grupo_id and r.codigo = case
      when d.origen = 'anticipo' then 'ANTICIPO'
      when d.origen = 'multa' then 'MULTA'
      when d.origen in ('prestamo_iess', 'prestamo_quirografario', 'prestamo_hipotecario') then 'PRESTAMO_IESS'
      when d.origen in ('prestamo_empresa', 'uniforme', 'consumo_interno') then 'PRESTAMO_EMPRESA'
      when d.origen = 'judicial' then 'RET_JUDICIAL'
      else 'OTRO_DESC' end
    where a.lote_id = v_lote_id and a.estado = 'aplicada' and a.monto_aplicado > 0;

    v_total_roles := v_total_roles + 1;
    v_total_neto := v_total_neto + v_neto_real;
  end loop;

  update public.nomina_periodos
  set estado = 'calculado', calculado_por = auth.uid(), calculado_at = now(),
      version = version + 1, updated_at = now()
  where id = p.id;
  v_evento_id := public.registrar_evento_nomina_v30(
    'nomina_periodo', p.id, null, 'periodo_calculado', 'abierto', 'calculado',
    'Roles y descuentos calculados', jsonb_build_object(
      'roles', v_total_roles, 'neto_real', round(v_total_neto, 2)
    ), p_idempotency_key
  );
  return jsonb_build_object('periodo_id', p.id, 'evento_id', v_evento_id,
    'roles_calculados', v_total_roles, 'total_neto_real', round(v_total_neto, 2),
    'estado', 'calculado', 'duplicado', false);
end;
$$;

-- ------------------------------------------------------------
-- 1. Preferencias vigentes y snapshot mensual
-- ------------------------------------------------------------
alter table public.empleado_compensacion
  add column if not exists mensualiza_decimo_tercero boolean not null default false,
  add column if not exists mensualiza_decimo_cuarto boolean not null default false,
  add column if not exists paga_fondos_reserva_mensual boolean not null default true;

create table public.nomina_periodos (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  anio integer not null check (anio between 2000 and 2200),
  mes integer not null check (mes between 1 and 12),
  fecha_desde date not null,
  fecha_hasta date not null,
  estado text not null default 'abierto'
    check (estado in ('abierto', 'calculado', 'cerrado')),
  idempotency_key uuid not null unique,
  generado_por uuid not null references public.perfiles(id) on delete restrict,
  generado_at timestamptz not null default now(),
  calculado_por uuid references public.perfiles(id) on delete restrict,
  calculado_at timestamptz,
  cerrado_por uuid references public.perfiles(id) on delete restrict,
  cerrado_at timestamptz,
  motivo_cierre text,
  version integer not null default 1,
  updated_at timestamptz not null default now(),
  unique (grupo_id, anio, mes),
  check (fecha_desde = make_date(anio, mes, 1)),
  check (fecha_hasta = (make_date(anio, mes, 1) + interval '1 month - 1 day')::date),
  check (
    (estado = 'abierto' and cerrado_at is null and cerrado_por is null)
    or (estado = 'calculado' and calculado_at is not null and calculado_por is not null)
    or (estado = 'cerrado' and calculado_at is not null and calculado_por is not null
      and cerrado_at is not null and cerrado_por is not null
      and btrim(coalesce(motivo_cierre, '')) <> '')
  )
);

create table public.nomina_rol_lineas (
  id uuid primary key default gen_random_uuid(),
  periodo_id uuid not null references public.nomina_periodos(id) on delete restrict,
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  afiliacion_id uuid references public.empleado_afiliaciones(id) on delete restrict,
  compensacion_id uuid not null references public.empleado_compensacion(id) on delete restrict,
  empresa_afiliacion_id uuid references public.empresas(id) on delete restrict,
  empresa_pagadora_id uuid not null references public.empresas(id) on delete restrict,
  identificacion text not null,
  nombres text not null,
  apellidos text not null,
  cargo text not null,
  area text,
  tipo_contrato text not null,
  fecha_ingreso_real date not null,
  fecha_salida date,
  afiliado boolean not null,
  fecha_afiliacion date,
  afiliacion_desde date,
  afiliacion_hasta date,
  sueldo_declarado numeric(14,2) not null check (sueldo_declarado >= 0),
  sueldo_real numeric(14,2) not null check (sueldo_real > 0),
  mensualiza_decimo_tercero boolean not null,
  mensualiza_decimo_cuarto boolean not null,
  paga_fondos_reserva_mensual boolean not null,
  dias_periodo numeric(7,2) not null default 30 check (dias_periodo = 30),
  dias_laborados numeric(7,2) not null default 0 check (dias_laborados between 0 and 30),
  dias_afiliados numeric(7,2) not null default 0 check (dias_afiliados between 0 and 30),
  dias_vacaciones numeric(7,2) not null default 0 check (dias_vacaciones >= 0),
  dias_ausencia_con_sueldo numeric(7,2) not null default 0 check (dias_ausencia_con_sueldo >= 0),
  dias_ausencia_sin_sueldo numeric(7,2) not null default 0 check (dias_ausencia_sin_sueldo >= 0),
  horas_extra_50 numeric(9,2) not null default 0 check (horas_extra_50 >= 0),
  horas_extra_100 numeric(9,2) not null default 0 check (horas_extra_100 >= 0),
  comisiones numeric(14,2) not null default 0 check (comisiones >= 0),
  bonos numeric(14,2) not null default 0 check (bonos >= 0),
  vacaciones_pagadas numeric(14,2) not null default 0 check (vacaciones_pagadas >= 0),
  otros_ingresos numeric(14,2) not null default 0 check (otros_ingresos >= 0),
  nota_novedades text,
  sueldo_proporcional_real numeric(14,2) not null default 0,
  sueldo_proporcional_declarado numeric(14,2) not null default 0,
  valor_horas_extra numeric(14,2) not null default 0,
  valor_horas_extra_declarado numeric(14,2) not null default 0,
  decimo_tercero_mensualizado numeric(14,2) not null default 0,
  decimo_tercero_declarado numeric(14,2) not null default 0,
  decimo_cuarto_mensualizado numeric(14,2) not null default 0,
  decimo_cuarto_declarado numeric(14,2) not null default 0,
  fondos_reserva_pagados numeric(14,2) not null default 0,
  fondos_reserva_declarados numeric(14,2) not null default 0,
  base_aportacion_declarada numeric(14,2) not null default 0,
  total_ingresos_real numeric(14,2) not null default 0,
  total_ingresos_declarado numeric(14,2) not null default 0,
  aporte_personal numeric(14,2) not null default 0,
  anticipos_cuota numeric(14,2) not null default 0,
  multas numeric(14,2) not null default 0,
  prestamos_iess numeric(14,2) not null default 0,
  prestamos_empresa numeric(14,2) not null default 0,
  retencion_judicial numeric(14,2) not null default 0,
  otros_descuentos numeric(14,2) not null default 0,
  total_descuentos_programados numeric(14,2) not null default 0,
  total_egresos numeric(14,2) not null default 0,
  descuento_lote_id uuid references public.descuento_aplicacion_lotes(id) on delete restrict,
  aporte_patronal numeric(14,2) not null default 0,
  provision_decimo_tercero numeric(14,2) not null default 0,
  provision_decimo_cuarto numeric(14,2) not null default 0,
  provision_vacaciones numeric(14,2) not null default 0,
  provision_fondos_reserva numeric(14,2) not null default 0,
  provision_decimo_tercero_declarada numeric(14,2) not null default 0,
  provision_decimo_cuarto_declarada numeric(14,2) not null default 0,
  provision_vacaciones_declarada numeric(14,2) not null default 0,
  provision_fondos_reserva_declarada numeric(14,2) not null default 0,
  neto_real numeric(14,2) not null default 0 check (neto_real >= 0),
  neto_declarado numeric(14,2) not null default 0 check (neto_declarado >= 0),
  brecha numeric(14,2) generated always as (neto_real - neto_declarado) stored,
  costo_empleador_real numeric(14,2) not null default 0,
  costo_empleador_declarado numeric(14,2) not null default 0,
  calculado_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (periodo_id, empleado_id),
  check ((afiliado and afiliacion_id is not null and empresa_afiliacion_id is not null
      and fecha_afiliacion is not null and afiliacion_desde is not null
      and sueldo_declarado > 0)
    or (not afiliado and empresa_afiliacion_id is null
      and fecha_afiliacion is null and afiliacion_desde is null
      and afiliacion_hasta is null and sueldo_declarado = 0
      and dias_afiliados = 0)),
  check (afiliacion_hasta is null or afiliacion_hasta >= afiliacion_desde),
  check (fecha_salida is null or fecha_salida >= fecha_ingreso_real),
  check (dias_laborados + dias_vacaciones + dias_ausencia_con_sueldo
    + dias_ausencia_sin_sueldo <= dias_periodo),
  check (total_egresos = aporte_personal + total_descuentos_programados),
  check (total_descuentos_programados = anticipos_cuota + multas + prestamos_iess
    + prestamos_empresa + retencion_judicial + otros_descuentos),
  check (neto_real = greatest(total_ingresos_real - total_egresos, 0)),
  check (neto_declarado = case when afiliado
    then greatest(total_ingresos_declarado - total_egresos, 0) else 0 end),
  check (costo_empleador_real = round(
    total_ingresos_real + aporte_patronal + provision_decimo_tercero
      + provision_decimo_cuarto + provision_vacaciones
      + provision_fondos_reserva, 2
  )),
  check (costo_empleador_declarado = case when afiliado then round(
    total_ingresos_declarado + aporte_patronal
      + provision_decimo_tercero_declarada
      + provision_decimo_cuarto_declarada
      + provision_vacaciones_declarada
      + provision_fondos_reserva_declarada, 2
    ) else 0 end)
);

create table public.nomina_rubros (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  codigo text not null check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  tipo text not null check (tipo in ('ingreso', 'egreso', 'costo_patronal')),
  origen text not null default 'sistema' check (origen in ('sistema', 'manual', 'descuento_v29')),
  orden integer not null default 100,
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  unique (grupo_id, codigo)
);

create table public.nomina_rol_rubros (
  id uuid primary key default gen_random_uuid(),
  rol_linea_id uuid not null references public.nomina_rol_lineas(id) on delete restrict,
  rubro_id uuid not null references public.nomina_rubros(id) on delete restrict,
  valor_real numeric(14,2) not null default 0 check (valor_real >= 0),
  valor_declarado numeric(14,2) not null default 0 check (valor_declarado >= 0),
  cantidad numeric(12,2) not null default 1 check (cantidad >= 0),
  descripcion text,
  fuente_tipo text,
  fuente_id uuid,
  created_at timestamptz not null default now()
);

create unique index uq_nomina_rol_rubro_sistema_v30
  on public.nomina_rol_rubros(rol_linea_id, rubro_id) where fuente_id is null;
create unique index uq_nomina_rol_rubro_fuente_v30
  on public.nomina_rol_rubros(rol_linea_id, fuente_tipo, fuente_id) where fuente_id is not null;
create index idx_nomina_periodos_fecha_v30
  on public.nomina_periodos(grupo_id, anio desc, mes desc, estado);
create index idx_nomina_rol_lineas_periodo_v30
  on public.nomina_rol_lineas(periodo_id, empresa_pagadora_id, empleado_id);
create index idx_nomina_rol_lineas_afiliadora_v30
  on public.nomina_rol_lineas(empresa_afiliacion_id, periodo_id) where afiliado;
create index idx_nomina_rol_rubros_linea_v30
  on public.nomina_rol_rubros(rol_linea_id, rubro_id);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'descuento_lotes_rol_linea_fkey_v30'
      and conrelid = 'public.descuento_aplicacion_lotes'::regclass
  ) then
    alter table public.descuento_aplicacion_lotes
      add constraint descuento_lotes_rol_linea_fkey_v30
      foreign key (nomina_rol_linea_id)
      references public.nomina_rol_lineas(id) on delete restrict;
  end if;
end;
$$;

alter table public.nomina_eventos drop constraint if exists nomina_eventos_entidad_check;
alter table public.nomina_eventos
  add constraint nomina_eventos_entidad_check check (entidad in (
    'empleado', 'afiliacion', 'compensacion', 'documento', 'parametros',
    'calendario_feriados', 'periodos_vacaciones', 'ausencia', 'novedad',
    'anticipo', 'descuento', 'descuento_aplicacion',
    'nomina_periodo', 'nomina_rol'
  ));

insert into public.nomina_rubros(grupo_id, codigo, nombre, tipo, origen, orden)
select g.id, r.codigo, r.nombre, r.tipo, r.origen, r.orden
from public.grupos_economicos g
cross join (values
  ('SUELDO', 'Sueldo proporcional', 'ingreso', 'sistema', 10),
  ('HE50', 'Horas suplementarias 50%', 'ingreso', 'sistema', 20),
  ('HE100', 'Horas extraordinarias 100%', 'ingreso', 'sistema', 21),
  ('COMISION', 'Comisiones', 'ingreso', 'manual', 30),
  ('BONO', 'Bonos', 'ingreso', 'manual', 31),
  ('VAC_PAGADA', 'Vacaciones pagadas', 'ingreso', 'manual', 32),
  ('D13', 'Decimo tercero mensualizado', 'ingreso', 'sistema', 40),
  ('D14', 'Decimo cuarto mensualizado', 'ingreso', 'sistema', 41),
  ('FONDOS', 'Fondos de reserva pagados', 'ingreso', 'sistema', 42),
  ('OTRO_ING', 'Otros ingresos', 'ingreso', 'manual', 49),
  ('APORTE_PERSONAL', 'Aporte personal IESS', 'egreso', 'sistema', 60),
  ('ANTICIPO', 'Cuota de anticipo', 'egreso', 'descuento_v29', 70),
  ('MULTA', 'Multa', 'egreso', 'descuento_v29', 71),
  ('PRESTAMO_IESS', 'Prestamo IESS', 'egreso', 'descuento_v29', 72),
  ('PRESTAMO_EMPRESA', 'Prestamo o consumo con empleador', 'egreso', 'descuento_v29', 73),
  ('RET_JUDICIAL', 'Retencion judicial', 'egreso', 'descuento_v29', 74),
  ('OTRO_DESC', 'Otros descuentos', 'egreso', 'descuento_v29', 79),
  ('APORTE_PATRONAL', 'Aporte patronal IESS', 'costo_patronal', 'sistema', 90),
  ('PROV_D13', 'Provision decimo tercero', 'costo_patronal', 'sistema', 91),
  ('PROV_D14', 'Provision decimo cuarto', 'costo_patronal', 'sistema', 92),
  ('PROV_VAC', 'Provision vacaciones', 'costo_patronal', 'sistema', 93),
  ('PROV_FONDOS', 'Provision fondos de reserva', 'costo_patronal', 'sistema', 94)
) r(codigo, nombre, tipo, origen, orden)
where g.activo
on conflict (grupo_id, codigo) do nothing;

alter table public.nomina_periodos enable row level security;
alter table public.nomina_rol_lineas enable row level security;
alter table public.nomina_rubros enable row level security;
alter table public.nomina_rol_rubros enable row level security;
drop policy if exists "leer_nomina_periodos_v30" on public.nomina_periodos;
create policy "leer_nomina_periodos_v30" on public.nomina_periodos
for select to authenticated using (public.usuario_puede_nomina(false));
drop policy if exists "leer_nomina_rol_lineas_v30" on public.nomina_rol_lineas;
create policy "leer_nomina_rol_lineas_v30" on public.nomina_rol_lineas
for select to authenticated using (public.usuario_puede_nomina(false));
drop policy if exists "leer_nomina_rubros_v30" on public.nomina_rubros;
create policy "leer_nomina_rubros_v30" on public.nomina_rubros
for select to authenticated using (public.usuario_puede_nomina(false));
drop policy if exists "leer_nomina_rol_rubros_v30" on public.nomina_rol_rubros;
create policy "leer_nomina_rol_rubros_v30" on public.nomina_rol_rubros
for select to authenticated using (public.usuario_puede_nomina(false));

-- ------------------------------------------------------------
-- 2. Inmutabilidad y auxiliares
-- ------------------------------------------------------------
create or replace function public.proteger_nomina_cerrada_v30()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_periodo_id uuid;
  v_estado text;
begin
  if tg_table_name = 'nomina_rol_lineas' then
    v_periodo_id := case when tg_op = 'DELETE' then old.periodo_id else new.periodo_id end;
  else
    select l.periodo_id into v_periodo_id
    from public.nomina_rol_lineas l
    where l.id = case when tg_op = 'DELETE' then old.rol_linea_id else new.rol_linea_id end;
  end if;
  select estado into v_estado from public.nomina_periodos where id = v_periodo_id;
  if v_estado = 'cerrado' then
    raise exception 'El periodo de Nomina esta cerrado y es inmutable';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.proteger_periodo_cerrado_v30()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.estado = 'cerrado' then
    raise exception 'Un periodo cerrado no puede modificarse ni eliminarse';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger trg_proteger_nomina_rol_v30
before insert or update or delete on public.nomina_rol_lineas
for each row execute function public.proteger_nomina_cerrada_v30();
create trigger trg_proteger_nomina_rubros_v30
before insert or update or delete on public.nomina_rol_rubros
for each row execute function public.proteger_nomina_cerrada_v30();
create trigger trg_proteger_periodo_cerrado_v30
before update or delete on public.nomina_periodos
for each row execute function public.proteger_periodo_cerrado_v30();

create or replace function public.obtener_parametro_nomina_v30(
  p_anio integer,
  p_parametro text
) returns numeric
language sql
stable
set search_path = ''
as $$
  select case p_parametro
    when 'salario_basico_unificado' then n.salario_basico_unificado
    when 'pct_aporte_personal' then n.pct_aporte_personal
    when 'pct_aporte_patronal' then n.pct_aporte_patronal
    when 'pct_fondos_reserva' then n.pct_fondos_reserva
    when 'pct_iece' then n.pct_iece
    when 'pct_secap' then n.pct_secap
    when 'horas_jornada_semanal' then n.horas_jornada_semanal
    when 'tope_multa_pct' then n.tope_multa_pct
    when 'tope_descuento_total_pct' then n.tope_descuento_total_pct
    when 'tope_retencion_empleador_pct' then n.tope_retencion_empleador_pct
  end
  from public.nomina_parametros n where n.anio = p_anio;
$$;

create or replace function public.registrar_evento_nomina_v30(
  p_entidad text,
  p_entidad_id uuid,
  p_empleado_id uuid,
  p_tipo text,
  p_estado_anterior text,
  p_estado_nuevo text,
  p_detalle text,
  p_datos jsonb,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    p_entidad, p_entidad_id, p_empleado_id, p_tipo,
    p_estado_anterior, p_estado_nuevo, nullif(btrim(p_detalle), ''),
    coalesce(p_datos, '{}'::jsonb), auth.uid(), p_idempotency_key
  ) returning id into v_id;
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 3. Configuracion, apertura y entradas variables
-- ------------------------------------------------------------
create or replace function public.configurar_beneficios_empleado_v30(
  p_empleado_id uuid,
  p_mensualiza_decimo_tercero boolean,
  p_mensualiza_decimo_cuarto boolean,
  p_paga_fondos_reserva_mensual boolean,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.empleado_compensacion%rowtype;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede configurar beneficios';
  end if;
  if p_idempotency_key is null or length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La configuracion requiere idempotencia y motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into c from public.empleado_compensacion
  where empleado_id = p_empleado_id and fecha_hasta is null for update;
  if not found then raise exception 'El empleado no tiene compensacion vigente'; end if;

  update public.empleado_compensacion
  set mensualiza_decimo_tercero = coalesce(p_mensualiza_decimo_tercero, false),
      mensualiza_decimo_cuarto = coalesce(p_mensualiza_decimo_cuarto, false),
      paga_fondos_reserva_mensual = coalesce(p_paga_fondos_reserva_mensual, true)
  where id = c.id;
  v_evento_id := public.registrar_evento_nomina_v30(
    'compensacion', c.id, p_empleado_id, 'beneficios_configurados', null, null,
    btrim(p_motivo), jsonb_build_object(
      'mensualiza_decimo_tercero', coalesce(p_mensualiza_decimo_tercero, false),
      'mensualiza_decimo_cuarto', coalesce(p_mensualiza_decimo_cuarto, false),
      'paga_fondos_reserva_mensual', coalesce(p_paga_fondos_reserva_mensual, true)
    ), p_idempotency_key
  );
  return jsonb_build_object('compensacion_id', c.id, 'evento_id', v_evento_id,
    'duplicado', false);
end;
$$;

create or replace function public.abrir_periodo_nomina_v30(
  p_grupo_id uuid,
  p_anio integer,
  p_mes integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_inicio date;
  v_fin date;
  v_total integer;
  v_faltantes text;
  v_invalidos text;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede abrir periodos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.nomina_periodos where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('periodo_id', v_id, 'duplicado', true); end if;
  if p_anio not between 2000 and 2200 or p_mes not between 1 and 12 then
    raise exception 'El periodo no es valido';
  end if;
  if not exists (select 1 from public.grupos_economicos g where g.id = p_grupo_id and g.activo) then
    raise exception 'El grupo economico no existe o esta inactivo';
  end if;
  if not exists (select 1 from public.nomina_parametros n where n.anio = p_anio) then
    raise exception 'Configura los parametros de Nomina del anio %', p_anio;
  end if;
  v_inicio := make_date(p_anio, p_mes, 1);
  v_fin := (v_inicio + interval '1 month - 1 day')::date;
  select string_agg(e.identificacion || ' - ' || e.apellidos || ' ' || e.nombres, ', ')
  into v_faltantes
  from public.empleados e
  where e.grupo_id = p_grupo_id
    and e.tipo_contrato <> 'servicios_profesionales'
    and e.fecha_ingreso_real <= v_fin
    and (e.fecha_salida is null or e.fecha_salida >= v_inicio)
    and not exists (
      select 1 from public.empleado_compensacion c
      where c.empleado_id = e.id and c.fecha_desde <= v_fin
        and (c.fecha_hasta is null or c.fecha_hasta >= v_inicio)
    );
  if v_faltantes is not null then
    raise exception 'Empleados sin compensacion para el periodo: %', v_faltantes;
  end if;

  select string_agg(
    e.identificacion || ' - ' || e.apellidos || ' ' || e.nombres, ', '
  ) into v_invalidos
  from public.empleados e
  join lateral (
    select ec.* from public.empleado_compensacion ec
    where ec.empleado_id = e.id and ec.fecha_desde <= v_fin
      and (ec.fecha_hasta is null or ec.fecha_hasta >= v_inicio)
    order by ec.fecha_desde desc limit 1
  ) c on true
  join public.empresas pag on pag.id = c.empresa_pagadora_id
  left join lateral (
    select ea.* from public.empleado_afiliaciones ea
    where ea.empleado_id = e.id and ea.fecha_desde <= v_fin
      and (ea.fecha_hasta is null or ea.fecha_hasta >= v_inicio)
    order by ea.fecha_desde desc limit 1
  ) a on true
  left join public.empresas afi on afi.id = a.empresa_id
  where e.grupo_id = p_grupo_id
    and e.tipo_contrato <> 'servicios_profesionales'
    and e.fecha_ingreso_real <= v_fin
    and (e.fecha_salida is null or e.fecha_salida >= v_inicio)
    and (
      pag.grupo_id <> p_grupo_id
      or (coalesce(a.afiliado, false)
        and (afi.id is null or afi.grupo_id <> p_grupo_id))
    );
  if v_invalidos is not null then
    raise exception 'Empleados con RUC pagador o afiliador fuera del grupo: %',
      v_invalidos;
  end if;

  insert into public.nomina_periodos(
    grupo_id, anio, mes, fecha_desde, fecha_hasta, idempotency_key, generado_por
  ) values (p_grupo_id, p_anio, p_mes, v_inicio, v_fin, p_idempotency_key, auth.uid())
  returning id into v_id;

  insert into public.nomina_rol_lineas(
    periodo_id, empleado_id, afiliacion_id, compensacion_id,
    empresa_afiliacion_id, empresa_pagadora_id,
    identificacion, nombres, apellidos, cargo, area, tipo_contrato,
    fecha_ingreso_real, fecha_salida, afiliado, fecha_afiliacion,
    afiliacion_desde, afiliacion_hasta,
    sueldo_declarado, sueldo_real, mensualiza_decimo_tercero,
    mensualiza_decimo_cuarto, paga_fondos_reserva_mensual
  )
  select v_id, e.id, a.id, c.id, a.empresa_id, c.empresa_pagadora_id,
    e.identificacion, e.nombres, e.apellidos, e.cargo, e.area, e.tipo_contrato,
    e.fecha_ingreso_real, e.fecha_salida, coalesce(a.afiliado, false),
    a.fecha_afiliacion,
    case when a.afiliado then a.fecha_desde end,
    case when a.afiliado then a.fecha_hasta end,
    coalesce(a.sueldo_declarado, 0), c.sueldo_real,
    c.mensualiza_decimo_tercero, c.mensualiza_decimo_cuarto,
    c.paga_fondos_reserva_mensual
  from public.empleados e
  join lateral (
    select ec.* from public.empleado_compensacion ec
    where ec.empleado_id = e.id and ec.fecha_desde <= v_fin
      and (ec.fecha_hasta is null or ec.fecha_hasta >= v_inicio)
    order by ec.fecha_desde desc limit 1
  ) c on true
  left join lateral (
    select ea.* from public.empleado_afiliaciones ea
    where ea.empleado_id = e.id and ea.fecha_desde <= v_fin
      and (ea.fecha_hasta is null or ea.fecha_hasta >= v_inicio)
    order by ea.fecha_desde desc limit 1
  ) a on true
  where e.grupo_id = p_grupo_id
    and e.tipo_contrato <> 'servicios_profesionales'
    and e.fecha_ingreso_real <= v_fin
    and (e.fecha_salida is null or e.fecha_salida >= v_inicio);
  get diagnostics v_total = row_count;
  if v_total = 0 then raise exception 'No existen empleados para el periodo'; end if;

  v_evento_id := public.registrar_evento_nomina_v30(
    'nomina_periodo', v_id, null, 'periodo_abierto', null, 'abierto',
    'Snapshot mensual creado', jsonb_build_object('anio', p_anio, 'mes', p_mes,
      'empleados', v_total), gen_random_uuid()
  );
  return jsonb_build_object('periodo_id', v_id, 'evento_id', v_evento_id,
    'empleados', v_total, 'estado', 'abierto', 'duplicado', false);
end;
$$;

create or replace function public.guardar_novedades_rol_v30(
  p_rol_linea_id uuid,
  p_datos jsonb,
  p_version integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.nomina_rol_lineas%rowtype;
  p public.nomina_periodos%rowtype;
  v_empresa_id uuid;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede registrar novedades del rol';
  end if;
  if p_idempotency_key is null or jsonb_typeof(p_datos) <> 'object' then
    raise exception 'La solicitud requiere idempotencia y un objeto de datos';
  end if;
  select id into v_evento_id from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  if exists (
    select 1 from jsonb_object_keys(p_datos) k
    where k not in ('horas_extra_50', 'horas_extra_100', 'comisiones', 'bonos',
      'vacaciones_pagadas', 'otros_ingresos', 'empresa_pagadora_id', 'nota')
  ) then raise exception 'La solicitud contiene un campo no permitido'; end if;

  select * into l from public.nomina_rol_lineas where id = p_rol_linea_id for update;
  if not found then raise exception 'La linea de rol no existe'; end if;
  select * into p from public.nomina_periodos where id = l.periodo_id for update;
  if p.estado <> 'abierto' then raise exception 'Las novedades solo se editan con el periodo abierto'; end if;
  if p_version is null or p_version <> l.version then
    raise exception 'La linea cambio en otra sesion; recarga antes de guardar';
  end if;
  v_empresa_id := case when p_datos ? 'empresa_pagadora_id'
    then nullif(p_datos->>'empresa_pagadora_id', '')::uuid else l.empresa_pagadora_id end;
  if v_empresa_id is null or not exists (
    select 1 from public.empresas e
    where e.id = v_empresa_id and e.grupo_id = p.grupo_id and e.activo
  ) then raise exception 'La empresa pagadora no pertenece al grupo'; end if;

  update public.nomina_rol_lineas
  set horas_extra_50 = coalesce((p_datos->>'horas_extra_50')::numeric, horas_extra_50),
      horas_extra_100 = coalesce((p_datos->>'horas_extra_100')::numeric, horas_extra_100),
      comisiones = coalesce((p_datos->>'comisiones')::numeric, comisiones),
      bonos = coalesce((p_datos->>'bonos')::numeric, bonos),
      vacaciones_pagadas = coalesce((p_datos->>'vacaciones_pagadas')::numeric, vacaciones_pagadas),
      otros_ingresos = coalesce((p_datos->>'otros_ingresos')::numeric, otros_ingresos),
      empresa_pagadora_id = v_empresa_id,
      nota_novedades = case when p_datos ? 'nota'
        then nullif(btrim(p_datos->>'nota'), '') else nota_novedades end,
      version = version + 1, updated_at = now()
  where id = l.id;
  v_evento_id := public.registrar_evento_nomina_v30(
    'nomina_rol', l.id, l.empleado_id, 'novedades_rol_guardadas',
    'abierto', 'abierto', 'Entradas variables actualizadas', p_datos,
    p_idempotency_key
  );
  return jsonb_build_object('rol_linea_id', l.id, 'evento_id', v_evento_id,
    'version', l.version + 1, 'duplicado', false);
end;
$$;

-- ------------------------------------------------------------
-- 5. Reapertura compensatoria y cierre inmutable
-- ------------------------------------------------------------
create or replace function public.reabrir_periodo_nomina_v30(
  p_periodo_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.nomina_periodos%rowtype;
  l record;
  v_evento_id uuid;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede reabrir un periodo calculado';
  end if;
  if p_idempotency_key is null or length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La reapertura requiere idempotencia y motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into p from public.nomina_periodos where id = p_periodo_id for update;
  if not found then raise exception 'El periodo no existe'; end if;
  if p.estado <> 'calculado' then
    raise exception 'Solo un periodo calculado y no cerrado puede reabrirse';
  end if;

  for l in
    select id, descuento_lote_id from public.nomina_rol_lineas
    where periodo_id = p.id order by empleado_id for update
  loop
    if l.descuento_lote_id is not null then
      perform public.revertir_aplicacion_descuentos_v29(
        l.descuento_lote_id, 'Reapertura de periodo: ' || btrim(p_motivo), gen_random_uuid()
      );
    end if;
    delete from public.nomina_rol_rubros where rol_linea_id = l.id;
  end loop;

  update public.nomina_rol_lineas
  set dias_laborados = 0, dias_afiliados = 0, dias_vacaciones = 0,
      dias_ausencia_con_sueldo = 0, dias_ausencia_sin_sueldo = 0,
      sueldo_proporcional_real = 0, sueldo_proporcional_declarado = 0,
      valor_horas_extra = 0, valor_horas_extra_declarado = 0,
      decimo_tercero_mensualizado = 0, decimo_tercero_declarado = 0,
      decimo_cuarto_mensualizado = 0, decimo_cuarto_declarado = 0,
      fondos_reserva_pagados = 0, fondos_reserva_declarados = 0,
      base_aportacion_declarada = 0, total_ingresos_real = 0,
      total_ingresos_declarado = 0, aporte_personal = 0,
      anticipos_cuota = 0, multas = 0, prestamos_iess = 0,
      prestamos_empresa = 0, retencion_judicial = 0, otros_descuentos = 0,
      total_descuentos_programados = 0, total_egresos = 0,
      descuento_lote_id = null, aporte_patronal = 0,
      provision_decimo_tercero = 0, provision_decimo_cuarto = 0,
      provision_vacaciones = 0, provision_fondos_reserva = 0,
      provision_decimo_tercero_declarada = 0,
      provision_decimo_cuarto_declarada = 0,
      provision_vacaciones_declarada = 0,
      provision_fondos_reserva_declarada = 0,
      neto_real = 0, neto_declarado = 0,
      costo_empleador_real = 0, costo_empleador_declarado = 0,
      calculado_at = null, version = version + 1, updated_at = now()
  where periodo_id = p.id;
  update public.nomina_periodos
  set estado = 'abierto', calculado_por = null, calculado_at = null,
      version = version + 1, updated_at = now()
  where id = p.id;

  v_evento_id := public.registrar_evento_nomina_v30(
    'nomina_periodo', p.id, null, 'periodo_reabierto', 'calculado', 'abierto',
    btrim(p_motivo), '{}'::jsonb, p_idempotency_key
  );
  return jsonb_build_object('periodo_id', p.id, 'evento_id', v_evento_id,
    'estado', 'abierto', 'duplicado', false);
end;
$$;

create or replace function public.cerrar_periodo_nomina_v30(
  p_periodo_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.nomina_periodos%rowtype;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede cerrar periodos';
  end if;
  if p_idempotency_key is null or length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El cierre requiere idempotencia y motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into p from public.nomina_periodos where id = p_periodo_id for update;
  if not found then raise exception 'El periodo no existe'; end if;
  if p.estado <> 'calculado' then raise exception 'Solo un periodo calculado puede cerrarse'; end if;
  if not exists (select 1 from public.nomina_rol_lineas where periodo_id = p.id) then
    raise exception 'El periodo no contiene roles';
  end if;
  if exists (
    select 1 from public.nomina_rol_lineas l
    where l.periodo_id = p.id and (l.calculado_at is null or l.descuento_lote_id is null)
  ) then raise exception 'Existen roles incompletos en el periodo'; end if;

  update public.nomina_periodos
  set estado = 'cerrado', cerrado_por = auth.uid(), cerrado_at = now(),
      motivo_cierre = btrim(p_motivo), version = version + 1, updated_at = now()
  where id = p.id;
  v_evento_id := public.registrar_evento_nomina_v30(
    'nomina_periodo', p.id, null, 'periodo_cerrado', 'calculado', 'cerrado',
    btrim(p_motivo), '{}'::jsonb, p_idempotency_key
  );
  return jsonb_build_object('periodo_id', p.id, 'evento_id', v_evento_id,
    'estado', 'cerrado', 'duplicado', false);
end;
$$;

-- ------------------------------------------------------------
-- 6. Vistas gerenciales con RLS heredado
-- ------------------------------------------------------------
create view public.vista_rol_real with (security_invoker = true) as
select p.id as periodo_id, p.anio, p.mes, p.estado,
       l.id as rol_linea_id, l.empleado_id, l.identificacion,
       l.apellidos, l.nombres, l.cargo, l.area,
       l.dias_laborados, l.dias_vacaciones,
       l.dias_ausencia_con_sueldo, l.dias_ausencia_sin_sueldo,
       l.sueldo_real, l.total_ingresos_real, l.aporte_personal,
       l.total_descuentos_programados, l.total_egresos, l.neto_real,
       l.costo_empleador_real, ep.id as empresa_pagadora_id,
       ep.ruc as empresa_pagadora_ruc, ep.razon_social as empresa_pagadora
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empresas ep on ep.id = l.empresa_pagadora_id;

create view public.vista_rol_declarado with (security_invoker = true) as
select p.id as periodo_id, p.anio, p.mes, p.estado,
       l.id as rol_linea_id, l.empleado_id, l.identificacion,
       l.apellidos, l.nombres, l.cargo, l.area,
       l.fecha_afiliacion, l.sueldo_declarado, l.base_aportacion_declarada,
       l.total_ingresos_declarado, l.aporte_personal, l.aporte_patronal,
       l.total_egresos, l.neto_declarado, l.costo_empleador_declarado,
       ea.id as empresa_afiliacion_id, ea.ruc as empresa_afiliacion_ruc,
       ea.razon_social as empresa_afiliacion
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empresas ea on ea.id = l.empresa_afiliacion_id
where l.afiliado;

create view public.vista_brecha_nomina with (security_invoker = true) as
select p.id as periodo_id, p.anio, p.mes, p.estado,
       l.id as rol_linea_id, l.empleado_id, l.identificacion,
       l.apellidos, l.nombres, l.sueldo_real, l.sueldo_declarado,
       l.total_ingresos_real, l.total_ingresos_declarado,
       l.neto_real, l.neto_declarado, l.brecha,
       l.empresa_pagadora_id, l.empresa_afiliacion_id
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id;

create view public.vista_costo_empleador_por_empresa with (security_invoker = true) as
select p.grupo_id, p.anio, p.mes, p.estado,
       e.id as empresa_pagadora_id, e.ruc, e.razon_social,
       count(*)::integer as empleados,
       coalesce(sum(l.total_ingresos_real), 0)::numeric(16,2) as ingresos_pagados,
       coalesce(sum(l.aporte_patronal), 0)::numeric(16,2) as aporte_patronal,
       coalesce(sum(l.provision_decimo_tercero + l.provision_decimo_cuarto
         + l.provision_vacaciones + l.provision_fondos_reserva), 0)::numeric(16,2)
         as provisiones,
       coalesce(sum(l.costo_empleador_real), 0)::numeric(16,2) as costo_total_real
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empresas e on e.id = l.empresa_pagadora_id
group by p.grupo_id, p.anio, p.mes, p.estado, e.id;

create view public.vista_pagos_por_empresa with (security_invoker = true) as
select p.grupo_id, p.id as periodo_id, p.anio, p.mes, p.estado,
       ep.id as empresa_pagadora_id, ep.ruc, ep.razon_social,
       e.forma_pago, count(*)::integer as beneficiarios,
       coalesce(sum(l.neto_real), 0)::numeric(16,2) as monto_total
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empresas ep on ep.id = l.empresa_pagadora_id
join public.empleados e on e.id = l.empleado_id
group by p.grupo_id, p.id, ep.id, e.forma_pago;

-- ------------------------------------------------------------
-- 7. Propiedad, privilegios y recarga
-- ------------------------------------------------------------
alter function public.proteger_nomina_cerrada_v30() owner to postgres;
alter function public.proteger_periodo_cerrado_v30() owner to postgres;
alter function public.obtener_parametro_nomina_v30(integer, text) owner to postgres;
alter function public.registrar_evento_nomina_v30(text, uuid, uuid, text, text, text, text, jsonb, uuid) owner to postgres;
alter function public.configurar_beneficios_empleado_v30(uuid, boolean, boolean, boolean, text, uuid) owner to postgres;
alter function public.abrir_periodo_nomina_v30(uuid, integer, integer, uuid) owner to postgres;
alter function public.guardar_novedades_rol_v30(uuid, jsonb, integer, uuid) owner to postgres;
alter function public.calcular_rol_v30(uuid, uuid) owner to postgres;
alter function public.reabrir_periodo_nomina_v30(uuid, text, uuid) owner to postgres;
alter function public.cerrar_periodo_nomina_v30(uuid, text, uuid) owner to postgres;

revoke all on public.nomina_periodos from public, anon;
revoke all on public.nomina_rol_lineas from public, anon;
revoke all on public.nomina_rubros from public, anon;
revoke all on public.nomina_rol_rubros from public, anon;
revoke insert, update, delete on public.nomina_periodos from authenticated;
revoke insert, update, delete on public.nomina_rol_lineas from authenticated;
revoke insert, update, delete on public.nomina_rubros from authenticated;
revoke insert, update, delete on public.nomina_rol_rubros from authenticated;
grant select on public.nomina_periodos to authenticated;
grant select on public.nomina_rol_lineas to authenticated;
grant select on public.nomina_rubros to authenticated;
grant select on public.nomina_rol_rubros to authenticated;
grant select on public.vista_rol_real to authenticated;
grant select on public.vista_rol_declarado to authenticated;
grant select on public.vista_brecha_nomina to authenticated;
grant select on public.vista_costo_empleador_por_empresa to authenticated;
grant select on public.vista_pagos_por_empresa to authenticated;

revoke execute on function public.proteger_nomina_cerrada_v30()
  from public, anon, authenticated;
revoke execute on function public.proteger_periodo_cerrado_v30()
  from public, anon, authenticated;
revoke execute on function public.registrar_evento_nomina_v30(text, uuid, uuid, text, text, text, text, jsonb, uuid)
  from public, anon, authenticated;
revoke execute on function public.obtener_parametro_nomina_v30(integer, text) from public, anon;
revoke execute on function public.configurar_beneficios_empleado_v30(uuid, boolean, boolean, boolean, text, uuid)
  from public, anon;
revoke execute on function public.abrir_periodo_nomina_v30(uuid, integer, integer, uuid)
  from public, anon;
revoke execute on function public.guardar_novedades_rol_v30(uuid, jsonb, integer, uuid)
  from public, anon;
revoke execute on function public.calcular_rol_v30(uuid, uuid) from public, anon;
revoke execute on function public.reabrir_periodo_nomina_v30(uuid, text, uuid)
  from public, anon;
revoke execute on function public.cerrar_periodo_nomina_v30(uuid, text, uuid)
  from public, anon;

grant execute on function public.obtener_parametro_nomina_v30(integer, text) to authenticated;
grant execute on function public.configurar_beneficios_empleado_v30(uuid, boolean, boolean, boolean, text, uuid)
  to authenticated;
grant execute on function public.abrir_periodo_nomina_v30(uuid, integer, integer, uuid)
  to authenticated;
grant execute on function public.guardar_novedades_rol_v30(uuid, jsonb, integer, uuid)
  to authenticated;
grant execute on function public.calcular_rol_v30(uuid, uuid) to authenticated;
grant execute on function public.reabrir_periodo_nomina_v30(uuid, text, uuid)
  to authenticated;
grant execute on function public.cerrar_periodo_nomina_v30(uuid, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';
