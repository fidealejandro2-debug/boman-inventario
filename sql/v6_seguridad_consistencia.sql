-- ============================================================
-- BOMAN INVENTARIO - Actualizacion v6
-- Integridad de stock, permisos por almacen y auditoria.
-- Ejecutar DESPUES de v5. No modifica migraciones anteriores.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Los ajustes pueden fijar el stock en cero. Los demas
--    movimientos deben conservar una cantidad mayor que cero.
-- ------------------------------------------------------------
alter table movimientos drop constraint if exists movimientos_cantidad_check;
alter table movimientos add constraint movimientos_cantidad_check check (
  (tipo = 'ajuste' and cantidad >= 0)
  or
  (tipo <> 'ajuste' and cantidad > 0)
);

-- ------------------------------------------------------------
-- 2. La vista debe respetar el RLS de las tablas que consulta.
-- ------------------------------------------------------------
create or replace view vista_stock
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
  (i.cantidad <= p.stock_minimo) as bajo_minimo
from inventario i
join productos p on p.id = i.producto_id
join almacenes a on a.id = i.entidad_id
where p.activo and a.activo;

revoke all on vista_stock from anon;
grant select on vista_stock to authenticated;

-- ------------------------------------------------------------
-- 3. Politicas base: un usuario inactivo no puede seguir usando
--    catalogos ni consultar perfiles mediante la API.
-- ------------------------------------------------------------
create or replace function usuario_actual_activo()
returns boolean as $$
  select exists (
    select 1 from perfiles where id = auth.uid() and activo
  );
$$ language sql stable security definer set search_path = public;

revoke execute on function usuario_actual_activo() from public, anon;
grant execute on function usuario_actual_activo() to authenticated;

drop policy if exists "leer_almacenes" on almacenes;
create policy "leer_almacenes" on almacenes for select to authenticated using (
  exists (select 1 from perfiles p where p.id = auth.uid() and p.activo)
);

drop policy if exists "leer_propio_perfil" on perfiles;
drop policy if exists "leer_perfiles" on perfiles;
-- Se permite leer nombres/perfiles porque movimientos los usa para mostrar responsables.
-- Un usuario inactivo solo puede leer su propia fila para que la app pueda cerrar su sesion.
create policy "leer_perfiles" on perfiles for select to authenticated using (
  id = auth.uid() or usuario_actual_activo()
);

drop policy if exists "leer_productos" on productos;
create policy "leer_productos" on productos for select to authenticated using (
  exists (select 1 from perfiles p where p.id = auth.uid() and p.activo)
);

drop policy if exists "admin_escribe_productos" on productos;
create policy "admin_escribe_productos" on productos for insert to authenticated
with check (
  exists (select 1 from perfiles p where p.id = auth.uid() and p.activo and p.rol = 'admin')
);

drop policy if exists "admin_actualiza_productos" on productos;
create policy "admin_actualiza_productos" on productos for update to authenticated
using (
  exists (select 1 from perfiles p where p.id = auth.uid() and p.activo and p.rol = 'admin')
)
with check (
  exists (select 1 from perfiles p where p.id = auth.uid() and p.activo and p.rol = 'admin')
);

-- ------------------------------------------------------------
-- 4. Registrar movimientos: la identidad sale del JWT, se valida
--    rol/almacen y no se admite crear recepciones manuales.
--    p_usuario_id se conserva por compatibilidad con la app v1.
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
  v_uid uuid := auth.uid();
  v_rol rol_usuario;
  v_entidad_usuario uuid;
  v_grupo uuid := gen_random_uuid();
  v_stock integer;
  v_anterior integer;
begin
  select rol, entidad_id into v_rol, v_entidad_usuario
  from perfiles where id = v_uid and activo;

  if v_uid is null or v_rol is null or v_rol not in ('admin', 'bodega', 'logistica') then
    raise exception 'No tienes permiso para registrar movimientos';
  end if;
  if p_usuario_id is distinct from v_uid then
    raise exception 'El usuario del movimiento no coincide con la sesion';
  end if;
  if p_entidad_id is null then
    raise exception 'Debes indicar el almacen';
  end if;
  if v_entidad_usuario is not null and p_entidad_id <> v_entidad_usuario then
    raise exception 'No tienes permiso para operar ese almacen';
  end if;
  if not exists (select 1 from almacenes where id = p_entidad_id and activo) then
    raise exception 'El almacen de origen no existe o esta inactivo';
  end if;
  if not exists (select 1 from productos where id = p_producto_id and activo) then
    raise exception 'El producto no existe o esta inactivo';
  end if;
  if p_tipo = 'transferencia_recibo' then
    raise exception 'La recepcion se genera automaticamente desde el despacho';
  end if;
  if p_tipo = 'ajuste' then
    if p_cantidad < 0 then raise exception 'El ajuste no puede ser negativo'; end if;
  elsif p_cantidad <= 0 then
    raise exception 'La cantidad debe ser mayor que cero';
  end if;

  if p_tipo = 'transferencia_envio' then
    if p_entidad_destino_id is null then
      raise exception 'Debes indicar el almacen destino';
    end if;
    if p_entidad_destino_id = p_entidad_id then
      raise exception 'El almacen destino debe ser diferente al origen';
    end if;
    if not exists (select 1 from almacenes where id = p_entidad_destino_id and activo) then
      raise exception 'El almacen destino no existe o esta inactivo';
    end if;
  elsif p_entidad_destino_id is not null then
    raise exception 'Solo una transferencia puede tener almacen destino';
  end if;

  if p_tipo = 'entrada' then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (p_producto_id, p_entidad_id, p_cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + p_cantidad, updated_at = now();

    insert into movimientos
      (producto_id, entidad_id, tipo, cantidad, nota, usuario_id, grupo_id)
    values
      (p_producto_id, p_entidad_id, p_tipo, p_cantidad, p_nota, v_uid, v_grupo);

  elsif p_tipo in ('salida', 'transferencia_envio') then
    select cantidad into v_stock from inventario
    where producto_id = p_producto_id and entidad_id = p_entidad_id
    for update;

    if v_stock is null or v_stock < p_cantidad then
      raise exception 'Stock insuficiente para este producto en este almacen';
    end if;

    update inventario set cantidad = cantidad - p_cantidad, updated_at = now()
    where producto_id = p_producto_id and entidad_id = p_entidad_id;

    insert into movimientos
      (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota, usuario_id, grupo_id)
    values
      (p_producto_id, p_entidad_id, p_entidad_destino_id, p_tipo, p_cantidad, p_nota, v_uid, v_grupo);

    if p_tipo = 'transferencia_envio' then
      insert into inventario (producto_id, entidad_id, cantidad)
      values (p_producto_id, p_entidad_destino_id, p_cantidad)
      on conflict (producto_id, entidad_id)
      do update set cantidad = inventario.cantidad + p_cantidad, updated_at = now();

      insert into movimientos
        (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota, usuario_id, grupo_id)
      values
        (p_producto_id, p_entidad_destino_id, p_entidad_id, 'transferencia_recibo', p_cantidad,
         coalesce(p_nota, '') || ' (auto por despacho)', v_uid, v_grupo);
    end if;

  elsif p_tipo = 'ajuste' then
    select cantidad into v_stock from inventario
    where producto_id = p_producto_id and entidad_id = p_entidad_id
    for update;
    v_anterior := coalesce(v_stock, 0);

    insert into inventario (producto_id, entidad_id, cantidad)
    values (p_producto_id, p_entidad_id, p_cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = p_cantidad, updated_at = now();

    insert into movimientos
      (producto_id, entidad_id, tipo, cantidad, cantidad_anterior, nota, usuario_id, grupo_id)
    values
      (p_producto_id, p_entidad_id, p_tipo, p_cantidad, v_anterior, p_nota, v_uid, v_grupo);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

revoke execute on function registrar_movimiento(uuid, uuid, tipo_movimiento, integer, text, uuid, uuid) from public, anon;
grant execute on function registrar_movimiento(uuid, uuid, tipo_movimiento, integer, text, uuid, uuid) to authenticated;

-- Ningun cliente inserta movimientos directamente: siempre debe usar una RPC atomica.
drop policy if exists "insertar_movimientos" on movimientos;
revoke insert on movimientos from public, anon, authenticated;

-- ------------------------------------------------------------
-- 5. Anulacion segura. Los ajustes se revierten por su diferencia,
--    sin borrar movimientos posteriores.
-- ------------------------------------------------------------
create or replace function anular_movimiento(
  p_movimiento_id uuid,
  p_motivo text default null
) returns void as $$
declare
  m record;
  v_uid uuid := auth.uid();
  v_rol rol_usuario;
  v_entidad_usuario uuid;
  v_actual integer;
  v_nuevo integer;
begin
  select rol, entidad_id into v_rol, v_entidad_usuario
  from perfiles where id = v_uid and activo;

  if v_uid is null or v_rol is null or v_rol not in ('admin', 'bodega', 'logistica') then
    raise exception 'No tienes permiso para anular movimientos';
  end if;
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Debes indicar el motivo de la anulacion';
  end if;

  select * into m from movimientos where id = p_movimiento_id for update;
  if not found then raise exception 'El movimiento no existe'; end if;
  if m.anulado then raise exception 'Este movimiento ya fue anulado'; end if;

  if m.tipo = 'transferencia_recibo' then
    if m.grupo_id is null then
      raise exception 'Anula el despacho correspondiente, no la recepcion';
    end if;
    select * into m from movimientos
    where grupo_id = m.grupo_id and tipo = 'transferencia_envio' and not anulado
    limit 1 for update;
    if not found then
      raise exception 'Anula el despacho correspondiente, no la recepcion';
    end if;
  end if;

  if v_entidad_usuario is not null and m.entidad_id <> v_entidad_usuario then
    raise exception 'No tienes permiso para anular movimientos de otro almacen';
  end if;

  if m.tipo = 'entrada' then
    select cantidad into v_actual from inventario
    where producto_id = m.producto_id and entidad_id = m.entidad_id for update;
    if v_actual is null or v_actual < m.cantidad then
      raise exception 'No se puede anular: esa mercaderia ya salio del almacen. Corrige con un ajuste.';
    end if;
    update inventario set cantidad = cantidad - m.cantidad, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;

  elsif m.tipo = 'salida' then
    insert into inventario (producto_id, entidad_id, cantidad)
    values (m.producto_id, m.entidad_id, m.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + m.cantidad, updated_at = now();

  elsif m.tipo = 'transferencia_envio' then
    select cantidad into v_actual from inventario
    where producto_id = m.producto_id and entidad_id = m.entidad_destino_id for update;
    if v_actual is null or v_actual < m.cantidad then
      raise exception 'No se puede anular: la tienda destino ya vendio o movio esa mercaderia.';
    end if;

    insert into inventario (producto_id, entidad_id, cantidad)
    values (m.producto_id, m.entidad_id, m.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = inventario.cantidad + m.cantidad, updated_at = now();

    update inventario set cantidad = cantidad - m.cantidad, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_destino_id;

  elsif m.tipo = 'ajuste' then
    if m.cantidad_anterior is null then
      raise exception 'Este ajuste no guarda el stock previo. Corrigelo con un nuevo ajuste.';
    end if;
    select cantidad into v_actual from inventario
    where producto_id = m.producto_id and entidad_id = m.entidad_id for update;
    if v_actual is null then raise exception 'No existe stock para revertir este ajuste'; end if;

    v_nuevo := v_actual - (m.cantidad - m.cantidad_anterior);
    if v_nuevo < 0 then
      raise exception 'No se puede anular: movimientos posteriores dejarian el stock negativo. Corrige con un ajuste.';
    end if;
    update inventario set cantidad = v_nuevo, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;
  end if;

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

revoke execute on function anular_movimiento(uuid, text) from public, anon;
grant execute on function anular_movimiento(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 6. Importacion restringida al almacen asignado.
-- ------------------------------------------------------------
create or replace function importar_stock(
  p_entidad_id uuid,
  p_items jsonb,
  p_nota text default null,
  p_cerrar_faltantes boolean default true
) returns jsonb as $$
declare
  v_rol rol_usuario;
  v_uid uuid := auth.uid();
  v_entidad_usuario uuid;
  v_nota text;
  it record;
  v_anterior integer;
  v_actualizados int := 0;
  v_sin_cambio int := 0;
  v_cerrados int := 0;
  v_desconocidos text[] := '{}';
begin
  select rol, entidad_id into v_rol, v_entidad_usuario
  from perfiles where id = v_uid and activo;

  if v_uid is null or v_rol is null or v_rol not in ('admin', 'bodega') then
    raise exception 'Solo admin o bodega pueden importar stock';
  end if;
  if p_entidad_id is null then raise exception 'Debes indicar el almacen'; end if;
  if v_entidad_usuario is not null and p_entidad_id <> v_entidad_usuario then
    raise exception 'No tienes permiso para importar stock en otro almacen';
  end if;
  if not exists (select 1 from almacenes where id = p_entidad_id and activo) then
    raise exception 'El almacen no existe o esta inactivo';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El archivo no contiene filas validas';
  end if;

  v_nota := coalesce(nullif(btrim(p_nota), ''), 'Importacion de stock')
            || ' (' || to_char(now() at time zone 'America/Guayaquil', 'DD/MM/YYYY HH24:MI') || ')';

  create temp table _import (sku text primary key, cantidad integer) on commit drop;

  insert into _import (sku, cantidad)
  select upper(btrim(x->>'sku')), greatest(0, (x->>'cantidad')::numeric::integer)
  from jsonb_array_elements(p_items) x
  where btrim(coalesce(x->>'sku', '')) <> ''
  on conflict (sku) do update set cantidad = excluded.cantidad;

  select coalesce(array_agg(i.sku order by i.sku), '{}') into v_desconocidos
  from _import i
  left join productos p on upper(p.sku) = i.sku and p.activo
  where p.id is null;

  for it in
    select p.id as producto_id, i.cantidad
    from _import i join productos p on upper(p.sku) = i.sku and p.activo
  loop
    select coalesce(cantidad, 0) into v_anterior
    from inventario where producto_id = it.producto_id and entidad_id = p_entidad_id
    for update;
    v_anterior := coalesce(v_anterior, 0);

    if v_anterior = it.cantidad then
      v_sin_cambio := v_sin_cambio + 1;
      continue;
    end if;

    insert into inventario (producto_id, entidad_id, cantidad)
    values (it.producto_id, p_entidad_id, it.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = it.cantidad, updated_at = now();

    insert into movimientos
      (producto_id, entidad_id, tipo, cantidad, cantidad_anterior, nota, usuario_id, grupo_id)
    values
      (it.producto_id, p_entidad_id, 'ajuste', it.cantidad, v_anterior, v_nota, v_uid, gen_random_uuid());
    v_actualizados := v_actualizados + 1;
  end loop;

  if p_cerrar_faltantes then
    for it in
      select inv.producto_id, inv.cantidad as anterior
      from inventario inv
      join productos p on p.id = inv.producto_id and p.activo
      where inv.entidad_id = p_entidad_id
        and inv.cantidad <> 0
        and upper(p.sku) not in (select sku from _import)
      for update of inv
    loop
      update inventario set cantidad = 0, updated_at = now()
      where producto_id = it.producto_id and entidad_id = p_entidad_id;

      insert into movimientos
        (producto_id, entidad_id, tipo, cantidad, cantidad_anterior, nota, usuario_id, grupo_id)
      values
        (it.producto_id, p_entidad_id, 'ajuste', 0, it.anterior,
         v_nota || ' - sin registro en el archivo', v_uid, gen_random_uuid());
      v_cerrados := v_cerrados + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'actualizados', v_actualizados,
    'sin_cambio', v_sin_cambio,
    'cerrados', v_cerrados,
    'desconocidos', to_jsonb(v_desconocidos)
  );
end;
$$ language plpgsql security definer set search_path = public;

revoke execute on function importar_stock(uuid, jsonb, text, boolean) from public, anon;
grant execute on function importar_stock(uuid, jsonb, text, boolean) to authenticated;

-- ------------------------------------------------------------
-- 7. Solo se permite editar la nota y cada cambio queda auditado.
-- ------------------------------------------------------------
create table if not exists movimientos_cambios (
  id uuid primary key default gen_random_uuid(),
  movimiento_id uuid not null references movimientos(id),
  campo text not null,
  valor_anterior text,
  valor_nuevo text,
  usuario_id uuid not null references perfiles(id),
  created_at timestamptz not null default now()
);

alter table movimientos_cambios enable row level security;

drop policy if exists "leer_movimientos_cambios" on movimientos_cambios;
create policy "leer_movimientos_cambios" on movimientos_cambios for select to authenticated using (
  exists (
    select 1 from perfiles p
    join movimientos m on m.id = movimientos_cambios.movimiento_id
    where p.id = auth.uid() and p.activo
      and (p.rol in ('admin', 'gerencia') or p.entidad_id is null
           or p.entidad_id = m.entidad_id or p.entidad_id = m.entidad_destino_id)
  )
);

create or replace function auditar_nota_movimiento()
returns trigger as $$
begin
  if old.nota is distinct from new.nota then
    insert into movimientos_cambios
      (movimiento_id, campo, valor_anterior, valor_nuevo, usuario_id)
    values
      (old.id, 'nota', old.nota, new.nota, auth.uid());
  end if;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_auditar_nota_movimiento on movimientos;
create trigger trg_auditar_nota_movimiento
before update of nota on movimientos
for each row execute function auditar_nota_movimiento();

drop policy if exists "editar_nota_movimiento" on movimientos;
create policy "editar_nota_movimiento" on movimientos for update to authenticated
using (
  exists (
    select 1 from perfiles p where p.id = auth.uid() and p.activo
      and p.rol in ('admin', 'bodega', 'logistica')
      and (p.entidad_id is null or p.entidad_id = movimientos.entidad_id)
  )
)
with check (
  exists (
    select 1 from perfiles p where p.id = auth.uid() and p.activo
      and p.rol in ('admin', 'bodega', 'logistica')
      and (p.entidad_id is null or p.entidad_id = movimientos.entidad_id)
  )
);

revoke update on movimientos from public, anon, authenticated;
grant update (nota) on movimientos to authenticated;
revoke all on movimientos_cambios from anon;
revoke insert, update, delete on movimientos_cambios from authenticated;
grant select on movimientos_cambios to authenticated;
revoke execute on function auditar_nota_movimiento() from public, anon, authenticated;

-- Seguridad por defecto para futuras funciones creadas por el rol que ejecuta esta migracion.
alter default privileges in schema public revoke execute on functions from public;
