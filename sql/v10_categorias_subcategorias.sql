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
