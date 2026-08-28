-- ============================================================
-- BOMAN INVENTARIO - Compras multiempresa v21
-- Proveedores compartidos por grupo, orden legal por RUC, aprobacion,
-- recepciones parciales y control de producto no conforme.
-- Ejecutar una sola vez DESPUES de v20.
-- ============================================================

-- Si PostgreSQL informa "unsafe use of new value", ejecuta primero solo
-- estas dos sentencias y luego vuelve a ejecutar el archivo completo.
alter type public.tipo_movimiento add value if not exists 'compra_recepcion';
alter type public.tipo_movimiento add value if not exists 'compra_recepcion_reversa';

-- ------------------------------------------------------------
-- 1. Maestro de proveedores compartido por grupo economico
-- ------------------------------------------------------------
create table if not exists public.proveedores (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  tipo_identificacion text not null check (
    tipo_identificacion in ('ruc', 'cedula', 'pasaporte', 'exterior')
  ),
  identificacion text not null check (btrim(identificacion) <> ''),
  razon_social text not null check (btrim(razon_social) <> ''),
  nombre_comercial text,
  correo text,
  telefono text,
  direccion text,
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id),
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, identificacion),
  check (
    (tipo_identificacion = 'ruc' and identificacion ~ '^[0-9]{13}$')
    or (tipo_identificacion = 'cedula' and identificacion ~ '^[0-9]{10}$')
    or (tipo_identificacion in ('pasaporte', 'exterior') and length(btrim(identificacion)) between 5 and 30)
  )
);

create table if not exists public.proveedor_empresas (
  proveedor_id uuid not null references public.proveedores(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  dias_credito integer not null default 0 check (dias_credito >= 0),
  proveedor_preferido boolean not null default false,
  activo boolean not null default true,
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (proveedor_id, empresa_id)
);

create index if not exists idx_proveedores_grupo_nombre
  on public.proveedores(grupo_id, activo, razon_social);
create index if not exists idx_proveedor_empresas_empresa
  on public.proveedor_empresas(empresa_id, proveedor_id);

-- ------------------------------------------------------------
-- 2. Ordenes de compra, recepciones y auditoria
-- ------------------------------------------------------------
create sequence if not exists public.seq_orden_compra;
create sequence if not exists public.seq_recepcion_compra;

create table if not exists public.ordenes_compra (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  proveedor_id uuid not null references public.proveedores(id) on delete restrict,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  estado text not null default 'pendiente_aprobacion' check (estado in (
    'pendiente_aprobacion', 'aprobada', 'parcial', 'recibida',
    'rechazada', 'anulada', 'cerrada_parcial'
  )),
  moneda text not null default 'USD' check (moneda ~ '^[A-Z]{3}$'),
  fecha_orden date not null default current_date,
  fecha_esperada date,
  referencia text,
  nota text,
  subtotal numeric(16,4) not null default 0 check (subtotal >= 0),
  descuento numeric(16,4) not null default 0 check (descuento >= 0),
  impuesto numeric(16,4) not null default 0 check (impuesto >= 0),
  total numeric(16,4) not null default 0 check (total >= 0),
  idempotency_key uuid not null unique,
  creado_por uuid not null references public.perfiles(id),
  aprobado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  aprobado_at timestamptz,
  cerrado_at timestamptz,
  version integer not null default 1
);

create table if not exists public.orden_compra_lineas (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references public.ordenes_compra(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  cantidad_ordenada integer not null check (cantidad_ordenada > 0),
  cantidad_recibida integer not null default 0 check (cantidad_recibida >= 0),
  cantidad_no_conforme integer not null default 0 check (cantidad_no_conforme >= 0),
  costo_unitario numeric(16,4) not null default 0 check (costo_unitario >= 0),
  descuento_porcentaje numeric(7,4) not null default 0
    check (descuento_porcentaje between 0 and 100),
  iva_porcentaje numeric(7,4) not null default 0
    check (iva_porcentaje between 0 and 100),
  subtotal numeric(16,4) not null default 0 check (subtotal >= 0),
  descuento numeric(16,4) not null default 0 check (descuento >= 0),
  impuesto numeric(16,4) not null default 0 check (impuesto >= 0),
  total numeric(16,4) not null default 0 check (total >= 0),
  observacion text,
  unique (orden_id, producto_id),
  check (cantidad_recibida + cantidad_no_conforme <= cantidad_ordenada)
);

create table if not exists public.recepciones_compra (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  orden_id uuid not null references public.ordenes_compra(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  estado text not null default 'aplicada' check (estado in ('aplicada', 'rectificada')),
  documento_proveedor text not null check (btrim(documento_proveedor) <> ''),
  nota text,
  idempotency_key uuid not null unique,
  recibido_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now(),
  rectificada_por uuid references public.perfiles(id),
  rectificada_at timestamptz,
  motivo_rectificacion text
);

create table if not exists public.recepcion_compra_lineas (
  id uuid primary key default gen_random_uuid(),
  recepcion_id uuid not null references public.recepciones_compra(id) on delete restrict,
  orden_linea_id uuid not null references public.orden_compra_lineas(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  cantidad_conforme integer not null default 0 check (cantidad_conforme >= 0),
  cantidad_no_conforme integer not null default 0 check (cantidad_no_conforme >= 0),
  costo_unitario numeric(16,4) not null check (costo_unitario >= 0),
  observacion text,
  unique (recepcion_id, orden_linea_id),
  check (cantidad_conforme + cantidad_no_conforme > 0)
);

create table if not exists public.recepcion_compra_no_conformidad_acciones (
  id uuid primary key default gen_random_uuid(),
  recepcion_linea_id uuid not null references public.recepcion_compra_lineas(id) on delete restrict,
  accion text not null check (accion in ('liberar_disponible', 'devolver_proveedor', 'baja')),
  cantidad integer not null check (cantidad > 0),
  detalle text not null check (btrim(detalle) <> ''),
  idempotency_key uuid not null unique,
  realizado_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.rectificaciones_recepcion_compra (
  id uuid primary key default gen_random_uuid(),
  recepcion_id uuid not null unique references public.recepciones_compra(id) on delete restrict,
  motivo text not null check (btrim(motivo) <> ''),
  idempotency_key uuid not null unique,
  realizado_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.orden_compra_eventos (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references public.ordenes_compra(id) on delete restrict,
  estado_anterior text,
  estado_nuevo text not null,
  detalle text,
  usuario_id uuid not null references public.perfiles(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_ordenes_compra_empresa_estado_fecha
  on public.ordenes_compra(empresa_id, estado, created_at desc);
create index if not exists idx_ordenes_compra_proveedor_fecha
  on public.ordenes_compra(proveedor_id, created_at desc);
create index if not exists idx_ordenes_compra_almacen_estado
  on public.ordenes_compra(almacen_id, estado, created_at desc);
create index if not exists idx_orden_compra_lineas_producto
  on public.orden_compra_lineas(producto_id, orden_id);
create index if not exists idx_recepciones_compra_orden_fecha
  on public.recepciones_compra(orden_id, created_at desc);
create index if not exists idx_recepcion_compra_nc_linea_fecha
  on public.recepcion_compra_no_conformidad_acciones(recepcion_linea_id, created_at);
create index if not exists idx_orden_compra_eventos_fecha
  on public.orden_compra_eventos(orden_id, created_at);

-- ------------------------------------------------------------
-- 3. Acceso de lectura por grupo, empresa y almacen
-- ------------------------------------------------------------
create or replace function public.usuario_puede_grupo_compra(p_grupo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_grupo_id is not null and exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text in ('admin', 'control', 'gerencia')
        or exists (
          select 1 from public.empresas e
          where e.grupo_id = p_grupo_id and e.activo
            and public.usuario_puede_empresa(e.id, false)
        )
      )
  );
$$;

create or replace function public.puede_ver_orden_compra(p_orden_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.ordenes_compra o
    where o.id = p_orden_id
      and public.usuario_puede_empresa(o.empresa_id, false)
      and public.usuario_puede_almacen(o.almacen_id, false)
  );
$$;

create or replace function public.puede_ver_recepcion_compra(p_recepcion_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.recepciones_compra r
    where r.id = p_recepcion_id
      and public.puede_ver_orden_compra(r.orden_id)
  );
$$;

alter table public.proveedores enable row level security;
alter table public.proveedor_empresas enable row level security;
alter table public.ordenes_compra enable row level security;
alter table public.orden_compra_lineas enable row level security;
alter table public.recepciones_compra enable row level security;
alter table public.recepcion_compra_lineas enable row level security;
alter table public.recepcion_compra_no_conformidad_acciones enable row level security;
alter table public.rectificaciones_recepcion_compra enable row level security;
alter table public.orden_compra_eventos enable row level security;

drop policy if exists "leer_proveedores_v21" on public.proveedores;
create policy "leer_proveedores_v21" on public.proveedores
for select to authenticated using (public.usuario_puede_grupo_compra(grupo_id));

drop policy if exists "leer_proveedor_empresas_v21" on public.proveedor_empresas;
create policy "leer_proveedor_empresas_v21" on public.proveedor_empresas
for select to authenticated using (public.usuario_puede_empresa(empresa_id, false));

drop policy if exists "leer_ordenes_compra_v21" on public.ordenes_compra;
create policy "leer_ordenes_compra_v21" on public.ordenes_compra
for select to authenticated using (
  public.usuario_puede_empresa(empresa_id, false)
  and public.usuario_puede_almacen(almacen_id, false)
);

drop policy if exists "leer_orden_compra_lineas_v21" on public.orden_compra_lineas;
create policy "leer_orden_compra_lineas_v21" on public.orden_compra_lineas
for select to authenticated using (public.puede_ver_orden_compra(orden_id));

drop policy if exists "leer_recepciones_compra_v21" on public.recepciones_compra;
create policy "leer_recepciones_compra_v21" on public.recepciones_compra
for select to authenticated using (public.puede_ver_orden_compra(orden_id));

drop policy if exists "leer_recepcion_compra_lineas_v21" on public.recepcion_compra_lineas;
create policy "leer_recepcion_compra_lineas_v21" on public.recepcion_compra_lineas
for select to authenticated using (public.puede_ver_recepcion_compra(recepcion_id));

drop policy if exists "leer_recepcion_compra_nc_acciones_v21"
  on public.recepcion_compra_no_conformidad_acciones;
create policy "leer_recepcion_compra_nc_acciones_v21"
on public.recepcion_compra_no_conformidad_acciones for select to authenticated using (
  exists (
    select 1 from public.recepcion_compra_lineas l
    where l.id = recepcion_linea_id
      and public.puede_ver_recepcion_compra(l.recepcion_id)
  )
);

drop policy if exists "leer_rectificaciones_recepcion_compra_v21"
  on public.rectificaciones_recepcion_compra;
create policy "leer_rectificaciones_recepcion_compra_v21"
on public.rectificaciones_recepcion_compra for select to authenticated using (
  public.puede_ver_recepcion_compra(recepcion_id)
);

drop policy if exists "leer_orden_compra_eventos_v21" on public.orden_compra_eventos;
create policy "leer_orden_compra_eventos_v21" on public.orden_compra_eventos
for select to authenticated using (public.puede_ver_orden_compra(orden_id));

-- ------------------------------------------------------------
-- 4. Proveedores y ordenes auditadas
-- ------------------------------------------------------------
create or replace function public.guardar_proveedor_v21(
  p_proveedor_id uuid,
  p_grupo_id uuid,
  p_tipo_identificacion text,
  p_identificacion text,
  p_razon_social text,
  p_nombre_comercial text default null,
  p_correo text default null,
  p_telefono text default null,
  p_direccion text default null,
  p_activo boolean default true
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_identificacion text := upper(btrim(coalesce(p_identificacion, '')));
  v_grupo_anterior uuid;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden gestionar proveedores';
  end if;
  if not exists (
    select 1 from public.grupos_economicos where id = p_grupo_id and activo
  ) then raise exception 'El grupo economico no existe o esta inactivo'; end if;
  if p_tipo_identificacion not in ('ruc', 'cedula', 'pasaporte', 'exterior') then
    raise exception 'El tipo de identificacion no es valido';
  end if;
  if p_tipo_identificacion = 'ruc' and v_identificacion !~ '^[0-9]{13}$' then
    raise exception 'El RUC del proveedor debe tener 13 digitos';
  elsif p_tipo_identificacion = 'cedula' and v_identificacion !~ '^[0-9]{10}$' then
    raise exception 'La cedula del proveedor debe tener 10 digitos';
  elsif p_tipo_identificacion in ('pasaporte', 'exterior')
        and length(v_identificacion) not between 5 and 30 then
    raise exception 'La identificacion exterior debe tener entre 5 y 30 caracteres';
  end if;
  if btrim(coalesce(p_razon_social, '')) = '' then
    raise exception 'La razon social del proveedor es obligatoria';
  end if;

  if p_proveedor_id is null then
    insert into public.proveedores (
      grupo_id, tipo_identificacion, identificacion, razon_social,
      nombre_comercial, correo, telefono, direccion, activo,
      creado_por, actualizado_por
    ) values (
      p_grupo_id, p_tipo_identificacion, v_identificacion, btrim(p_razon_social),
      nullif(btrim(p_nombre_comercial), ''), nullif(btrim(p_correo), ''),
      nullif(btrim(p_telefono), ''), nullif(btrim(p_direccion), ''),
      coalesce(p_activo, true), auth.uid(), auth.uid()
    ) returning id into v_id;
  else
    select grupo_id into v_grupo_anterior
    from public.proveedores where id = p_proveedor_id;
    if not found then raise exception 'El proveedor no existe'; end if;
    if v_grupo_anterior <> p_grupo_id and exists (
      select 1 from public.ordenes_compra where proveedor_id = p_proveedor_id
    ) then
      raise exception 'El proveedor ya tiene ordenes y no puede trasladarse a otro grupo';
    end if;
    update public.proveedores
    set grupo_id = p_grupo_id,
        tipo_identificacion = p_tipo_identificacion,
        identificacion = v_identificacion,
        razon_social = btrim(p_razon_social),
        nombre_comercial = nullif(btrim(p_nombre_comercial), ''),
        correo = nullif(btrim(p_correo), ''),
        telefono = nullif(btrim(p_telefono), ''),
        direccion = nullif(btrim(p_direccion), ''),
        activo = coalesce(p_activo, true),
        actualizado_por = auth.uid(), updated_at = now()
    where id = p_proveedor_id
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

create or replace function public.crear_orden_compra_v21(
  p_empresa_id uuid,
  p_proveedor_id uuid,
  p_almacen_id uuid,
  p_items jsonb,
  p_fecha_esperada date default null,
  p_referencia text default null,
  p_nota text default null,
  p_idempotency_key uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol text := public.rol_usuario_actual();
  v_id uuid;
  v_numero text;
  v_grupo_id uuid;
begin
  if v_rol not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para crear ordenes de compra';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 21)
  );
  select id, numero into v_id, v_numero
  from public.ordenes_compra where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_id, 'numero', v_numero, 'duplicado', true);
  end if;
  select grupo_id into v_grupo_id
  from public.empresas where id = p_empresa_id and activo;
  if not found then raise exception 'La empresa compradora no existe o esta inactiva'; end if;
  if not public.usuario_puede_capacidad_empresa(p_empresa_id, p_almacen_id, 'compras') then
    raise exception 'No tienes compras y custodia habilitadas para esta empresa y almacen';
  end if;
  if not exists (
    select 1 from public.proveedores
    where id = p_proveedor_id and grupo_id = v_grupo_id and activo
  ) then raise exception 'El proveedor no existe, esta inactivo o pertenece a otro grupo'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La orden debe contener al menos un producto';
  end if;
  if exists (
    select producto_id
    from jsonb_to_recordset(p_items) x(producto_id uuid)
    group by producto_id having count(*) > 1
  ) then raise exception 'La orden contiene productos repetidos'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_items) x(
      producto_id uuid, cantidad integer, costo_unitario numeric,
      descuento_porcentaje numeric, iva_porcentaje numeric, observacion text
    )
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or coalesce(x.cantidad, 0) <= 0
      or coalesce(x.costo_unitario, 0) < 0
      or coalesce(x.descuento_porcentaje, 0) not between 0 and 100
      or coalesce(x.iva_porcentaje, 0) not between 0 and 100
  ) then raise exception 'La orden contiene productos, cantidades o costos invalidos'; end if;

  v_numero := 'OC-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY')
    || '-' || lpad(nextval('public.seq_orden_compra')::text, 6, '0');
  insert into public.ordenes_compra (
    numero, empresa_id, proveedor_id, almacen_id, fecha_esperada,
    referencia, nota, idempotency_key, creado_por
  ) values (
    v_numero, p_empresa_id, p_proveedor_id, p_almacen_id, p_fecha_esperada,
    nullif(btrim(p_referencia), ''), nullif(btrim(p_nota), ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;

  insert into public.orden_compra_lineas (
    orden_id, producto_id, cantidad_ordenada, costo_unitario,
    descuento_porcentaje, iva_porcentaje, subtotal, descuento,
    impuesto, total, observacion
  )
  select v_id, x.producto_id, x.cantidad, coalesce(x.costo_unitario, 0),
         coalesce(x.descuento_porcentaje, 0), coalesce(x.iva_porcentaje, 0),
         round(x.cantidad * coalesce(x.costo_unitario, 0), 4),
         round(x.cantidad * coalesce(x.costo_unitario, 0)
           * coalesce(x.descuento_porcentaje, 0) / 100, 4),
         round((x.cantidad * coalesce(x.costo_unitario, 0)
           * (1 - coalesce(x.descuento_porcentaje, 0) / 100))
           * coalesce(x.iva_porcentaje, 0) / 100, 4),
         round((x.cantidad * coalesce(x.costo_unitario, 0)
           * (1 - coalesce(x.descuento_porcentaje, 0) / 100))
           * (1 + coalesce(x.iva_porcentaje, 0) / 100), 4),
         nullif(btrim(x.observacion), '')
  from jsonb_to_recordset(p_items) x(
    producto_id uuid, cantidad integer, costo_unitario numeric,
    descuento_porcentaje numeric, iva_porcentaje numeric, observacion text
  );

  update public.ordenes_compra o
  set subtotal = t.subtotal, descuento = t.descuento,
      impuesto = t.impuesto, total = t.total
  from (
    select orden_id, sum(subtotal) subtotal, sum(descuento) descuento,
           sum(impuesto) impuesto, sum(total) total
    from public.orden_compra_lineas where orden_id = v_id group by orden_id
  ) t where o.id = t.orden_id;

  insert into public.proveedor_empresas (
    proveedor_id, empresa_id, actualizado_por
  ) values (p_proveedor_id, p_empresa_id, auth.uid())
  on conflict (proveedor_id, empresa_id) do update
  set activo = true, actualizado_por = auth.uid(), updated_at = now();

  insert into public.orden_compra_eventos(
    orden_id, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (
    v_id, null, 'pendiente_aprobacion',
    concat('Orden creada', coalesce(' - ' || nullif(btrim(p_nota), ''), '')),
    auth.uid()
  );
  return jsonb_build_object('id', v_id, 'numero', v_numero, 'duplicado', false);
end;
$$;

create or replace function public.resolver_orden_compra_v21(
  p_orden_id uuid,
  p_aprobar boolean,
  p_nota text default null
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_compra%rowtype;
  v_estado text;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden aprobar compras';
  end if;
  select * into o from public.ordenes_compra where id = p_orden_id for update;
  if not found then raise exception 'La orden de compra no existe'; end if;
  if o.estado <> 'pendiente_aprobacion' then
    raise exception 'La orden ya fue procesada';
  end if;
  if p_aprobar and o.creado_por = auth.uid()
     and public.rol_usuario_actual() <> 'admin' then
    raise exception 'Control no puede aprobar una orden creada por el mismo usuario';
  end if;
  if not p_aprobar and btrim(coalesce(p_nota, '')) = '' then
    raise exception 'Indica el motivo del rechazo';
  end if;
  if p_aprobar and not public.usuario_puede_capacidad_empresa(
    o.empresa_id, o.almacen_id, 'compras'
  ) then raise exception 'No tienes compras y custodia habilitadas para esta orden'; end if;
  if p_aprobar and not exists (
    select 1
    from public.proveedores p
    join public.empresas e on e.id = o.empresa_id
    where p.id = o.proveedor_id and p.grupo_id = e.grupo_id and p.activo
  ) then raise exception 'El proveedor esta inactivo o ya no pertenece al grupo comprador'; end if;

  v_estado := case when p_aprobar then 'aprobada' else 'rechazada' end;
  update public.ordenes_compra
  set estado = v_estado, aprobado_por = auth.uid(),
      aprobado_at = case when p_aprobar then now() end,
      cerrado_at = case when not p_aprobar then now() end,
      nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = o.id;
  insert into public.orden_compra_eventos(
    orden_id, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (o.id, o.estado, v_estado, nullif(btrim(p_nota), ''), auth.uid());
  return v_estado;
end;
$$;

create or replace function public.cerrar_saldo_orden_compra_v21(
  p_orden_id uuid,
  p_motivo text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_compra%rowtype;
  v_estado text;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden cerrar una orden';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then
    raise exception 'Indica el motivo del cierre de la orden';
  end if;
  select * into o from public.ordenes_compra where id = p_orden_id for update;
  if not found then raise exception 'La orden de compra no existe'; end if;
  if o.estado not in ('aprobada', 'parcial') then
    raise exception 'La orden no tiene un saldo abierto que pueda cerrarse';
  end if;
  v_estado := case when o.estado = 'parcial' then 'cerrada_parcial' else 'anulada' end;
  update public.ordenes_compra
  set estado = v_estado, cerrado_at = now(),
      nota = concat_ws(E'\n', nota, 'Cierre de saldo: ' || btrim(p_motivo)),
      updated_at = now(), version = version + 1
  where id = o.id;
  insert into public.orden_compra_eventos(
    orden_id, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (o.id, o.estado, v_estado, btrim(p_motivo), auth.uid());
  return v_estado;
end;
$$;

-- ------------------------------------------------------------
-- 5. Recepcion parcial: disponible, cuarentena o saldo pendiente
-- ------------------------------------------------------------
create or replace function public.recibir_orden_compra_v21(
  p_orden_id uuid,
  p_items jsonb,
  p_documento_proveedor text,
  p_nota text default null,
  p_idempotency_key uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_compra%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_recepcion_id uuid;
  v_numero text;
  v_estado text;
  it record;
  v_pendiente integer;
  v_movimiento jsonb;
begin
  if v_rol not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para recibir compras';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_documento_proveedor, '')) = '' then
    raise exception 'La guia, factura o documento del proveedor es obligatorio';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 21)
  );
  select id, numero into v_recepcion_id, v_numero
  from public.recepciones_compra where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_recepcion_id, 'numero', v_numero, 'duplicado', true);
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La recepcion debe contener al menos una linea';
  end if;
  if exists (
    select orden_linea_id
    from jsonb_to_recordset(p_items) x(orden_linea_id uuid)
    group by orden_linea_id having count(*) > 1
  ) then raise exception 'La recepcion contiene lineas repetidas'; end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(
      orden_linea_id uuid, cantidad_conforme integer,
      cantidad_no_conforme integer, observacion text
    )
    where x.orden_linea_id is null
      or coalesce(x.cantidad_conforme, 0) < 0
      or coalesce(x.cantidad_no_conforme, 0) < 0
      or coalesce(x.cantidad_conforme, 0) + coalesce(x.cantidad_no_conforme, 0) <= 0
      or (coalesce(x.cantidad_no_conforme, 0) > 0
          and btrim(coalesce(x.observacion, p_nota, '')) = '')
  ) then
    raise exception 'La recepcion contiene cantidades invalidas o una no conformidad sin evidencia';
  end if;

  select * into o from public.ordenes_compra where id = p_orden_id for update;
  if not found then raise exception 'La orden de compra no existe'; end if;
  if o.estado not in ('aprobada', 'parcial') then
    raise exception 'La orden no esta disponible para recepcion';
  end if;
  if not public.usuario_puede_capacidad_empresa(o.empresa_id, o.almacen_id, 'compras') then
    raise exception 'No tienes compras y custodia habilitadas para esta empresa y almacen';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_items) x(
      orden_linea_id uuid, cantidad_conforme integer,
      cantidad_no_conforme integer, observacion text
    )
    left join public.orden_compra_lineas l
      on l.id = x.orden_linea_id and l.orden_id = o.id
    where l.id is null
      or coalesce(x.cantidad_conforme, 0) + coalesce(x.cantidad_no_conforme, 0)
         > l.cantidad_ordenada - l.cantidad_recibida - l.cantidad_no_conforme
  ) then raise exception 'Una cantidad supera el saldo pendiente de la orden'; end if;

  v_numero := 'RC-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY')
    || '-' || lpad(nextval('public.seq_recepcion_compra')::text, 6, '0');
  insert into public.recepciones_compra (
    numero, orden_id, empresa_id, almacen_id, documento_proveedor,
    nota, idempotency_key, recibido_por
  ) values (
    v_numero, o.id, o.empresa_id, o.almacen_id, btrim(p_documento_proveedor),
    nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid()
  ) returning id into v_recepcion_id;

  for it in
    select l.id as orden_linea_id, l.producto_id, l.costo_unitario,
           x.cantidad_conforme, x.cantidad_no_conforme, x.observacion
    from jsonb_to_recordset(p_items) x(
      orden_linea_id uuid, cantidad_conforme integer,
      cantidad_no_conforme integer, observacion text
    )
    join public.orden_compra_lineas l
      on l.id = x.orden_linea_id and l.orden_id = o.id
    order by l.producto_id
  loop
    if public.conteo_abierto_producto(o.almacen_id, it.producto_id) then
      raise exception 'Hay un conteo abierto para uno de los productos recibidos';
    end if;

    insert into public.recepcion_compra_lineas (
      recepcion_id, orden_linea_id, producto_id, cantidad_conforme,
      cantidad_no_conforme, costo_unitario, observacion
    ) values (
      v_recepcion_id, it.orden_linea_id, it.producto_id,
      it.cantidad_conforme, it.cantidad_no_conforme, it.costo_unitario,
      nullif(btrim(it.observacion), '')
    );

    if it.cantidad_conforme > 0 then
      v_movimiento := public.aplicar_movimiento_stock_v20(
        it.producto_id, o.almacen_id, o.empresa_id,
        'compra_recepcion'::public.tipo_movimiento, it.cantidad_conforme,
        v_recepcion_id, 'recepcion_compra',
        'Recepcion ' || v_numero || ' · Orden ' || o.numero
          || ' · Documento ' || btrim(p_documento_proveedor),
        null, null,
        md5('v21-compra-' || v_recepcion_id::text || '-' || it.orden_linea_id::text)::uuid
      );
    end if;

    if it.cantidad_no_conforme > 0 then
      perform set_config('boman.cuarentena_tipo', 'recepcion_compra_no_conforme', true);
      perform set_config('boman.cuarentena_documento_tipo', 'recepcion_compra', true);
      perform set_config('boman.cuarentena_documento_id', v_recepcion_id::text, true);
      perform set_config(
        'boman.cuarentena_detalle',
        concat('Orden ', o.numero, ' · ', coalesce(nullif(btrim(it.observacion), ''), p_nota)),
        true
      );
      insert into public.inventario_cuarentena as q(producto_id, almacen_id, cantidad)
      values (it.producto_id, o.almacen_id, it.cantidad_no_conforme)
      on conflict (producto_id, almacen_id) do update
      set cantidad = q.cantidad + excluded.cantidad, updated_at = now();
    end if;

    update public.orden_compra_lineas
    set cantidad_recibida = cantidad_recibida + it.cantidad_conforme,
        cantidad_no_conforme = cantidad_no_conforme + it.cantidad_no_conforme
    where id = it.orden_linea_id;
  end loop;

  select count(*)::integer into v_pendiente
  from public.orden_compra_lineas
  where orden_id = o.id
    and cantidad_recibida + cantidad_no_conforme < cantidad_ordenada;
  v_estado := case when v_pendiente = 0 then 'recibida' else 'parcial' end;
  update public.ordenes_compra
  set estado = v_estado, updated_at = now(), version = version + 1,
      cerrado_at = case when v_estado = 'recibida' then now() else null end
  where id = o.id;

  insert into public.orden_compra_eventos(
    orden_id, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (
    o.id, o.estado, v_estado,
    'Recepcion ' || v_numero || ' · Documento proveedor '
      || btrim(p_documento_proveedor)
      || coalesce(' · ' || nullif(btrim(p_nota), ''), ''),
    auth.uid()
  );
  return jsonb_build_object(
    'id', v_recepcion_id, 'numero', v_numero,
    'estado_orden', v_estado, 'duplicado', false
  );
end;
$$;

-- ------------------------------------------------------------
-- 6. Disposicion de producto no conforme recibido de proveedor
-- ------------------------------------------------------------
create or replace function public.resolver_no_conformidad_compra_v21(
  p_recepcion_linea_id uuid,
  p_accion text,
  p_cantidad integer,
  p_detalle text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol text := public.rol_usuario_actual();
  l public.recepcion_compra_lineas%rowtype;
  r public.recepciones_compra%rowtype;
  o public.ordenes_compra%rowtype;
  v_accion_id uuid;
  v_resuelto integer;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden resolver producto no conforme';
  end if;
  if p_accion not in ('liberar_disponible', 'devolver_proveedor', 'baja') then
    raise exception 'La disposicion seleccionada no es valida';
  end if;
  if p_accion = 'baja' and v_rol <> 'admin' then
    raise exception 'Solo Administracion puede autorizar la baja';
  end if;
  if coalesce(p_cantidad, 0) <= 0 then raise exception 'La cantidad debe ser mayor que cero'; end if;
  if length(btrim(coalesce(p_detalle, ''))) < 10 then
    raise exception 'Registra evidencia de la inspeccion o devolucion (minimo 10 caracteres)';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 21)
  );
  select id into v_accion_id
  from public.recepcion_compra_no_conformidad_acciones
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_accion_id, 'duplicado', true);
  end if;

  select * into l from public.recepcion_compra_lineas
  where id = p_recepcion_linea_id for update;
  if not found then raise exception 'La linea no conforme no existe'; end if;
  if l.cantidad_no_conforme <= 0 then raise exception 'La linea no tiene producto no conforme'; end if;
  select * into r from public.recepciones_compra where id = l.recepcion_id for update;
  if r.estado <> 'aplicada' then raise exception 'La recepcion fue rectificada'; end if;
  select * into o from public.ordenes_compra where id = r.orden_id;
  if not public.usuario_puede_almacen(r.almacen_id, true) then
    raise exception 'No tienes acceso operativo al almacen de cuarentena';
  end if;

  select coalesce(sum(a.cantidad), 0)::integer into v_resuelto
  from public.recepcion_compra_no_conformidad_acciones a
  where a.recepcion_linea_id = l.id;
  if v_resuelto + p_cantidad > l.cantidad_no_conforme then
    raise exception 'La disposicion supera el saldo no conforme pendiente';
  end if;
  if not exists (
    select 1 from public.inventario_cuarentena q
    where q.producto_id = l.producto_id and q.almacen_id = r.almacen_id
      and q.cantidad >= p_cantidad
  ) then raise exception 'El saldo fisico de cuarentena es insuficiente'; end if;

  insert into public.recepcion_compra_no_conformidad_acciones(
    recepcion_linea_id, accion, cantidad, detalle,
    idempotency_key, realizado_por
  ) values (
    l.id, p_accion, p_cantidad, btrim(p_detalle),
    p_idempotency_key, auth.uid()
  ) returning id into v_accion_id;

  perform set_config('boman.cuarentena_tipo', 'disposicion_no_conformidad_compra', true);
  perform set_config('boman.cuarentena_documento_tipo', 'no_conformidad_compra', true);
  perform set_config('boman.cuarentena_documento_id', v_accion_id::text, true);
  perform set_config(
    'boman.cuarentena_detalle',
    p_accion || ' · Orden ' || o.numero || ' · ' || btrim(p_detalle), true
  );
  update public.inventario_cuarentena
  set cantidad = cantidad - p_cantidad, updated_at = now()
  where producto_id = l.producto_id and almacen_id = r.almacen_id;

  if p_accion = 'liberar_disponible' then
    perform public.aplicar_movimiento_stock_v20(
      l.producto_id, r.almacen_id, r.empresa_id,
      'cuarentena_liberacion'::public.tipo_movimiento, p_cantidad,
      v_accion_id, 'no_conformidad_compra',
      'Liberacion de cuarentena · Orden ' || o.numero || ' · ' || btrim(p_detalle),
      null, null,
      md5('v21-libera-nc-' || v_accion_id::text)::uuid
    );
  end if;

  return jsonb_build_object(
    'id', v_accion_id, 'accion', p_accion, 'cantidad', p_cantidad,
    'saldo_pendiente', l.cantidad_no_conforme - v_resuelto - p_cantidad,
    'duplicado', false
  );
end;
$$;

-- ------------------------------------------------------------
-- 7. Rectificacion administrativa mediante movimientos compensatorios
-- ------------------------------------------------------------
create or replace function public.admin_rectificar_recepcion_compra_v21(
  p_recepcion_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.recepciones_compra%rowtype;
  o public.ordenes_compra%rowtype;
  v_rectificacion_id uuid;
  v_estado text;
  it record;
  v_original uuid;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede rectificar una recepcion de compra';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Describe el error y su evidencia con al menos 10 caracteres';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 21)
  );
  select id into v_rectificacion_id
  from public.rectificaciones_recepcion_compra where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_rectificacion_id, 'duplicado', true);
  end if;
  select * into r from public.recepciones_compra
  where id = p_recepcion_id for update;
  if not found then raise exception 'La recepcion de compra no existe'; end if;
  if r.estado <> 'aplicada' then raise exception 'La recepcion ya fue rectificada'; end if;
  select * into o from public.ordenes_compra where id = r.orden_id for update;

  if exists (
    select 1
    from public.recepcion_compra_lineas rl
    join public.recepcion_compra_no_conformidad_acciones a
      on a.recepcion_linea_id = rl.id
    where rl.recepcion_id = r.id
  ) then
    raise exception 'La recepcion ya tiene disposiciones de calidad y no puede rectificarse completa';
  end if;

  if exists (
    select 1
    from public.recepcion_compra_lineas rl
    join public.movimientos m on m.producto_id = rl.producto_id
      and m.entidad_id = r.almacen_id
      and m.created_at > r.created_at
      and m.grupo_id is distinct from r.id
      and not coalesce(m.anulado, false)
    where rl.recepcion_id = r.id and rl.cantidad_conforme > 0
  ) then
    raise exception 'Existen movimientos posteriores. Usa conteo controlado o una devolucion a proveedor';
  end if;
  if exists (
    select 1
    from public.recepcion_compra_lineas rl
    left join public.inventario i
      on i.producto_id = rl.producto_id and i.entidad_id = r.almacen_id
    left join public.inventario_cuarentena q
      on q.producto_id = rl.producto_id and q.almacen_id = r.almacen_id
    where rl.recepcion_id = r.id
      and (coalesce(i.cantidad, 0) < rl.cantidad_conforme
        or coalesce(q.cantidad, 0) < rl.cantidad_no_conforme)
  ) then raise exception 'El saldo disponible o en cuarentena ya no permite rectificar esta recepcion'; end if;

  insert into public.rectificaciones_recepcion_compra(
    recepcion_id, motivo, idempotency_key, realizado_por
  ) values (r.id, btrim(p_motivo), p_idempotency_key, auth.uid())
  returning id into v_rectificacion_id;

  for it in
    select * from public.recepcion_compra_lineas
    where recepcion_id = r.id order by producto_id
  loop
    if it.cantidad_conforme > 0 then
      select id into v_original
      from public.movimientos
      where grupo_id = r.id and producto_id = it.producto_id
        and tipo::text = 'compra_recepcion' and not anulado
      order by created_at limit 1 for update;

      perform public.aplicar_movimiento_stock_v20(
        it.producto_id, r.almacen_id, r.empresa_id,
        'compra_recepcion_reversa'::public.tipo_movimiento,
        -it.cantidad_conforme, v_rectificacion_id,
        'rectificacion_recepcion_compra',
        'Rectificacion de ' || r.numero || ' · ' || btrim(p_motivo),
        null, v_original,
        md5('v21-rectifica-' || v_rectificacion_id::text || '-' || it.orden_linea_id::text)::uuid
      );
      if v_original is not null then
        update public.movimientos
        set anulado = true, anulado_por = auth.uid(), anulado_at = now(),
            motivo_anulacion = 'Rectificacion de recepcion: ' || btrim(p_motivo)
        where id = v_original;
      end if;
    end if;

    if it.cantidad_no_conforme > 0 then
      perform set_config('boman.cuarentena_tipo', 'rectificacion_recepcion_compra', true);
      perform set_config('boman.cuarentena_documento_tipo', 'rectificacion_recepcion_compra', true);
      perform set_config('boman.cuarentena_documento_id', v_rectificacion_id::text, true);
      perform set_config('boman.cuarentena_detalle', btrim(p_motivo), true);
      update public.inventario_cuarentena
      set cantidad = cantidad - it.cantidad_no_conforme, updated_at = now()
      where producto_id = it.producto_id and almacen_id = r.almacen_id;
    end if;

    update public.orden_compra_lineas
    set cantidad_recibida = cantidad_recibida - it.cantidad_conforme,
        cantidad_no_conforme = cantidad_no_conforme - it.cantidad_no_conforme
    where id = it.orden_linea_id;
  end loop;

  v_estado := case
    when exists (
      select 1 from public.orden_compra_lineas
      where orden_id = o.id and cantidad_recibida + cantidad_no_conforme > 0
    ) then 'parcial' else 'aprobada' end;
  update public.ordenes_compra
  set estado = v_estado, cerrado_at = null, updated_at = now(), version = version + 1
  where id = o.id;
  update public.recepciones_compra
  set estado = 'rectificada', rectificada_por = auth.uid(), rectificada_at = now(),
      motivo_rectificacion = btrim(p_motivo)
  where id = r.id;
  insert into public.orden_compra_eventos(
    orden_id, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (
    o.id, o.estado, v_estado,
    'Recepcion ' || r.numero || ' rectificada · ' || btrim(p_motivo), auth.uid()
  );
  return jsonb_build_object(
    'id', v_rectificacion_id, 'recepcion', r.numero,
    'estado_orden', v_estado, 'duplicado', false
  );
end;
$$;

-- El trigger instalado en v20 conserva su nombre y pasa a reconocer los
-- movimientos de compra como una capacidad especifica de empresa/almacen.
create or replace function public.validar_capacidad_movimiento_v20()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('boman.reclasificando_multiempresa', true) = '1' then
    return new;
  end if;
  if new.empresa_id is null then return new; end if;

  if new.tipo::text in ('venta_xml', 'devolucion_venta', 'venta_xml_reversa') then
    if not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = new.empresa_id and ea.almacen_id = new.entidad_id
        and ea.permite_ventas and ea.custodia_inventario
    ) then raise exception 'La empresa no tiene habilitadas ventas y custodia en este almacen'; end if;
  elsif new.tipo::text in ('entrada', 'compra_recepcion') then
    if not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = new.empresa_id and ea.almacen_id = new.entidad_id
        and ea.permite_compras and ea.custodia_inventario
    ) then raise exception 'La empresa no tiene habilitadas compras y custodia en este almacen'; end if;
  elsif new.tipo::text in (
    'salida', 'ajuste', 'cuarentena_liberacion',
    'movimiento_manual_reversa', 'compra_recepcion_reversa'
  ) then
    if not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = new.empresa_id and ea.almacen_id = new.entidad_id
        and ea.custodia_inventario
    ) then raise exception 'La empresa no tiene custodia habilitada en este almacen'; end if;
  elsif new.tipo::text in (
    'transferencia_envio', 'transferencia_recibo', 'transferencia_retorno'
  ) then
    if not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = new.empresa_id and ea.almacen_id = new.entidad_id
        and ea.custodia_inventario
    ) then raise exception 'La empresa no tiene custodia habilitada en el almacen del movimiento'; end if;
    if new.entidad_destino_id is not null and not exists (
      select 1 from public.empresa_almacenes ea
      where ea.almacen_id = new.entidad_destino_id
        and ea.custodia_inventario
    ) then raise exception 'El otro almacen de la transferencia no tiene una empresa custodio habilitada'; end if;
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- 8. Vistas de seguimiento gerencial
-- ------------------------------------------------------------
create or replace view public.vista_ordenes_compra_resumen
with (security_invoker = true) as
select
  o.id,
  o.numero,
  o.empresa_id,
  e.codigo as empresa_codigo,
  e.razon_social as empresa,
  o.proveedor_id,
  p.identificacion as proveedor_identificacion,
  p.razon_social as proveedor,
  o.almacen_id,
  a.nombre as almacen,
  o.estado,
  o.fecha_orden,
  o.fecha_esperada,
  o.referencia,
  o.subtotal,
  o.descuento,
  o.impuesto,
  o.total,
  coalesce(sum(l.cantidad_ordenada), 0)::integer as unidades_ordenadas,
  coalesce(sum(l.cantidad_recibida), 0)::integer as unidades_conformes,
  coalesce(sum(l.cantidad_no_conforme), 0)::integer as unidades_no_conformes,
  coalesce(sum(
    l.cantidad_ordenada - l.cantidad_recibida - l.cantidad_no_conforme
  ), 0)::integer as unidades_pendientes,
  o.creado_por,
  o.aprobado_por,
  o.created_at,
  o.updated_at
from public.ordenes_compra o
join public.empresas e on e.id = o.empresa_id
join public.proveedores p on p.id = o.proveedor_id
join public.almacenes a on a.id = o.almacen_id
left join public.orden_compra_lineas l on l.orden_id = o.id
group by o.id, e.id, p.id, a.id;

create or replace view public.vista_compras_producto
with (security_invoker = true) as
select
  o.empresa_id,
  o.proveedor_id,
  o.almacen_id,
  l.producto_id,
  p.sku,
  p.nombre as producto,
  sum(l.cantidad_ordenada)::integer as cantidad_ordenada,
  sum(l.cantidad_recibida)::integer as cantidad_conforme,
  sum(l.cantidad_no_conforme)::integer as cantidad_no_conforme,
  sum(l.total) as valor_ordenado,
  case when sum(l.cantidad_ordenada) > 0
    then round(sum(l.subtotal - l.descuento) / sum(l.cantidad_ordenada), 4)
    else 0 end as costo_neto_promedio_ordenado
from public.ordenes_compra o
join public.orden_compra_lineas l on l.orden_id = o.id
join public.productos p on p.id = l.producto_id
where o.estado in ('aprobada', 'parcial', 'recibida')
group by o.empresa_id, o.proveedor_id, o.almacen_id, l.producto_id, p.id;

-- ------------------------------------------------------------
-- 9. Propiedad, privilegios y recarga de PostgREST
-- ------------------------------------------------------------
alter function public.usuario_puede_grupo_compra(uuid) owner to postgres;
alter function public.puede_ver_orden_compra(uuid) owner to postgres;
alter function public.puede_ver_recepcion_compra(uuid) owner to postgres;
alter function public.guardar_proveedor_v21(uuid, uuid, text, text, text, text, text, text, text, boolean) owner to postgres;
alter function public.crear_orden_compra_v21(uuid, uuid, uuid, jsonb, date, text, text, uuid) owner to postgres;
alter function public.resolver_orden_compra_v21(uuid, boolean, text) owner to postgres;
alter function public.cerrar_saldo_orden_compra_v21(uuid, text) owner to postgres;
alter function public.recibir_orden_compra_v21(uuid, jsonb, text, text, uuid) owner to postgres;
alter function public.resolver_no_conformidad_compra_v21(uuid, text, integer, text, uuid) owner to postgres;
alter function public.admin_rectificar_recepcion_compra_v21(uuid, text, uuid) owner to postgres;
alter function public.validar_capacidad_movimiento_v20() owner to postgres;

revoke all on public.proveedores from public, anon;
revoke all on public.proveedor_empresas from public, anon;
revoke all on public.ordenes_compra from public, anon;
revoke all on public.orden_compra_lineas from public, anon;
revoke all on public.recepciones_compra from public, anon;
revoke all on public.recepcion_compra_lineas from public, anon;
revoke all on public.recepcion_compra_no_conformidad_acciones from public, anon;
revoke all on public.rectificaciones_recepcion_compra from public, anon;
revoke all on public.orden_compra_eventos from public, anon;

revoke insert, update, delete on public.proveedores from authenticated;
revoke insert, update, delete on public.proveedor_empresas from authenticated;
revoke insert, update, delete on public.ordenes_compra from authenticated;
revoke insert, update, delete on public.orden_compra_lineas from authenticated;
revoke insert, update, delete on public.recepciones_compra from authenticated;
revoke insert, update, delete on public.recepcion_compra_lineas from authenticated;
revoke insert, update, delete on public.recepcion_compra_no_conformidad_acciones from authenticated;
revoke insert, update, delete on public.rectificaciones_recepcion_compra from authenticated;
revoke insert, update, delete on public.orden_compra_eventos from authenticated;

grant select on public.proveedores to authenticated;
grant select on public.proveedor_empresas to authenticated;
grant select on public.ordenes_compra to authenticated;
grant select on public.orden_compra_lineas to authenticated;
grant select on public.recepciones_compra to authenticated;
grant select on public.recepcion_compra_lineas to authenticated;
grant select on public.recepcion_compra_no_conformidad_acciones to authenticated;
grant select on public.rectificaciones_recepcion_compra to authenticated;
grant select on public.orden_compra_eventos to authenticated;
grant select on public.vista_ordenes_compra_resumen to authenticated;
grant select on public.vista_compras_producto to authenticated;

revoke execute on function public.usuario_puede_grupo_compra(uuid) from public, anon;
revoke execute on function public.puede_ver_orden_compra(uuid) from public, anon;
revoke execute on function public.puede_ver_recepcion_compra(uuid) from public, anon;
revoke execute on function public.guardar_proveedor_v21(uuid, uuid, text, text, text, text, text, text, text, boolean) from public, anon;
revoke execute on function public.crear_orden_compra_v21(uuid, uuid, uuid, jsonb, date, text, text, uuid) from public, anon;
revoke execute on function public.resolver_orden_compra_v21(uuid, boolean, text) from public, anon;
revoke execute on function public.cerrar_saldo_orden_compra_v21(uuid, text) from public, anon;
revoke execute on function public.recibir_orden_compra_v21(uuid, jsonb, text, text, uuid) from public, anon;
revoke execute on function public.resolver_no_conformidad_compra_v21(uuid, text, integer, text, uuid) from public, anon;
revoke execute on function public.admin_rectificar_recepcion_compra_v21(uuid, text, uuid) from public, anon;

grant execute on function public.usuario_puede_grupo_compra(uuid) to authenticated;
grant execute on function public.puede_ver_orden_compra(uuid) to authenticated;
grant execute on function public.puede_ver_recepcion_compra(uuid) to authenticated;
grant execute on function public.guardar_proveedor_v21(uuid, uuid, text, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.crear_orden_compra_v21(uuid, uuid, uuid, jsonb, date, text, text, uuid) to authenticated;
grant execute on function public.resolver_orden_compra_v21(uuid, boolean, text) to authenticated;
grant execute on function public.cerrar_saldo_orden_compra_v21(uuid, text) to authenticated;
grant execute on function public.recibir_orden_compra_v21(uuid, jsonb, text, text, uuid) to authenticated;
grant execute on function public.resolver_no_conformidad_compra_v21(uuid, text, integer, text, uuid) to authenticated;
grant execute on function public.admin_rectificar_recepcion_compra_v21(uuid, text, uuid) to authenticated;

revoke execute on function public.validar_capacidad_movimiento_v20()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
