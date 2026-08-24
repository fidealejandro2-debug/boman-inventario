-- ============================================================
-- BOMAN INVENTARIO — Actualización v5
-- Importación masiva de stock por almacén (toma de inventario)
-- Reemplaza el stock del almacén y deja rastro en el kardex:
-- cada cambio se registra como un 'ajuste' anulable.
-- Correr completo en Supabase → SQL Editor (después de v4)
-- ============================================================

create or replace function importar_stock(
  p_entidad_id uuid,
  p_items jsonb,            -- [{"sku":"CAM-ARG-PRN-24-M","cantidad":12}, ...]
  p_nota text default null,
  p_cerrar_faltantes boolean default true  -- productos ausentes del archivo → 0
) returns jsonb as $$
declare
  v_rol rol_usuario;
  v_uid uuid := auth.uid();
  v_nota text;
  it record;
  v_prod uuid;
  v_anterior integer;
  v_actualizados int := 0;
  v_sin_cambio  int := 0;
  v_cerrados    int := 0;
  v_desconocidos text[] := '{}';
begin
  -- ---- Permisos ----
  select rol into v_rol from perfiles where id = v_uid and activo;
  if v_rol is null or v_rol not in ('admin', 'bodega') then
    raise exception 'Solo admin o bodega pueden importar stock';
  end if;

  if p_entidad_id is null then
    raise exception 'Debes indicar el almacén';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El archivo no contiene filas válidas';
  end if;

  v_nota := coalesce(nullif(btrim(p_nota), ''), 'Importación de stock')
            || ' (' || to_char(now() at time zone 'America/Guayaquil', 'DD/MM/YYYY HH24:MI') || ')';

  -- ---- Tabla temporal con lo que viene del archivo ----
  create temp table _import (sku text primary key, cantidad integer) on commit drop;

  insert into _import (sku, cantidad)
  select upper(btrim(x->>'sku')), greatest(0, (x->>'cantidad')::numeric::integer)
  from jsonb_array_elements(p_items) x
  where btrim(coalesce(x->>'sku', '')) <> ''
  on conflict (sku) do update set cantidad = excluded.cantidad;

  -- ---- SKUs que no existen en el catálogo ----
  select coalesce(array_agg(i.sku order by i.sku), '{}')
  into v_desconocidos
  from _import i
  left join productos p on upper(p.sku) = i.sku
  where p.id is null;

  -- ---- Aplicar cada fila ----
  for it in
    select p.id as producto_id, i.cantidad
    from _import i
    join productos p on upper(p.sku) = i.sku
  loop
    select coalesce(cantidad, 0) into v_anterior
    from inventario where producto_id = it.producto_id and entidad_id = p_entidad_id;
    v_anterior := coalesce(v_anterior, 0);

    if v_anterior = it.cantidad then
      v_sin_cambio := v_sin_cambio + 1;
      continue;
    end if;

    insert into inventario (producto_id, entidad_id, cantidad)
    values (it.producto_id, p_entidad_id, it.cantidad)
    on conflict (producto_id, entidad_id)
    do update set cantidad = it.cantidad, updated_at = now();

    insert into movimientos (producto_id, entidad_id, tipo, cantidad, cantidad_anterior, nota, usuario_id, grupo_id)
    values (it.producto_id, p_entidad_id, 'ajuste', it.cantidad, v_anterior, v_nota, v_uid, gen_random_uuid());

    v_actualizados := v_actualizados + 1;
  end loop;

  -- ---- Productos con stock en este almacén que NO vinieron en el archivo ----
  if p_cerrar_faltantes then
    for it in
      select inv.producto_id, inv.cantidad as anterior
      from inventario inv
      join productos p on p.id = inv.producto_id
      where inv.entidad_id = p_entidad_id
        and inv.cantidad <> 0
        and upper(p.sku) not in (select sku from _import)
    loop
      update inventario set cantidad = 0, updated_at = now()
      where producto_id = it.producto_id and entidad_id = p_entidad_id;

      insert into movimientos (producto_id, entidad_id, tipo, cantidad, cantidad_anterior, nota, usuario_id, grupo_id)
      values (it.producto_id, p_entidad_id, 'ajuste', 0, it.anterior,
              v_nota || ' — sin registro en el archivo', v_uid, gen_random_uuid());

      v_cerrados := v_cerrados + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'actualizados', v_actualizados,
    'sin_cambio',   v_sin_cambio,
    'cerrados',     v_cerrados,
    'desconocidos', to_jsonb(v_desconocidos)
  );
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function importar_stock(uuid, jsonb, text, boolean) to authenticated;
