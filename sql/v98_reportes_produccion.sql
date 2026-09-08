-- ============================================================
-- BOMAN INVENTARIO - v98: reportes de produccion
--
-- Un solo RPC parametrizable (p_agrupar_por) en vez de 4 funciones separadas,
-- mismo criterio de agregacion que v96/v95. Cada agrupacion filtra los
-- contratos del rango por fecha_entrega (el reporte de negocio de "que se
-- entrego/entrega en el rango"), salvo 'dia' que usa fecha_inicio_produccion
-- (el reporte operativo de "que se corta cada dia" -mismo campo que v96).
--
-- Ejecutar despues de v94 y v35.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null or to_regclass('public.contrato_prendas') is null then
    raise exception 'Falta instalar v79 antes de v98';
  end if;
  if to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta instalar v35 antes de v98';
  end if;
end;
$requisitos$;

create or replace function public.reporte_produccion_v98(
  p_desde date,
  p_hasta date,
  p_agrupar_por text default 'dia'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_resultado jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar reportes de produccion';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El rango de fechas no es valido';
  end if;
  if p_hasta - p_desde > 366 then
    raise exception 'El rango no puede superar 366 dias';
  end if;
  if p_agrupar_por not in ('dia', 'prenda', 'disenador', 'contrato') then
    raise exception 'La agrupacion no es valida';
  end if;

  if p_agrupar_por = 'dia' then
    with filtrados as materialized (
      select c.id, c.fecha_inicio_produccion as clave
      from public.contratos c
      where c.fecha_inicio_produccion between p_desde and p_hasta
        and lower(c.estado) <> 'entregado'
    ),
    filas as (
      select f.clave::text as etiqueta, count(distinct f.id)::bigint as contratos,
        coalesce(sum(cp.cantidad), 0)::bigint as prendas
      from filtrados f
      left join public.contrato_prendas cp on cp.contrato_id = f.id
        and lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
      group by f.clave
    )
    select jsonb_build_object(
      'agrupado_por', 'dia', 'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
      'total_contratos', (select count(*) from filtrados),
      'total_prendas', coalesce((select sum(prendas) from filas), 0),
      'filas', coalesce((select jsonb_agg(to_jsonb(filas) order by etiqueta) from filas), '[]'::jsonb)
    ) into v_resultado;

  elsif p_agrupar_por = 'prenda' then
    with filtrados as materialized (
      select c.id from public.contratos c
      where c.fecha_entrega between p_desde and p_hasta
        and lower(c.estado) <> 'entregado'
    ),
    filas as (
      select cp.prenda as etiqueta, count(distinct cp.contrato_id)::bigint as contratos,
        sum(cp.cantidad)::bigint as prendas
      from public.contrato_prendas cp
      join filtrados f on f.id = cp.contrato_id
      where lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
      group by cp.prenda
    )
    select jsonb_build_object(
      'agrupado_por', 'prenda', 'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
      'total_contratos', (select count(*) from filtrados),
      'total_prendas', coalesce((select sum(prendas) from filas), 0),
      'filas', coalesce((select jsonb_agg(to_jsonb(filas) order by prendas desc, etiqueta) from filas), '[]'::jsonb)
    ) into v_resultado;

  elsif p_agrupar_por = 'disenador' then
    with filtrados as materialized (
      select c.id, coalesce(nullif(btrim(c.disenador), ''), 'Sin asignar') as clave
      from public.contratos c
      where c.fecha_entrega between p_desde and p_hasta
        and lower(c.estado) <> 'entregado'
    ),
    filas as (
      select f.clave as etiqueta, count(distinct f.id)::bigint as contratos,
        coalesce(sum(cp.cantidad), 0)::bigint as prendas
      from filtrados f
      left join public.contrato_prendas cp on cp.contrato_id = f.id
        and lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
      group by f.clave
    )
    select jsonb_build_object(
      'agrupado_por', 'disenador', 'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
      'total_contratos', (select count(*) from filtrados),
      'total_prendas', coalesce((select sum(prendas) from filas), 0),
      'filas', coalesce((select jsonb_agg(to_jsonb(filas) order by contratos desc, etiqueta) from filas), '[]'::jsonb)
    ) into v_resultado;

  else -- 'contrato'
    with filtrados as materialized (
      select c.* from public.contratos c
      where c.fecha_entrega between p_desde and p_hasta
        and lower(c.estado) <> 'entregado'
    ),
    filas as (
      select f.numero as etiqueta, f.cliente, f.vendedor, f.disenador, f.estado,
        f.fecha_inicio_produccion, f.fecha_entrega, f.total_prendas,
        coalesce((
          select jsonb_object_agg(x.prenda, x.cantidad order by x.prenda)
          from (select cp.prenda, sum(cp.cantidad)::bigint cantidad
                from public.contrato_prendas cp where cp.contrato_id = f.id group by cp.prenda) x
        ), '{}'::jsonb) as prendas
      from filtrados f
    )
    select jsonb_build_object(
      'agrupado_por', 'contrato', 'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
      'total_contratos', (select count(*) from filtrados),
      'total_prendas', coalesce((select sum(total_prendas) from filtrados), 0),
      'filas', coalesce((select jsonb_agg(to_jsonb(filas) order by fecha_entrega, etiqueta) from filas), '[]'::jsonb)
    ) into v_resultado;
  end if;

  return v_resultado;
end;
$fn$;

alter function public.reporte_produccion_v98(date, date, text) owner to postgres;
revoke all on function public.reporte_produccion_v98(date, date, text) from public, anon;
grant execute on function public.reporte_produccion_v98(date, date, text) to authenticated;

comment on function public.reporte_produccion_v98(date, date, text) is
  'Reporte de produccion agrupado por dia/prenda/disenador/contrato. dia usa fecha_inicio_produccion (operativo); el resto usa fecha_entrega (negocio). Requiere produccion.acceder.';

commit;

notify pgrst, 'reload schema';
