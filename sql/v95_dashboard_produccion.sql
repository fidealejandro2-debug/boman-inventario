-- ============================================================
-- BOMAN INVENTARIO - v95: Dashboard ejecutivo de produccion
--
-- Lee las tablas normalizadas de contratos creadas en v79 y alimentadas
-- por la sincronizacion BomanSport. Los agregados se calculan dentro de
-- PostgreSQL; el navegador solo recibe el resumen y una pagina de detalle.
-- Ejecutar despues de v94.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.contrato_prendas') is null
     or to_regclass('public.contrato_archivos') is null then
    raise exception 'Falta instalar v79 antes de v95';
  end if;
  if to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta instalar v35 antes de v95';
  end if;
end;
$requisitos$;

create or replace function public.resumen_dashboard_produccion_v95(
  p_desde date,
  p_hasta date,
  p_vendedor text default null,
  p_estado text default null,
  p_prioridad text default null,
  p_incluir_entregados boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_resultado jsonb;
begin
  if auth.uid() is null
     or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar produccion';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El rango de fechas no es valido';
  end if;
  if p_hasta - p_desde > 366 then
    raise exception 'El rango no puede superar 366 dias';
  end if;

  with filtrados as materialized (
    select c.*
    from public.contratos c
    where c.fecha_entrega between p_desde and p_hasta
      and (p_incluir_entregados or lower(c.estado) <> 'entregado')
      and (nullif(btrim(p_vendedor), '') is null
           or lower(c.vendedor) = lower(btrim(p_vendedor)))
      and (nullif(btrim(p_estado), '') is null
           or lower(c.estado) = lower(btrim(p_estado)))
      and (nullif(btrim(p_prioridad), '') is null
           or lower(c.prioridad) = lower(btrim(p_prioridad)))
  ),
  prendas as (
    select cp.prenda, sum(cp.cantidad)::bigint as cantidad
    from public.contrato_prendas cp
    join filtrados f on f.id = cp.contrato_id
    where lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
    group by cp.prenda
  ),
  estados as (
    select f.estado, count(*)::bigint as cantidad
    from filtrados f group by f.estado
  ),
  vendedores as (
    select coalesce(nullif(btrim(f.vendedor), ''), 'Sin vendedor') as vendedor,
           count(*)::bigint as contratos,
           coalesce(sum(f.total_prendas), 0)::bigint as prendas,
           coalesce(sum(f.presupuesto), 0)::numeric(16,2) as presupuesto
    from filtrados f
    group by coalesce(nullif(btrim(f.vendedor), ''), 'Sin vendedor')
  ),
  cronograma as (
    select f.fecha_inicio_produccion as fecha,
           f.tipo_contrato,
           count(*)::bigint as contratos,
           coalesce(sum(f.total_prendas), 0)::bigint as prendas,
           case f.tipo_contrato
             when 'Equipo Profesional' then 100
             when 'Mercadería' then 150
             when 'Emergente' then 50
             else 600
           end as capacidad
    from filtrados f
    where f.fecha_inicio_produccion is not null
    group by f.fecha_inicio_produccion, f.tipo_contrato
  ),
  proximas as (
    select f.numero, f.cliente, f.vendedor, f.estado, f.prioridad,
           f.fecha_entrega, f.total_prendas,
           (f.fecha_entrega - v_hoy)::integer as dias_restantes
    from filtrados f
    where f.fecha_entrega between v_hoy and v_hoy + 7
    order by f.fecha_entrega, f.numero
    limit 30
  )
  select jsonb_build_object(
    'generado_at', now(),
    'hoy', v_hoy,
    'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'ultima_actualizacion', (select max(updated_at) from public.contratos),
    'kpis', jsonb_build_object(
      'contratos', (select count(*) from filtrados),
      'prendas', coalesce((select sum(total_prendas) from filtrados), 0),
      'presupuesto', coalesce((select sum(presupuesto) from filtrados), 0),
      'abonos', coalesce((select sum(abono) from filtrados), 0),
      'saldo', coalesce((select sum(greatest(presupuesto - abono, 0)) from filtrados), 0),
      'atrasados', (select count(*) from filtrados where fecha_entrega < v_hoy),
      'urgentes', (select count(*) from filtrados where lower(prioridad) = 'urgente')
    ),
    'estados', coalesce((
      select jsonb_agg(jsonb_build_object('estado', estado, 'cantidad', cantidad)
                       order by cantidad desc, estado)
      from estados
    ), '[]'::jsonb),
    'prendas', coalesce((
      select jsonb_agg(jsonb_build_object('prenda', prenda, 'cantidad', cantidad)
                       order by cantidad desc, prenda)
      from prendas
    ), '[]'::jsonb),
    'vendedores', coalesce((
      select jsonb_agg(jsonb_build_object(
        'vendedor', vendedor, 'contratos', contratos,
        'prendas', prendas, 'presupuesto', presupuesto
      ) order by contratos desc, vendedor)
      from (select * from vendedores order by contratos desc, vendedor limit 12) x
    ), '[]'::jsonb),
    'cronograma', coalesce((
      select jsonb_agg(jsonb_build_object(
        'fecha', fecha, 'tipo', tipo_contrato, 'contratos', contratos,
        'prendas', prendas, 'capacidad', capacidad,
        'excede', prendas > capacidad
      ) order by fecha, tipo_contrato)
      from cronograma
    ), '[]'::jsonb),
    'proximas_entregas', coalesce((
      select jsonb_agg(to_jsonb(proximas) order by fecha_entrega, numero)
      from proximas
    ), '[]'::jsonb),
    'filtros', jsonb_build_object(
      'vendedores', coalesce((select jsonb_agg(v order by v) from (
        select distinct vendedor as v from public.contratos where btrim(vendedor) <> ''
      ) q), '[]'::jsonb),
      'estados', coalesce((select jsonb_agg(e order by e) from (
        select distinct estado as e from public.contratos where btrim(estado) <> ''
      ) q), '[]'::jsonb)
    )
  ) into v_resultado;

  return v_resultado;
end;
$fn$;

create or replace function public.listar_dashboard_produccion_v95(
  p_desde date,
  p_hasta date,
  p_vendedor text default null,
  p_estado text default null,
  p_prioridad text default null,
  p_incluir_entregados boolean default false,
  p_pagina integer default 1,
  p_por_pagina integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_pagina integer := greatest(coalesce(p_pagina, 1), 1);
  v_por_pagina integer := least(greatest(coalesce(p_por_pagina, 50), 1), 100);
  v_resultado jsonb;
begin
  if auth.uid() is null
     or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar produccion';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El rango de fechas no es valido';
  end if;

  with filtrados as materialized (
    select c.*
    from public.contratos c
    where c.fecha_entrega between p_desde and p_hasta
      and (p_incluir_entregados or lower(c.estado) <> 'entregado')
      and (nullif(btrim(p_vendedor), '') is null
           or lower(c.vendedor) = lower(btrim(p_vendedor)))
      and (nullif(btrim(p_estado), '') is null
           or lower(c.estado) = lower(btrim(p_estado)))
      and (nullif(btrim(p_prioridad), '') is null
           or lower(c.prioridad) = lower(btrim(p_prioridad)))
  ),
  pagina as (
    select f.*
    from filtrados f
    order by f.fecha_entrega, case when lower(f.prioridad) = 'urgente' then 0 else 1 end,
             f.numero
    limit v_por_pagina offset (v_pagina - 1) * v_por_pagina
  ),
  filas as (
    select p.*,
      coalesce((
        select jsonb_object_agg(x.prenda, x.cantidad order by x.prenda)
        from (
          select cp.prenda, sum(cp.cantidad)::bigint cantidad
          from public.contrato_prendas cp
          where cp.contrato_id = p.id
          group by cp.prenda
        ) x
      ), '{}'::jsonb) as prendas_desglose,
      (select ca.drive_id from public.contrato_archivos ca
       where ca.contrato_id = p.id and ca.tipo = 'mockup'
         and nullif(btrim(ca.drive_id), '') is not null
       order by ca.orden, ca.id limit 1) as mockup_drive_id
    from pagina p
  )
  select jsonb_build_object(
    'total', (select count(*) from filtrados),
    'pagina', v_pagina,
    'por_pagina', v_por_pagina,
    'filas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'numero', numero, 'cliente', cliente, 'vendedor', vendedor,
        'disenador', disenador, 'estado', estado, 'prioridad', prioridad,
        'tipo_contrato', tipo_contrato, 'fecha_ingreso', fecha_ingreso,
        'fecha_inicio', fecha_inicio_produccion, 'fecha_entrega', fecha_entrega,
        'dias_restantes', fecha_entrega - v_hoy,
        'atrasado', fecha_entrega < v_hoy and lower(estado) <> 'entregado',
        'total_prendas', total_prendas, 'prendas', prendas_desglose,
        'presupuesto', presupuesto, 'abono', abono,
        'saldo', greatest(presupuesto - abono, 0),
        'mockup_drive_id', mockup_drive_id
      ) order by fecha_entrega, case when lower(prioridad) = 'urgente' then 0 else 1 end, numero)
      from filas
    ), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$fn$;

alter function public.resumen_dashboard_produccion_v95(date,date,text,text,text,boolean)
  owner to postgres;
alter function public.listar_dashboard_produccion_v95(date,date,text,text,text,boolean,integer,integer)
  owner to postgres;

revoke all on function public.resumen_dashboard_produccion_v95(date,date,text,text,text,boolean)
  from public, anon;
revoke all on function public.listar_dashboard_produccion_v95(date,date,text,text,text,boolean,integer,integer)
  from public, anon;
grant execute on function public.resumen_dashboard_produccion_v95(date,date,text,text,text,boolean)
  to authenticated;
grant execute on function public.listar_dashboard_produccion_v95(date,date,text,text,text,boolean,integer,integer)
  to authenticated;

comment on function public.resumen_dashboard_produccion_v95(date,date,text,text,text,boolean) is
  'Indicadores, desgloses y cronograma del dashboard de produccion. Requiere produccion.acceder.';
comment on function public.listar_dashboard_produccion_v95(date,date,text,text,text,boolean,integer,integer) is
  'Detalle paginado del dashboard de produccion. Nunca devuelve mas de 100 contratos por llamada.';

commit;

notify pgrst, 'reload schema';
