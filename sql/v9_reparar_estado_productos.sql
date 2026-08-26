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

