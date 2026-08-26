-- ============================================================
-- BOMAN INVENTARIO - Ventas por XML SRI v13
-- Facturas autorizadas, equivalencias de códigos externos y
-- descuento atómico de inventario por almacén.
-- Ejecutar una sola vez DESPUÉS de v12.
-- ============================================================

-- Si PostgreSQL informa que el valor nuevo del enum todavía no puede
-- utilizarse, ejecuta primero esta sentencia sola y después el archivo completo.
alter type public.tipo_movimiento add value if not exists 'venta_xml';

-- ------------------------------------------------------------
-- 1. Emisores, establecimientos y equivalencias de productos
-- ------------------------------------------------------------
create table if not exists public.emisores_facturacion (
  ruc text primary key check (ruc ~ '^[0-9]{13}$'),
  razon_social text not null,
  activo boolean not null default true,
  creado_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.establecimiento_almacen_facturacion (
  emisor_ruc text not null references public.emisores_facturacion(ruc),
  establecimiento text not null check (establecimiento ~ '^[0-9]{3}$'),
  punto_emision text not null check (punto_emision ~ '^[0-9]{3}$'),
  almacen_id uuid not null references public.almacenes(id),
  actualizado_por uuid not null references public.perfiles(id),
  updated_at timestamptz not null default now(),
  primary key (emisor_ruc, establecimiento, punto_emision)
);

-- Un código del facturador puede corresponder a varios SKU internos.
-- Así una línea genérica puede distribuirse entre varias tallas o colores.
create table if not exists public.producto_codigos_facturacion (
  emisor_ruc text not null references public.emisores_facturacion(ruc),
  codigo_externo text not null,
  producto_id uuid not null references public.productos(id),
  descripcion_externa text,
  usos integer not null default 1 check (usos > 0),
  ultimo_uso_at timestamptz not null default now(),
  actualizado_por uuid not null references public.perfiles(id),
  primary key (emisor_ruc, codigo_externo, producto_id),
  check (btrim(codigo_externo) <> '')
);

create index if not exists idx_codigos_facturacion_codigo
  on public.producto_codigos_facturacion(emisor_ruc, codigo_externo);

-- ------------------------------------------------------------
-- 2. Facturas importadas, líneas y distribución por SKU
-- ------------------------------------------------------------
create table if not exists public.documentos_venta_xml (
  id uuid primary key default gen_random_uuid(),
  clave_acceso text not null unique check (clave_acceso ~ '^[0-9]{49}$'),
  numero_autorizacion text,
  estado_sri text not null check (estado_sri = 'AUTORIZADO'),
  emisor_ruc text not null references public.emisores_facturacion(ruc),
  razon_social_emisor text not null,
  establecimiento text not null,
  punto_emision text not null,
  secuencial text not null,
  numero_documento text not null,
  fecha_emision date not null,
  fecha_autorizacion timestamptz,
  importe_total numeric(14, 2) not null default 0 check (importe_total >= 0),
  almacen_id uuid not null references public.almacenes(id),
  archivo_nombre text,
  archivo_hash text not null check (archivo_hash ~ '^[0-9a-f]{64}$'),
  nota text,
  unidades_inventario integer not null default 0 check (unidades_inventario >= 0),
  creado_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now(),
  unique (emisor_ruc, establecimiento, punto_emision, secuencial)
);

create table if not exists public.documento_venta_xml_lineas (
  id uuid primary key default gen_random_uuid(),
  documento_id uuid not null references public.documentos_venta_xml(id) on delete restrict,
  numero_linea integer not null check (numero_linea > 0),
  codigo_principal text,
  codigo_auxiliar text,
  descripcion text not null,
  cantidad numeric(18, 6) not null check (cantidad > 0),
  precio_unitario numeric(18, 6) not null default 0 check (precio_unitario >= 0),
  descuento numeric(14, 2) not null default 0 check (descuento >= 0),
  total_sin_impuesto numeric(14, 2) not null default 0 check (total_sin_impuesto >= 0),
  afecta_inventario boolean not null default true,
  unique (documento_id, numero_linea)
);

create table if not exists public.documento_venta_xml_asignaciones (
  id uuid primary key default gen_random_uuid(),
  linea_id uuid not null references public.documento_venta_xml_lineas(id) on delete restrict,
  producto_id uuid not null references public.productos(id),
  cantidad integer not null check (cantidad > 0),
  unique (linea_id, producto_id)
);

create index if not exists idx_documentos_venta_xml_almacen_fecha
  on public.documentos_venta_xml(almacen_id, fecha_emision desc, created_at desc);
create index if not exists idx_documentos_venta_xml_emisor_numero
  on public.documentos_venta_xml(emisor_ruc, numero_documento);
create index if not exists idx_documento_venta_xml_lineas_documento
  on public.documento_venta_xml_lineas(documento_id, numero_linea);
create index if not exists idx_documento_venta_xml_asignaciones_producto
  on public.documento_venta_xml_asignaciones(producto_id, linea_id);

alter table public.emisores_facturacion enable row level security;
alter table public.establecimiento_almacen_facturacion enable row level security;
alter table public.producto_codigos_facturacion enable row level security;
alter table public.documentos_venta_xml enable row level security;
alter table public.documento_venta_xml_lineas enable row level security;
alter table public.documento_venta_xml_asignaciones enable row level security;

-- ------------------------------------------------------------
-- 3. Lectura con RLS; toda escritura queda detrás del RPC
-- ------------------------------------------------------------
create or replace function public.puede_ver_documento_venta_xml(p_documento_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.documentos_venta_xml d
    where d.id = p_documento_id
      and public.usuario_puede_almacen(d.almacen_id, false)
  );
$$;

drop policy if exists "leer_emisores_facturacion" on public.emisores_facturacion;
create policy "leer_emisores_facturacion"
on public.emisores_facturacion for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'tienda', 'gerencia')
);

drop policy if exists "leer_establecimientos_facturacion" on public.establecimiento_almacen_facturacion;
create policy "leer_establecimientos_facturacion"
on public.establecimiento_almacen_facturacion for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
);

drop policy if exists "leer_codigos_facturacion" on public.producto_codigos_facturacion;
create policy "leer_codigos_facturacion"
on public.producto_codigos_facturacion for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'tienda', 'gerencia')
);

drop policy if exists "leer_documentos_venta_xml" on public.documentos_venta_xml;
create policy "leer_documentos_venta_xml"
on public.documentos_venta_xml for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
);

drop policy if exists "leer_documento_venta_xml_lineas" on public.documento_venta_xml_lineas;
create policy "leer_documento_venta_xml_lineas"
on public.documento_venta_xml_lineas for select to authenticated using (
  public.puede_ver_documento_venta_xml(documento_id)
);

drop policy if exists "leer_documento_venta_xml_asignaciones" on public.documento_venta_xml_asignaciones;
create policy "leer_documento_venta_xml_asignaciones"
on public.documento_venta_xml_asignaciones for select to authenticated using (
  exists (
    select 1 from public.documento_venta_xml_lineas l
    where l.id = linea_id
      and public.puede_ver_documento_venta_xml(l.documento_id)
  )
);

-- ------------------------------------------------------------
-- 4. Aplicación atómica e idempotente de una factura autorizada
-- ------------------------------------------------------------
create or replace function public.aplicar_factura_venta_xml(
  p_documento jsonb,
  p_almacen_id uuid,
  p_asignaciones jsonb,
  p_nota text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol text := public.rol_usuario_actual();
  v_clave text := btrim(coalesce(p_documento->>'clave_acceso', ''));
  v_estado text := upper(btrim(coalesce(p_documento->>'estado_sri', '')));
  v_ruc text := btrim(coalesce(p_documento->>'emisor_ruc', ''));
  v_razon text := btrim(coalesce(p_documento->>'razon_social_emisor', ''));
  v_estab text := btrim(coalesce(p_documento->>'establecimiento', ''));
  v_pto text := btrim(coalesce(p_documento->>'punto_emision', ''));
  v_sec text := btrim(coalesce(p_documento->>'secuencial', ''));
  v_fecha date;
  v_fecha_autorizacion timestamptz;
  v_total numeric(14, 2);
  v_hash text := lower(btrim(coalesce(p_documento->>'archivo_hash', '')));
  v_doc_id uuid;
  v_linea_id uuid;
  v_mapeado uuid;
  v_stock integer;
  v_unidades integer := 0;
  v_movimientos integer := 0;
  it record;
begin
  if v_rol not in ('admin', 'control', 'tienda', 'bodega') then
    raise exception 'No tienes permiso para importar ventas';
  end if;
  if p_almacen_id is null or not public.usuario_puede_almacen(p_almacen_id, true) then
    raise exception 'No tienes permiso para descontar inventario de ese almacén';
  end if;
  if not exists (select 1 from public.almacenes where id = p_almacen_id and activo) then
    raise exception 'El almacén no existe o está inactivo';
  end if;
  if v_estado <> 'AUTORIZADO' then
    raise exception 'Solo se pueden aplicar comprobantes AUTORIZADOS por el SRI';
  end if;
  if v_clave !~ '^[0-9]{49}$' then raise exception 'La clave de acceso del XML no es válida'; end if;
  if v_ruc !~ '^[0-9]{13}$' then raise exception 'El RUC emisor del XML no es válido'; end if;
  if v_estab !~ '^[0-9]{3}$' or v_pto !~ '^[0-9]{3}$' or v_sec !~ '^[0-9]{9}$' then
    raise exception 'La numeración del comprobante no es válida';
  end if;
  if v_razon = '' then raise exception 'El XML no contiene la razón social del emisor'; end if;
  if v_hash !~ '^[0-9a-f]{64}$' then raise exception 'No se pudo verificar la huella del archivo XML'; end if;
  if coalesce(p_documento->>'fecha_emision', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'La fecha de emisión del XML no es válida';
  end if;
  v_fecha := (p_documento->>'fecha_emision')::date;
  v_total := coalesce(nullif(p_documento->>'importe_total', '')::numeric, 0);
  if v_total < 0 then raise exception 'El total del comprobante no es válido'; end if;
  if nullif(p_documento->>'fecha_autorizacion', '') is not null then
    begin
      v_fecha_autorizacion := (p_documento->>'fecha_autorizacion')::timestamptz;
    exception when others then
      v_fecha_autorizacion := null;
    end;
  end if;
  if jsonb_typeof(p_documento->'lineas') <> 'array'
     or jsonb_array_length(p_documento->'lineas') = 0 then
    raise exception 'La factura no contiene líneas';
  end if;
  if jsonb_typeof(coalesce(p_asignaciones, '[]'::jsonb)) <> 'array' then
    raise exception 'Las asignaciones de productos no son válidas';
  end if;

  -- El primer emisor debe ser confirmado por Administración o Control.
  if not exists (select 1 from public.emisores_facturacion) then
    if v_rol not in ('admin', 'control') then
      raise exception 'Administración o Control deben habilitar primero el emisor de las facturas';
    end if;
    insert into public.emisores_facturacion (ruc, razon_social, creado_por)
    values (v_ruc, v_razon, auth.uid());
  elsif not exists (
    select 1 from public.emisores_facturacion where ruc = v_ruc and activo
  ) then
    raise exception 'El RUC emisor de este XML no está habilitado para ventas';
  end if;

  -- La clave de acceso impide descontar dos veces por reintentos o doble clic.
  select id into v_doc_id
  from public.documentos_venta_xml
  where clave_acceso = v_clave;
  if found then
    if not public.puede_ver_documento_venta_xml(v_doc_id) then
      raise exception 'Este comprobante ya fue procesado en otro almacén';
    end if;
    return jsonb_build_object(
      'id', v_doc_id, 'duplicado', true,
      'mensaje', 'La factura ya estaba aplicada; el inventario no se modificó'
    );
  end if;

  select almacen_id into v_mapeado
  from public.establecimiento_almacen_facturacion
  where emisor_ruc = v_ruc and establecimiento = v_estab and punto_emision = v_pto;
  if found and v_mapeado <> p_almacen_id then
    raise exception 'El establecimiento %-% está vinculado a otro almacén', v_estab, v_pto;
  elsif not found then
    insert into public.establecimiento_almacen_facturacion
      (emisor_ruc, establecimiento, punto_emision, almacen_id, actualizado_por)
    values (v_ruc, v_estab, v_pto, p_almacen_id, auth.uid());
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_documento->'lineas') as l(
      numero_linea integer, descripcion text, cantidad numeric, afecta_inventario boolean
    )
    where l.numero_linea is null or l.numero_linea <= 0
       or btrim(coalesce(l.descripcion, '')) = ''
       or l.cantidad is null or l.cantidad <= 0
  ) then raise exception 'La factura contiene una línea inválida'; end if;

  if exists (
    select numero_linea
    from jsonb_to_recordset(p_documento->'lineas') as l(numero_linea integer)
    group by numero_linea having count(*) > 1
  ) then raise exception 'La factura contiene números de línea repetidos'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_documento->'lineas') as l(
      numero_linea integer, cantidad numeric, afecta_inventario boolean
    )
    where coalesce(l.afecta_inventario, true) and l.cantidad <> trunc(l.cantidad)
  ) then raise exception 'Las líneas inventariables deben tener cantidades enteras'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_asignaciones, '[]'::jsonb)) as a(
      numero_linea integer, producto_id uuid, cantidad integer
    )
    where a.numero_linea is null or a.producto_id is null or coalesce(a.cantidad, 0) <= 0
  ) then raise exception 'Existe una asignación de producto inválida'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_asignaciones, '[]'::jsonb)) as a(
      numero_linea integer, producto_id uuid, cantidad integer
    )
    left join public.productos p on p.id = a.producto_id and p.activo
    left join jsonb_to_recordset(p_documento->'lineas') as l(
      numero_linea integer, afecta_inventario boolean
    ) on l.numero_linea = a.numero_linea
    where p.id is null or l.numero_linea is null or not coalesce(l.afecta_inventario, true)
  ) then raise exception 'Una asignación apunta a una línea o producto no válido'; end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_documento->'lineas') as l(
      numero_linea integer, cantidad numeric, afecta_inventario boolean
    )
    left join (
      select numero_linea, sum(cantidad)::numeric cantidad
      from jsonb_to_recordset(coalesce(p_asignaciones, '[]'::jsonb)) as a(
        numero_linea integer, producto_id uuid, cantidad integer
      ) group by numero_linea
    ) a on a.numero_linea = l.numero_linea
    where coalesce(l.afecta_inventario, true)
      and coalesce(a.cantidad, 0) <> l.cantidad
  ) then raise exception 'Debes distribuir exactamente la cantidad completa de cada línea'; end if;

  insert into public.documentos_venta_xml (
    clave_acceso, numero_autorizacion, estado_sri, emisor_ruc, razon_social_emisor,
    establecimiento, punto_emision, secuencial, numero_documento, fecha_emision,
    fecha_autorizacion, importe_total, almacen_id, archivo_nombre, archivo_hash,
    nota, creado_por
  ) values (
    v_clave, nullif(btrim(p_documento->>'numero_autorizacion'), ''), v_estado,
    v_ruc, v_razon, v_estab, v_pto, v_sec, v_estab || '-' || v_pto || '-' || v_sec,
    v_fecha, v_fecha_autorizacion, v_total, p_almacen_id,
    nullif(btrim(p_documento->>'archivo_nombre'), ''), v_hash,
    nullif(btrim(p_nota), ''), auth.uid()
  )
  on conflict (clave_acceso) do nothing
  returning id into v_doc_id;

  if v_doc_id is null then
    select id into v_doc_id from public.documentos_venta_xml where clave_acceso = v_clave;
    return jsonb_build_object(
      'id', v_doc_id, 'duplicado', true,
      'mensaje', 'La factura ya estaba aplicada; el inventario no se modificó'
    );
  end if;

  for it in
    select *
    from jsonb_to_recordset(p_documento->'lineas') as l(
      numero_linea integer, codigo_principal text, codigo_auxiliar text,
      descripcion text, cantidad numeric, precio_unitario numeric,
      descuento numeric, total_sin_impuesto numeric, afecta_inventario boolean
    ) order by numero_linea
  loop
    insert into public.documento_venta_xml_lineas (
      documento_id, numero_linea, codigo_principal, codigo_auxiliar, descripcion,
      cantidad, precio_unitario, descuento, total_sin_impuesto, afecta_inventario
    ) values (
      v_doc_id, it.numero_linea, nullif(btrim(it.codigo_principal), ''),
      nullif(btrim(it.codigo_auxiliar), ''), btrim(it.descripcion), it.cantidad,
      coalesce(it.precio_unitario, 0), coalesce(it.descuento, 0),
      coalesce(it.total_sin_impuesto, 0), coalesce(it.afecta_inventario, true)
    ) returning id into v_linea_id;

    insert into public.documento_venta_xml_asignaciones (linea_id, producto_id, cantidad)
    select v_linea_id, a.producto_id, sum(a.cantidad)::integer
    from jsonb_to_recordset(coalesce(p_asignaciones, '[]'::jsonb)) as a(
      numero_linea integer, producto_id uuid, cantidad integer
    )
    where a.numero_linea = it.numero_linea
    group by a.producto_id;

    -- Aprende ambos códigos externos, excepto valores genéricos N/A.
    if nullif(btrim(it.codigo_principal), '') is not null
       and upper(btrim(it.codigo_principal)) <> 'N/A' then
      insert into public.producto_codigos_facturacion as c(
        emisor_ruc, codigo_externo, producto_id, descripcion_externa, actualizado_por
      )
      select v_ruc, upper(btrim(it.codigo_principal)), a.producto_id,
             btrim(it.descripcion), auth.uid()
      from jsonb_to_recordset(coalesce(p_asignaciones, '[]'::jsonb)) as a(
        numero_linea integer, producto_id uuid, cantidad integer
      ) where a.numero_linea = it.numero_linea
      group by a.producto_id
      on conflict (emisor_ruc, codigo_externo, producto_id) do update
      set descripcion_externa = excluded.descripcion_externa,
          usos = c.usos + 1, ultimo_uso_at = now(), actualizado_por = auth.uid();
    end if;

    if nullif(btrim(it.codigo_auxiliar), '') is not null
       and upper(btrim(it.codigo_auxiliar)) <> 'N/A' then
      insert into public.producto_codigos_facturacion as c(
        emisor_ruc, codigo_externo, producto_id, descripcion_externa, actualizado_por
      )
      select v_ruc, upper(btrim(it.codigo_auxiliar)), a.producto_id,
             btrim(it.descripcion), auth.uid()
      from jsonb_to_recordset(coalesce(p_asignaciones, '[]'::jsonb)) as a(
        numero_linea integer, producto_id uuid, cantidad integer
      ) where a.numero_linea = it.numero_linea
      group by a.producto_id
      on conflict (emisor_ruc, codigo_externo, producto_id) do update
      set descripcion_externa = excluded.descripcion_externa,
          usos = c.usos + 1, ultimo_uso_at = now(), actualizado_por = auth.uid();
    end if;
  end loop;

  -- Bloquea los productos siempre en orden para evitar carreras entre facturas.
  for it in
    select a.producto_id, sum(a.cantidad)::integer cantidad
    from jsonb_to_recordset(coalesce(p_asignaciones, '[]'::jsonb)) as a(
      numero_linea integer, producto_id uuid, cantidad integer
    )
    group by a.producto_id order by a.producto_id
  loop
    if public.conteo_abierto_producto(p_almacen_id, it.producto_id) then
      raise exception 'Hay un conteo abierto para uno de los productos de la factura';
    end if;
    select cantidad into v_stock
    from public.inventario
    where producto_id = it.producto_id and entidad_id = p_almacen_id
    for update;
    if coalesce(v_stock, 0) < it.cantidad then
      raise exception 'Stock insuficiente para aplicar la factura en uno de los productos';
    end if;

    update public.inventario
    set cantidad = cantidad - it.cantidad, updated_at = now()
    where producto_id = it.producto_id and entidad_id = p_almacen_id;

    insert into public.movimientos (
      producto_id, entidad_id, tipo, cantidad, nota, usuario_id, grupo_id
    ) values (
      it.producto_id, p_almacen_id, 'venta_xml', it.cantidad,
      concat('Venta XML ', v_estab, '-', v_pto, '-', v_sec,
             coalesce(' - ' || nullif(btrim(p_nota), ''), '')),
      auth.uid(), v_doc_id
    );
    v_unidades := v_unidades + it.cantidad;
    v_movimientos := v_movimientos + 1;
  end loop;

  update public.documentos_venta_xml
  set unidades_inventario = v_unidades
  where id = v_doc_id;

  return jsonb_build_object(
    'id', v_doc_id,
    'duplicado', false,
    'numero_documento', v_estab || '-' || v_pto || '-' || v_sec,
    'unidades', v_unidades,
    'movimientos', v_movimientos,
    'mensaje', 'Factura aplicada correctamente'
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Propiedad y privilegios
-- ------------------------------------------------------------
alter function public.puede_ver_documento_venta_xml(uuid) owner to postgres;
alter function public.aplicar_factura_venta_xml(jsonb, uuid, jsonb, text) owner to postgres;

revoke all on public.emisores_facturacion from public, anon;
revoke all on public.establecimiento_almacen_facturacion from public, anon;
revoke all on public.producto_codigos_facturacion from public, anon;
revoke all on public.documentos_venta_xml from public, anon;
revoke all on public.documento_venta_xml_lineas from public, anon;
revoke all on public.documento_venta_xml_asignaciones from public, anon;

revoke insert, update, delete on public.emisores_facturacion from authenticated;
revoke insert, update, delete on public.establecimiento_almacen_facturacion from authenticated;
revoke insert, update, delete on public.producto_codigos_facturacion from authenticated;
revoke insert, update, delete on public.documentos_venta_xml from authenticated;
revoke insert, update, delete on public.documento_venta_xml_lineas from authenticated;
revoke insert, update, delete on public.documento_venta_xml_asignaciones from authenticated;

grant select on public.emisores_facturacion to authenticated;
grant select on public.establecimiento_almacen_facturacion to authenticated;
grant select on public.producto_codigos_facturacion to authenticated;
grant select on public.documentos_venta_xml to authenticated;
grant select on public.documento_venta_xml_lineas to authenticated;
grant select on public.documento_venta_xml_asignaciones to authenticated;

revoke execute on function public.puede_ver_documento_venta_xml(uuid) from public, anon;
grant execute on function public.puede_ver_documento_venta_xml(uuid) to authenticated;
revoke execute on function public.aplicar_factura_venta_xml(jsonb, uuid, jsonb, text) from public, anon;
grant execute on function public.aplicar_factura_venta_xml(jsonb, uuid, jsonb, text) to authenticated;

-- Solicita a PostgREST que actualice inmediatamente su caché de tablas y RPC.
notify pgrst, 'reload schema';
