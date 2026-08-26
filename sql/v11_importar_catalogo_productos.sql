-- ============================================================
-- BOMAN INVENTARIO - Actualizacion v11
-- Importacion atomica y auditada del catalogo maestro.
-- Ejecutar DESPUES de v10.
-- ============================================================

create table if not exists public.catalogo_importaciones (
  id uuid primary key default gen_random_uuid(),
  realizado_por uuid not null references public.perfiles(id),
  nota text,
  total_filas integer not null,
  creados integer not null,
  actualizados integer not null,
  sin_cambio integer not null,
  detalle jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_catalogo_importaciones_fecha
  on public.catalogo_importaciones(created_at desc);

alter table public.catalogo_importaciones enable row level security;

drop policy if exists "admin_gerencia_lee_catalogo_importaciones" on public.catalogo_importaciones;
create policy "admin_gerencia_lee_catalogo_importaciones"
on public.catalogo_importaciones for select to authenticated using (
  exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.activo and p.rol in ('admin', 'gerencia')
  )
);

create or replace function public.admin_importar_catalogo_productos(
  p_items jsonb,
  p_nota text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_total integer;
  v_creados integer := 0;
  v_actualizados integer := 0;
  v_sin_cambio integer := 0;
  v_categoria_id uuid;
  v_subcategoria_id uuid;
  v_subcategoria_final uuid;
  v_talla_final text;
  v_color_final text;
  v_producto public.productos%rowtype;
  it record;
begin
  if not exists (
    select 1 from public.perfiles
    where id = v_uid and activo and rol = 'admin'
  ) then
    raise exception 'Solo un administrador activo puede importar el catalogo';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El archivo no contiene productos validos';
  end if;
  if jsonb_array_length(p_items) > 5000 then
    raise exception 'La importacion admite un maximo de 5000 filas';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) x
    where btrim(coalesce(x->>'sku', '')) = ''
       or btrim(coalesce(x->>'nombre', '')) = ''
       or btrim(coalesce(x->>'categoria', '')) = ''
  ) then
    raise exception 'Todas las filas deben tener SKU, nombre y categoria';
  end if;

  create temp table pg_temp._catalogo_import (
    sku text primary key,
    nombre text not null,
    categoria text not null,
    subcategoria text,
    talla text,
    color text,
    stock_minimo integer,
    precio numeric(12,2),
    actualizar_subcategoria boolean not null,
    actualizar_talla boolean not null,
    actualizar_color boolean not null
  ) on commit drop;

  insert into pg_temp._catalogo_import
    (sku, nombre, categoria, subcategoria, talla, color, stock_minimo, precio,
     actualizar_subcategoria, actualizar_talla, actualizar_color)
  select distinct on (sku_normalizado)
    sku_normalizado,
    btrim(x->>'nombre'),
    btrim(x->>'categoria'),
    nullif(btrim(x->>'subcategoria'), ''),
    nullif(btrim(x->>'talla'), ''),
    nullif(btrim(x->>'color'), ''),
    case
      when nullif(btrim(x->>'stock_minimo'), '') is null then null
      else (x->>'stock_minimo')::numeric::integer
    end,
    case
      when nullif(btrim(x->>'precio'), '') is null then null
      else (x->>'precio')::numeric(12,2)
    end,
    coalesce((x->>'actualizar_subcategoria')::boolean, true),
    coalesce((x->>'actualizar_talla')::boolean, true),
    coalesce((x->>'actualizar_color')::boolean, true)
  from (
    select valor as x, orden,
           upper(btrim(valor->>'sku')) as sku_normalizado
    from jsonb_array_elements(p_items) with ordinality as entrada(valor, orden)
  ) normalizados
  order by sku_normalizado, orden desc;

  if exists (
    select 1 from pg_temp._catalogo_import
    where coalesce(stock_minimo, 0) < 0 or coalesce(precio, 0) < 0
  ) then
    raise exception 'El precio y el stock minimo no pueden ser negativos';
  end if;

  select count(*) into v_total from pg_temp._catalogo_import;

  insert into public.categorias_productos (nombre)
  select min(categoria)
  from pg_temp._catalogo_import
  group by lower(btrim(categoria))
  on conflict do nothing;

  insert into public.subcategorias_productos (categoria_id, nombre)
  select c.id, min(i.subcategoria)
  from pg_temp._catalogo_import i
  join public.categorias_productos c
    on lower(btrim(c.nombre)) = lower(btrim(i.categoria))
  where i.subcategoria is not null
  group by c.id, lower(btrim(i.subcategoria))
  on conflict do nothing;

  for it in
    select * from pg_temp._catalogo_import order by sku
  loop
    select id into v_categoria_id
    from public.categorias_productos
    where lower(btrim(nombre)) = lower(btrim(it.categoria)) and activo;

    if v_categoria_id is null then
      raise exception 'La categoria "%" esta inactiva', it.categoria;
    end if;

    v_subcategoria_id := null;
    if it.subcategoria is not null then
      select id into v_subcategoria_id
      from public.subcategorias_productos
      where categoria_id = v_categoria_id
        and lower(btrim(nombre)) = lower(btrim(it.subcategoria))
        and activo;

      if v_subcategoria_id is null then
        raise exception 'La subcategoria "%" esta inactiva o no pertenece a "%"', it.subcategoria, it.categoria;
      end if;
    end if;

    select * into v_producto
    from public.productos
    where upper(btrim(sku)) = it.sku
    limit 1
    for update;

    if not found then
      insert into public.productos (
        sku, nombre, categoria, categoria_id, subcategoria, subcategoria_id,
        talla, color, stock_minimo, precio
      ) values (
        it.sku, it.nombre, it.categoria, v_categoria_id, it.subcategoria, v_subcategoria_id,
        it.talla, it.color, coalesce(it.stock_minimo, 0), it.precio
      );
      v_creados := v_creados + 1;
    else
      v_subcategoria_final := case
        when it.actualizar_subcategoria then v_subcategoria_id
        when v_producto.categoria_id = v_categoria_id then v_producto.subcategoria_id
        else null
      end;
      v_talla_final := case when it.actualizar_talla then it.talla else v_producto.talla end;
      v_color_final := case when it.actualizar_color then it.color else v_producto.color end;

      if row(
      v_producto.nombre, v_producto.categoria_id, v_producto.subcategoria_id,
      v_producto.talla, v_producto.color, v_producto.stock_minimo, v_producto.precio
      ) is distinct from row(
        it.nombre, v_categoria_id, v_subcategoria_final,
        v_talla_final, v_color_final, coalesce(it.stock_minimo, v_producto.stock_minimo),
        coalesce(it.precio, v_producto.precio)
      ) then
        update public.productos
        set nombre = it.nombre,
            categoria_id = v_categoria_id,
            subcategoria_id = v_subcategoria_final,
            talla = v_talla_final,
            color = v_color_final,
            stock_minimo = coalesce(it.stock_minimo, stock_minimo),
            precio = coalesce(it.precio, precio)
        where id = v_producto.id;
        v_actualizados := v_actualizados + 1;
      else
        v_sin_cambio := v_sin_cambio + 1;
      end if;
    end if;
  end loop;

  insert into public.catalogo_importaciones (
    realizado_por, nota, total_filas, creados, actualizados, sin_cambio, detalle
  ) values (
    v_uid, nullif(btrim(p_nota), ''), v_total,
    v_creados, v_actualizados, v_sin_cambio, p_items
  );

  return jsonb_build_object(
    'total', v_total,
    'creados', v_creados,
    'actualizados', v_actualizados,
    'sin_cambio', v_sin_cambio
  );
end;
$$;

alter function public.admin_importar_catalogo_productos(jsonb, text)
  owner to postgres;

revoke all on public.catalogo_importaciones from public, anon;
revoke insert, update, delete on public.catalogo_importaciones from authenticated;
grant select on public.catalogo_importaciones to authenticated;

revoke all on function public.admin_importar_catalogo_productos(jsonb, text)
  from public, anon;
grant execute on function public.admin_importar_catalogo_productos(jsonb, text)
  to authenticated;
