-- ============================================================
-- v148 - Venta rápida para tiendas propias, con comprobante obligatorio
-- en transferencias y reconciliación contra la factura XML real.
--
-- Por qué existe (no reusa ventas_franquicia/registrar_venta_franquicia_v143):
-- esas tablas y esa RPC están llavadas por franquicia_id y exigen rol
-- 'franquiciado'/'vendedor_franquicia' vía franquicia_usuario_actual_v42(),
-- que a su vez exige una fila en public.franquicias. Una tienda propia
-- (almacen tipo='tienda' SIN fila en franquicias, ver v71) no puede pasar
-- por ahí. Se reusa en cambio almacen_caja_operativo_v71() (v71) y
-- registrar_caja_franquicia_v42() (v83) -ya generalizados a almacen_id- en
-- vez de reinventar la resolución de identidad.
--
-- Por qué NO toca inventario: una venta rápida es solo un registro de caja.
-- El único movimiento de stock real sigue siendo el de la factura XML
-- cuando se aplica vía /ventas (aplicar_factura_venta_xml_operativa_v46).
-- Si la venta rápida también descontara stock, y luego la misma venta se
-- factura por XML, el producto se restaría dos veces. Por eso
-- vincular_venta_rapida_factura_v148 solo marca un cruce contable/fiscal,
-- nunca toca movimientos ni inventario.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v148', 0));

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta v134: no existe el registro formal de migraciones';
  end if;
  if to_regprocedure('public.almacen_caja_operativo_v71()') is null then
    raise exception 'Falta v71: instala primero la caja generalizada de tiendas propias';
  end if;
  if to_regprocedure('public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid,uuid)') is null then
    raise exception 'Falta v83: instala primero registrar_caja_franquicia_v42 con p_almacen_id';
  end if;
  if to_regclass('public.documentos_venta_xml') is null then
    raise exception 'Falta v13: instala primero documentos_venta_xml';
  end if;
end;
$requisitos$;

-- ------------------------------------------------------------
-- 1. Tablas
-- ------------------------------------------------------------
create table if not exists public.venta_rapida_v148 (
  id uuid primary key default gen_random_uuid(),
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  franquicia_id uuid references public.franquicias(id) on delete restrict,
  numero integer not null check (numero > 0),
  fecha date not null,
  concepto text not null check (btrim(concepto) <> ''),
  subtotal numeric(14,2) not null check (subtotal >= 0),
  descuento numeric(14,2) not null default 0 check (descuento >= 0),
  total numeric(14,2) not null check (total > 0),
  estado text not null default 'registrada' check (estado in (
    'registrada', 'vinculada_factura', 'sin_factura', 'anulada'
  )),
  documento_venta_xml_id uuid references public.documentos_venta_xml(id) on delete set null,
  motivo_sin_factura text,
  nota text,
  idempotency_key uuid not null unique,
  creada_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  anulada_por uuid references public.perfiles(id) on delete restrict,
  anulada_at timestamptz,
  motivo_anulacion text,
  unique (almacen_id, numero),
  unique (documento_venta_xml_id),
  check (total = round(subtotal - descuento, 2))
);

create index if not exists idx_venta_rapida_v148_almacen
  on public.venta_rapida_v148(almacen_id, fecha desc, numero desc);

create table if not exists public.venta_rapida_lineas_v148 (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references public.venta_rapida_v148(id) on delete cascade,
  producto_id uuid references public.productos(id) on delete restrict,
  descripcion text not null check (btrim(descripcion) <> ''),
  cantidad numeric(12,2) not null check (cantidad > 0),
  precio_unitario numeric(14,2) not null check (precio_unitario >= 0),
  total numeric(14,2) not null check (total >= 0),
  check (total = round(cantidad * precio_unitario, 2))
);

create index if not exists idx_venta_rapida_lineas_v148_venta
  on public.venta_rapida_lineas_v148(venta_id);

create table if not exists public.venta_rapida_pagos_v148 (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references public.venta_rapida_v148(id) on delete cascade,
  numero integer not null check (numero > 0),
  medio_pago text not null check (medio_pago in ('efectivo', 'transferencia', 'tarjeta', 'otro')),
  monto numeric(14,2) not null check (monto > 0),
  referencia text,
  comprobante_storage_path text,
  comprobante_nombre text,
  comprobante_mime_type text,
  comprobante_tamano_bytes bigint,
  movimiento_caja_id uuid references public.franquicia_caja_movimientos(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (venta_id, numero)
);

create unique index if not exists uq_venta_rapida_pago_comprobante_path_v148
  on public.venta_rapida_pagos_v148(comprobante_storage_path)
  where comprobante_storage_path is not null;

create table if not exists public.venta_comprobantes_pendientes_v148 (
  id uuid primary key,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  creado_por uuid not null references public.perfiles(id) on delete cascade,
  storage_path text not null unique check (btrim(storage_path) <> ''),
  nombre_archivo text not null check (btrim(nombre_archivo) <> ''),
  mime_type text not null check (mime_type in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  )),
  tamano_bytes bigint not null check (tamano_bytes between 1 and 8388608),
  usado_en uuid references public.venta_rapida_pagos_v148(id) on delete set null,
  vence_en timestamptz not null default now() + interval '24 hours',
  created_at timestamptz not null default now()
);

create index if not exists idx_venta_comprobantes_pendientes_v148_usuario
  on public.venta_comprobantes_pendientes_v148(creado_por, vence_en desc)
  where usado_en is null;

-- ------------------------------------------------------------
-- 2. Bucket de Storage (privado, mismo límite que caja-comprobantes v138)
-- ------------------------------------------------------------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'ventas-comprobantes', 'ventas-comprobantes', false, 8388608,
  array['image/jpeg','image/png','image/webp','application/pdf']::text[]
)
on conflict(id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
-- 3. Permiso: role 'tienda' necesita 'franquicia.ventas' (hoy solo lo
--    tienen franquiciado/vendedor_franquicia -v42 líneas 80-91).
-- ------------------------------------------------------------
insert into public.rol_permisos(rol, permiso_codigo, permitido)
values ('tienda', 'franquicia.ventas', true)
on conflict (rol, permiso_codigo) do update set permitido = true, updated_at = now();

-- ------------------------------------------------------------
-- 4. Comprobantes: prepare -> upload -> consumir (mismo patrón que v138)
-- ------------------------------------------------------------
create or replace function public.preparar_comprobante_venta_v148(
  p_almacen_id uuid,
  p_nombre_archivo text,
  p_mime_type text,
  p_tamano_bytes bigint,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $v148$
declare
  v_uid uuid := auth.uid();
  v_rol text := public.rol_usuario_actual();
  v_ext text;
  v_path text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if not exists (select 1 from public.almacenes a where a.id = p_almacen_id and a.activo) then
    raise exception 'El almacen indicado no existe o esta inactivo';
  end if;
  if v_rol <> 'admin' and (
    not public.usuario_tiene_permiso_v35('franquicia.ventas')
    or not public.usuario_puede_almacen(p_almacen_id, true)
  ) then
    raise exception 'No tienes permiso para adjuntar comprobantes en este local';
  end if;
  if lower(coalesce(p_mime_type, '')) not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) then
    raise exception 'Usa una foto JPG, PNG o WebP, o un comprobante PDF';
  end if;
  if p_tamano_bytes is null or p_tamano_bytes not between 1 and 8388608 then
    raise exception 'El comprobante debe pesar entre 1 byte y 8 MB';
  end if;

  v_ext := case lower(p_mime_type)
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'application/pdf' then 'pdf'
    else 'jpg'
  end;
  v_path := p_almacen_id::text || '/' || v_uid::text || '/'
    || p_idempotency_key::text || '.' || v_ext;

  insert into public.venta_comprobantes_pendientes_v148(
    id, almacen_id, creado_por, storage_path,
    nombre_archivo, mime_type, tamano_bytes
  ) values (
    p_idempotency_key, p_almacen_id, v_uid, v_path,
    left(btrim(coalesce(nullif(p_nombre_archivo, ''), 'comprobante')), 255),
    lower(p_mime_type), p_tamano_bytes
  ) on conflict(id) do nothing;

  select storage_path into v_path
  from public.venta_comprobantes_pendientes_v148
  where id = p_idempotency_key and creado_por = v_uid
    and almacen_id = p_almacen_id and usado_en is null and vence_en > now();
  if v_path is null then raise exception 'La clave del comprobante ya fue utilizada'; end if;
  return jsonb_build_object('id', p_idempotency_key, 'path', v_path);
end;
$v148$;

create or replace function public.puede_subir_comprobante_venta_v148(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $v148$
  select exists (
    select 1 from public.venta_comprobantes_pendientes_v148 p
    where p.storage_path = p_path and p.creado_por = auth.uid()
      and p.usado_en is null and p.vence_en > now()
  );
$v148$;

-- Nota: v150 vuelve a definir esta función para sumar la lectura de quien
-- tenga el permiso 'franquicia.comprobantes.auditar_todo' (ese permiso
-- todavia no existe en esta migración).
create or replace function public.puede_leer_comprobante_venta_v148(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $v148$
  select exists (
    select 1 from public.venta_comprobantes_pendientes_v148 p
    where p.storage_path = p_path and p.creado_por = auth.uid()
      and p.usado_en is null and p.vence_en > now()
  ) or exists (
    select 1 from public.venta_rapida_pagos_v148 vp
    join public.venta_rapida_v148 v on v.id = vp.venta_id
    where vp.comprobante_storage_path = p_path
      and public.usuario_puede_almacen(v.almacen_id, false)
  );
$v148$;

drop policy if exists "subir_comprobante_venta_v148" on storage.objects;
create policy "subir_comprobante_venta_v148"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'ventas-comprobantes'
  and public.puede_subir_comprobante_venta_v148(name)
);

drop policy if exists "leer_comprobante_venta_v148" on storage.objects;
create policy "leer_comprobante_venta_v148"
on storage.objects for select to authenticated
using (
  bucket_id = 'ventas-comprobantes'
  and public.puede_leer_comprobante_venta_v148(name)
);

-- ------------------------------------------------------------
-- 5. Registrar venta rápida
-- ------------------------------------------------------------
create or replace function public.registrar_venta_rapida_v148(
  p_fecha date,
  p_concepto text,
  p_items jsonb,
  p_pagos jsonb,
  p_descuento numeric,
  p_nota text,
  p_idempotency_key uuid,
  p_almacen_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $v148$
declare
  v_rol text := public.rol_usuario_actual();
  v_almacen_id uuid;
  v_franquicia_id uuid;
  v_venta uuid;
  v_numero integer;
  v_subtotal numeric(14,2);
  v_descuento numeric(14,2) := round(coalesce(p_descuento, 0), 2);
  v_total numeric(14,2);
  v_linea record;
  v_pago record;
  v_pago_numero integer;
  v_pago_id uuid;
  v_movimiento uuid;
  v_comprobante public.venta_comprobantes_pendientes_v148%rowtype;
begin
  if v_rol in ('tienda', 'franquiciado') and public.usuario_tiene_permiso_v35('franquicia.ventas') then
    select o.almacen_id, o.franquicia_id into v_almacen_id, v_franquicia_id
    from public.almacen_caja_operativo_v71() o;
    if v_almacen_id is null then raise exception 'No tienes un local activo asignado para vender'; end if;
  elsif v_rol = 'admin' then
    if p_almacen_id is null then raise exception 'Indica a que local pertenece la venta'; end if;
    if not exists (select 1 from public.almacenes a where a.id = p_almacen_id and a.activo) then
      raise exception 'El almacen indicado no existe o esta inactivo';
    end if;
    v_almacen_id := p_almacen_id;
    select f.id into v_franquicia_id from public.franquicias f
    where f.almacen_id = p_almacen_id and f.activo;
  else
    raise exception 'No tienes permiso para registrar ventas';
  end if;

  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_venta from public.venta_rapida_v148 where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('id', v_venta, 'duplicado', true); end if;

  if p_fecha is null or p_fecha > (now() at time zone 'America/Guayaquil')::date then
    raise exception 'La fecha de venta no es valida';
  end if;
  if btrim(coalesce(p_concepto, '')) = '' then
    raise exception 'Describe brevemente la venta (concepto)';
  end if;

  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'La lista de items no es valida';
  end if;
  if jsonb_array_length(coalesce(p_items, '[]'::jsonb)) > 0 then
    if exists (
      select 1 from jsonb_to_recordset(p_items) x(producto_id uuid, descripcion text, cantidad numeric, precio_unitario numeric)
      where btrim(coalesce(x.descripcion, '')) = ''
        or coalesce(x.cantidad, 0) <= 0
        or coalesce(x.precio_unitario, -1) < 0
    ) then
      raise exception 'La venta contiene items con datos invalidos';
    end if;
    select round(sum(x.cantidad * x.precio_unitario), 2) into v_subtotal
    from jsonb_to_recordset(p_items) x(cantidad numeric, precio_unitario numeric);
  else
    v_subtotal := 0;
  end if;

  if v_descuento < 0 or v_descuento > v_subtotal then raise exception 'El descuento no es valido'; end if;
  v_total := v_subtotal - v_descuento;
  -- Una venta rapida sin items (puro cobro/abono) no tiene de donde sacar el
  -- total de p_items: en ese caso el total lo trae la suma de p_pagos.
  if v_total = 0 then
    if jsonb_typeof(coalesce(p_pagos, '[]'::jsonb)) <> 'array' or jsonb_array_length(p_pagos) = 0 then
      raise exception 'Indica el monto cobrado';
    end if;
    select round(sum(x.monto), 2) into v_total
    from jsonb_to_recordset(p_pagos) x(monto numeric);
    v_subtotal := v_total;
  end if;
  if v_total <= 0 then raise exception 'El total debe ser mayor que cero'; end if;

  if jsonb_typeof(coalesce(p_pagos, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_pagos) = 0
    or exists (
      select 1 from jsonb_to_recordset(p_pagos) x(medio_pago text, monto numeric)
      where x.medio_pago not in ('efectivo', 'transferencia', 'tarjeta', 'otro')
        or round(coalesce(x.monto, 0), 2) <= 0
    ) then
    raise exception 'Distribuye el total entre medios de pago validos';
  end if;
  if exists (
    select medio_pago from jsonb_to_recordset(p_pagos) x(medio_pago text) group by medio_pago having count(*) > 1
  ) then
    raise exception 'Agrupa cada medio de pago en una sola linea';
  end if;
  if (select round(sum(x.monto), 2) from jsonb_to_recordset(p_pagos) x(monto numeric)) <> round(v_total, 2) then
    raise exception 'La suma de pagos debe ser exactamente igual al total';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_pagos) x(medio_pago text, referencia text)
    where x.medio_pago in ('transferencia', 'tarjeta') and btrim(coalesce(x.referencia, '')) = ''
  ) then
    raise exception 'Transferencia y tarjeta requieren numero de referencia';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_pagos) x(medio_pago text, comprobante_id uuid)
    where x.medio_pago = 'transferencia' and x.comprobante_id is null
  ) then
    raise exception 'Las ventas con transferencia requieren comprobante adjunto';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_almacen_id::text, 148));
  select coalesce(max(v.numero), 0) + 1 into v_numero from public.venta_rapida_v148 v where v.almacen_id = v_almacen_id;

  insert into public.venta_rapida_v148(
    almacen_id, franquicia_id, numero, fecha, concepto, subtotal, descuento, total,
    nota, idempotency_key, creada_por
  ) values (
    v_almacen_id, v_franquicia_id, v_numero, p_fecha, btrim(p_concepto), v_subtotal, v_descuento, v_total,
    nullif(btrim(coalesce(p_nota, '')), ''), p_idempotency_key, auth.uid()
  ) returning id into v_venta;

  for v_linea in
    select * from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
      x(producto_id uuid, descripcion text, cantidad numeric, precio_unitario numeric)
  loop
    insert into public.venta_rapida_lineas_v148(venta_id, producto_id, descripcion, cantidad, precio_unitario, total)
    values (v_venta, v_linea.producto_id, btrim(v_linea.descripcion), v_linea.cantidad, round(v_linea.precio_unitario, 2),
      round(v_linea.cantidad * v_linea.precio_unitario, 2));
  end loop;

  v_pago_numero := 0;
  for v_pago in
    select * from jsonb_to_recordset(p_pagos)
      x(medio_pago text, monto numeric, referencia text, comprobante_id uuid)
  loop
    v_pago_numero := v_pago_numero + 1;
    v_comprobante := null;
    if v_pago.comprobante_id is not null then
      select * into v_comprobante
      from public.venta_comprobantes_pendientes_v148
      where id = v_pago.comprobante_id and almacen_id = v_almacen_id and creado_por = auth.uid()
        and usado_en is null and vence_en > now()
      for update;
      if not found then raise exception 'El comprobante no fue preparado o ya fue utilizado'; end if;
      if not exists (
        select 1 from storage.objects o
        where o.bucket_id = 'ventas-comprobantes' and o.name = v_comprobante.storage_path
      ) then
        raise exception 'El comprobante no termino de cargarse';
      end if;
    end if;

    select public.registrar_caja_franquicia_v42(
      p_fecha, 'ingreso', 'venta_rapida',
      'Venta rapida #' || v_numero || ' - ' || btrim(p_concepto),
      round(v_pago.monto, 2), v_pago.medio_pago, nullif(btrim(v_pago.referencia), ''),
      md5(v_venta::text || ':' || v_pago_numero::text)::uuid, v_almacen_id
    ) into v_movimiento;

    insert into public.venta_rapida_pagos_v148(
      venta_id, numero, medio_pago, monto, referencia,
      comprobante_storage_path, comprobante_nombre, comprobante_mime_type, comprobante_tamano_bytes,
      movimiento_caja_id
    ) values (
      v_venta, v_pago_numero, v_pago.medio_pago, round(v_pago.monto, 2), nullif(btrim(v_pago.referencia), ''),
      case when v_comprobante.id is null then null else v_comprobante.storage_path end,
      case when v_comprobante.id is null then null else v_comprobante.nombre_archivo end,
      case when v_comprobante.id is null then null else v_comprobante.mime_type end,
      case when v_comprobante.id is null then null else v_comprobante.tamano_bytes end,
      v_movimiento
    ) returning id into v_pago_id;

    if v_comprobante.id is not null then
      update public.venta_comprobantes_pendientes_v148 set usado_en = v_pago_id where id = v_comprobante.id;
    end if;
  end loop;

  return jsonb_build_object('id', v_venta, 'numero', v_numero, 'total', v_total, 'duplicado', false);
end;
$v148$;

-- ------------------------------------------------------------
-- 6. Vincular / marcar sin factura / anular
-- ------------------------------------------------------------
create or replace function public.vincular_venta_rapida_factura_v148(
  p_venta_id uuid,
  p_documento_venta_xml_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $v148$
declare v public.venta_rapida_v148%rowtype; d public.documentos_venta_xml%rowtype;
begin
  select * into v from public.venta_rapida_v148 where id = p_venta_id for update;
  if not found then raise exception 'La venta no existe'; end if;
  if public.rol_usuario_actual() <> 'admin' and not public.usuario_puede_almacen(v.almacen_id, true) then
    raise exception 'No tienes permiso sobre esta venta';
  end if;
  if v.estado = 'anulada' then raise exception 'La venta esta anulada'; end if;
  select * into d from public.documentos_venta_xml where id = p_documento_venta_xml_id;
  if not found then raise exception 'La factura indicada no existe'; end if;
  if d.almacen_id <> v.almacen_id then raise exception 'La factura pertenece a otro almacen'; end if;
  if exists (select 1 from public.venta_rapida_v148 where documento_venta_xml_id = p_documento_venta_xml_id) then
    raise exception 'Esa factura ya esta vinculada a otra venta rapida';
  end if;
  update public.venta_rapida_v148
  set documento_venta_xml_id = p_documento_venta_xml_id, estado = 'vinculada_factura'
  where id = p_venta_id;
end;
$v148$;

create or replace function public.marcar_venta_rapida_sin_factura_v148(
  p_venta_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $v148$
declare v public.venta_rapida_v148%rowtype;
begin
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'Indica por que esta venta no se factura'; end if;
  select * into v from public.venta_rapida_v148 where id = p_venta_id for update;
  if not found then raise exception 'La venta no existe'; end if;
  if public.rol_usuario_actual() <> 'admin' and not public.usuario_puede_almacen(v.almacen_id, true) then
    raise exception 'No tienes permiso sobre esta venta';
  end if;
  if v.estado = 'anulada' then raise exception 'La venta esta anulada'; end if;
  update public.venta_rapida_v148
  set estado = 'sin_factura', motivo_sin_factura = btrim(p_motivo)
  where id = p_venta_id;
end;
$v148$;

create or replace function public.anular_venta_rapida_v148(
  p_venta_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $v148$
declare v public.venta_rapida_v148%rowtype; p record;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'Indica el motivo de anulacion'; end if;
  select * into v from public.venta_rapida_v148 where id = p_venta_id for update;
  if not found then raise exception 'La venta no existe'; end if;
  if public.rol_usuario_actual() <> 'admin' and not public.usuario_puede_almacen(v.almacen_id, true) then
    raise exception 'No tienes permiso sobre esta venta';
  end if;
  if v.estado = 'anulada' then return; end if;

  for p in select * from public.venta_rapida_pagos_v148 where venta_id = p_venta_id and movimiento_caja_id is not null loop
    perform public.revertir_caja_franquicia_v42(
      p.movimiento_caja_id, btrim(p_motivo),
      md5(p_idempotency_key::text || ':' || p.id::text)::uuid
    );
  end loop;

  update public.venta_rapida_v148
  set estado = 'anulada', anulada_por = auth.uid(), anulada_at = now(), motivo_anulacion = btrim(p_motivo)
  where id = p_venta_id;
end;
$v148$;

-- ------------------------------------------------------------
-- 7. RLS
-- ------------------------------------------------------------
alter table public.venta_rapida_v148 enable row level security;
alter table public.venta_rapida_lineas_v148 enable row level security;
alter table public.venta_rapida_pagos_v148 enable row level security;
alter table public.venta_comprobantes_pendientes_v148 enable row level security;
revoke all on public.venta_rapida_v148, public.venta_rapida_lineas_v148,
  public.venta_rapida_pagos_v148, public.venta_comprobantes_pendientes_v148
  from public, anon, authenticated;

drop policy if exists "leer_venta_rapida_v148" on public.venta_rapida_v148;
create policy "leer_venta_rapida_v148" on public.venta_rapida_v148
for select to authenticated using (public.usuario_puede_almacen(almacen_id, false));

drop policy if exists "leer_venta_rapida_lineas_v148" on public.venta_rapida_lineas_v148;
create policy "leer_venta_rapida_lineas_v148" on public.venta_rapida_lineas_v148
for select to authenticated using (
  exists (select 1 from public.venta_rapida_v148 v where v.id = venta_id and public.usuario_puede_almacen(v.almacen_id, false))
);

drop policy if exists "leer_venta_rapida_pagos_v148" on public.venta_rapida_pagos_v148;
create policy "leer_venta_rapida_pagos_v148" on public.venta_rapida_pagos_v148
for select to authenticated using (
  exists (select 1 from public.venta_rapida_v148 v where v.id = venta_id and public.usuario_puede_almacen(v.almacen_id, false))
);

-- ------------------------------------------------------------
-- 8. Dueño, grants
-- ------------------------------------------------------------
alter table public.venta_rapida_v148 owner to postgres;
alter table public.venta_rapida_lineas_v148 owner to postgres;
alter table public.venta_rapida_pagos_v148 owner to postgres;
alter table public.venta_comprobantes_pendientes_v148 owner to postgres;
alter function public.preparar_comprobante_venta_v148(uuid,text,text,bigint,uuid) owner to postgres;
alter function public.puede_subir_comprobante_venta_v148(text) owner to postgres;
alter function public.puede_leer_comprobante_venta_v148(text) owner to postgres;
alter function public.registrar_venta_rapida_v148(date,text,jsonb,jsonb,numeric,text,uuid,uuid) owner to postgres;
alter function public.vincular_venta_rapida_factura_v148(uuid,uuid) owner to postgres;
alter function public.marcar_venta_rapida_sin_factura_v148(uuid,text) owner to postgres;
alter function public.anular_venta_rapida_v148(uuid,text,uuid) owner to postgres;

revoke all on function public.preparar_comprobante_venta_v148(uuid,text,text,bigint,uuid),
  public.puede_subir_comprobante_venta_v148(text),
  public.puede_leer_comprobante_venta_v148(text),
  public.registrar_venta_rapida_v148(date,text,jsonb,jsonb,numeric,text,uuid,uuid),
  public.vincular_venta_rapida_factura_v148(uuid,uuid),
  public.marcar_venta_rapida_sin_factura_v148(uuid,text),
  public.anular_venta_rapida_v148(uuid,text,uuid)
  from public, anon;
grant execute on function public.preparar_comprobante_venta_v148(uuid,text,text,bigint,uuid),
  public.puede_subir_comprobante_venta_v148(text),
  public.puede_leer_comprobante_venta_v148(text),
  public.registrar_venta_rapida_v148(date,text,jsonb,jsonb,numeric,text,uuid,uuid),
  public.vincular_venta_rapida_factura_v148(uuid,uuid),
  public.marcar_venta_rapida_sin_factura_v148(uuid,text),
  public.anular_venta_rapida_v148(uuid,text,uuid)
  to authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v148', 148, 'v148_venta_rapida_tienda.sql',
  'Venta rapida para tiendas propias (solo caja, sin tocar inventario), comprobante obligatorio en transferencia, reconciliacion con factura XML'
)
on conflict (id) do update set version=excluded.version, archivo=excluded.archivo,
  notas=excluded.notas, aplicada_at=now();

notify pgrst, 'reload schema';
commit;
