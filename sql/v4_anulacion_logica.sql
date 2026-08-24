-- ============================================================
-- BOMAN INVENTARIO — Actualización v4
-- Anulación LÓGICA (trazable, ISO 9001)
-- El movimiento ya no se borra: queda visible tachado, con
-- motivo, autor y fecha de anulación.
-- Correr completo en Supabase → SQL Editor (después de v3)
-- ============================================================

-- ------------------------------------------------------------
-- 1. COLUMNAS DE ANULACIÓN
-- ------------------------------------------------------------
alter table movimientos add column if not exists anulado boolean not null default false;
alter table movimientos add column if not exists anulado_por uuid references perfiles(id);
alter table movimientos add column if not exists anulado_at timestamptz;
alter table movimientos add column if not exists motivo_anulacion text;

create index if not exists idx_movimientos_anulado on movimientos(anulado);

-- ------------------------------------------------------------
-- 2. anular_movimiento: ahora MARCA en vez de borrar
-- ------------------------------------------------------------
create or replace function anular_movimiento(
  p_movimiento_id uuid,
  p_motivo text default null
) returns void as $$
declare
  m record;
  v_rol rol_usuario;
  v_uid uuid := auth.uid();
begin
  select rol into v_rol from perfiles where id = v_uid and activo;
  if v_rol is null or v_rol not in ('admin', 'bodega', 'logistica') then
    raise exception 'No tienes permiso para anular movimientos';
  end if;

  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Debes indicar el motivo de la anulación';
  end if;

  select * into m from movimientos where id = p_movimiento_id;
  if not found then
    raise exception 'El movimiento no existe';
  end if;

  if m.anulado then
    raise exception 'Este movimiento ya fue anulado';
  end if;

  -- La recepción no se anula sola: se anula el despacho que la generó
  if m.tipo = 'transferencia_recibo' then
    if m.grupo_id is null then
      raise exception 'Anula el despacho correspondiente, no la recepción';
    end if;
    select * into m from movimientos
    where grupo_id = m.grupo_id and tipo = 'transferencia_envio' and not anulado limit 1;
    if not found then
      raise exception 'Anula el despacho correspondiente, no la recepción';
    end if;
  end if;

  -- ---- Revertir el efecto en inventario ----
  if m.tipo = 'entrada' then
    update inventario set cantidad = cantidad - m.cantidad, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;
    if (select coalesce(cantidad, 0) from inventario
        where producto_id = m.producto_id and entidad_id = m.entidad_id) < 0 then
      raise exception 'No se puede anular: esa mercadería ya salió del almacén. Corrige con un ajuste.';
    end if;

  elsif m.tipo = 'salida' then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (m.producto_id, m.entidad_id, m.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + m.cantidad, updated_at = now();

  elsif m.tipo = 'transferencia_envio' then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (m.producto_id, m.entidad_id, m.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + m.cantidad, updated_at = now();

    if m.entidad_destino_id is not null then
      update inventario set cantidad = cantidad - m.cantidad, updated_at = now()
      where producto_id = m.producto_id and entidad_id = m.entidad_destino_id;
      if (select coalesce(cantidad, 0) from inventario
          where producto_id = m.producto_id and entidad_id = m.entidad_destino_id) < 0 then
        raise exception 'No se puede anular: la tienda destino ya vendió o movió esa mercadería.';
      end if;
    end if;

  elsif m.tipo = 'ajuste' then
    if m.cantidad_anterior is null then
      raise exception 'Este ajuste no guarda el stock previo. Corrígelo con un nuevo ajuste.';
    end if;
    update inventario set cantidad = m.cantidad_anterior, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;
  end if;

  -- ---- Marcar como anulado (NO se borra) ----
  if m.grupo_id is not null and m.tipo = 'transferencia_envio' then
    update movimientos
      set anulado = true, anulado_por = v_uid, anulado_at = now(), motivo_anulacion = btrim(p_motivo)
    where grupo_id = m.grupo_id and not anulado;
  else
    update movimientos
      set anulado = true, anulado_por = v_uid, anulado_at = now(), motivo_anulacion = btrim(p_motivo)
    where id = m.id;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function anular_movimiento(uuid, text) to authenticated;

-- Retirar la versión anterior (que borraba)
drop function if exists anular_movimiento(uuid);

-- ------------------------------------------------------------
-- 3. Blindaje: nadie puede borrar movimientos
-- ------------------------------------------------------------
revoke delete on movimientos from authenticated;
drop policy if exists "borrar_movimientos" on movimientos;
