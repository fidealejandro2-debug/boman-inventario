-- ============================================================
-- BOMAN INVENTARIO - v96: cronograma y capacidad diaria de produccion
--
-- La carga de cada contrato se atribuye a su fecha_inicio_produccion (el dia
-- en que el taller empieza a cortar), mismo criterio que ya usa el
-- "cronograma" del dashboard v95 (resumen_dashboard_produccion_v95, agrupado
-- por fecha_inicio_produccion). v96 lo abre por PRENDA en vez de por tipo de
-- contrato, y agrega el detalle de un dia y los mockups pendientes del rango.
--
-- Ejecutar despues de v94 (necesita contrato_prendas poblada) y v35.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null or to_regclass('public.contrato_prendas') is null then
    raise exception 'Falta instalar v79 antes de v96';
  end if;
  if to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta instalar v35 antes de v96';
  end if;
end;
$requisitos$;

-- ------------------------------------------------------------
-- 1. Capacidad diaria por prenda (editable por admin). Una prenda sin fila
-- aqui usa CAPACIDAD_DEFECTO_V96 (ver la funcion de cronograma): asi no hace
-- falta precargar cada nombre de prenda que existe en BomanSport para que la
-- vista funcione desde el primer dia.
-- ------------------------------------------------------------
create table if not exists public.capacidad_produccion_diaria_v96 (
  prenda text primary key check (btrim(prenda) <> ''),
  capacidad_dia integer not null check (capacidad_dia > 0),
  actualizado_por uuid references public.perfiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.capacidad_produccion_diaria_v96 enable row level security;
drop policy if exists "leer_capacidad_produccion_v96" on public.capacidad_produccion_diaria_v96;
create policy "leer_capacidad_produccion_v96" on public.capacidad_produccion_diaria_v96
for select to authenticated using (public.usuario_tiene_permiso_v35('produccion.acceder'));
revoke all on public.capacidad_produccion_diaria_v96 from public, anon;
revoke insert, update, delete on public.capacidad_produccion_diaria_v96 from authenticated;
grant select on public.capacidad_produccion_diaria_v96 to authenticated;
alter table public.capacidad_produccion_diaria_v96 owner to postgres;

-- ------------------------------------------------------------
-- 2. Guardar capacidad (solo admin: es un ajuste operativo global, no un
-- permiso de modulo con matices por rol).
-- ------------------------------------------------------------
create or replace function public.guardar_capacidad_produccion_v96(p_prenda text, p_capacidad_dia integer)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
begin
  if auth.uid() is null or public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo un administrador puede ajustar la capacidad de produccion';
  end if;
  if nullif(btrim(p_prenda), '') is null then raise exception 'Indica la prenda'; end if;
  if coalesce(p_capacidad_dia, 0) <= 0 then raise exception 'La capacidad debe ser mayor a cero'; end if;
  insert into public.capacidad_produccion_diaria_v96(prenda, capacidad_dia, actualizado_por, updated_at)
  values (btrim(p_prenda), p_capacidad_dia, auth.uid(), now())
  on conflict (prenda) do update set
    capacidad_dia = excluded.capacidad_dia, actualizado_por = excluded.actualizado_por, updated_at = now();
end;
$fn$;

-- ------------------------------------------------------------
-- 3. Cronograma del rango: carga diaria por prenda vs. capacidad.
-- ------------------------------------------------------------
create or replace function public.cronograma_produccion_v96(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_capacidad_defecto constant integer := 100;
  v_resultado jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar el cronograma de produccion';
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then
    raise exception 'El rango de fechas no es valido';
  end if;
  if p_hasta - p_desde > 92 then
    raise exception 'El rango no puede superar 92 dias';
  end if;

  with rango as materialized (
    select c.id, c.fecha_inicio_produccion as dia
    from public.contratos c
    where c.fecha_inicio_produccion between p_desde and p_hasta
      and lower(c.estado) <> 'entregado'
  ),
  carga_prenda as (
    select r.dia, cp.prenda, sum(cp.cantidad)::bigint cantidad
    from rango r
    join public.contrato_prendas cp on cp.contrato_id = r.id
    where lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
    group by r.dia, cp.prenda
  ),
  carga_prenda_capacidad as (
    select cpr.dia, cpr.prenda, cpr.cantidad,
      coalesce(cap.capacidad_dia, v_capacidad_defecto) as capacidad
    from carga_prenda cpr
    left join public.capacidad_produccion_diaria_v96 cap on cap.prenda = cpr.prenda
  ),
  dias as (
    select r.dia,
      count(distinct r.id)::bigint as contratos,
      coalesce(sum(cpc.cantidad), 0)::bigint as total_prendas,
      bool_or(cpc.cantidad > cpc.capacidad) as excede_algun_prenda
    from rango r
    left join carga_prenda_capacidad cpc on cpc.dia = r.dia
    group by r.dia
  )
  select jsonb_build_object(
    'generado_at', now(),
    'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'capacidad_defecto', v_capacidad_defecto,
    'dias', coalesce((
      select jsonb_agg(jsonb_build_object(
        'fecha', d.dia, 'contratos', d.contratos, 'total_prendas', d.total_prendas,
        'excede', coalesce(d.excede_algun_prenda, false),
        'prendas', coalesce((
          select jsonb_agg(jsonb_build_object(
            'prenda', cpc.prenda, 'cantidad', cpc.cantidad, 'capacidad', cpc.capacidad,
            'excede', cpc.cantidad > cpc.capacidad
          ) order by cpc.cantidad desc, cpc.prenda)
          from carga_prenda_capacidad cpc where cpc.dia = d.dia
        ), '[]'::jsonb)
      ) order by d.dia)
      from dias d
    ), '[]'::jsonb),
    'capacidades', coalesce((
      select jsonb_agg(jsonb_build_object('prenda', prenda, 'capacidad_dia', capacidad_dia) order by prenda)
      from public.capacidad_produccion_diaria_v96
    ), '[]'::jsonb),
    'mockups_pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', c.numero, 'cliente', c.cliente, 'fecha_entrega', c.fecha_entrega,
        'descripcion', ca.descripcion, 'url', ca.url
      ) order by c.fecha_entrega, c.numero)
      from public.contratos c
      join public.contrato_archivos ca on ca.contrato_id = c.id and ca.tipo = 'mockup'
      where not c.aprobo_mockup
        and c.fecha_entrega between p_desde and p_hasta
        and lower(c.estado) <> 'entregado'
      limit 50
    ), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$fn$;

-- ------------------------------------------------------------
-- 4. Detalle de un dia (para el click en la linea de tiempo).
-- ------------------------------------------------------------
create or replace function public.detalle_dia_produccion_v96(p_dia date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare v_resultado jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar el cronograma de produccion';
  end if;
  if p_dia is null then raise exception 'Indica el dia'; end if;

  select jsonb_build_object(
    'fecha', p_dia,
    'contratos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', c.numero, 'cliente', c.cliente, 'vendedor', c.vendedor,
        'disenador', c.disenador, 'estado', c.estado, 'total_prendas', c.total_prendas,
        'fecha_entrega', c.fecha_entrega,
        'prendas', coalesce((
          select jsonb_object_agg(x.prenda, x.cantidad order by x.prenda)
          from (
            select cp.prenda, sum(cp.cantidad)::bigint cantidad
            from public.contrato_prendas cp where cp.contrato_id = c.id
            group by cp.prenda
          ) x
        ), '{}'::jsonb)
      ) order by c.numero)
      from public.contratos c where c.fecha_inicio_produccion = p_dia
    ), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$fn$;

alter function public.guardar_capacidad_produccion_v96(text, integer) owner to postgres;
alter function public.cronograma_produccion_v96(date, date) owner to postgres;
alter function public.detalle_dia_produccion_v96(date) owner to postgres;

revoke all on function public.guardar_capacidad_produccion_v96(text, integer) from public, anon;
revoke all on function public.cronograma_produccion_v96(date, date) from public, anon;
revoke all on function public.detalle_dia_produccion_v96(date) from public, anon;
grant execute on function public.guardar_capacidad_produccion_v96(text, integer) to authenticated;
grant execute on function public.cronograma_produccion_v96(date, date) to authenticated;
grant execute on function public.detalle_dia_produccion_v96(date) to authenticated;

comment on function public.cronograma_produccion_v96(date, date) is
  'Linea de tiempo de produccion: carga diaria por prenda vs. capacidad, contratos por dia y mockups pendientes del rango. Requiere produccion.acceder.';

commit;

notify pgrst, 'reload schema';
