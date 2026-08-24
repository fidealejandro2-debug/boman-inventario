-- ============================================================
-- BOMAN INVENTARIO — Actualización v3
-- 1) Permite ANULAR movimientos revirtiendo el stock
-- 2) Vincula despacho + recepción para anularlos juntos
-- 3) Permite editar la nota de un movimiento
-- Correr completo en Supabase → SQL Editor (después de v2)
-- ============================================================

-- ------------------------------------------------------------
-- 1. COLUMNAS NUEVAS
-- ------------------------------------------------------------
-- grupo_id: une el despacho con su recepción automática
alter table movimientos add column if not exists grupo_id uuid;
-- cantidad_anterior: guarda el stock previo a un ajuste, para poder revertirlo
alter table movimientos add column if not exists cantidad_anterior integer;

create index if not exists idx_movimientos_grupo on movimientos(grupo_id);

-- Vincular retroactivamente las transferencias ya existentes
with pares as (
  select e.id as envio_id, r.id as recibo_id, gen_random_uuid() as g
  from movimientos e
  join movimientos r
    on r.tipo = 'transferencia_recibo'
   and r.producto_id = e.producto_id
   and r.cantidad = e.cantidad
   and r.entidad_id = e.entidad_destino_id
   and r.entidad_destino_id = e.entidad_id
   and abs(extract(epoch from (r.created_at - e.created_at))) < 5
  where e.tipo = 'transferencia_envio' and e.grupo_id is null and r.grupo_id is null
)
update movimientos m set grupo_id = p.g
from pares p where m.id = p.envio_id or m.id = p.recibo_id;

-- ------------------------------------------------------------
-- 2. registrar_movimiento: ahora guarda grupo y stock previo
-- ------------------------------------------------------------
create or replace function registrar_movimiento(
  p_producto_id uuid,
  p_entidad_id uuid,
  p_tipo tipo_movimiento,
  p_cantidad integer,
  p_nota text,
  p_usuario_id uuid,
  p_entidad_destino_id uuid default null
) returns void as $$
declare
  v_grupo uuid := gen_random_uuid();
  v_anterior integer;
begin
  if p_tipo = 'ajuste' then
    select coalesce(cantidad, 0) into v_anterior
    from inventario where producto_id = p_producto_id and entidad_id = p_entidad_id;
    v_anterior := coalesce(v_anterior, 0);
  end if;

  insert into movimientos (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota, usuario_id, grupo_id, cantidad_anterior)
  values (p_producto_id, p_entidad_id, p_entidad_destino_id, p_tipo, p_cantidad, p_nota, p_usuario_id, v_grupo, v_anterior);

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
      raise exception 'Stock insuficiente para este producto en este almacén';
    end if;

    if p_tipo = 'transferencia_envio' and p_entidad_destino_id is not null then
      insert into inventario (producto_id, entidad_id, cantidad)
      values (p_producto_id, p_entidad_destino_id, p_cantidad)
      on conflict (producto_id, entidad_id)
      do update set cantidad = inventario.cantidad + p_cantidad, updated_at = now();

      insert into movimientos (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota, usuario_id, grupo_id)
      values (p_producto_id, p_entidad_destino_id, p_entidad_id, 'transferencia_recibo', p_cantidad,
              coalesce(p_nota, '') || ' (auto por despacho)', p_usuario_id, v_grupo);
    end if;

  elsif p_tipo = 'ajuste' then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (p_producto_id, p_entidad_id, p_cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = p_cantidad, updated_at = now();
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- ------------------------------------------------------------
-- 3. anular_movimiento: revierte el stock y borra el registro
-- ------------------------------------------------------------
create or replace function anular_movimiento(p_movimiento_id uuid)
returns void as $$
declare
  m record;
  v_rol rol_usuario;
begin
  select rol into v_rol from perfiles where id = auth.uid() and activo;
  if v_rol is null or v_rol not in ('admin', 'bodega', 'logistica') then
    raise exception 'No tienes permiso para anular movimientos';
  end if;

  select * into m from movimientos where id = p_movimiento_id;
  if not found then
    raise exception 'El movimiento no existe';
  end if;

  -- La recepción no se anula sola: se anula el despacho que la generó
  if m.tipo = 'transferencia_recibo' and m.grupo_id is not null then
    select * into m from movimientos
    where grupo_id = m.grupo_id and tipo = 'transferencia_envio' limit 1;
    if not found then
      raise exception 'Anula el despacho correspondiente, no la recepción';
    end if;
  end if;

  if m.tipo = 'entrada' then
    update inventario set cantidad = cantidad - m.cantidad, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;
    if (select cantidad from inventario where producto_id = m.producto_id and entidad_id = m.entidad_id) < 0 then
      raise exception 'No se puede anular: esa mercadería ya salió del almacén. Registra una salida o un ajuste.';
    end if;

  elsif m.tipo = 'salida' then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (m.producto_id, m.entidad_id, m.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + m.cantidad, updated_at = now();

  elsif m.tipo = 'transferencia_envio' then
    -- devolver al origen
    insert into inventario (producto_id, entidad_id, cantidad)
    values (m.producto_id, m.entidad_id, m.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + m.cantidad, updated_at = now();
    -- quitar del destino
    if m.entidad_destino_id is not null then
      update inventario set cantidad = cantidad - m.cantidad, updated_at = now()
      where producto_id = m.producto_id and entidad_id = m.entidad_destino_id;
      if (select coalesce(cantidad, 0) from inventario where producto_id = m.producto_id and entidad_id = m.entidad_destino_id) < 0 then
        raise exception 'No se puede anular: la tienda destino ya vendió o movió esa mercadería.';
      end if;
    end if;

  elsif m.tipo = 'ajuste' then
    if m.cantidad_anterior is null then
      raise exception 'Este ajuste es anterior a la actualización y no guarda el stock previo. Corrígelo con un nuevo ajuste.';
    end if;
    update inventario set cantidad = m.cantidad_anterior, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;
  end if;

  -- Borrar el movimiento (y su par, si es transferencia)
  if m.grupo_id is not null and m.tipo = 'transferencia_envio' then
    delete from movimientos where grupo_id = m.grupo_id;
  else
    delete from movimientos where id = m.id;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- ------------------------------------------------------------
-- 4. Permitir editar la NOTA de un movimiento
-- ------------------------------------------------------------
drop policy if exists "editar_nota_movimiento" on movimientos;
create policy "editar_nota_movimiento" on movimientos for update to authenticated
  using (exists (select 1 from perfiles p where p.id = auth.uid() and p.activo
                   and p.rol in ('admin', 'bodega', 'logistica')));

grant execute on function anular_movimiento(uuid) to authenticated;
