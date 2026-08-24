-- ============================================================
-- BOMAN SPORT — Inventario de Producto Terminado
-- Esquema para Supabase (Postgres + RLS)
-- Ejecutar completo en: Supabase Dashboard > SQL Editor
-- ============================================================

-- 1. ALMACENES (Bodega Central + tiendas)
create table if not exists almacenes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  codigo text not null unique, -- ej: 'BODEGA', 'TIENDA-PUYO'
  tipo text not null default 'tienda' check (tipo in ('bodega', 'tienda')),
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

insert into almacenes (nombre, codigo, tipo) values
  ('Bodega Central', 'BODEGA', 'bodega'),
  ('Shopping Ambato', 'TIENDA-SHOPPING-AMB', 'tienda'),
  ('Mariano Egüez Ambato', 'TIENDA-MEGUEZ-AMB', 'tienda'),
  ('Puyo', 'TIENDA-PUYO', 'tienda'),
  ('Riobamba', 'TIENDA-RIOBAMBA', 'tienda'),
  ('Guayaquil', 'TIENDA-GYE', 'tienda'),
  ('Santo Domingo', 'TIENDA-SD', 'tienda')
on conflict (codigo) do nothing;

-- 2. PERFILES DE USUARIO (extiende auth.users de Supabase)
create type rol_usuario as enum ('admin', 'bodega', 'logistica', 'gerencia');

create table if not exists perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre_completo text not null,
  rol rol_usuario not null default 'bodega',
  entidad_id uuid references almacenes(id), -- null = ve todas las entidades (admin/gerencia)
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

-- 3. PRODUCTOS (catálogo de prendas terminadas)
create table if not exists productos (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  nombre text not null,
  categoria text not null, -- camiseta, short, buzo, etc.
  talla text,
  color text,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

-- 4. INVENTARIO (stock actual por producto + entidad)
create table if not exists inventario (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id),
  entidad_id uuid not null references almacenes(id),
  cantidad integer not null default 0 check (cantidad >= 0),
  updated_at timestamptz not null default now(),
  unique (producto_id, entidad_id)
);

-- 5. MOVIMIENTOS (historial: entrada, salida, transferencia)
create type tipo_movimiento as enum ('entrada', 'salida', 'transferencia_envio', 'transferencia_recibo', 'ajuste');

create table if not exists movimientos (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id),
  entidad_id uuid not null references almacenes(id),
  entidad_destino_id uuid references almacenes(id), -- solo para transferencias
  tipo tipo_movimiento not null,
  cantidad integer not null check (cantidad > 0),
  nota text,
  usuario_id uuid not null references perfiles(id),
  created_at timestamptz not null default now()
);

-- ============================================================
-- FUNCIÓN: aplicar un movimiento y actualizar inventario atómicamente
-- ============================================================
create or replace function registrar_movimiento(
  p_producto_id uuid,
  p_entidad_id uuid,
  p_tipo tipo_movimiento,
  p_cantidad integer,
  p_nota text,
  p_usuario_id uuid,
  p_entidad_destino_id uuid default null
) returns void as $$
begin
  -- Insertar el registro de movimiento
  insert into movimientos (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota, usuario_id)
  values (p_producto_id, p_entidad_id, p_entidad_destino_id, p_tipo, p_cantidad, p_nota, p_usuario_id);

  -- Actualizar inventario según el tipo
  if p_tipo in ('entrada', 'transferencia_recibo') then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (p_producto_id, p_entidad_id, p_cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + p_cantidad, updated_at = now();

  elsif p_tipo in ('salida', 'transferencia_envio') then
    update inventario
    set cantidad = cantidad - p_cantidad, updated_at = now()
    where producto_id = p_producto_id and entidad_id = p_entidad_id;

    if not found or (select cantidad from inventario where producto_id = p_producto_id and entidad_id = p_entidad_id) < 0 then
      raise exception 'Stock insuficiente para este producto en esta entidad';
    end if;

    -- Si es transferencia, generar automáticamente el recibo en la entidad destino
    if p_tipo = 'transferencia_envio' and p_entidad_destino_id is not null then
      insert into inventario (producto_id, entidad_id, cantidad)
      values (p_producto_id, p_entidad_destino_id, p_cantidad)
      on conflict (producto_id, entidad_id)
      do update set cantidad = inventario.cantidad + p_cantidad, updated_at = now();

      insert into movimientos (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota, usuario_id)
      values (p_producto_id, p_entidad_destino_id, p_entidad_id, 'transferencia_recibo', p_cantidad,
              coalesce(p_nota, '') || ' (auto-generado por transferencia)', p_usuario_id);
    end if;

  elsif p_tipo = 'ajuste' then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (p_producto_id, p_entidad_id, p_cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = p_cantidad, updated_at = now();
  end if;
end;
$$ language plpgsql security definer;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table perfiles enable row level security;
alter table productos enable row level security;
alter table inventario enable row level security;
alter table movimientos enable row level security;
alter table almacenes enable row level security;

-- Todos los usuarios autenticados pueden leer almacenes y su propio perfil
create policy "leer_almacenes" on almacenes for select to authenticated using (true);
create policy "leer_propio_perfil" on perfiles for select to authenticated using (true);

-- Productos: todos leen, solo admin escribe
create policy "leer_productos" on productos for select to authenticated using (true);
create policy "admin_escribe_productos" on productos for insert to authenticated
  with check (exists (select 1 from perfiles where id = auth.uid() and rol = 'admin'));
create policy "admin_actualiza_productos" on productos for update to authenticated
  using (exists (select 1 from perfiles where id = auth.uid() and rol = 'admin'));

-- Inventario: admin/gerencia ven todo; bodega/logística solo su entidad
create policy "leer_inventario" on inventario for select to authenticated using (
  exists (
    select 1 from perfiles p
    where p.id = auth.uid()
    and (p.rol in ('admin', 'gerencia') or p.entidad_id = inventario.entidad_id)
  )
);

-- Movimientos: mismo criterio; inserción vía función registrar_movimiento (security definer)
create policy "leer_movimientos" on movimientos for select to authenticated using (
  exists (
    select 1 from perfiles p
    where p.id = auth.uid()
    and (p.rol in ('admin', 'gerencia') or p.entidad_id = movimientos.entidad_id)
  )
);
create policy "insertar_movimientos" on movimientos for insert to authenticated
  with check (
    exists (
      select 1 from perfiles p
      where p.id = auth.uid()
      and p.rol in ('admin', 'bodega', 'logistica')
    )
  );

-- ============================================================
-- Trigger: crear perfil automáticamente al registrar un usuario
-- (rol por defecto 'bodega'; el admin lo ajusta después desde la app o el dashboard de Supabase)
-- ============================================================
create or replace function crear_perfil_nuevo_usuario()
returns trigger as $$
begin
  insert into perfiles (id, nombre_completo, rol)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre_completo', new.email), 'bodega');
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function crear_perfil_nuevo_usuario();
