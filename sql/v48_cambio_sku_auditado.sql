-- ============================================================
-- BOMAN INVENTARIO - v48: cambiar el SKU, auditado
--
-- v8 revoco el update de tabla sobre productos y concedio solo una lista de
-- columnas descriptivas. 'sku' nunca estuvo en esa lista, asi que editarlo
-- desde la interfaz devuelve "permission denied for table productos". El
-- candado es correcto: el SKU es la identidad de la prenda, va impreso en las
-- etiquetas y es la llave de las importaciones. Lo que faltaba no era abrir la
-- columna a cualquiera, sino una via administrativa que exija motivo y deje
-- rastro.
--
-- Ejecutar despues de v47.
-- ============================================================

-- 1. El motivo viaja hasta el trigger de auditoria ------------------------
alter table public.productos_maestro_cambios
  add column if not exists motivo text;

-- 2. La auditoria del maestro pasa a vigilar el SKU -----------------------
-- Sin esto, cambiar el codigo de una prenda no dejaba ninguna huella: la
-- funcion de v12 comparaba todo menos justamente el identificador.
create or replace function public.auditar_producto_maestro()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_anterior jsonb;
  v_nuevo jsonb;
begin
  v_anterior := jsonb_build_object(
    'sku', old.sku,
    'nombre', old.nombre, 'categoria_id', old.categoria_id,
    'subcategoria_id', old.subcategoria_id, 'talla', old.talla,
    'color', old.color, 'stock_minimo', old.stock_minimo,
    'precio', old.precio, 'club', old.club, 'activo', old.activo
  );
  v_nuevo := jsonb_build_object(
    'sku', new.sku,
    'nombre', new.nombre, 'categoria_id', new.categoria_id,
    'subcategoria_id', new.subcategoria_id, 'talla', new.talla,
    'color', new.color, 'stock_minimo', new.stock_minimo,
    'precio', new.precio, 'club', new.club, 'activo', new.activo
  );
  if v_anterior is distinct from v_nuevo then
    insert into public.productos_maestro_cambios
      (producto_id, realizado_por, valores_anteriores, valores_nuevos, motivo)
    values (
      old.id, auth.uid(), v_anterior, v_nuevo,
      -- La pone la RPC que exige motivo; en una edicion normal viene vacia.
      nullif(btrim(coalesce(current_setting('boman.motivo_maestro', true), '')), '')
    );
  end if;
  return new;
end;
$fn$;

-- 3. Via administrativa para cambiar el SKU -------------------------------
create or replace function public.admin_cambiar_sku_producto_v48(
  p_producto_id uuid,
  p_sku text,
  p_motivo text
) returns text
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_anterior text;
  v_nuevo text := upper(btrim(coalesce(p_sku, '')));
begin
  if not exists (
    select 1 from public.perfiles
    where id = auth.uid() and activo and rol = 'admin'
  ) then
    raise exception 'Solo un administrador activo puede cambiar el codigo de una prenda';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica el motivo del cambio de codigo con al menos 10 caracteres';
  end if;
  if v_nuevo = '' then
    raise exception 'El codigo no puede quedar vacio';
  end if;
  -- Mismo alfabeto que acepta el importador de catalogo: sin espacios ni
  -- acentos, para que el codigo sobreviva a los archivos de Excel y a las
  -- etiquetas impresas.
  if v_nuevo !~ '^[A-Z0-9][A-Z0-9._/-]{1,39}$' then
    raise exception 'El codigo solo admite letras, numeros y los signos . _ - / (2 a 40 caracteres)';
  end if;

  select sku into v_anterior from public.productos where id = p_producto_id for update;
  if not found then raise exception 'El producto no existe'; end if;
  if v_anterior = v_nuevo then return v_nuevo; end if;

  if exists (select 1 from public.productos where upper(sku) = v_nuevo and id <> p_producto_id) then
    raise exception 'Ese codigo ya pertenece a otra prenda';
  end if;

  -- El trigger de auditoria lo lee y lo guarda junto al cambio.
  perform set_config('boman.motivo_maestro',
    'Cambio de codigo ' || v_anterior || ' a ' || v_nuevo || ': ' || btrim(p_motivo), true);

  update public.productos set sku = v_nuevo where id = p_producto_id;

  return v_nuevo;
end;
$fn$;

alter function public.auditar_producto_maestro() owner to postgres;
alter function public.admin_cambiar_sku_producto_v48(uuid, text, text) owner to postgres;

-- La columna sigue cerrada: el unico camino es esta funcion.
revoke update (sku) on public.productos from public, anon, authenticated;
revoke execute on function public.admin_cambiar_sku_producto_v48(uuid, text, text) from public, anon;
grant execute on function public.admin_cambiar_sku_producto_v48(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
