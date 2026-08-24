-- ============================================================
-- BOMAN INVENTARIO — Actualización v2
-- 1) Arregla el bug de RLS (stock invisible)
-- 2) Agrega stock mínimo, ubicación y precio
-- 3) Índices para búsqueda rápida
-- Correr completo en Supabase → SQL Editor
-- ============================================================

-- ------------------------------------------------------------
-- 1. ARREGLO DEL BUG: políticas de lectura
-- ------------------------------------------------------------
-- Antes: bodega/logística con entidad_id NULL no veía NADA.
-- Ahora: si entidad_id es NULL, ve todos los almacenes.

drop policy if exists "leer_inventario" on inventario;
create policy "leer_inventario" on inventario for select to authenticated using (
  exists (
    select 1 from perfiles p
    where p.id = auth.uid()
      and p.activo
      and (
        p.rol in ('admin', 'gerencia')
        or p.entidad_id is null
        or p.entidad_id = inventario.entidad_id
      )
  )
);

drop policy if exists "leer_movimientos" on movimientos;
create policy "leer_movimientos" on movimientos for select to authenticated using (
  exists (
    select 1 from perfiles p
    where p.id = auth.uid()
      and p.activo
      and (
        p.rol in ('admin', 'gerencia')
        or p.entidad_id is null
        or p.entidad_id = movimientos.entidad_id
        or p.entidad_id = movimientos.entidad_destino_id
      )
  )
);

-- Permitir que admin actualice productos y los desactive
drop policy if exists "admin_actualiza_productos" on productos;
create policy "admin_actualiza_productos" on productos for update to authenticated
  using (exists (select 1 from perfiles where id = auth.uid() and rol = 'admin'));

-- ------------------------------------------------------------
-- 2. CAMPOS NUEVOS
-- ------------------------------------------------------------
alter table productos add column if not exists color text;
alter table productos add column if not exists stock_minimo integer not null default 0;
alter table productos add column if not exists precio numeric(12,2);
alter table productos add column if not exists club text;

-- ------------------------------------------------------------
-- 3. ÍNDICES (búsqueda rápida sobre 545+ productos)
-- ------------------------------------------------------------
create index if not exists idx_productos_categoria on productos(categoria);
create index if not exists idx_productos_nombre on productos(lower(nombre));
create index if not exists idx_productos_sku on productos(lower(sku));
create index if not exists idx_inventario_entidad on inventario(entidad_id);
create index if not exists idx_movimientos_fecha on movimientos(created_at desc);
create index if not exists idx_movimientos_producto on movimientos(producto_id);

-- ------------------------------------------------------------
-- 4. VISTA DE STOCK CONSOLIDADO (para reportes rápidos)
-- ------------------------------------------------------------
create or replace view vista_stock as
select
  i.id,
  i.cantidad,
  i.updated_at,
  p.id  as producto_id,
  p.sku,
  p.nombre  as producto,
  p.categoria,
  p.talla,
  p.color,
  p.stock_minimo,
  p.precio,
  a.id  as almacen_id,
  a.nombre as almacen,
  a.tipo   as almacen_tipo,
  (i.cantidad <= p.stock_minimo) as bajo_minimo
from inventario i
join productos p on p.id = i.producto_id
join almacenes a on a.id = i.entidad_id
where p.activo and a.activo;

-- ------------------------------------------------------------
-- 5. RECORDATORIO: asigna tu rol de admin
-- ------------------------------------------------------------
-- Reemplaza el correo por el tuyo y descomenta la línea:
-- update perfiles set rol = 'admin', entidad_id = null
-- where id = (select id from auth.users where email = 'tu-correo@ejemplo.com');
