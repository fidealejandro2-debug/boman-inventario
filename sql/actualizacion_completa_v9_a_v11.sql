-- ============================================================
-- BOMAN INVENTARIO - PAQUETE CONSOLIDADO PENDIENTE
-- Incluye v9 + v10 + v11 en el orden correcto.
-- Ejecutar UNA SOLA VEZ despues de v8.
-- Generado para despliegue simplificado.
-- ============================================================

-- ============================================================
-- BOMAN INVENTARIO - Actualizacion v9
-- Reparacion de permisos para activar/desactivar productos.
-- Ejecutar DESPUES de v8.
-- ============================================================

-- La funcion debe ejecutarse con los permisos de su propietario. Esto permite
-- mantener bloqueado el UPDATE directo de productos.activo y conservar siempre
-- la validacion de stock y el registro de auditoria.
create or replace function public.admin_cambiar_estado_producto(
  p_producto_id uuid,
  p_activo boolean,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_activo_anterior boolean;
  v_stock_total bigint;
begin
  if not exists (
    select 1
    from public.perfiles
    where id = v_uid and activo and rol = 'admin'
  ) then
    raise exception 'Solo un administrador activo puede cambiar el estado de un producto';
  end if;

  if p_producto_id is null or p_activo is null then
    raise exception 'Los datos del producto estan incompletos';
  end if;
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Debes indicar el motivo del cambio';
  end if;

  select activo
  into v_activo_anterior
  from public.productos
  where id = p_producto_id
  for update;

  if not found then
    raise exception 'El producto no existe';
  end if;
  if v_activo_anterior = p_activo then
    return;
  end if;

  if not p_activo then
    select coalesce(sum(cantidad), 0)
    into v_stock_total
    from public.inventario
    where producto_id = p_producto_id;

    if v_stock_total <> 0 then
      raise exception 'No se puede desactivar: el producto todavia tiene % unidad(es) en inventario. Deja el stock en cero mediante movimientos o ajustes.', v_stock_total;
    end if;
  end if;

  update public.productos
  set activo = p_activo
  where id = p_producto_id;

  insert into public.productos_cambios (
    producto_id,
    realizado_por,
    activo_anterior,
    activo_nuevo,
    motivo
  ) values (
    p_producto_id,
    v_uid,
    v_activo_anterior,
    p_activo,
    btrim(p_motivo)
  );
end;
$$;

-- En Supabase, postgres es propietario de las tablas del esquema public. Al
-- convertirlo tambien en propietario de esta funcion, SECURITY DEFINER puede
-- actualizar productos sin devolver "permission denied for table productos".
alter function public.admin_cambiar_estado_producto(uuid, boolean, text)
  owner to postgres;

revoke all on function public.admin_cambiar_estado_producto(uuid, boolean, text)
  from public, anon;
grant execute on function public.admin_cambiar_estado_producto(uuid, boolean, text)
  to authenticated;

-- ============================================================
-- SIGUIENTE ACTUALIZACION DEL PAQUETE
-- ============================================================

-- ============================================================
-- BOMAN INVENTARIO - Actualizacion v10
-- Catalogo administrable de categorias y subcategorias.
-- Ejecutar DESPUES de v9.
-- ============================================================

create table if not exists public.categorias_productos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (btrim(nombre) <> ''),
  descripcion text,
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists categorias_productos_nombre_unico
  on public.categorias_productos (lower(btrim(nombre)));

create table if not exists public.subcategorias_productos (
  id uuid primary key default gen_random_uuid(),
  categoria_id uuid not null references public.categorias_productos(id),
  nombre text not null check (btrim(nombre) <> ''),
  descripcion text,
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists subcategorias_productos_nombre_unico
  on public.subcategorias_productos (categoria_id, lower(btrim(nombre)));
create index if not exists idx_subcategorias_productos_categoria
  on public.subcategorias_productos (categoria_id);

alter table public.productos
  add column if not exists categoria_id uuid references public.categorias_productos(id),
  add column if not exists subcategoria_id uuid references public.subcategorias_productos(id),
  add column if not exists subcategoria text;

create index if not exists idx_productos_categoria_id
  on public.productos (categoria_id);
create index if not exists idx_productos_subcategoria_id
  on public.productos (subcategoria_id);

-- Convierte las categorias de texto que ya existen en el inventario al catalogo
-- nuevo, sin modificar el nombre visible usado por reportes y movimientos.
insert into public.categorias_productos (nombre)
select min(btrim(p.categoria))
from public.productos p
where btrim(coalesce(p.categoria, '')) <> ''
group by lower(btrim(p.categoria))
on conflict do nothing;

insert into public.categorias_productos (nombre)
select 'Sin categoría'
where exists (
  select 1 from public.productos
  where btrim(coalesce(categoria, '')) = ''
)
on conflict do nothing;

update public.productos p
set categoria_id = c.id
from public.categorias_productos c
where p.categoria_id is null
  and lower(btrim(p.categoria)) = lower(btrim(c.nombre));

update public.productos p
set categoria = c.nombre,
    categoria_id = c.id
from public.categorias_productos c
where p.categoria_id is null
  and btrim(coalesce(p.categoria, '')) = ''
  and lower(c.nombre) = lower('Sin categoría');

alter table public.productos
  alter column categoria_id set not null;

-- La vista conserva sus columnas anteriores y agrega al final los campos del
-- catalogo jerarquico, para no romper consumidores que ya usan vista_stock.
create or replace view public.vista_stock
with (security_invoker = true) as
select
  i.id,
  i.cantidad,
  i.updated_at,
  p.id as producto_id,
  p.sku,
  p.nombre as producto,
  p.categoria,
  p.talla,
  p.color,
  p.stock_minimo,
  p.precio,
  a.id as almacen_id,
  a.nombre as almacen,
  a.tipo as almacen_tipo,
  (i.cantidad <= p.stock_minimo) as bajo_minimo,
  p.categoria_id,
  p.subcategoria_id,
  p.subcategoria
from public.inventario i
join public.productos p on p.id = i.producto_id
join public.almacenes a on a.id = i.entidad_id
where p.activo and a.activo;

-- Mantiene sincronizados los IDs normalizados con las columnas de texto legadas.
-- Las columnas de texto se conservan porque actualmente alimentan vista_stock,
-- movimientos, busquedas, exportaciones y reportes existentes.
create or replace function public.sincronizar_categoria_producto()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_categoria_id uuid;
  v_categoria text;
  v_subcategoria text;
  v_categoria_sub uuid;
begin
  if new.categoria_id is not null then
    select nombre into v_categoria
    from public.categorias_productos
    where id = new.categoria_id;

    if not found then
      raise exception 'La categoria seleccionada no existe';
    end if;
    new.categoria := v_categoria;
  elsif btrim(coalesce(new.categoria, '')) <> '' then
    select id, nombre into v_categoria_id, v_categoria
    from public.categorias_productos
    where lower(btrim(nombre)) = lower(btrim(new.categoria))
    limit 1;
    if found then
      new.categoria_id := v_categoria_id;
      new.categoria := v_categoria;
    end if;
  else
    raise exception 'La categoria es obligatoria';
  end if;

  if new.subcategoria_id is not null then
    select categoria_id, nombre into v_categoria_sub, v_subcategoria
    from public.subcategorias_productos
    where id = new.subcategoria_id;

    if not found then
      raise exception 'La subcategoria seleccionada no existe';
    end if;
    if new.categoria_id is null or v_categoria_sub <> new.categoria_id then
      raise exception 'La subcategoria no pertenece a la categoria seleccionada';
    end if;
    new.subcategoria := v_subcategoria;
  else
    new.subcategoria := null;
  end if;

  return new;
end;
$$;

alter function public.sincronizar_categoria_producto() owner to postgres;

drop trigger if exists trg_sincronizar_categoria_producto on public.productos;
create trigger trg_sincronizar_categoria_producto
before insert or update of categoria, categoria_id, subcategoria, subcategoria_id
on public.productos
for each row execute function public.sincronizar_categoria_producto();

alter table public.categorias_productos enable row level security;
alter table public.subcategorias_productos enable row level security;

drop policy if exists "leer_categorias_productos" on public.categorias_productos;
create policy "leer_categorias_productos"
on public.categorias_productos for select to authenticated using (
  public.usuario_actual_activo()
);

drop policy if exists "admin_crea_categorias_productos" on public.categorias_productos;
create policy "admin_crea_categorias_productos"
on public.categorias_productos for insert to authenticated with check (
  exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.activo and p.rol = 'admin'
  )
);

drop policy if exists "admin_edita_categorias_productos" on public.categorias_productos;
create policy "admin_edita_categorias_productos"
on public.categorias_productos for update to authenticated
using (
  exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.activo and p.rol = 'admin'
  )
)
with check (
  exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.activo and p.rol = 'admin'
  )
);

drop policy if exists "leer_subcategorias_productos" on public.subcategorias_productos;
create policy "leer_subcategorias_productos"
on public.subcategorias_productos for select to authenticated using (
  public.usuario_actual_activo()
);

drop policy if exists "admin_crea_subcategorias_productos" on public.subcategorias_productos;
create policy "admin_crea_subcategorias_productos"
on public.subcategorias_productos for insert to authenticated with check (
  exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.activo and p.rol = 'admin'
  )
);

drop policy if exists "admin_edita_subcategorias_productos" on public.subcategorias_productos;
create policy "admin_edita_subcategorias_productos"
on public.subcategorias_productos for update to authenticated
using (
  exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.activo and p.rol = 'admin'
  )
)
with check (
  exists (
    select 1 from public.perfiles p
    where p.id = auth.uid() and p.activo and p.rol = 'admin'
  )
);

revoke all on public.categorias_productos from public, anon;
revoke all on public.subcategorias_productos from public, anon;
revoke delete on public.categorias_productos from authenticated;
revoke delete on public.subcategorias_productos from authenticated;
grant select, insert, update on public.categorias_productos to authenticated;
grant select, insert, update on public.subcategorias_productos to authenticated;

-- v8 permite editar solo una lista explicita de columnas. Se agregan las nuevas
-- sin volver a habilitar la columna activo, que sigue protegida por su RPC auditada.
grant update (categoria, categoria_id, subcategoria, subcategoria_id)
  on public.productos to authenticated;

revoke execute on function public.sincronizar_categoria_producto()
  from public, anon, authenticated;

-- ============================================================
-- SIGUIENTE ACTUALIZACION DEL PAQUETE
-- ============================================================

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

