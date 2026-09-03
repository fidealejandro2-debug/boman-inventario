-- ============================================================
-- BOMAN INVENTARIO - v65
-- Importacion masiva de XML de compras y homologacion pendiente
-- Ejecutar despues de v64 y antes de verificacion_v65.sql.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.registrar_comprobante_compra_v58(jsonb,jsonb,jsonb,uuid)') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null
     or to_regclass('public.productos') is null then
    raise exception 'Faltan dependencias. Instala y valida hasta v64 antes de v65';
  end if;
end $$;

create table if not exists public.compras_xml_lotes (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  origen text not null check (origen in ('archivos', 'carpeta')),
  archivos_recibidos integer not null check (archivos_recibidos > 0),
  archivos_cargados integer not null default 0 check (archivos_cargados >= 0),
  archivos_duplicados integer not null default 0 check (archivos_duplicados >= 0),
  idempotency_key uuid not null unique,
  cargado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (archivos_cargados + archivos_duplicados <= archivos_recibidos)
);

create table if not exists public.compras_xml_importaciones (
  id uuid primary key default gen_random_uuid(),
  lote_id uuid not null references public.compras_xml_lotes(id) on delete restrict,
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  proveedor_id uuid references public.proveedores(id) on delete restrict,
  proveedor_ruc text not null check (proveedor_ruc ~ '^[0-9]{13}$'),
  proveedor_razon_social text not null check (btrim(proveedor_razon_social) <> ''),
  archivo_nombre text not null check (btrim(archivo_nombre) <> ''),
  archivo_hash text not null check (archivo_hash ~ '^[0-9a-f]{64}$'),
  clave_acceso text not null check (clave_acceso ~ '^[0-9]{49}$'),
  numero_autorizacion text,
  fecha_autorizacion timestamptz,
  establecimiento text not null check (establecimiento ~ '^[0-9]{3}$'),
  punto_emision text not null check (punto_emision ~ '^[0-9]{3}$'),
  secuencial text not null check (secuencial ~ '^[0-9]{9}$'),
  fecha_emision date not null,
  base_cero numeric(14,2) not null default 0 check (base_cero >= 0),
  base_gravada numeric(14,2) not null default 0 check (base_gravada >= 0),
  tarifa_gravada numeric(7,4) not null default 0 check (tarifa_gravada between 0 and 100),
  base_no_objeto numeric(14,2) not null default 0 check (base_no_objeto >= 0),
  base_exenta numeric(14,2) not null default 0 check (base_exenta >= 0),
  monto_iva numeric(14,2) not null default 0 check (monto_iva >= 0),
  monto_ice numeric(14,2) not null default 0 check (monto_ice >= 0),
  propina numeric(14,2) not null default 0 check (propina >= 0),
  total numeric(14,2) not null check (total >= 0),
  forma_pago text,
  estado text not null default 'pendiente_homologacion' check (estado in (
    'pendiente_homologacion', 'listo', 'procesado', 'descartado'
  )),
  lineas_total integer not null default 0 check (lineas_total >= 0),
  lineas_homologadas integer not null default 0 check (
    lineas_homologadas >= 0 and lineas_homologadas <= lineas_total
  ),
  comprobante_id uuid references public.comprobantes_compra(id) on delete restrict,
  nota text,
  cargado_por uuid not null references public.perfiles(id) on delete restrict,
  homologado_por uuid references public.perfiles(id) on delete restrict,
  homologado_at timestamptz,
  procesado_por uuid references public.perfiles(id) on delete restrict,
  procesado_at timestamptz,
  descartado_por uuid references public.perfiles(id) on delete restrict,
  descartado_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, archivo_hash),
  unique (grupo_id, clave_acceso),
  check (
    round(total, 2) = round(
      base_cero + base_gravada + base_no_objeto + base_exenta
      + monto_iva + monto_ice + propina, 2
    )
  ),
  check ((estado = 'procesado') = (comprobante_id is not null))
);

create table if not exists public.compras_xml_importacion_lineas (
  id uuid primary key default gen_random_uuid(),
  importacion_id uuid not null
    references public.compras_xml_importaciones(id) on delete cascade,
  numero_linea integer not null check (numero_linea > 0),
  codigo_proveedor text,
  codigo_auxiliar text,
  descripcion text not null check (btrim(descripcion) <> ''),
  cantidad numeric(14,4) not null check (cantidad > 0),
  precio_unitario numeric(16,4) not null check (precio_unitario >= 0),
  descuento numeric(14,2) not null default 0 check (descuento >= 0),
  subtotal numeric(14,2) not null check (subtotal >= 0),
  tarifa_iva numeric(7,4) not null default 0 check (tarifa_iva between 0 and 100),
  valor_iva numeric(14,2) not null default 0 check (valor_iva >= 0),
  producto_id uuid references public.productos(id) on delete restrict,
  homologacion_origen text check (homologacion_origen in ('guardada', 'manual')),
  unique (importacion_id, numero_linea)
);

create table if not exists public.proveedor_producto_homologaciones (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  proveedor_ruc text not null check (proveedor_ruc ~ '^[0-9]{13}$'),
  codigo_proveedor text not null check (btrim(codigo_proveedor) <> ''),
  producto_id uuid not null references public.productos(id) on delete restrict,
  activo boolean not null default true,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, proveedor_ruc, codigo_proveedor)
);

create table if not exists public.compras_xml_eventos (
  id uuid primary key default gen_random_uuid(),
  importacion_id uuid not null
    references public.compras_xml_importaciones(id) on delete restrict,
  tipo text not null check (tipo in ('cargado', 'homologado', 'procesado', 'descartado')),
  detalle text not null check (btrim(detalle) <> ''),
  datos jsonb not null default '{}'::jsonb,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_compras_xml_estado_v65
  on public.compras_xml_importaciones(estado, created_at desc);
create index if not exists idx_compras_xml_empresa_fecha_v65
  on public.compras_xml_importaciones(empresa_id, fecha_emision desc);
create index if not exists idx_compras_xml_lineas_pendientes_v65
  on public.compras_xml_importacion_lineas(importacion_id)
  where producto_id is null;
create index if not exists idx_homologacion_proveedor_codigo_v65
  on public.proveedor_producto_homologaciones(grupo_id, proveedor_ruc, codigo_proveedor)
  where activo;

create or replace function public.usuario_puede_compra_xml_v65(
  p_empresa_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and public.usuario_tiene_permiso_v35('compras.acceder')
    and public.usuario_puede_empresa(p_empresa_id, p_escritura);
$$;

create or replace function public.cargar_xml_compras_v65(
  p_archivos jsonb,
  p_origen text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_rol text := public.rol_usuario_actual();
  v_lote public.compras_xml_lotes%rowtype;
  v_archivo jsonb;
  v_comp jsonb;
  v_importacion_id uuid;
  v_empresa public.empresas%rowtype;
  v_proveedor_id uuid;
  v_recibidos integer;
  v_cargados integer := 0;
  v_duplicados integer := 0;
  v_listos integer := 0;
  v_pendientes integer := 0;
  v_lineas integer;
  v_homologadas integer;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion para importar compras'; end if;
  if v_rol not in ('admin', 'control', 'gerencia') then
    raise exception 'Solo Administracion, Control o Gerencia pueden importar XML de compras';
  end if;
  if not public.usuario_tiene_permiso_v35('compras.acceder') then
    raise exception 'No tienes permiso para acceder a Compras';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if p_origen not in ('archivos', 'carpeta') then raise exception 'Origen de carga invalido'; end if;
  if jsonb_typeof(coalesce(p_archivos, 'null'::jsonb)) <> 'array' then
    raise exception 'La carga debe contener una lista de archivos';
  end if;
  v_recibidos := jsonb_array_length(p_archivos);
  if v_recibidos < 1 or v_recibidos > 200 then
    raise exception 'Selecciona entre 1 y 200 XML por lote';
  end if;

  select * into v_lote from public.compras_xml_lotes
  where idempotency_key = p_idempotency_key;
  if found then
    select
      count(*) filter (where estado = 'listo')::integer,
      count(*) filter (where estado = 'pendiente_homologacion')::integer
    into v_listos, v_pendientes
    from public.compras_xml_importaciones where lote_id = v_lote.id;
    return jsonb_build_object(
      'lote_id', v_lote.id, 'duplicado', true,
      'recibidos', v_lote.archivos_recibidos,
      'cargados', v_lote.archivos_cargados,
      'duplicados', v_lote.archivos_duplicados,
      'listos', v_listos,
      'pendientes_homologacion', v_pendientes
    );
  end if;

  -- El grupo se fija con el primer receptor valido y cada archivo posterior
  -- tiene que pertenecer al mismo grupo economico.
  v_comp := p_archivos->0->'comprobante';
  select e.* into v_empresa from public.empresas e
  where e.ruc = regexp_replace(coalesce(v_comp->>'comprador_ruc', ''), '[^0-9]', '', 'g')
    and e.activo;
  if not found or not public.usuario_puede_compra_xml_v65(v_empresa.id, true) then
    raise exception 'El RUC receptor del primer XML no corresponde a una empresa que puedas operar';
  end if;

  insert into public.compras_xml_lotes (
    grupo_id, origen, archivos_recibidos, idempotency_key, cargado_por
  ) values (
    v_empresa.grupo_id, p_origen, v_recibidos, p_idempotency_key, v_uid
  ) returning * into v_lote;

  for v_archivo in select value from jsonb_array_elements(p_archivos)
  loop
    v_comp := v_archivo->'comprobante';
    select e.* into v_empresa from public.empresas e
    where e.ruc = regexp_replace(coalesce(v_comp->>'comprador_ruc', ''), '[^0-9]', '', 'g')
      and e.activo;
    if not found or v_empresa.grupo_id <> v_lote.grupo_id
       or not public.usuario_puede_compra_xml_v65(v_empresa.id, true) then
      raise exception 'El XML % tiene un RUC receptor desconocido o sin permiso', v_archivo->>'archivo_nombre';
    end if;
    if coalesce(v_archivo->>'archivo_hash', '') !~ '^[0-9a-f]{64}$'
       or coalesce(v_comp->>'clave_acceso', '') !~ '^[0-9]{49}$'
       or coalesce(v_comp->>'proveedor_ruc', '') !~ '^[0-9]{13}$'
       or coalesce(v_comp->>'establecimiento', '') !~ '^[0-9]{3}$'
       or coalesce(v_comp->>'punto_emision', '') !~ '^[0-9]{3}$'
       or coalesce(v_comp->>'secuencial', '') !~ '^[0-9]{9}$' then
      raise exception 'El XML % no contiene identificadores tributarios validos', v_archivo->>'archivo_nombre';
    end if;
    if jsonb_typeof(v_archivo->'lineas') <> 'array'
       or jsonb_array_length(v_archivo->'lineas') = 0 then
      raise exception 'El XML % no contiene lineas de compra', v_archivo->>'archivo_nombre';
    end if;

    select p.id into v_proveedor_id
    from public.proveedores p
    where p.grupo_id = v_lote.grupo_id
      and p.identificacion = v_comp->>'proveedor_ruc' and p.activo
    limit 1;

    v_importacion_id := null;
    insert into public.compras_xml_importaciones (
      lote_id, grupo_id, empresa_id, proveedor_id, proveedor_ruc,
      proveedor_razon_social, archivo_nombre, archivo_hash, clave_acceso,
      numero_autorizacion, fecha_autorizacion, establecimiento, punto_emision,
      secuencial, fecha_emision, base_cero, base_gravada, tarifa_gravada,
      base_no_objeto, base_exenta, monto_iva, monto_ice, propina, total,
      forma_pago, cargado_por
    ) values (
      v_lote.id, v_lote.grupo_id, v_empresa.id, v_proveedor_id,
      v_comp->>'proveedor_ruc', v_comp->>'proveedor_razon_social',
      v_archivo->>'archivo_nombre', v_archivo->>'archivo_hash',
      v_comp->>'clave_acceso', nullif(v_archivo->>'numero_autorizacion', ''),
      nullif(v_archivo->>'fecha_autorizacion', '')::timestamptz,
      v_comp->>'establecimiento', v_comp->>'punto_emision', v_comp->>'secuencial',
      (v_comp->>'fecha_emision')::date,
      coalesce((v_comp->>'base_cero')::numeric, 0),
      coalesce((v_comp->>'base_gravada')::numeric, 0),
      coalesce((v_comp->>'tarifa_gravada')::numeric, 0),
      coalesce((v_comp->>'base_no_objeto')::numeric, 0),
      coalesce((v_comp->>'base_exenta')::numeric, 0),
      coalesce((v_comp->>'monto_iva')::numeric, 0),
      coalesce((v_comp->>'monto_ice')::numeric, 0),
      coalesce((v_comp->>'propina')::numeric, 0),
      (v_comp->>'total')::numeric, nullif(v_comp->>'forma_pago', ''), v_uid
    ) on conflict do nothing
    returning id into v_importacion_id;

    if v_importacion_id is null then
      v_duplicados := v_duplicados + 1;
      continue;
    end if;

    insert into public.compras_xml_importacion_lineas (
      importacion_id, numero_linea, codigo_proveedor, codigo_auxiliar,
      descripcion, cantidad, precio_unitario, descuento, subtotal,
      tarifa_iva, valor_iva, producto_id, homologacion_origen
    )
    select
      v_importacion_id, x.numero_linea, nullif(btrim(x.codigo_proveedor), ''),
      nullif(btrim(x.codigo_auxiliar), ''), x.descripcion, x.cantidad,
      x.precio_unitario, coalesce(x.descuento, 0), x.subtotal,
      coalesce(x.tarifa_iva, 0), coalesce(x.valor_iva, 0), h.producto_id,
      case when h.producto_id is null then null else 'guardada' end
    from jsonb_to_recordset(v_archivo->'lineas') x(
      numero_linea integer, codigo_proveedor text, codigo_auxiliar text,
      descripcion text, cantidad numeric, precio_unitario numeric,
      descuento numeric, subtotal numeric, tarifa_iva numeric, valor_iva numeric
    )
    left join public.proveedor_producto_homologaciones h
      on h.grupo_id = v_lote.grupo_id and h.activo
     and h.proveedor_ruc = v_comp->>'proveedor_ruc'
     and h.codigo_proveedor = coalesce(nullif(btrim(x.codigo_proveedor), ''), nullif(btrim(x.codigo_auxiliar), ''));

    select count(*)::integer, count(*) filter (where producto_id is not null)::integer
    into v_lineas, v_homologadas
    from public.compras_xml_importacion_lineas where importacion_id = v_importacion_id;

    update public.compras_xml_importaciones
    set lineas_total = v_lineas,
        lineas_homologadas = v_homologadas,
        estado = case when v_proveedor_id is not null and v_lineas = v_homologadas
          then 'listo' else 'pendiente_homologacion' end,
        updated_at = now()
    where id = v_importacion_id;

    insert into public.compras_xml_eventos (
      importacion_id, tipo, detalle, datos, usuario_id, idempotency_key
    ) values (
      v_importacion_id, 'cargado', 'XML cargado en la bandeja de homologacion',
      jsonb_build_object('archivo', v_archivo->>'archivo_nombre', 'lineas', v_lineas),
      v_uid, gen_random_uuid()
    );
    v_cargados := v_cargados + 1;
    if v_proveedor_id is not null and v_lineas = v_homologadas then
      v_listos := v_listos + 1;
    else
      v_pendientes := v_pendientes + 1;
    end if;
  end loop;

  update public.compras_xml_lotes
  set archivos_cargados = v_cargados, archivos_duplicados = v_duplicados
  where id = v_lote.id;

  return jsonb_build_object(
    'lote_id', v_lote.id, 'duplicado', false, 'recibidos', v_recibidos,
    'cargados', v_cargados, 'duplicados', v_duplicados,
    'listos', v_listos, 'pendientes_homologacion', v_pendientes
  );
end;
$fn$;

create or replace function public.homologar_lineas_compra_xml_v65(
  p_importacion_id uuid,
  p_lineas jsonb,
  p_nota text,
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
  v_item jsonb;
  v_linea public.compras_xml_importacion_lineas%rowtype;
  v_producto uuid;
  v_total integer;
  v_homologadas integer;
  v_proveedor uuid;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion para homologar compras'; end if;
  if v_rol not in ('admin', 'control', 'gerencia') then
    raise exception 'Solo Administracion, Control o Gerencia pueden homologar compras';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'Indica una nota de homologacion de al menos 5 caracteres';
  end if;
  if exists (select 1 from public.compras_xml_eventos where idempotency_key = p_idempotency_key) then
    select lineas_total, lineas_homologadas into v_total, v_homologadas
    from public.compras_xml_importaciones where id = p_importacion_id;
    return jsonb_build_object('duplicado', true, 'total', v_total, 'homologadas', v_homologadas);
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
  if jsonb_typeof(coalesce(p_lineas, '[]'::jsonb)) <> 'array' then
    raise exception 'Las homologaciones deben enviarse como una lista';
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_lineas, '[]'::jsonb))
  loop
    v_producto := nullif(v_item->>'producto_id', '')::uuid;
    select * into v_linea from public.compras_xml_importacion_lineas
    where id = nullif(v_item->>'linea_id', '')::uuid
      and importacion_id = v_import.id for update;
    if not found then raise exception 'Una linea no pertenece al XML seleccionado'; end if;
    if v_producto is null or not exists (
      select 1 from public.productos p where p.id = v_producto and p.activo
    ) then
      raise exception 'Selecciona un producto activo para cada linea enviada';
    end if;
    update public.compras_xml_importacion_lineas
    set producto_id = v_producto, homologacion_origen = 'manual'
    where id = v_linea.id;

    if coalesce((v_item->>'recordar')::boolean, true)
       and coalesce(v_linea.codigo_proveedor, v_linea.codigo_auxiliar) is not null then
      insert into public.proveedor_producto_homologaciones as h (
        grupo_id, proveedor_ruc, codigo_proveedor, producto_id,
        activo, actualizado_por
      ) values (
        v_import.grupo_id, v_import.proveedor_ruc,
        coalesce(v_linea.codigo_proveedor, v_linea.codigo_auxiliar),
        v_producto, true, v_uid
      ) on conflict (grupo_id, proveedor_ruc, codigo_proveedor) do update set
        producto_id = excluded.producto_id, activo = true,
        actualizado_por = excluded.actualizado_por, updated_at = now();
    end if;
  end loop;

  select p.id into v_proveedor from public.proveedores p
  where p.grupo_id = v_import.grupo_id
    and p.identificacion = v_import.proveedor_ruc and p.activo
  limit 1;
  select count(*)::integer, count(*) filter (where producto_id is not null)::integer
  into v_total, v_homologadas
  from public.compras_xml_importacion_lineas where importacion_id = v_import.id;

  update public.compras_xml_importaciones
  set proveedor_id = v_proveedor, lineas_total = v_total,
      lineas_homologadas = v_homologadas,
      estado = case when v_proveedor is not null and v_total = v_homologadas
        then 'listo' else 'pendiente_homologacion' end,
      nota = btrim(p_nota), homologado_por = v_uid,
      homologado_at = now(), updated_at = now()
  where id = v_import.id;

  insert into public.compras_xml_eventos (
    importacion_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_import.id, 'homologado', btrim(p_nota),
    jsonb_build_object('total', v_total, 'homologadas', v_homologadas,
      'proveedor_encontrado', v_proveedor is not null),
    v_uid, p_idempotency_key
  );
  return jsonb_build_object(
    'duplicado', false, 'total', v_total, 'homologadas', v_homologadas,
    'proveedor_encontrado', v_proveedor is not null,
    'estado', case when v_proveedor is not null and v_total = v_homologadas
      then 'listo' else 'pendiente_homologacion' end
  );
end;
$fn$;

create or replace function public.procesar_compra_xml_v65(
  p_importacion_id uuid,
  p_sustento_codigo text,
  p_nota text,
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
  v_resultado jsonb;
  v_lineas jsonb;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion para registrar la compra'; end if;
  if v_rol not in ('admin', 'control', 'gerencia') then
    raise exception 'Solo Administracion, Control o Gerencia pueden registrar comprobantes';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'Indica una nota de registro de al menos 5 caracteres';
  end if;
  select * into v_import from public.compras_xml_importaciones
  where id = p_importacion_id for update;
  if not found then raise exception 'La importacion no existe'; end if;
  if not public.usuario_puede_compra_xml_v65(v_import.empresa_id, true) then
    raise exception 'No tienes permiso sobre la empresa receptora';
  end if;
  if v_import.estado = 'procesado' then
    return jsonb_build_object('duplicado', true, 'comprobante_id', v_import.comprobante_id);
  end if;
  if v_import.estado <> 'listo' or v_import.proveedor_id is null
     or v_import.lineas_homologadas <> v_import.lineas_total then
    raise exception 'Homologa todas las lineas y el proveedor antes de registrar el comprobante';
  end if;
  if not exists (
    select 1 from public.sustentos_tributarios s
    where s.codigo = p_sustento_codigo and s.activo
  ) then
    raise exception 'Selecciona un sustento tributario activo';
  end if;

  select jsonb_agg(jsonb_build_object(
    'numero_linea', l.numero_linea,
    'codigo_proveedor', l.codigo_proveedor,
    'descripcion', l.descripcion,
    'cantidad', l.cantidad,
    'precio_unitario', l.precio_unitario,
    'descuento', l.descuento,
    'subtotal', l.subtotal,
    'tarifa_iva', l.tarifa_iva,
    'valor_iva', l.valor_iva,
    'producto_id', l.producto_id
  ) order by l.numero_linea) into v_lineas
  from public.compras_xml_importacion_lineas l
  where l.importacion_id = v_import.id;

  select public.registrar_comprobante_compra_v58(
    jsonb_build_object(
      'empresa_id', v_import.empresa_id,
      'proveedor_id', v_import.proveedor_id,
      'tipo', 'factura',
      'establecimiento', v_import.establecimiento,
      'punto_emision', v_import.punto_emision,
      'secuencial', v_import.secuencial,
      'clave_acceso', v_import.clave_acceso,
      'numero_autorizacion', v_import.numero_autorizacion,
      'fecha_emision', v_import.fecha_emision,
      'fecha_autorizacion', v_import.fecha_autorizacion,
      'sustento_codigo', p_sustento_codigo,
      'base_cero', v_import.base_cero,
      'base_gravada', v_import.base_gravada,
      'tarifa_gravada', v_import.tarifa_gravada,
      'base_no_objeto', v_import.base_no_objeto,
      'base_exenta', v_import.base_exenta,
      'monto_iva', v_import.monto_iva,
      'monto_ice', v_import.monto_ice,
      'propina', v_import.propina,
      'total', v_import.total,
      'forma_pago', v_import.forma_pago,
      'nota', btrim(p_nota),
      'archivo_nombre', v_import.archivo_nombre,
      'archivo_hash', v_import.archivo_hash
    ), v_lineas, '[]'::jsonb, v_import.id
  ) into v_resultado;

  update public.compras_xml_importaciones
  set estado = 'procesado', comprobante_id = (v_resultado->>'id')::uuid,
      nota = btrim(p_nota), procesado_por = v_uid, procesado_at = now(),
      updated_at = now()
  where id = v_import.id;

  insert into public.compras_xml_eventos (
    importacion_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_import.id, 'procesado', btrim(p_nota), v_resultado, v_uid, p_idempotency_key
  ) on conflict (idempotency_key) do nothing;
  return v_resultado || jsonb_build_object('importacion_id', v_import.id);
end;
$fn$;

create or replace function public.descartar_compra_xml_v65(
  p_importacion_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_import public.compras_xml_importaciones%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden descartar XML';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Indica un motivo de al menos 10 caracteres';
  end if;
  if exists (select 1 from public.compras_xml_eventos where idempotency_key = p_idempotency_key) then
    return;
  end if;
  select * into v_import from public.compras_xml_importaciones
  where id = p_importacion_id for update;
  if not found then raise exception 'La importacion no existe'; end if;
  if not public.usuario_puede_compra_xml_v65(v_import.empresa_id, true) then
    raise exception 'No tienes permiso sobre la empresa receptora';
  end if;
  if v_import.estado = 'procesado' then raise exception 'Un comprobante registrado no se descarta desde la bandeja'; end if;
  update public.compras_xml_importaciones
  set estado = 'descartado', nota = btrim(p_motivo), descartado_por = v_uid,
      descartado_at = now(), updated_at = now()
  where id = v_import.id;
  insert into public.compras_xml_eventos (
    importacion_id, tipo, detalle, usuario_id, idempotency_key
  ) values (v_import.id, 'descartado', btrim(p_motivo), v_uid, p_idempotency_key);
end;
$fn$;

create or replace view public.vista_compras_xml_pendientes_v65
with (security_invoker = true) as
select
  i.id, i.lote_id, i.empresa_id, e.codigo as empresa_codigo,
  e.razon_social as empresa, i.proveedor_id, i.proveedor_ruc,
  i.proveedor_razon_social, i.archivo_nombre, i.clave_acceso,
  i.establecimiento || '-' || i.punto_emision || '-' || i.secuencial as numero_documento,
  i.fecha_emision, i.total, i.estado, i.lineas_total,
  i.lineas_homologadas, i.lineas_total - i.lineas_homologadas as lineas_pendientes,
  i.comprobante_id, i.nota, i.created_at, i.updated_at
from public.compras_xml_importaciones i
join public.empresas e on e.id = i.empresa_id;

alter table public.compras_xml_lotes enable row level security;
alter table public.compras_xml_importaciones enable row level security;
alter table public.compras_xml_importacion_lineas enable row level security;
alter table public.proveedor_producto_homologaciones enable row level security;
alter table public.compras_xml_eventos enable row level security;

drop policy if exists "leer_lotes_compras_xml_v65" on public.compras_xml_lotes;
create policy "leer_lotes_compras_xml_v65" on public.compras_xml_lotes
for select to authenticated using (
  exists (
    select 1 from public.empresas e
    where e.grupo_id = compras_xml_lotes.grupo_id
      and public.usuario_puede_compra_xml_v65(e.id, false)
  )
);

drop policy if exists "leer_importaciones_compras_xml_v65" on public.compras_xml_importaciones;
create policy "leer_importaciones_compras_xml_v65" on public.compras_xml_importaciones
for select to authenticated using (
  public.usuario_puede_compra_xml_v65(empresa_id, false)
);

drop policy if exists "leer_lineas_compras_xml_v65" on public.compras_xml_importacion_lineas;
create policy "leer_lineas_compras_xml_v65" on public.compras_xml_importacion_lineas
for select to authenticated using (
  exists (
    select 1 from public.compras_xml_importaciones i
    where i.id = importacion_id
      and public.usuario_puede_compra_xml_v65(i.empresa_id, false)
  )
);

drop policy if exists "leer_homologaciones_compras_xml_v65" on public.proveedor_producto_homologaciones;
create policy "leer_homologaciones_compras_xml_v65" on public.proveedor_producto_homologaciones
for select to authenticated using (
  exists (
    select 1 from public.empresas e
    where e.grupo_id = proveedor_producto_homologaciones.grupo_id
      and public.usuario_puede_compra_xml_v65(e.id, false)
  )
);

drop policy if exists "leer_eventos_compras_xml_v65" on public.compras_xml_eventos;
create policy "leer_eventos_compras_xml_v65" on public.compras_xml_eventos
for select to authenticated using (
  exists (
    select 1 from public.compras_xml_importaciones i
    where i.id = importacion_id
      and public.usuario_puede_compra_xml_v65(i.empresa_id, false)
  )
);

revoke all on public.compras_xml_lotes from public, anon;
revoke all on public.compras_xml_importaciones from public, anon;
revoke all on public.compras_xml_importacion_lineas from public, anon;
revoke all on public.proveedor_producto_homologaciones from public, anon;
revoke all on public.compras_xml_eventos from public, anon;
revoke insert, update, delete on public.compras_xml_lotes from authenticated;
revoke insert, update, delete on public.compras_xml_importaciones from authenticated;
revoke insert, update, delete on public.compras_xml_importacion_lineas from authenticated;
revoke insert, update, delete on public.proveedor_producto_homologaciones from authenticated;
revoke insert, update, delete on public.compras_xml_eventos from authenticated;
grant select on public.compras_xml_lotes to authenticated;
grant select on public.compras_xml_importaciones to authenticated;
grant select on public.compras_xml_importacion_lineas to authenticated;
grant select on public.proveedor_producto_homologaciones to authenticated;
grant select on public.compras_xml_eventos to authenticated;

revoke all on public.vista_compras_xml_pendientes_v65 from public, anon;
grant select on public.vista_compras_xml_pendientes_v65 to authenticated;

alter function public.usuario_puede_compra_xml_v65(uuid,boolean) owner to postgres;
alter function public.cargar_xml_compras_v65(jsonb,text,uuid) owner to postgres;
alter function public.homologar_lineas_compra_xml_v65(uuid,jsonb,text,uuid) owner to postgres;
alter function public.procesar_compra_xml_v65(uuid,text,text,uuid) owner to postgres;
alter function public.descartar_compra_xml_v65(uuid,text,uuid) owner to postgres;
revoke execute on function public.usuario_puede_compra_xml_v65(uuid,boolean) from public, anon;
revoke execute on function public.cargar_xml_compras_v65(jsonb,text,uuid) from public, anon;
revoke execute on function public.homologar_lineas_compra_xml_v65(uuid,jsonb,text,uuid) from public, anon;
revoke execute on function public.procesar_compra_xml_v65(uuid,text,text,uuid) from public, anon;
revoke execute on function public.descartar_compra_xml_v65(uuid,text,uuid) from public, anon;
grant execute on function public.usuario_puede_compra_xml_v65(uuid,boolean) to authenticated;
grant execute on function public.cargar_xml_compras_v65(jsonb,text,uuid) to authenticated;
grant execute on function public.homologar_lineas_compra_xml_v65(uuid,jsonb,text,uuid) to authenticated;
grant execute on function public.procesar_compra_xml_v65(uuid,text,text,uuid) to authenticated;
grant execute on function public.descartar_compra_xml_v65(uuid,text,uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
