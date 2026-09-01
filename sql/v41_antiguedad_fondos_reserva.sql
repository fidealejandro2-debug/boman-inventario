-- ============================================================
-- BOMAN INVENTARIO - Antiguedad acumulada para fondos de reserva v41
-- Ejecutar una sola vez DESPUES de v40.
--
-- El finiquito cierra vacaciones y demas valores del vinculo anterior, pero
-- no borra el tiempo de servicio que debe sumarse si la persona vuelve al
-- mismo empleador. Para no atribuir antiguedad entre RUC distintos, este
-- calculo usa los vinculos laborales y determina su empleador por el RUC de
-- afiliacion asociado; para personal no afiliado usa la empresa pagadora.
--
-- Reglas:
--   * suma solamente dias efectivamente cubiertos por cada periodo;
--   * no cuenta el intervalo durante el cual la persona estuvo fuera;
--   * separa el acumulado por RUC empleador;
--   * un cambio de sueldo dentro del mismo RUC no reinicia el acumulado;
--   * una vez completado el primer ano, el derecho permanece adquirido.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tiempo de servicio acumulado bajo un mismo RUC
-- ------------------------------------------------------------
create or replace function public.dias_servicio_fondo_reserva_v41(
  p_empleado_id uuid,
  p_empresa_id uuid,
  p_fecha_corte date
) returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  with vinculos_empleador as (
    select
      v.id,
      v.fecha_ingreso,
      v.fecha_salida,
      coalesce(
        (
          select a.empresa_id
          from public.empleado_afiliaciones a
          where a.empleado_id = v.empleado_id
            and a.afiliado
            and a.fecha_desde <= coalesce(v.fecha_salida, p_fecha_corte)
            and coalesce(a.fecha_hasta, p_fecha_corte) >= v.fecha_ingreso
          order by
            case when a.fecha_desde <= v.fecha_ingreso
              and coalesce(a.fecha_hasta, p_fecha_corte) >= v.fecha_ingreso
              then 0 else 1 end,
            a.fecha_desde
          limit 1
        ),
        (
          select c.empresa_pagadora_id
          from public.empleado_compensacion c
          where c.empleado_id = v.empleado_id
            and c.fecha_desde <= coalesce(v.fecha_salida, p_fecha_corte)
            and coalesce(c.fecha_hasta, p_fecha_corte) >= v.fecha_ingreso
          order by
            case when c.fecha_desde <= v.fecha_ingreso
              and coalesce(c.fecha_hasta, p_fecha_corte) >= v.fecha_ingreso
              then 0 else 1 end,
            c.fecha_desde
          limit 1
        )
      ) as empresa_id
    from public.empleado_vinculos v
    where v.empleado_id = p_empleado_id
      and v.fecha_ingreso <= p_fecha_corte
  ), periodos as (
    select
      v.fecha_ingreso as inicio,
      least(coalesce(v.fecha_salida, p_fecha_corte), p_fecha_corte) as fin
    from vinculos_empleador v
    where v.empresa_id = p_empresa_id
      and p_fecha_corte is not null
      and least(coalesce(v.fecha_salida, p_fecha_corte), p_fecha_corte)
          >= v.fecha_ingreso
  ), maximos as (
    select p.*,
      max(p.fin) over (
        order by p.inicio, p.fin
        rows between unbounded preceding and 1 preceding
      ) as fin_anterior
    from periodos p
  ), marcados as (
    select m.*,
      case when m.fin_anterior is null or m.inicio > m.fin_anterior + 1
        then 1 else 0 end as nueva_isla
    from maximos m
  ), islas as (
    select min(inicio) as inicio, max(fin) as fin
    from (
      select m.*,
        sum(nueva_isla) over (order by inicio, fin) as isla
      from marcados m
    ) x
    group by isla
  )
  select coalesce(sum(
    case
      -- Al consultar el propio dia de corte se mide el tiempo ya cumplido al
      -- empezar ese dia, igual que fecha_ingreso + interval '1 year'.
      when fin = p_fecha_corte then fin - inicio
      else fin - inicio + 1
    end
  ), 0)::integer
  from islas;
$$;

create or replace function public.dias_requeridos_fondo_reserva_v41(
  p_empleado_id uuid,
  p_empresa_id uuid
) returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  with vinculos_empleador as (
    select
      v.fecha_ingreso,
      coalesce(
        (
          select a.empresa_id
          from public.empleado_afiliaciones a
          where a.empleado_id = v.empleado_id
            and a.afiliado
            and a.fecha_desde <= coalesce(v.fecha_salida, current_date)
            and coalesce(a.fecha_hasta, current_date) >= v.fecha_ingreso
          order by
            case when a.fecha_desde <= v.fecha_ingreso
              and coalesce(a.fecha_hasta, current_date) >= v.fecha_ingreso
              then 0 else 1 end,
            a.fecha_desde
          limit 1
        ),
        (
          select c.empresa_pagadora_id
          from public.empleado_compensacion c
          where c.empleado_id = v.empleado_id
            and c.fecha_desde <= coalesce(v.fecha_salida, current_date)
            and coalesce(c.fecha_hasta, current_date) >= v.fecha_ingreso
          order by
            case when c.fecha_desde <= v.fecha_ingreso
              and coalesce(c.fecha_hasta, current_date) >= v.fecha_ingreso
              then 0 else 1 end,
            c.fecha_desde
          limit 1
        )
      ) as empresa_id
    from public.empleado_vinculos v
    where v.empleado_id = p_empleado_id
  )
  select coalesce(
    ((min(v.fecha_ingreso) + interval '1 year')::date - min(v.fecha_ingreso)),
    365
  )::integer
  from vinculos_empleador v
  where v.empresa_id = p_empresa_id;
$$;

create or replace function public.cumple_fondo_reserva_v41(
  p_empleado_id uuid,
  p_empresa_id uuid,
  p_fecha_corte date
) returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select p_empleado_id is not null
    and p_empresa_id is not null
    and p_fecha_corte is not null
    and public.dias_servicio_fondo_reserva_v41(
      p_empleado_id, p_empresa_id, p_fecha_corte
    ) >= public.dias_requeridos_fondo_reserva_v41(
      p_empleado_id, p_empresa_id
    );
$$;

comment on function public.dias_servicio_fondo_reserva_v41(uuid, uuid, date) is
  'Suma vinculos laborales del empleado bajo el mismo RUC, fusionando solapamientos y excluyendo las separaciones.';
comment on function public.cumple_fondo_reserva_v41(uuid, uuid, date) is
  'Indica si el empleado completo el primer ano acumulado bajo el mismo RUC para efectos de fondos de reserva.';

-- ------------------------------------------------------------
-- 2. v30 debe usar el acumulado, no solo la afiliacion vigente
-- ------------------------------------------------------------
-- Se reemplaza unicamente el predicado repetido dentro de la funcion ya
-- instalada. Se exige encontrar exactamente sus tres usos (pago real,
-- provision real y provision declarada); si la funcion fue modificada de
-- otra forma, la migracion se detiene en vez de dejar un calculo parcial.
do $migracion$
declare
  v_definicion text;
  v_predicado text :=
    'p.fecha_hasta >= (l.fecha_afiliacion + interval ''1 year'')::date';
  v_nuevo text :=
    'public.cumple_fondo_reserva_v41(l.empleado_id, l.empresa_afiliacion_id, p.fecha_hasta)';
  v_apariciones integer;
  v_apariciones_nuevas integer;
begin
  select pg_catalog.pg_get_functiondef(p.oid)
  into v_definicion
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'calcular_rol_v30'
    and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_periodo_id uuid, p_idempotency_key uuid';

  if v_definicion is null then
    raise exception 'No existe calcular_rol_v30(uuid,uuid); instala v30 antes de v41';
  end if;

  v_apariciones := (
    length(v_definicion) - length(replace(v_definicion, v_predicado, ''))
  ) / length(v_predicado);
  v_apariciones_nuevas := (
    length(v_definicion) - length(replace(v_definicion, v_nuevo, ''))
  ) / length(v_nuevo);

  if v_apariciones = 0 and v_apariciones_nuevas = 3 then
    -- Reejecucion idempotente: la funcion ya fue corregida.
    null;
  elsif v_apariciones <> 3 or v_apariciones_nuevas <> 0 then
    raise exception
      'calcular_rol_v30 tiene % predicados anteriores y % nuevos; se esperaban 3 y 0. No se modifico la funcion',
      v_apariciones, v_apariciones_nuevas;
  else
    v_definicion := replace(v_definicion, v_predicado, v_nuevo);
    execute v_definicion;
  end if;
end;
$migracion$;

-- ------------------------------------------------------------
-- 3. Vista de control para Nomina
-- ------------------------------------------------------------
create or replace view public.vista_antiguedad_fondo_reserva_v41
with (security_invoker = true) as
with vinculos_empleador as (
  select
    v.id as vinculo_id,
    v.empleado_id,
    v.fecha_ingreso,
    v.fecha_salida,
    coalesce(
      (
        select a.empresa_id
        from public.empleado_afiliaciones a
        where a.empleado_id = v.empleado_id
          and a.afiliado
          and a.fecha_desde <= coalesce(v.fecha_salida, current_date)
          and coalesce(a.fecha_hasta, current_date) >= v.fecha_ingreso
        order by
          case when a.fecha_desde <= v.fecha_ingreso
            and coalesce(a.fecha_hasta, current_date) >= v.fecha_ingreso
            then 0 else 1 end,
          a.fecha_desde
        limit 1
      ),
      (
        select c.empresa_pagadora_id
        from public.empleado_compensacion c
        where c.empleado_id = v.empleado_id
          and c.fecha_desde <= coalesce(v.fecha_salida, current_date)
          and coalesce(c.fecha_hasta, current_date) >= v.fecha_ingreso
        order by
          case when c.fecha_desde <= v.fecha_ingreso
            and coalesce(c.fecha_hasta, current_date) >= v.fecha_ingreso
            then 0 else 1 end,
          c.fecha_desde
        limit 1
      )
    ) as empresa_id
  from public.empleado_vinculos v
)
select
  e.id as empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  emp.id as empresa_id,
  emp.ruc,
  emp.razon_social as empresa,
  min(v.fecha_ingreso) as primer_servicio_desde,
  max(v.fecha_salida) filter (where v.fecha_salida is not null) as ultima_salida,
  count(*)::integer as segmentos_historial,
  public.dias_servicio_fondo_reserva_v41(
    e.id, emp.id, current_date
  ) as dias_acumulados,
  public.dias_requeridos_fondo_reserva_v41(
    e.id, emp.id
  ) as dias_requeridos,
  public.cumple_fondo_reserva_v41(
    e.id, emp.id, current_date
  ) as derecho_adquirido,
  exists (
    select 1
    from vinculos_empleador vigente
    where vigente.empleado_id = e.id
      and vigente.empresa_id = emp.id
      and vigente.fecha_salida is null
  ) as vigente_en_ruc
from public.empleados e
join vinculos_empleador v on v.empleado_id = e.id
join public.empresas emp on emp.id = v.empresa_id
group by e.id, e.identificacion, e.apellidos, e.nombres,
         emp.id, emp.ruc, emp.razon_social;

-- ------------------------------------------------------------
-- 4. Propiedad y permisos
-- ------------------------------------------------------------
alter function public.dias_servicio_fondo_reserva_v41(uuid, uuid, date)
  owner to postgres;
alter function public.dias_requeridos_fondo_reserva_v41(uuid, uuid)
  owner to postgres;
alter function public.cumple_fondo_reserva_v41(uuid, uuid, date)
  owner to postgres;
alter function public.calcular_rol_v30(uuid, uuid) owner to postgres;

revoke execute on function public.dias_servicio_fondo_reserva_v41(uuid, uuid, date)
  from public, anon;
revoke execute on function public.dias_requeridos_fondo_reserva_v41(uuid, uuid)
  from public, anon;
revoke execute on function public.cumple_fondo_reserva_v41(uuid, uuid, date)
  from public, anon;
grant execute on function public.dias_servicio_fondo_reserva_v41(uuid, uuid, date)
  to authenticated;
grant execute on function public.dias_requeridos_fondo_reserva_v41(uuid, uuid)
  to authenticated;
grant execute on function public.cumple_fondo_reserva_v41(uuid, uuid, date)
  to authenticated;

revoke all on public.vista_antiguedad_fondo_reserva_v41 from public, anon;
grant select on public.vista_antiguedad_fondo_reserva_v41 to authenticated;

-- calcular_rol_v30 conserva su contrato publico anterior.
revoke execute on function public.calcular_rol_v30(uuid, uuid) from public, anon;
grant execute on function public.calcular_rol_v30(uuid, uuid) to authenticated;
