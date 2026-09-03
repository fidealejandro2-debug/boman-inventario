-- ============================================================
-- BOMAN INVENTARIO - v67
-- Creacion controlada de productos desde homologacion de compras
-- Basado en BS-IN-PR-03: CAT-ENTIDAD-VAR-ANIO(-TALLA).
-- Ejecutar despues de v66 y antes de verificacion_v67.sql.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.compras_xml_importacion_lineas') is null
     or to_regprocedure('public.usuario_puede_compra_xml_v65(uuid,boolean)') is null then
    raise exception 'Faltan v65-v66. Instalalas y validalas antes de v67';
  end if;
end $$;

create table if not exists public.sku_abreviaturas_v67 (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  tipo text not null check (tipo in ('categoria', 'entidad', 'variante')),
  nombre text not null check (btrim(nombre) <> ''),
  nombre_normalizado text not null check (btrim(nombre_normalizado) <> ''),
  codigo text not null check (codigo ~ '^[A-Z0-9]{3}$'),
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, tipo, nombre_normalizado),
  unique (grupo_id, tipo, codigo)
);

create table if not exists public.productos_sku_creaciones_v67 (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  producto_id uuid not null unique references public.productos(id) on delete restrict,
  importacion_id uuid references public.compras_xml_importaciones(id) on delete restrict,
  importacion_linea_id uuid references public.compras_xml_importacion_lineas(id) on delete restrict,
  categoria_codigo text not null check (categoria_codigo ~ '^[A-Z0-9]{3}$'),
  entidad_codigo text not null check (entidad_codigo ~ '^[A-Z0-9]{3}$'),
  variante_codigo text,
  anio_codigo text,
  talla_codigo text,
  motivo text not null check (length(btrim(motivo)) >= 10),
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

-- Abreviaturas expresamente documentadas en BS-IN-PR-03.
with catalogo(tipo, nombre, nombre_normalizado, codigo) as (
  values
    ('categoria', 'Camiseta', 'camiseta', 'CAM'),
    ('categoria', 'Guante', 'guante', 'GUA'),
    ('categoria', 'Buzo', 'buzo', 'BUZ'),
    ('categoria', 'Contrato', 'contrato', 'CTR'),
    ('entidad', 'Macara', 'macara', 'MAC'),
    ('entidad', 'Manta', 'manta', 'MAN'),
    ('entidad', 'Boman', 'boman', 'BOM'),
    ('entidad', 'Adidas', 'adidas', 'ADS'),
    ('entidad', 'Golty', 'golty', 'GOL'),
    ('variante', 'Principal', 'principal', 'PRI'),
    ('variante', 'Alterna', 'alterna', 'ALT'),
    ('variante', 'Arquero', 'arquero', 'ARQ'),
    ('variante', 'Profesional', 'profesional', 'PRF'),
    ('variante', 'Semi Pro', 'semi pro', 'SEM'),
    ('variante', 'Nacional', 'nacional', 'NAC')
)
insert into public.sku_abreviaturas_v67 (
  grupo_id, tipo, nombre, nombre_normalizado, codigo
)
select g.id, c.tipo, c.nombre, c.nombre_normalizado, c.codigo
from public.grupos_economicos g cross join catalogo c
on conflict do nothing;

create or replace function public.registrar_abreviatura_sku_v67(
  p_grupo_id uuid,
  p_tipo text,
  p_nombre text,
  p_codigo text,
  p_usuario_id uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
  v_nombre text := btrim(coalesce(p_nombre, ''));
  v_normalizado text;
  v_codigo text := upper(btrim(coalesce(p_codigo, '')));
begin
  if p_tipo not in ('categoria', 'entidad', 'variante') then
    raise exception 'Tipo de abreviatura SKU invalido';
  end if;
  if v_nombre = '' then raise exception 'Indica el nombre de cada segmento SKU'; end if;
  if v_codigo !~ '^[A-Z0-9]{3}$' then
    raise exception 'Cada segmento SKU debe tener exactamente 3 letras o numeros';
  end if;
  v_normalizado := lower(regexp_replace(translate(v_nombre,
    'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun'), '[^a-zA-Z0-9]+', ' ', 'g'));
  v_normalizado := btrim(regexp_replace(v_normalizado, '\s+', ' ', 'g'));
  if p_tipo = 'categoria' then
    v_normalizado := regexp_replace(v_normalizado, 's$', '');
  end if;

  select a.id into v_id
  from public.sku_abreviaturas_v67 a
  where a.grupo_id = p_grupo_id and a.tipo = p_tipo
    and a.nombre_normalizado = v_normalizado and a.activo;
  if found then
    if (select codigo from public.sku_abreviaturas_v67 where id = v_id) <> v_codigo then
      raise exception 'La abreviatura de % ya existe y debe reutilizarse', v_nombre;
    end if;
    return v_id;
  end if;
  if exists (
    select 1 from public.sku_abreviaturas_v67 a
    where a.grupo_id = p_grupo_id and a.tipo = p_tipo
      and a.codigo = v_codigo and a.activo
  ) then
    raise exception 'El codigo % ya representa otro valor de %', v_codigo, p_tipo;
  end if;

  insert into public.sku_abreviaturas_v67 (
    grupo_id, tipo, nombre, nombre_normalizado, codigo, creado_por
  ) values (
    p_grupo_id, p_tipo, v_nombre, v_normalizado, v_codigo, p_usuario_id
  ) returning id into v_id;
  return v_id;
end;
$fn$;

create or replace function public.crear_producto_desde_homologacion_v67(
  p_importacion_id uuid,
  p_linea_id uuid,
  p_producto jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_rol text := public.rol_usuario_actual();
  v_import public.compras_xml_importaciones%rowtype;
  v_linea public.compras_xml_importacion_lineas%rowtype;
  v_producto_id uuid;
  v_existente public.productos%rowtype;
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
  v_entidad_nombre text := btrim(coalesce(p_producto->>'entidad_nombre', ''));
  v_variante_nombre text := btrim(coalesce(p_producto->>'variante_nombre', ''));
  v_codigo_proveedor text;
  v_total integer;
  v_homologadas integer;
  v_stock_minimo integer;
  v_precio numeric;
  v_costo_estandar numeric;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion para crear productos'; end if;
  if v_rol <> 'admin' then
    raise exception 'Solo Administracion puede autorizar y crear codigos SKU nuevos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Documenta la autorizacion o motivo con al menos 10 caracteres';
  end if;
  select p.id into v_producto_id
  from public.productos_sku_creaciones_v67 c
  join public.productos p on p.id = c.producto_id
  where c.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('duplicado', true, 'producto_id', v_producto_id);
  end if;

  select * into v_import from public.compras_xml_importaciones
  where id = p_importacion_id for update;
  if not found then raise exception 'La importacion no existe'; end if;
  if not public.usuario_puede_compra_xml_v65(v_import.empresa_id, true) then
    raise exception 'No tienes permiso sobre la empresa receptora';
  end if;
  if v_import.estado in ('procesado', 'descartado') then
    raise exception 'La importacion ya esta cerrada';
  end if;
  select * into v_linea from public.compras_xml_importacion_lineas
  where id = p_linea_id and importacion_id = v_import.id for update;
  if not found then raise exception 'La linea no pertenece al XML seleccionado'; end if;
  v_codigo_proveedor := coalesce(
    nullif(btrim(v_linea.codigo_proveedor), ''),
    nullif(btrim(v_linea.codigo_auxiliar), '')
  );
  if v_codigo_proveedor is null then
    raise exception 'La linea no tiene codigo del proveedor y no puede recordarse automaticamente';
  end if;

  v_categoria_id := nullif(p_producto->>'categoria_id', '')::uuid;
  select c.nombre into v_categoria_nombre
  from public.categorias_productos c
  where c.id = v_categoria_id and c.activo;
  if not found then raise exception 'Selecciona una categoria activa'; end if;
  v_subcategoria_id := nullif(p_producto->>'subcategoria_id', '')::uuid;
  if v_subcategoria_id is not null then
    select s.nombre into v_subcategoria_nombre
    from public.subcategorias_productos s
    where s.id = v_subcategoria_id and s.categoria_id = v_categoria_id and s.activo;
    if not found then raise exception 'La subcategoria no pertenece a la categoria'; end if;
  end if;
  if v_nombre = '' then raise exception 'El nombre del producto es obligatorio'; end if;
  v_nombre_normalizado := btrim(regexp_replace(
    translate(lower(v_nombre), 'áéíóúüñ', 'aeiouun'),
    '[^a-z0-9]+', ' ', 'g'
  ));
  v_talla_normalizada := btrim(regexp_replace(
    translate(lower(coalesce(p_producto->>'talla', '')), 'áéíóúüñ', 'aeiouun'),
    '[^a-z0-9]+', ' ', 'g'
  ));
  v_color_normalizado := btrim(regexp_replace(
    translate(lower(coalesce(p_producto->>'color', '')), 'áéíóúüñ', 'aeiouun'),
    '[^a-z0-9]+', ' ', 'g'
  ));

  perform public.registrar_abreviatura_sku_v67(
    v_import.grupo_id, 'categoria', v_categoria_nombre, v_cat, v_uid
  );
  perform public.registrar_abreviatura_sku_v67(
    v_import.grupo_id, 'entidad', v_entidad_nombre, v_ent, v_uid
  );
  if v_cat = 'CTR' then
    v_sku := 'CTR-' || v_ent || '-UN';
    v_var := null; v_anio := null; v_talla_codigo := null;
  else
    perform public.registrar_abreviatura_sku_v67(
      v_import.grupo_id, 'variante', v_variante_nombre, v_var, v_uid
    );
    if v_anio !~ '^[0-9]{2}$' then raise exception 'El anio SKU debe tener 2 digitos'; end if;
    if v_talla_codigo <> '' and v_talla_codigo !~ '^[A-Z0-9]{1,8}$' then
      raise exception 'La talla SKU solo admite letras o numeros, sin espacios';
    end if;
    v_sku := v_cat || '-' || v_ent || '-' || v_var || '-' || v_anio
      || case when v_talla_codigo = '' then '' else '-' || v_talla_codigo end;
  end if;
  if upper(btrim(coalesce(p_producto->>'sku', ''))) <> v_sku then
    raise exception 'El SKU no coincide con los segmentos autorizados. Debe ser %', v_sku;
  end if;
  if exists (select 1 from public.productos p where upper(p.sku) = v_sku) then
    raise exception 'El SKU % ya existe; reutiliza el producto existente', v_sku;
  end if;
  select * into v_existente
  from public.productos p
  where p.activo
    and btrim(regexp_replace(
      translate(lower(p.nombre), 'áéíóúüñ', 'aeiouun'),
      '[^a-z0-9]+', ' ', 'g'
    )) = v_nombre_normalizado
    and btrim(regexp_replace(
      translate(lower(coalesce(p.talla, '')), 'áéíóúüñ', 'aeiouun'),
      '[^a-z0-9]+', ' ', 'g'
    )) = v_talla_normalizada
    and btrim(regexp_replace(
      translate(lower(coalesce(p.color, '')), 'áéíóúüñ', 'aeiouun'),
      '[^a-z0-9]+', ' ', 'g'
    )) = v_color_normalizado
  limit 1;
  if found then
    raise exception 'Ya existe un producto equivalente con SKU %; revisalo antes de crear otro', v_existente.sku;
  end if;
  if coalesce(p_producto->>'tipo_inventario', '') not in (
    'producto_terminado', 'materia_prima', 'insumo', 'empaque', 'subproducto'
  ) then raise exception 'Selecciona un tipo de inventario valido'; end if;
  if not exists (
    select 1 from public.unidades_medida_produccion u
    where u.codigo = p_producto->>'unidad_medida' and u.activo
  ) then raise exception 'Selecciona una unidad de medida activa'; end if;
  begin
    v_stock_minimo := coalesce(nullif(p_producto->>'stock_minimo', '')::integer, 0);
    v_precio := nullif(p_producto->>'precio', '')::numeric;
    v_costo_estandar := nullif(p_producto->>'costo_estandar', '')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Costo, precio y stock minimo deben contener valores numericos validos';
  end;
  if v_stock_minimo < 0 or coalesce(v_precio, 0) < 0
     or coalesce(v_costo_estandar, 0) < 0 then
    raise exception 'Costo, precio y stock minimo no pueden ser negativos';
  end if;

  insert into public.productos (
    sku, nombre, categoria, categoria_id, subcategoria, subcategoria_id,
    talla, color, stock_minimo, precio, tipo_inventario, unidad_medida,
    costo_estandar, produccion_updated_at, produccion_updated_by
  ) values (
    v_sku, v_nombre, v_categoria_nombre, v_categoria_id,
    v_subcategoria_nombre, v_subcategoria_id,
    nullif(btrim(p_producto->>'talla'), ''),
    nullif(btrim(p_producto->>'color'), ''),
    v_stock_minimo, v_precio,
    p_producto->>'tipo_inventario', p_producto->>'unidad_medida',
    v_costo_estandar, now(), v_uid
  ) returning id into v_producto_id;

  insert into public.productos_sku_creaciones_v67 (
    grupo_id, producto_id, importacion_id, importacion_linea_id,
    categoria_codigo, entidad_codigo, variante_codigo, anio_codigo,
    talla_codigo, motivo, creado_por, idempotency_key
  ) values (
    v_import.grupo_id, v_producto_id, v_import.id, v_linea.id,
    v_cat, v_ent, v_var, v_anio, nullif(v_talla_codigo, ''),
    btrim(p_motivo), v_uid, p_idempotency_key
  );

  update public.compras_xml_importacion_lineas
  set producto_id = v_producto_id, homologacion_origen = 'manual'
  where id = v_linea.id;
  insert into public.proveedor_producto_homologaciones as h (
    grupo_id, proveedor_ruc, codigo_proveedor, producto_id,
    activo, actualizado_por
  ) values (
    v_import.grupo_id, v_import.proveedor_ruc, v_codigo_proveedor,
    v_producto_id, true, v_uid
  ) on conflict (grupo_id, proveedor_ruc, codigo_proveedor) do update set
    producto_id = excluded.producto_id, activo = true,
    actualizado_por = excluded.actualizado_por, updated_at = now();

  select count(*)::integer, count(*) filter (where producto_id is not null)::integer
  into v_total, v_homologadas
  from public.compras_xml_importacion_lineas where importacion_id = v_import.id;
  update public.compras_xml_importaciones
  set lineas_total = v_total, lineas_homologadas = v_homologadas,
      estado = case when proveedor_id is not null and v_total = v_homologadas
        then 'listo' else 'pendiente_homologacion' end,
      nota = btrim(p_motivo), homologado_por = v_uid,
      homologado_at = now(), updated_at = now()
  where id = v_import.id;
  insert into public.compras_xml_eventos (
    importacion_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_import.id, 'homologado', 'Producto creado y homologado: ' || v_sku,
    jsonb_build_object('producto_id', v_producto_id, 'sku', v_sku,
      'linea_id', v_linea.id, 'motivo', btrim(p_motivo)),
    v_uid, p_idempotency_key
  );
  return jsonb_build_object(
    'duplicado', false, 'producto_id', v_producto_id, 'sku', v_sku,
    'estado', case when v_import.proveedor_id is not null and v_total = v_homologadas
      then 'listo' else 'pendiente_homologacion' end
  );
end;
$fn$;

alter table public.sku_abreviaturas_v67 enable row level security;
alter table public.productos_sku_creaciones_v67 enable row level security;

drop policy if exists "leer_abreviaturas_sku_v67" on public.sku_abreviaturas_v67;
create policy "leer_abreviaturas_sku_v67" on public.sku_abreviaturas_v67
for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);
drop policy if exists "leer_creaciones_sku_v67" on public.productos_sku_creaciones_v67;
create policy "leer_creaciones_sku_v67" on public.productos_sku_creaciones_v67
for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);

revoke all on public.sku_abreviaturas_v67 from public, anon;
revoke all on public.productos_sku_creaciones_v67 from public, anon;
revoke insert, update, delete on public.sku_abreviaturas_v67 from authenticated;
revoke insert, update, delete on public.productos_sku_creaciones_v67 from authenticated;
grant select on public.sku_abreviaturas_v67 to authenticated;
grant select on public.productos_sku_creaciones_v67 to authenticated;

alter function public.registrar_abreviatura_sku_v67(uuid,text,text,text,uuid) owner to postgres;
alter function public.crear_producto_desde_homologacion_v67(uuid,uuid,jsonb,text,uuid) owner to postgres;
revoke all on function public.registrar_abreviatura_sku_v67(uuid,text,text,text,uuid) from public, anon, authenticated;
revoke all on function public.crear_producto_desde_homologacion_v67(uuid,uuid,jsonb,text,uuid) from public, anon;
grant execute on function public.crear_producto_desde_homologacion_v67(uuid,uuid,jsonb,text,uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
