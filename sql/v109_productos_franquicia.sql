-- ============================================================
-- BOMAN INVENTARIO - v109: el franquiciado puede crear productos
--
-- Hoy solo admin crea productos (app/productos/page.tsx, gate crudo por rol).
-- Este archivo agrega un permiso nuevo (productos.crear, por defecto en
-- franquiciado/vendedor_franquicia) y una funcion de creacion aparte de
-- crear_producto_desde_homologacion_v67 -esa exige una importacion XML de
-- compras y bloquea a no-admin a proposito; esta es para crear un producto
-- desde cero. El SKU se arma igual que en v67 (BS-IN-PR-03:
-- CAT-ENTIDAD-VAR-ANIO(-TALLA)), pero el franquiciado solo puede ELEGIR
-- abreviaturas ya existentes, nunca crear una nueva: si su producto no
-- encaja en ninguna, eso debe escalar a administracion, no autogenerarse.
--
-- La alerta a admin reusa notificaciones_comunicados (v53) con el mismo
-- patron que v86/v87 (rol_destino, sin pantalla nueva).
--
-- Ejecutar despues de v53, v67 y v68.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.sku_abreviaturas_v67') is null
     or to_regclass('public.notificaciones_comunicados') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Faltan v53, v67 o v35. Instalalas antes de v109';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'perfiles' and column_name = 'grupo_id'
  ) then
    raise exception 'Falta v68 (perfiles.grupo_id). Instalala antes de v109';
  end if;
end;
$requisitos$;

-- ------------------------------------------------------------
-- 1. Permiso nuevo: por defecto solo para los roles de franquicia.
--    Admin ya tiene todo por el bypass de rol de siempre.
-- ------------------------------------------------------------
insert into public.permisos_sistema as p (codigo, modulo, nombre, descripcion, orden)
values ('productos.crear', 'Inventario', 'Crear productos', 'Da de alta un producto nuevo con SKU sugerido.', 205)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.codigo = 'productos.crear'
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos set permitido = true, updated_at = now()
where permiso_codigo = 'productos.crear'
  and rol::text in ('franquiciado', 'vendedor_franquicia');

-- ------------------------------------------------------------
-- 2. Auditoria de lo creado por franquicia
-- ------------------------------------------------------------
create table if not exists public.productos_creados_franquicia_v109 (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null unique references public.productos(id) on delete restrict,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  almacen_id uuid references public.almacenes(id) on delete restrict,
  categoria_codigo text not null check (categoria_codigo ~ '^[A-Z0-9]{3}$'),
  entidad_codigo text not null check (entidad_codigo ~ '^[A-Z0-9]{3}$'),
  variante_codigo text,
  anio_codigo text,
  talla_codigo text,
  sku text not null,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  revisado_at timestamptz,
  revisado_por uuid references public.perfiles(id) on delete restrict
);

comment on table public.productos_creados_franquicia_v109 is
  'Bitacora de productos creados por un franquiciado (no por admin/homologacion XML). '
  'revisado_at queda null hasta que un admin/control lo marca visto en /productos.';

create index if not exists idx_productos_franquicia_pendientes_v109
  on public.productos_creados_franquicia_v109(revisado_at) where revisado_at is null;

-- ------------------------------------------------------------
-- 3. Lectura de abreviaturas disponibles (sin tocar la RLS admin-only de
--    sku_abreviaturas_v67: son solo etiquetas/codigos, no datos sensibles).
-- ------------------------------------------------------------
create or replace function public.sku_abreviaturas_disponibles_v109()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'categoria', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', nombre, 'codigo', codigo) order by nombre)
      from public.sku_abreviaturas_v67 where tipo = 'categoria' and activo
    ), '[]'::jsonb),
    'entidad', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', nombre, 'codigo', codigo) order by nombre)
      from public.sku_abreviaturas_v67 where tipo = 'entidad' and activo
    ), '[]'::jsonb),
    'variante', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', nombre, 'codigo', codigo) order by nombre)
      from public.sku_abreviaturas_v67 where tipo = 'variante' and activo
    ), '[]'::jsonb)
  );
$fn$;

-- ------------------------------------------------------------
-- 4. Crear el producto
-- ------------------------------------------------------------
create or replace function public.crear_producto_franquicia_v109(
  p_producto jsonb,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_producto_id uuid;
  v_almacen_id uuid;
  v_categoria_id uuid;
  v_categoria_nombre text;
  v_subcategoria_id uuid;
  v_subcategoria_nombre text;
  v_cat text := upper(btrim(coalesce(p_producto->>'categoria_codigo', '')));
  v_ent text := upper(btrim(coalesce(p_producto->>'entidad_codigo', '')));
  v_var text := upper(btrim(coalesce(p_producto->>'variante_codigo', '')));
  v_anio text := upper(btrim(coalesce(p_producto->>'anio_codigo', '')));
  v_talla_codigo text := upper(btrim(coalesce(p_producto->>'talla_codigo', '')));
  v_sku text;
  v_nombre text := btrim(coalesce(p_producto->>'nombre', ''));
  v_nombre_normalizado text;
  v_talla_normalizada text;
  v_color_normalizado text;
  v_existente public.productos%rowtype;
  v_rol text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion para crear productos'; end if;
  if not public.usuario_tiene_permiso_v35('productos.crear') then
    raise exception 'No tienes permiso para crear productos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;

  select p.id into v_producto_id
  from public.productos_creados_franquicia_v109 c
  join public.productos p on p.id = c.producto_id
  where c.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('duplicado', true, 'producto_id', v_producto_id);
  end if;

  select rol_usuario_actual() into v_rol;
  select pa.almacen_id into v_almacen_id
  from public.perfil_almacenes pa where pa.perfil_id = v_uid limit 1;

  if v_nombre = '' then raise exception 'El nombre del producto es obligatorio'; end if;
  v_categoria_id := nullif(p_producto->>'categoria_id', '')::uuid;
  select c.nombre into v_categoria_nombre
  from public.categorias_productos c where c.id = v_categoria_id and c.activo;
  if not found then raise exception 'Selecciona una categoria activa'; end if;
  v_subcategoria_id := nullif(p_producto->>'subcategoria_id', '')::uuid;
  if v_subcategoria_id is not null then
    select s.nombre into v_subcategoria_nombre
    from public.subcategorias_productos s
    where s.id = v_subcategoria_id and s.categoria_id = v_categoria_id and s.activo;
    if not found then raise exception 'La subcategoria no pertenece a la categoria'; end if;
  end if;

  -- El franquiciado solo elige abreviaturas YA registradas: si no existe,
  -- debe escalar a administracion en vez de autogenerarse una.
  if not exists (
    select 1 from public.sku_abreviaturas_v67
    where tipo = 'categoria' and codigo = v_cat and activo
  ) then raise exception 'Ese codigo de categoria no existe. Comunicate con administracion.'; end if;
  if not exists (
    select 1 from public.sku_abreviaturas_v67
    where tipo = 'entidad' and codigo = v_ent and activo
  ) then raise exception 'Ese codigo de entidad no existe. Comunicate con administracion.'; end if;

  if v_cat = 'CTR' then
    v_sku := 'CTR-' || v_ent || '-UN';
    v_var := null; v_anio := null; v_talla_codigo := null;
  else
    if not exists (
      select 1 from public.sku_abreviaturas_v67
      where tipo = 'variante' and codigo = v_var and activo
    ) then raise exception 'Ese codigo de variante no existe. Comunicate con administracion.'; end if;
    if v_anio !~ '^[0-9]{2}$' then raise exception 'El anio del SKU debe tener 2 digitos'; end if;
    if v_talla_codigo <> '' and v_talla_codigo !~ '^[A-Z0-9]{1,8}$' then
      raise exception 'La talla del SKU solo admite letras o numeros, sin espacios';
    end if;
    v_sku := v_cat || '-' || v_ent || '-' || v_var || '-' || v_anio
      || case when v_talla_codigo = '' then '' else '-' || v_talla_codigo end;
  end if;
  if exists (select 1 from public.productos p where upper(p.sku) = v_sku) then
    raise exception 'El SKU % ya existe; usa el producto existente en vez de crear otro', v_sku;
  end if;

  -- Mismo criterio que crear_producto_desde_homologacion_v67: si ya existe
  -- un producto activo con el mismo nombre+talla+color, no se duplica.
  v_nombre_normalizado := btrim(regexp_replace(
    translate(lower(v_nombre), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', ' ', 'g'));
  v_talla_normalizada := btrim(regexp_replace(
    translate(lower(coalesce(p_producto->>'talla', '')), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', ' ', 'g'));
  v_color_normalizado := btrim(regexp_replace(
    translate(lower(coalesce(p_producto->>'color', '')), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', ' ', 'g'));
  select * into v_existente
  from public.productos p
  where p.activo
    and btrim(regexp_replace(translate(lower(p.nombre), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', ' ', 'g')) = v_nombre_normalizado
    and btrim(regexp_replace(translate(lower(coalesce(p.talla, '')), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', ' ', 'g')) = v_talla_normalizada
    and btrim(regexp_replace(translate(lower(coalesce(p.color, '')), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', ' ', 'g')) = v_color_normalizado
  limit 1;
  if found then
    raise exception 'Ya existe un producto equivalente con SKU %; usalo en vez de crear otro', v_existente.sku;
  end if;

  insert into public.productos (
    sku, nombre, categoria, categoria_id, subcategoria, subcategoria_id,
    talla, color, stock_minimo, precio
  ) values (
    v_sku, v_nombre, v_categoria_nombre, v_categoria_id,
    v_subcategoria_nombre, v_subcategoria_id,
    nullif(btrim(p_producto->>'talla'), ''), nullif(btrim(p_producto->>'color'), ''),
    0, null
  ) returning id into v_producto_id;

  insert into public.productos_creados_franquicia_v109 (
    producto_id, creado_por, almacen_id, categoria_codigo, entidad_codigo,
    variante_codigo, anio_codigo, talla_codigo, sku, idempotency_key
  ) values (
    v_producto_id, v_uid, v_almacen_id, v_cat, v_ent,
    v_var, v_anio, nullif(v_talla_codigo, ''), v_sku, p_idempotency_key
  );

  -- Alerta a admin/control, mismo patron que v86/v87: un insert por rol,
  -- origen_clave unico, on conflict do nothing (nunca duplica el aviso).
  insert into public.notificaciones_comunicados (
    origen_clave, origen_tipo, almacen_id, rol_destino,
    modulo, nivel, titulo, mensaje, href, creado_por
  )
  select
    'producto_franquicia:' || v_producto_id::text || ':' || r.rol::text,
    'producto_franquicia', v_almacen_id, r.rol,
    'Inventario', 'accion', 'Producto nuevo creado por franquicia',
    'Se creo el producto "' || v_nombre || '" (SKU ' || v_sku || ') desde '
      || coalesce((select a.nombre from public.almacenes a where a.id = v_almacen_id), 'una franquicia')
      || '. Revisalo en Productos.',
    '/productos', v_uid
  from unnest(array['admin', 'control']::public.rol_usuario[]) r(rol)
  on conflict (origen_clave) do nothing;

  return jsonb_build_object('duplicado', false, 'producto_id', v_producto_id, 'sku', v_sku);
end;
$fn$;

-- ------------------------------------------------------------
-- 5. Marcar revisado (solo el checklist de auditoria; no toca el producto)
-- ------------------------------------------------------------
create or replace function public.marcar_revisado_producto_franquicia_v109(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'No tienes permiso para revisar productos de franquicia';
  end if;
  update public.productos_creados_franquicia_v109
  set revisado_at = now(), revisado_por = auth.uid()
  where id = p_id and revisado_at is null;
end;
$fn$;

-- ------------------------------------------------------------
-- 6. RLS y permisos
-- ------------------------------------------------------------
alter table public.productos_creados_franquicia_v109 enable row level security;

drop policy if exists "leer_productos_franquicia_v109" on public.productos_creados_franquicia_v109;
create policy "leer_productos_franquicia_v109" on public.productos_creados_franquicia_v109
for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);

alter table public.productos_creados_franquicia_v109 owner to postgres;
revoke all on public.productos_creados_franquicia_v109 from public, anon;
revoke insert, update, delete on public.productos_creados_franquicia_v109 from authenticated;
grant select on public.productos_creados_franquicia_v109 to authenticated;

alter function public.sku_abreviaturas_disponibles_v109() owner to postgres;
alter function public.crear_producto_franquicia_v109(jsonb, uuid) owner to postgres;
alter function public.marcar_revisado_producto_franquicia_v109(uuid) owner to postgres;

revoke all on function public.sku_abreviaturas_disponibles_v109() from public, anon;
revoke all on function public.crear_producto_franquicia_v109(jsonb, uuid) from public, anon;
revoke all on function public.marcar_revisado_producto_franquicia_v109(uuid) from public, anon;
grant execute on function public.sku_abreviaturas_disponibles_v109() to authenticated;
grant execute on function public.crear_producto_franquicia_v109(jsonb, uuid) to authenticated;
grant execute on function public.marcar_revisado_producto_franquicia_v109(uuid) to authenticated;

comment on function public.crear_producto_franquicia_v109(jsonb, uuid) is
  'Crea un producto con SKU sugerido (BS-IN-PR-03) para roles de franquicia. '
  'Solo usa abreviaturas ya registradas en sku_abreviaturas_v67; alerta a admin/control via notificaciones_comunicados.';

commit;

notify pgrst, 'reload schema';
