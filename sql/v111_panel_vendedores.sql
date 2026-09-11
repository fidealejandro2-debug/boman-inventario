-- ============================================================
-- BOMAN INVENTARIO - v111: panel nativo de vendedores
-- Ejecutar despues de v110 y sin migraciones en paralelo.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.contrato_prendas') is null
     or to_regclass('public.contrato_archivos') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null
     or to_regprocedure('public.obtener_expediente_contrato_v97(uuid)') is null then
    raise exception 'Falta instalar contratos y expediente (v79-v110) antes de v111';
  end if;
end;
$requisitos$;

create index if not exists idx_contratos_vendedor_v111
  on public.contratos (lower(btrim(vendedor)));
create index if not exists idx_contratos_entrega_estado_v111
  on public.contratos (fecha_entrega, estado);

create or replace function public.panel_vendedores_v111(
  p_vendedores text[] default null,
  p_desde date default null,
  p_hasta date default null,
  p_estados text[] default null,
  p_prioridades text[] default null,
  p_cliente text default null,
  p_pagina integer default 1,
  p_por_pagina integer default 30
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $v111$
declare
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_desde date := coalesce(p_desde, (now() at time zone 'America/Guayaquil')::date);
  v_hasta date := coalesce(p_hasta, (now() at time zone 'America/Guayaquil')::date + 14);
  v_pagina integer := greatest(coalesce(p_pagina, 1), 1);
  v_por_pagina integer := least(greatest(coalesce(p_por_pagina, 30), 1), 100);
  v_resultado jsonb;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesion para consultar contratos';
  end if;
  if not public.usuario_tiene_permiso_v35('contratos.acceder') then
    raise exception 'No tienes permiso para consultar contratos';
  end if;
  if v_desde > v_hasta then
    raise exception 'La fecha desde no puede ser posterior a la fecha hasta';
  end if;
  if v_hasta - v_desde > 3660 then
    raise exception 'El rango no puede superar diez anios';
  end if;

  with filtrados as materialized (
    select c.*,
      c.fecha_entrega is not null
        and c.fecha_entrega < v_hoy
        and lower(btrim(c.estado)) not in ('entregado', 'anulado') as atrasado,
      case when c.fecha_entrega is null then null
        else c.fecha_entrega - v_hoy end as dias_para_entrega
    from public.contratos c
    where c.fecha_entrega between v_desde and v_hasta
      and (
        coalesce(cardinality(p_vendedores), 0) = 0
        or exists (
          select 1 from unnest(p_vendedores) v
          where lower(btrim(v)) = lower(btrim(c.vendedor))
        )
      )
      and (
        coalesce(cardinality(p_estados), 0) = 0
        or exists (
          select 1 from unnest(p_estados) e
          where lower(btrim(e)) = lower(btrim(c.estado))
        )
      )
      and (
        coalesce(cardinality(p_prioridades), 0) = 0
        or exists (
          select 1 from unnest(p_prioridades) pr
          where lower(btrim(pr)) = lower(btrim(c.prioridad))
        )
      )
      and (
        nullif(btrim(coalesce(p_cliente, '')), '') is null
        or c.cliente ilike '%' || btrim(p_cliente) || '%'
        or c.numero ilike '%' || btrim(p_cliente) || '%'
      )
  ), pagina as (
    select f.*
    from filtrados f
    order by f.atrasado desc, f.fecha_entrega, f.prioridad desc, f.numero
    offset (v_pagina - 1) * v_por_pagina
    limit v_por_pagina
  ), enriquecidos as (
    select p.id, p.numero, p.cliente, p.vendedor, p.estado, p.prioridad,
      p.tipo_contrato, p.fecha_ingreso, p.fecha_inicio_produccion,
      p.fecha_entrega, p.total_prendas, p.presupuesto, p.abono,
      greatest(p.presupuesto - p.abono, 0)::numeric(14,2) as saldo,
      p.atrasado, p.dias_para_entrega,
      a.drive_id as mockup_drive_id, a.url as mockup_url,
      coalesce(pr.detalle, '[]'::jsonb) as prendas
    from pagina p
    left join lateral (
      select ca.drive_id, ca.url
      from public.contrato_archivos ca
      where ca.contrato_id = p.id and ca.tipo = 'mockup'
      order by ca.orden, ca.id
      limit 1
    ) a on true
    left join lateral (
      select jsonb_agg(
        jsonb_build_object(
          'prenda', q.prenda,
          'calidad', q.calidad,
          'cantidad', q.cantidad
        ) order by q.cantidad desc, q.prenda, q.calidad
      ) as detalle
      from (
        select cp.prenda, nullif(btrim(cp.calidad), '') as calidad,
          sum(cp.cantidad)::integer as cantidad
        from public.contrato_prendas cp
        where cp.contrato_id = p.id
        group by cp.prenda, nullif(btrim(cp.calidad), '')
      ) q
    ) pr on true
  )
  select jsonb_build_object(
    'hoy', v_hoy,
    'filtros', jsonb_build_object('desde', v_desde, 'hasta', v_hasta),
    'catalogos', jsonb_build_object(
      'vendedores', coalesce((
        select jsonb_agg(x.vendedor order by lower(x.vendedor))
        from (
          select min(btrim(c.vendedor)) as vendedor
          from public.contratos c
          where nullif(btrim(c.vendedor), '') is not null
          group by lower(btrim(c.vendedor))
        ) x
      ), '[]'::jsonb),
      'estados', coalesce((
        select jsonb_agg(x.estado order by lower(x.estado))
        from (
          select min(btrim(c.estado)) as estado
          from public.contratos c
          where nullif(btrim(c.estado), '') is not null
          group by lower(btrim(c.estado))
        ) x
      ), '[]'::jsonb),
      'prioridades', coalesce((
        select jsonb_agg(x.prioridad order by lower(x.prioridad))
        from (
          select min(btrim(c.prioridad)) as prioridad
          from public.contratos c
          where nullif(btrim(c.prioridad), '') is not null
          group by lower(btrim(c.prioridad))
        ) x
      ), '[]'::jsonb)
    ),
    'kpis', jsonb_build_object(
      'contratos', (select count(*) from filtrados),
      'prendas', coalesce((select sum(total_prendas) from filtrados), 0),
      'presupuesto', coalesce((select sum(presupuesto) from filtrados), 0),
      'abono', coalesce((select sum(abono) from filtrados), 0),
      'saldo', coalesce((select sum(greatest(presupuesto - abono, 0)) from filtrados), 0),
      'atrasados', (select count(*) from filtrados where atrasado)
    ),
    'total', (select count(*) from filtrados),
    'pagina', v_pagina,
    'por_pagina', v_por_pagina,
    'filas', coalesce((select jsonb_agg(to_jsonb(e)
      order by e.atrasado desc, e.fecha_entrega, e.prioridad desc, e.numero)
      from enriquecidos e), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$v111$;

-- El expediente v97 exige produccion.acceder. El panel comercial necesita
-- abrir el mismo brief con contratos.acceder, sin exponer gestion ni enlaces.
create or replace function public.obtener_brief_vendedor_v111(p_contrato_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $v111$
declare
  v_resultado jsonb;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesion para consultar contratos';
  end if;
  if not public.usuario_tiene_permiso_v35('contratos.acceder') then
    raise exception 'No tienes permiso para consultar contratos';
  end if;

  select jsonb_build_object(
    'contrato', to_jsonb(c),
    'prendas', coalesce((select jsonb_agg(to_jsonb(x) order by x.prenda, x.calidad, x.genero, x.talla)
      from public.contrato_prendas x where x.contrato_id = c.id), '[]'::jsonb),
    'jugadores', coalesce((select jsonb_agg(to_jsonb(x) order by x.orden, x.id)
      from public.contrato_jugadores x where x.contrato_id = c.id), '[]'::jsonb),
    'archivos', coalesce((select jsonb_agg(to_jsonb(x) order by x.tipo, x.orden, x.id)
      from public.contrato_archivos x where x.contrato_id = c.id), '[]'::jsonb),
    'especificaciones', coalesce((select jsonb_agg(to_jsonb(x) order by x.orden, x.id)
      from public.contrato_specs x where x.contrato_id = c.id), '[]'::jsonb),
    'facturacion', coalesce((select jsonb_agg(to_jsonb(x) order by x.orden, x.id)
      from public.contrato_facturacion x where x.contrato_id = c.id), '[]'::jsonb),
    'etapas', '[]'::jsonb,
    'eventos', '[]'::jsonb,
    'enlaces', '[]'::jsonb
  ) into v_resultado
  from public.contratos c
  where c.id = p_contrato_id;

  if v_resultado is null then
    raise exception 'El contrato no existe';
  end if;
  return v_resultado;
end;
$v111$;

alter function public.panel_vendedores_v111(
  text[],date,date,text[],text[],text,integer,integer
) owner to postgres;
alter function public.obtener_brief_vendedor_v111(uuid) owner to postgres;
revoke all on function public.panel_vendedores_v111(
  text[],date,date,text[],text[],text,integer,integer
) from public, anon;
revoke all on function public.obtener_brief_vendedor_v111(uuid) from public, anon;
grant execute on function public.panel_vendedores_v111(
  text[],date,date,text[],text[],text,integer,integer
) to authenticated;
grant execute on function public.obtener_brief_vendedor_v111(uuid) to authenticated;

comment on function public.panel_vendedores_v111(
  text[],date,date,text[],text[],text,integer,integer
) is 'Panel comercial paginado de contratos con seleccion multiple de vendedores, alertas y resumen financiero.';
comment on function public.obtener_brief_vendedor_v111(uuid)
  is 'Brief de solo lectura para usuarios comerciales con contratos.acceder.';

commit;
