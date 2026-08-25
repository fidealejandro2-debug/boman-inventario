-- ============================================================
-- BOMAN INVENTARIO - Actualizacion v8
-- Activacion/desactivacion segura y auditada de productos.
-- Ejecutar DESPUES de v7. No modifica migraciones anteriores.
-- ============================================================

create table if not exists productos_cambios (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id),
  realizado_por uuid not null references perfiles(id),
  activo_anterior boolean not null,
  activo_nuevo boolean not null,
  motivo text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_productos_cambios_producto_fecha
  on productos_cambios(producto_id, created_at desc);

alter table productos_cambios enable row level security;

drop policy if exists "leer_productos_cambios" on productos_cambios;
create policy "leer_productos_cambios"
on productos_cambios for select to authenticated using (
  exists (
    select 1 from perfiles p
    where p.id = auth.uid() and p.activo and p.rol in ('admin', 'gerencia')
  )
);

create or replace function admin_cambiar_estado_producto(
  p_producto_id uuid,
  p_activo boolean,
  p_motivo text
) returns void as $$
declare
  v_uid uuid := auth.uid();
  v_activo_anterior boolean;
  v_stock_total bigint;
begin
  if not exists (
    select 1 from perfiles
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

  select activo into v_activo_anterior
  from productos
  where id = p_producto_id
  for update;

  if not found then
    raise exception 'El producto no existe';
  end if;
  if v_activo_anterior = p_activo then
    return;
  end if;

  if not p_activo then
    select coalesce(sum(cantidad), 0) into v_stock_total
    from inventario
    where producto_id = p_producto_id;

    if v_stock_total <> 0 then
      raise exception 'No se puede desactivar: el producto todavia tiene % unidad(es) en inventario. Deja el stock en cero mediante movimientos o ajustes.', v_stock_total;
    end if;
  end if;

  update productos
  set activo = p_activo
  where id = p_producto_id;

  insert into productos_cambios (
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
$$ language plpgsql security definer set search_path = public;

-- Los datos descriptivos siguen siendo editables por administradores mediante RLS,
-- pero el estado activo solo puede cambiarse usando la funcion auditada.
revoke update on productos from public, anon, authenticated;
grant update (nombre, categoria, talla, color, stock_minimo, precio, club)
  on productos to authenticated;

revoke insert, update, delete on productos_cambios from public, anon, authenticated;
grant select on productos_cambios to authenticated;

revoke execute on function admin_cambiar_estado_producto(uuid, boolean, text)
  from public, anon;
grant execute on function admin_cambiar_estado_producto(uuid, boolean, text)
  to authenticated;

