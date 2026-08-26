-- ============================================================
-- BOMAN INVENTARIO - Fase ERP operativa v12
-- Documentos multilínea, solicitudes, transferencias con recepción,
-- conteos aprobados, permisos por almacén y stock operativo.
-- Ejecutar una sola vez DESPUÉS de v11.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Roles operativos y asignación explícita de almacenes
-- ------------------------------------------------------------
alter type public.rol_usuario add value if not exists 'tienda';
alter type public.rol_usuario add value if not exists 'control';

create table if not exists public.perfil_almacenes (
  perfil_id uuid not null references public.perfiles(id) on delete cascade,
  almacen_id uuid not null references public.almacenes(id),
  created_at timestamptz not null default now(),
  primary key (perfil_id, almacen_id)
);

insert into public.perfil_almacenes (perfil_id, almacen_id)
select id, entidad_id
from public.perfiles
where entidad_id is not null
on conflict do nothing;

alter table public.perfil_almacenes enable row level security;

create or replace function public.rol_usuario_actual()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.rol::text
  from public.perfiles p
  where p.id = auth.uid() and p.activo;
$$;

create or replace function public.usuario_puede_almacen(
  p_almacen_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid()
      and p.activo
      and (
        (p.rol::text in ('admin', 'control'))
        or (not p_escritura and p.rol::text = 'gerencia')
        or p.entidad_id = p_almacen_id
        or exists (
          select 1 from public.perfil_almacenes pa
          where pa.perfil_id = p.id and pa.almacen_id = p_almacen_id
        )
      )
  );
$$;

drop policy if exists "leer_perfil_almacenes" on public.perfil_almacenes;
create policy "leer_perfil_almacenes"
on public.perfil_almacenes for select to authenticated using (
  perfil_id = auth.uid()
  or public.rol_usuario_actual() = 'admin'
);

create or replace function public.admin_asignar_almacenes(
  p_perfil_id uuid,
  p_almacen_ids uuid[]
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol text;
  v_ids uuid[] := coalesce(p_almacen_ids, array[]::uuid[]);
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo un administrador puede asignar almacenes';
  end if;

  select rol::text into v_rol
  from public.perfiles
  where id = p_perfil_id and activo;
  if not found then raise exception 'El usuario no existe o está inactivo'; end if;

  if exists (
    select 1 from unnest(v_ids) x
    left join public.almacenes a on a.id = x and a.activo
    where a.id is null
  ) then
    raise exception 'Uno de los almacenes asignados no existe o está inactivo';
  end if;

  if v_rol not in ('admin', 'control', 'gerencia') and cardinality(v_ids) = 0 then
    raise exception 'Los usuarios operativos deben tener al menos un almacén asignado';
  end if;

  delete from public.perfil_almacenes where perfil_id = p_perfil_id;
  if v_rol not in ('admin', 'control', 'gerencia') then
    insert into public.perfil_almacenes (perfil_id, almacen_id)
    select p_perfil_id, x from unnest(v_ids) x
    on conflict do nothing;

    update public.perfiles
    set entidad_id = v_ids[1]
    where id = p_perfil_id;
  else
    update public.perfiles set entidad_id = null where id = p_perfil_id;
  end if;
end;
$$;

-- Las políticas históricas pasan a respetar también asignaciones múltiples.
drop policy if exists "leer_inventario" on public.inventario;
create policy "leer_inventario" on public.inventario
for select to authenticated using (
  public.usuario_puede_almacen(entidad_id, false)
);

drop policy if exists "leer_movimientos" on public.movimientos;
create policy "leer_movimientos" on public.movimientos
for select to authenticated using (
  public.usuario_puede_almacen(entidad_id, false)
  or public.usuario_puede_almacen(entidad_destino_id, false)
);

-- ------------------------------------------------------------
-- 2. Configuración de inventario por producto y almacén
-- ------------------------------------------------------------
create table if not exists public.producto_almacen_config (
  producto_id uuid not null references public.productos(id) on delete cascade,
  almacen_id uuid not null references public.almacenes(id),
  activo boolean not null default true,
  stock_minimo integer not null default 0 check (stock_minimo >= 0),
  stock_maximo integer check (stock_maximo is null or stock_maximo >= 0),
  stock_seguridad integer not null default 0 check (stock_seguridad >= 0),
  punto_reposicion integer not null default 0 check (punto_reposicion >= 0),
  ubicacion text,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.perfiles(id),
  primary key (producto_id, almacen_id),
  check (stock_maximo is null or stock_maximo >= stock_minimo)
);

insert into public.producto_almacen_config
  (producto_id, almacen_id, stock_minimo, punto_reposicion)
select p.id, a.id, p.stock_minimo, p.stock_minimo
from public.productos p
cross join public.almacenes a
where p.activo and a.activo
on conflict do nothing;

create index if not exists idx_producto_almacen_config_almacen
  on public.producto_almacen_config(almacen_id, producto_id);

alter table public.producto_almacen_config enable row level security;

drop policy if exists "leer_producto_almacen_config" on public.producto_almacen_config;
create policy "leer_producto_almacen_config"
on public.producto_almacen_config for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
);

create or replace function public.sembrar_config_producto_almacen()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.producto_almacen_config
    (producto_id, almacen_id, stock_minimo, punto_reposicion)
  select new.id, a.id, coalesce(new.stock_minimo, 0), coalesce(new.stock_minimo, 0)
  from public.almacenes a where a.activo
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_sembrar_config_producto_almacen on public.productos;
create trigger trg_sembrar_config_producto_almacen
after insert on public.productos
for each row execute function public.sembrar_config_producto_almacen();

create or replace function public.sembrar_config_nuevo_almacen()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.producto_almacen_config
    (producto_id, almacen_id, stock_minimo, punto_reposicion)
  select p.id, new.id, coalesce(p.stock_minimo, 0), coalesce(p.stock_minimo, 0)
  from public.productos p where p.activo
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists trg_sembrar_config_nuevo_almacen on public.almacenes;
create trigger trg_sembrar_config_nuevo_almacen
after insert on public.almacenes
for each row execute function public.sembrar_config_nuevo_almacen();

-- Historial completo del maestro: además del cambio de estado de v8, conserva
-- quién modificó descripción, clasificación, talla, color, precio o mínimo.
create table if not exists public.productos_maestro_cambios (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references public.productos(id),
  realizado_por uuid references public.perfiles(id),
  valores_anteriores jsonb not null,
  valores_nuevos jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_productos_maestro_cambios_producto_fecha
  on public.productos_maestro_cambios(producto_id, created_at desc);

alter table public.productos_maestro_cambios enable row level security;
drop policy if exists "control_lee_productos_maestro_cambios" on public.productos_maestro_cambios;
create policy "control_lee_productos_maestro_cambios"
on public.productos_maestro_cambios for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);

create or replace function public.auditar_producto_maestro()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anterior jsonb;
  v_nuevo jsonb;
begin
  v_anterior := jsonb_build_object(
    'nombre', old.nombre, 'categoria_id', old.categoria_id,
    'subcategoria_id', old.subcategoria_id, 'talla', old.talla,
    'color', old.color, 'stock_minimo', old.stock_minimo,
    'precio', old.precio, 'club', old.club, 'activo', old.activo
  );
  v_nuevo := jsonb_build_object(
    'nombre', new.nombre, 'categoria_id', new.categoria_id,
    'subcategoria_id', new.subcategoria_id, 'talla', new.talla,
    'color', new.color, 'stock_minimo', new.stock_minimo,
    'precio', new.precio, 'club', new.club, 'activo', new.activo
  );
  if v_anterior is distinct from v_nuevo then
    insert into public.productos_maestro_cambios
      (producto_id, realizado_por, valores_anteriores, valores_nuevos)
    values (old.id, auth.uid(), v_anterior, v_nuevo);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_auditar_producto_maestro on public.productos;
create trigger trg_auditar_producto_maestro
after update on public.productos
for each row execute function public.auditar_producto_maestro();

create or replace function public.guardar_config_producto_almacen(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administración o Control pueden configurar mínimos';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'No hay configuraciones para guardar';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      producto_id uuid, almacen_id uuid, stock_minimo integer,
      stock_maximo integer, stock_seguridad integer,
      punto_reposicion integer, ubicacion text, activo boolean
    )
    where x.producto_id is null or x.almacen_id is null
       or coalesce(x.stock_minimo, 0) < 0
       or coalesce(x.stock_seguridad, 0) < 0
       or coalesce(x.punto_reposicion, 0) < 0
       or (x.stock_maximo is not null and x.stock_maximo < coalesce(x.stock_minimo, 0))
  ) then
    raise exception 'Hay valores inválidos en la configuración';
  end if;

  insert into public.producto_almacen_config as c
    (producto_id, almacen_id, stock_minimo, stock_maximo,
     stock_seguridad, punto_reposicion, ubicacion, activo, updated_by, updated_at)
  select x.producto_id, x.almacen_id, coalesce(x.stock_minimo, 0), x.stock_maximo,
         coalesce(x.stock_seguridad, 0), coalesce(x.punto_reposicion, 0),
         nullif(btrim(x.ubicacion), ''), coalesce(x.activo, true), auth.uid(), now()
  from jsonb_to_recordset(p_items) as x(
    producto_id uuid, almacen_id uuid, stock_minimo integer,
    stock_maximo integer, stock_seguridad integer,
    punto_reposicion integer, ubicacion text, activo boolean
  )
  join public.productos p on p.id = x.producto_id and p.activo
  join public.almacenes a on a.id = x.almacen_id and a.activo
  on conflict (producto_id, almacen_id) do update
  set stock_minimo = excluded.stock_minimo,
      stock_maximo = excluded.stock_maximo,
      stock_seguridad = excluded.stock_seguridad,
      punto_reposicion = excluded.punto_reposicion,
      ubicacion = excluded.ubicacion,
      activo = excluded.activo,
      updated_by = auth.uid(),
      updated_at = now();

  get diagnostics v_total = row_count;
  return v_total;
end;
$$;

-- ------------------------------------------------------------
-- 3. Documentos operativos multilínea
-- ------------------------------------------------------------
create sequence if not exists public.seq_solicitud_reposicion;
create sequence if not exists public.seq_transferencia_inventario;
create sequence if not exists public.seq_conteo_inventario;

create table if not exists public.documentos_inventario (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  tipo text not null check (tipo in ('solicitud_reposicion', 'transferencia', 'conteo')),
  estado text not null check (estado in (
    'borrador', 'solicitado', 'aprobado', 'rechazado', 'preparando',
    'despachado', 'en_transito', 'recibido', 'recibido_con_diferencia',
    'cerrado_con_diferencia', 'en_conteo', 'pendiente_revision',
    'aplicado', 'anulado'
  )),
  origen_id uuid references public.almacenes(id),
  destino_id uuid references public.almacenes(id),
  documento_origen_id uuid references public.documentos_inventario(id),
  prioridad text not null default 'normal' check (prioridad in ('normal', 'urgente')),
  referencia text,
  nota text,
  idempotency_key uuid unique,
  creado_por uuid not null references public.perfiles(id),
  aprobado_por uuid references public.perfiles(id),
  preparado_por uuid references public.perfiles(id),
  despachado_por uuid references public.perfiles(id),
  recibido_por uuid references public.perfiles(id),
  revisado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  aprobado_at timestamptz,
  despachado_at timestamptz,
  recibido_at timestamptz,
  aplicado_at timestamptz,
  version integer not null default 1,
  check (origen_id is null or destino_id is null or origen_id <> destino_id)
);

create table if not exists public.documento_inventario_lineas (
  id uuid primary key default gen_random_uuid(),
  documento_id uuid not null references public.documentos_inventario(id) on delete cascade,
  producto_id uuid not null references public.productos(id),
  cantidad_solicitada integer check (cantidad_solicitada is null or cantidad_solicitada > 0),
  cantidad_aprobada integer check (cantidad_aprobada is null or cantidad_aprobada >= 0),
  cantidad_preparada integer check (cantidad_preparada is null or cantidad_preparada >= 0),
  cantidad_despachada integer check (cantidad_despachada is null or cantidad_despachada >= 0),
  cantidad_recibida integer check (cantidad_recibida is null or cantidad_recibida >= 0),
  cantidad_rechazada integer check (cantidad_rechazada is null or cantidad_rechazada >= 0),
  stock_sistema integer check (stock_sistema is null or stock_sistema >= 0),
  cantidad_contada integer check (cantidad_contada is null or cantidad_contada >= 0),
  cantidad_reconteo integer check (cantidad_reconteo is null or cantidad_reconteo >= 0),
  observacion text,
  unique (documento_id, producto_id)
);

create table if not exists public.documento_inventario_eventos (
  id uuid primary key default gen_random_uuid(),
  documento_id uuid not null references public.documentos_inventario(id) on delete cascade,
  estado_anterior text,
  estado_nuevo text not null,
  detalle text,
  usuario_id uuid not null references public.perfiles(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_documentos_inventario_tipo_estado
  on public.documentos_inventario(tipo, estado, created_at desc);
create index if not exists idx_documentos_inventario_origen
  on public.documentos_inventario(origen_id, created_at desc);
create index if not exists idx_documentos_inventario_destino
  on public.documentos_inventario(destino_id, created_at desc);
create index if not exists idx_documento_lineas_producto
  on public.documento_inventario_lineas(producto_id, documento_id);
create index if not exists idx_documento_eventos_doc_fecha
  on public.documento_inventario_eventos(documento_id, created_at);

alter table public.documentos_inventario enable row level security;
alter table public.documento_inventario_lineas enable row level security;
alter table public.documento_inventario_eventos enable row level security;

create or replace function public.puede_ver_documento(p_documento_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.documentos_inventario d
    where d.id = p_documento_id
      and (
        public.usuario_puede_almacen(d.origen_id, false)
        or public.usuario_puede_almacen(d.destino_id, false)
      )
  );
$$;

drop policy if exists "leer_documentos_inventario" on public.documentos_inventario;
create policy "leer_documentos_inventario"
on public.documentos_inventario for select to authenticated using (
  public.usuario_puede_almacen(origen_id, false)
  or public.usuario_puede_almacen(destino_id, false)
);

drop policy if exists "leer_documento_inventario_lineas" on public.documento_inventario_lineas;
create policy "leer_documento_inventario_lineas"
on public.documento_inventario_lineas for select to authenticated using (
  public.puede_ver_documento(documento_id)
);

drop policy if exists "leer_documento_inventario_eventos" on public.documento_inventario_eventos;
create policy "leer_documento_inventario_eventos"
on public.documento_inventario_eventos for select to authenticated using (
  public.puede_ver_documento(documento_id)
);

create or replace function public.numero_documento_inventario(p_tipo text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_num bigint;
  v_prefijo text;
begin
  if p_tipo = 'solicitud_reposicion' then
    v_num := nextval('public.seq_solicitud_reposicion'); v_prefijo := 'SR';
  elsif p_tipo = 'transferencia' then
    v_num := nextval('public.seq_transferencia_inventario'); v_prefijo := 'TR';
  elsif p_tipo = 'conteo' then
    v_num := nextval('public.seq_conteo_inventario'); v_prefijo := 'CT';
  else
    raise exception 'Tipo de documento no válido';
  end if;
  return v_prefijo || '-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY')
         || '-' || lpad(v_num::text, 6, '0');
end;
$$;

create or replace function public.registrar_evento_documento(
  p_documento_id uuid,
  p_estado_anterior text,
  p_estado_nuevo text,
  p_detalle text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.documento_inventario_eventos
    (documento_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  values
    (p_documento_id, p_estado_anterior, p_estado_nuevo, nullif(btrim(p_detalle), ''), auth.uid());
end;
$$;

create or replace function public.conteo_abierto_producto(
  p_almacen_id uuid,
  p_producto_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.documentos_inventario d
    join public.documento_inventario_lineas l on l.documento_id = d.id
    where d.tipo = 'conteo'
      and d.origen_id = p_almacen_id
      and l.producto_id = p_producto_id
      and d.estado in ('en_conteo', 'pendiente_revision')
  );
$$;

-- ------------------------------------------------------------
-- 4. Solicitudes de reposición
-- ------------------------------------------------------------
create or replace function public.crear_solicitud_reposicion(
  p_destino_id uuid,
  p_items jsonb,
  p_prioridad text default 'normal',
  p_nota text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_rol text := public.rol_usuario_actual();
begin
  if p_idempotency_key is not null then
    select id into v_id from public.documentos_inventario
    where idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;

  if v_rol not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para solicitar reposición';
  end if;
  if not public.usuario_puede_almacen(p_destino_id, true) then
    raise exception 'No tienes permiso para solicitar para ese almacén';
  end if;
  if p_prioridad not in ('normal', 'urgente') then
    raise exception 'Prioridad no válida';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La solicitud debe tener al menos un producto';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer)
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or coalesce(x.cantidad, 0) <= 0
  ) then
    raise exception 'La solicitud contiene productos o cantidades inválidas';
  end if;

  insert into public.documentos_inventario
    (numero, tipo, estado, destino_id, prioridad, nota, idempotency_key, creado_por)
  values
    (public.numero_documento_inventario('solicitud_reposicion'),
     'solicitud_reposicion', 'solicitado', p_destino_id, p_prioridad,
     nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid())
  returning id into v_id;

  insert into public.documento_inventario_lineas
    (documento_id, producto_id, cantidad_solicitada, observacion)
  select v_id, x.producto_id, sum(x.cantidad)::integer, max(nullif(btrim(x.observacion), ''))
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  group by x.producto_id;

  perform public.registrar_evento_documento(v_id, null, 'solicitado', p_nota);
  return v_id;
end;
$$;

create or replace function public.resolver_solicitud_reposicion(
  p_solicitud_id uuid,
  p_aprobar boolean,
  p_origen_id uuid default null,
  p_items jsonb default null,
  p_nota text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.documentos_inventario%rowtype;
  v_transferencia uuid;
  v_rol text := public.rol_usuario_actual();
  it record;
  v_aprobada integer;
  v_stock integer;
  v_reservado integer;
begin
  if v_rol not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para resolver solicitudes';
  end if;

  select * into s from public.documentos_inventario
  where id = p_solicitud_id for update;
  if not found or s.tipo <> 'solicitud_reposicion' then
    raise exception 'La solicitud no existe';
  end if;
  if s.estado <> 'solicitado' then
    raise exception 'La solicitud ya fue procesada';
  end if;

  if not p_aprobar then
    if btrim(coalesce(p_nota, '')) = '' then
      raise exception 'Debes indicar el motivo del rechazo';
    end if;
    update public.documentos_inventario
    set estado = 'rechazado', revisado_por = auth.uid(), nota = concat_ws(E'\n', nota, btrim(p_nota)),
        updated_at = now(), version = version + 1
    where id = s.id;
    perform public.registrar_evento_documento(s.id, 'solicitado', 'rechazado', p_nota);
    return null;
  end if;

  if p_origen_id is null or p_origen_id = s.destino_id then
    raise exception 'Selecciona una bodega de origen diferente al destino';
  end if;
  if not public.usuario_puede_almacen(p_origen_id, true) then
    raise exception 'No tienes permiso para despachar desde ese almacén';
  end if;

  if p_idempotency_key is not null then
    select id into v_transferencia from public.documentos_inventario
    where idempotency_key = p_idempotency_key;
    if found then return v_transferencia; end if;
  end if;

  insert into public.documentos_inventario
    (numero, tipo, estado, origen_id, destino_id, documento_origen_id,
     prioridad, nota, idempotency_key, creado_por, aprobado_por, aprobado_at)
  values
    (public.numero_documento_inventario('transferencia'), 'transferencia', 'aprobado',
     p_origen_id, s.destino_id, s.id, s.prioridad, nullif(btrim(p_nota), ''),
     p_idempotency_key, auth.uid(), auth.uid(), now())
  returning id into v_transferencia;

  for it in
    select l.*,
           coalesce((select (x->>'cantidad')::integer
                     from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
                     where (x->>'producto_id')::uuid = l.producto_id
                     limit 1), l.cantidad_solicitada) as aprobar
    from public.documento_inventario_lineas l
    where l.documento_id = s.id
  loop
    v_aprobada := coalesce(it.aprobar, 0);
    if v_aprobada < 0 or v_aprobada > it.cantidad_solicitada then
      raise exception 'La cantidad aprobada no puede superar la solicitada';
    end if;
    if v_aprobada = 0 then
      update public.documento_inventario_lineas set cantidad_aprobada = 0 where id = it.id;
      continue;
    end if;

    select coalesce(i.cantidad, 0) into v_stock
    from public.productos p
    left join public.inventario i on i.producto_id = p.id and i.entidad_id = p_origen_id
    where p.id = it.producto_id and p.activo;

    select coalesce(sum(coalesce(l.cantidad_preparada, l.cantidad_aprobada, 0)), 0)
    into v_reservado
    from public.documentos_inventario d
    join public.documento_inventario_lineas l on l.documento_id = d.id
    where d.tipo = 'transferencia' and d.origen_id = p_origen_id
      and d.estado in ('aprobado', 'preparando') and l.producto_id = it.producto_id;

    if v_stock - v_reservado < v_aprobada then
      raise exception 'Stock disponible insuficiente para aprobar uno de los productos';
    end if;

    update public.documento_inventario_lineas
    set cantidad_aprobada = v_aprobada where id = it.id;
    insert into public.documento_inventario_lineas
      (documento_id, producto_id, cantidad_solicitada, cantidad_aprobada, observacion)
    values
      (v_transferencia, it.producto_id, it.cantidad_solicitada, v_aprobada, it.observacion);
  end loop;

  if not exists (
    select 1 from public.documento_inventario_lineas
    where documento_id = v_transferencia and cantidad_aprobada > 0
  ) then
    raise exception 'Debes aprobar al menos una línea';
  end if;

  update public.documentos_inventario
  set estado = 'aprobado', origen_id = p_origen_id, aprobado_por = auth.uid(), aprobado_at = now(),
      nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = s.id;

  perform public.registrar_evento_documento(s.id, 'solicitado', 'aprobado', p_nota);
  perform public.registrar_evento_documento(v_transferencia, null, 'aprobado', 'Creada desde ' || s.numero);
  return v_transferencia;
end;
$$;

-- ------------------------------------------------------------
-- 5. Transferencias: preparar, despachar, transportar y recibir
-- ------------------------------------------------------------
create or replace function public.crear_transferencia_directa(
  p_origen_id uuid,
  p_destino_id uuid,
  p_items jsonb,
  p_nota text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_rol text := public.rol_usuario_actual();
  it record;
  v_stock integer;
  v_reservado integer;
begin
  if p_idempotency_key is not null then
    select id into v_id from public.documentos_inventario
    where idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;
  if v_rol not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para crear transferencias';
  end if;
  if p_origen_id is null or p_destino_id is null or p_origen_id = p_destino_id then
    raise exception 'El origen y destino deben ser diferentes';
  end if;
  if not public.usuario_puede_almacen(p_origen_id, true) then
    raise exception 'No tienes permiso sobre el almacén de origen';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La transferencia debe tener productos';
  end if;

  for it in
    select producto_id, sum(cantidad)::integer cantidad, max(observacion) observacion
    from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
    group by producto_id
  loop
    if it.producto_id is null or it.cantidad <= 0 or not exists (
      select 1 from public.productos where id = it.producto_id and activo
    ) then raise exception 'La transferencia contiene una línea inválida'; end if;

    select coalesce(i.cantidad, 0) into v_stock
    from public.productos p left join public.inventario i
      on i.producto_id = p.id and i.entidad_id = p_origen_id
    where p.id = it.producto_id;
    select coalesce(sum(coalesce(l.cantidad_preparada, l.cantidad_aprobada, 0)), 0)
    into v_reservado
    from public.documentos_inventario d
    join public.documento_inventario_lineas l on l.documento_id = d.id
    where d.tipo = 'transferencia' and d.origen_id = p_origen_id
      and d.estado in ('aprobado', 'preparando') and l.producto_id = it.producto_id;
    if v_stock - v_reservado < it.cantidad then
      raise exception 'Stock disponible insuficiente para uno de los productos';
    end if;
  end loop;

  insert into public.documentos_inventario
    (numero, tipo, estado, origen_id, destino_id, nota, idempotency_key,
     creado_por, aprobado_por, aprobado_at)
  values
    (public.numero_documento_inventario('transferencia'), 'transferencia', 'aprobado',
     p_origen_id, p_destino_id, nullif(btrim(p_nota), ''), p_idempotency_key,
     auth.uid(), auth.uid(), now())
  returning id into v_id;

  insert into public.documento_inventario_lineas
    (documento_id, producto_id, cantidad_solicitada, cantidad_aprobada, observacion)
  select v_id, producto_id, sum(cantidad)::integer, sum(cantidad)::integer,
         max(nullif(btrim(observacion), ''))
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  group by producto_id;

  perform public.registrar_evento_documento(v_id, null, 'aprobado', p_nota);
  return v_id;
end;
$$;

create or replace function public.guardar_preparacion_transferencia(
  p_documento_id uuid,
  p_items jsonb,
  p_nota text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para preparar transferencias';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'transferencia' or d.estado not in ('aprobado', 'preparando') then
    raise exception 'La transferencia no está disponible para preparación';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el origen';
  end if;

  update public.documento_inventario_lineas l
  set cantidad_preparada = x.cantidad,
      observacion = coalesce(nullif(btrim(x.observacion), ''), l.observacion)
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  where l.documento_id = d.id and l.producto_id = x.producto_id
    and x.cantidad >= 0 and x.cantidad <= l.cantidad_aprobada;

  if exists (
    select 1 from public.documento_inventario_lineas
    where documento_id = d.id
      and (cantidad_preparada is null or cantidad_preparada > cantidad_aprobada)
  ) then raise exception 'Debes preparar todas las líneas aprobadas'; end if;

  update public.documentos_inventario
  set estado = 'preparando', preparado_por = auth.uid(),
      nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(d.id, d.estado, 'preparando', p_nota);
end;
$$;

create or replace function public.despachar_transferencia(
  p_documento_id uuid,
  p_nota text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  it record;
  v_stock integer;
  v_otros_reservados integer;
  v_cantidad integer;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para despachar transferencias';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'transferencia' or d.estado not in ('aprobado', 'preparando') then
    raise exception 'La transferencia no se puede despachar en su estado actual';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el origen';
  end if;

  for it in
    select * from public.documento_inventario_lineas
    where documento_id = d.id order by id
  loop
    v_cantidad := coalesce(it.cantidad_preparada, it.cantidad_aprobada, 0);
    if v_cantidad <= 0 then continue; end if;
    if public.conteo_abierto_producto(d.origen_id, it.producto_id) then
      raise exception 'Hay un conteo abierto para uno de los productos en el origen';
    end if;

    select cantidad into v_stock from public.inventario
    where producto_id = it.producto_id and entidad_id = d.origen_id for update;
    v_stock := coalesce(v_stock, 0);

    select coalesce(sum(coalesce(l.cantidad_preparada, l.cantidad_aprobada, 0)), 0)
    into v_otros_reservados
    from public.documentos_inventario od
    join public.documento_inventario_lineas l on l.documento_id = od.id
    where od.tipo = 'transferencia' and od.origen_id = d.origen_id
      and od.estado in ('aprobado', 'preparando') and od.id <> d.id
      and l.producto_id = it.producto_id;

    if v_stock - v_otros_reservados < v_cantidad then
      raise exception 'Stock disponible insuficiente al momento del despacho';
    end if;

    update public.inventario set cantidad = cantidad - v_cantidad, updated_at = now()
    where producto_id = it.producto_id and entidad_id = d.origen_id;
    update public.documento_inventario_lineas
    set cantidad_despachada = v_cantidad where id = it.id;

    insert into public.movimientos
      (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota,
       usuario_id, grupo_id)
    values
      (it.producto_id, d.origen_id, d.destino_id, 'transferencia_envio', v_cantidad,
       concat('Documento ', d.numero, coalesce(' - ' || nullif(btrim(p_nota), ''), '')),
       auth.uid(), d.id);
  end loop;

  update public.documentos_inventario
  set estado = 'despachado', despachado_por = auth.uid(), despachado_at = now(),
      nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(d.id, d.estado, 'despachado', p_nota);
end;
$$;

create or replace function public.marcar_transferencia_en_transito(
  p_documento_id uuid,
  p_nota text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare d public.documentos_inventario%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'logistica') then
    raise exception 'No tienes permiso para actualizar el transporte';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'transferencia' or d.estado <> 'despachado' then
    raise exception 'La transferencia no está lista para tránsito';
  end if;
  if not (public.usuario_puede_almacen(d.origen_id, true)
          or public.usuario_puede_almacen(d.destino_id, true)
          or public.rol_usuario_actual() in ('admin', 'control')) then
    raise exception 'No tienes acceso a esta transferencia';
  end if;
  update public.documentos_inventario
  set estado = 'en_transito', nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(d.id, 'despachado', 'en_transito', p_nota);
end;
$$;

create or replace function public.recibir_transferencia(
  p_documento_id uuid,
  p_items jsonb,
  p_nota text default null
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  it record;
  v_recibida integer;
  v_rechazada integer;
  v_diferencia boolean := false;
  v_estado text;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para recibir transferencias';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'transferencia' or d.estado not in ('despachado', 'en_transito') then
    raise exception 'La transferencia no está pendiente de recepción';
  end if;
  if not public.usuario_puede_almacen(d.destino_id, true) then
    raise exception 'No tienes permiso sobre el destino';
  end if;

  for it in
    select l.*,
      (select x from jsonb_array_elements(p_items) x
       where (x->>'producto_id')::uuid = l.producto_id limit 1) as recibido
    from public.documento_inventario_lineas l
    where l.documento_id = d.id
  loop
    if it.recibido is null then raise exception 'Debes confirmar todas las líneas'; end if;
    v_recibida := coalesce((it.recibido->>'cantidad_recibida')::integer, 0);
    v_rechazada := coalesce((it.recibido->>'cantidad_rechazada')::integer, 0);
    if v_recibida < 0 or v_rechazada < 0
       or v_recibida + v_rechazada > coalesce(it.cantidad_despachada, 0) then
      raise exception 'Una cantidad recibida o rechazada no es válida';
    end if;
    if public.conteo_abierto_producto(d.destino_id, it.producto_id) then
      raise exception 'Hay un conteo abierto para uno de los productos en el destino';
    end if;
    if v_recibida + v_rechazada <> it.cantidad_despachada or v_rechazada > 0 then
      v_diferencia := true;
    end if;

    if v_recibida > 0 then
      insert into public.inventario (producto_id, entidad_id, cantidad)
      values (it.producto_id, d.destino_id, v_recibida)
      on conflict (producto_id, entidad_id) do update
      set cantidad = public.inventario.cantidad + excluded.cantidad, updated_at = now();

      insert into public.movimientos
        (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota,
         usuario_id, grupo_id)
      values
        (it.producto_id, d.destino_id, d.origen_id, 'transferencia_recibo', v_recibida,
         concat('Documento ', d.numero, coalesce(' - ' || nullif(btrim(p_nota), ''), '')),
         auth.uid(), d.id);
    end if;

    update public.documento_inventario_lineas
    set cantidad_recibida = v_recibida,
        cantidad_rechazada = v_rechazada,
        observacion = coalesce(nullif(btrim(it.recibido->>'observacion'), ''), observacion)
    where id = it.id;
  end loop;

  if v_diferencia and btrim(coalesce(p_nota, '')) = '' then
    raise exception 'Debes explicar la diferencia de recepción';
  end if;
  v_estado := case when v_diferencia then 'recibido_con_diferencia' else 'recibido' end;

  update public.documentos_inventario
  set estado = v_estado, recibido_por = auth.uid(), recibido_at = now(),
      nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(d.id, d.estado, v_estado, p_nota);
  return v_estado;
end;
$$;

create or replace function public.cerrar_incidencia_transferencia(
  p_documento_id uuid,
  p_nota text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare d public.documentos_inventario%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Control puede cerrar diferencias';
  end if;
  if btrim(coalesce(p_nota, '')) = '' then raise exception 'Indica cómo se resolvió la diferencia'; end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.estado <> 'recibido_con_diferencia' then
    raise exception 'La transferencia no tiene una diferencia abierta';
  end if;
  update public.documentos_inventario
  set estado = 'cerrado_con_diferencia', revisado_por = auth.uid(),
      nota = concat_ws(E'\n', nota, btrim(p_nota)), updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(d.id, d.estado, 'cerrado_con_diferencia', p_nota);
end;
$$;

-- ------------------------------------------------------------
-- 6. Conteos físicos con recuento y aprobación independiente
-- ------------------------------------------------------------
create or replace function public.crear_conteo_inventario(
  p_almacen_id uuid,
  p_producto_ids uuid[] default null,
  p_nota text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_rol text := public.rol_usuario_actual();
begin
  if p_idempotency_key is not null then
    select id into v_id from public.documentos_inventario where idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;
  if v_rol not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para iniciar conteos';
  end if;
  if not public.usuario_puede_almacen(p_almacen_id, true) then
    raise exception 'No tienes permiso sobre ese almacén';
  end if;

  insert into public.documentos_inventario
    (numero, tipo, estado, origen_id, nota, idempotency_key, creado_por)
  values
    (public.numero_documento_inventario('conteo'), 'conteo', 'en_conteo',
     p_almacen_id, nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid())
  returning id into v_id;

  insert into public.documento_inventario_lineas
    (documento_id, producto_id, stock_sistema)
  select v_id, p.id, coalesce(i.cantidad, 0)
  from public.productos p
  join public.producto_almacen_config c
    on c.producto_id = p.id and c.almacen_id = p_almacen_id and c.activo
  left join public.inventario i
    on i.producto_id = p.id and i.entidad_id = p_almacen_id
  where p.activo and (p_producto_ids is null or p.id = any(p_producto_ids));

  if not exists (select 1 from public.documento_inventario_lineas where documento_id = v_id) then
    raise exception 'El conteo no contiene productos habilitados';
  end if;
  if exists (
    select 1 from public.documento_inventario_lineas nueva
    join public.documento_inventario_lineas abierta on abierta.producto_id = nueva.producto_id
    join public.documentos_inventario d on d.id = abierta.documento_id
    where nueva.documento_id = v_id and abierta.documento_id <> v_id
      and d.tipo = 'conteo' and d.origen_id = p_almacen_id
      and d.estado in ('en_conteo', 'pendiente_revision')
  ) then raise exception 'Ya existe un conteo abierto para uno de los productos'; end if;

  perform public.registrar_evento_documento(v_id, null, 'en_conteo', p_nota);
  return v_id;
end;
$$;

create or replace function public.guardar_conteo_inventario(
  p_documento_id uuid,
  p_items jsonb,
  p_enviar_revision boolean default false,
  p_nota text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare d public.documentos_inventario%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para registrar conteos';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'conteo' or d.estado <> 'en_conteo' then
    raise exception 'El conteo no está abierto';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacén';
  end if;

  update public.documento_inventario_lineas l
  set cantidad_contada = x.cantidad,
      observacion = coalesce(nullif(btrim(x.observacion), ''), l.observacion)
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  where l.documento_id = d.id and l.producto_id = x.producto_id and x.cantidad >= 0;

  if p_enviar_revision then
    if exists (
      select 1 from public.documento_inventario_lineas
      where documento_id = d.id and cantidad_contada is null
    ) then raise exception 'Faltan productos por contar'; end if;
    update public.documentos_inventario
    set estado = 'pendiente_revision', nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
        updated_at = now(), version = version + 1
    where id = d.id;
    perform public.registrar_evento_documento(d.id, 'en_conteo', 'pendiente_revision', p_nota);
  else
    update public.documentos_inventario set updated_at = now(), version = version + 1 where id = d.id;
  end if;
end;
$$;

create or replace function public.guardar_reconteo_inventario(
  p_documento_id uuid,
  p_items jsonb,
  p_nota text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare d public.documentos_inventario%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Control puede registrar el segundo conteo';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'conteo' or d.estado <> 'pendiente_revision' then
    raise exception 'El conteo no está pendiente de revisión';
  end if;
  if d.creado_por = auth.uid() then
    raise exception 'Quien realizó el primer conteo no puede registrar el segundo';
  end if;

  update public.documento_inventario_lineas l
  set cantidad_reconteo = x.cantidad,
      observacion = coalesce(nullif(btrim(x.observacion), ''), l.observacion)
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  where l.documento_id = d.id and l.producto_id = x.producto_id
    and x.cantidad >= 0 and l.cantidad_contada is distinct from l.stock_sistema;

  update public.documentos_inventario
  set revisado_por = auth.uid(), nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(d.id, 'pendiente_revision', 'pendiente_revision', 'Segundo conteo: ' || coalesce(p_nota, 'registrado'));
end;
$$;

create or replace function public.resolver_conteo_inventario(
  p_documento_id uuid,
  p_aprobar boolean,
  p_nota text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  it record;
  v_actual integer;
  v_final integer;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Control puede resolver conteos';
  end if;
  if btrim(coalesce(p_nota, '')) = '' then raise exception 'La resolución debe tener una observación'; end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'conteo' or d.estado <> 'pendiente_revision' then
    raise exception 'El conteo no está pendiente de revisión';
  end if;
  if d.creado_por = auth.uid() then
    raise exception 'No puedes aprobar tu propio conteo';
  end if;

  if not p_aprobar then
    update public.documentos_inventario
    set estado = 'en_conteo', revisado_por = auth.uid(),
        nota = concat_ws(E'\n', nota, btrim(p_nota)), updated_at = now(), version = version + 1
    where id = d.id;
    update public.documento_inventario_lineas set cantidad_reconteo = null where documento_id = d.id;
    perform public.registrar_evento_documento(d.id, 'pendiente_revision', 'en_conteo', p_nota);
    return;
  end if;

  if exists (
    select 1 from public.documento_inventario_lineas
    where documento_id = d.id
      and cantidad_contada is distinct from stock_sistema
      and cantidad_reconteo is null
  ) then raise exception 'Las diferencias requieren un segundo conteo antes de aprobar'; end if;

  for it in
    select * from public.documento_inventario_lineas where documento_id = d.id order by id
  loop
    select cantidad into v_actual from public.inventario
    where producto_id = it.producto_id and entidad_id = d.origen_id for update;
    v_actual := coalesce(v_actual, 0);
    if v_actual <> it.stock_sistema then
      raise exception 'El stock cambió durante el conteo. Reabre el conteo para actualizar la base.';
    end if;
    v_final := coalesce(it.cantidad_reconteo, it.cantidad_contada);
    if v_final is null then raise exception 'Existe una línea sin conteo'; end if;

    if v_final <> v_actual then
      insert into public.inventario (producto_id, entidad_id, cantidad)
      values (it.producto_id, d.origen_id, v_final)
      on conflict (producto_id, entidad_id) do update
      set cantidad = excluded.cantidad, updated_at = now();

      insert into public.movimientos
        (producto_id, entidad_id, tipo, cantidad, cantidad_anterior,
         nota, usuario_id, grupo_id)
      values
        (it.producto_id, d.origen_id, 'ajuste', v_final, v_actual,
         'Conteo aprobado ' || d.numero || ' - ' || btrim(p_nota), auth.uid(), d.id);
    end if;
  end loop;

  update public.documentos_inventario
  set estado = 'aplicado', aprobado_por = auth.uid(), aprobado_at = now(), aplicado_at = now(),
      nota = concat_ws(E'\n', nota, btrim(p_nota)), updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(d.id, 'pendiente_revision', 'aplicado', p_nota);
end;
$$;

-- ------------------------------------------------------------
-- 7. Movimientos manuales: sin transferencias ni ajustes directos
-- ------------------------------------------------------------
create or replace function public.registrar_movimiento_manual(
  p_producto_id uuid,
  p_entidad_id uuid,
  p_tipo public.tipo_movimiento,
  p_cantidad integer,
  p_referencia text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stock integer;
begin
  if public.rol_usuario_actual() not in ('admin', 'bodega') then
    raise exception 'No tienes permiso para registrar entradas o salidas manuales';
  end if;
  if not public.usuario_puede_almacen(p_entidad_id, true) then
    raise exception 'No tienes permiso sobre ese almacén';
  end if;
  if p_tipo not in ('entrada', 'salida') then
    raise exception 'Las transferencias y ajustes deben usar sus documentos operativos';
  end if;
  if p_cantidad <= 0 then raise exception 'La cantidad debe ser mayor que cero'; end if;
  if btrim(coalesce(p_referencia, '')) = '' then
    raise exception 'La referencia o motivo es obligatorio';
  end if;
  if not exists (select 1 from public.productos where id = p_producto_id and activo) then
    raise exception 'El producto no existe o está inactivo';
  end if;
  if public.conteo_abierto_producto(p_entidad_id, p_producto_id) then
    raise exception 'Hay un conteo abierto para este producto';
  end if;

  if p_tipo = 'entrada' then
    insert into public.inventario (producto_id, entidad_id, cantidad)
    values (p_producto_id, p_entidad_id, p_cantidad)
    on conflict (producto_id, entidad_id) do update
    set cantidad = public.inventario.cantidad + excluded.cantidad, updated_at = now();
  else
    select cantidad into v_stock from public.inventario
    where producto_id = p_producto_id and entidad_id = p_entidad_id for update;
    if coalesce(v_stock, 0) < p_cantidad then raise exception 'Stock insuficiente'; end if;
    update public.inventario set cantidad = cantidad - p_cantidad, updated_at = now()
    where producto_id = p_producto_id and entidad_id = p_entidad_id;
  end if;

  insert into public.movimientos
    (producto_id, entidad_id, tipo, cantidad, nota, usuario_id, grupo_id)
  values
    (p_producto_id, p_entidad_id, p_tipo, p_cantidad, btrim(p_referencia), auth.uid(), gen_random_uuid());
end;
$$;

-- La anulación es una tarea de Control, nunca de quien ejecutó el movimiento.
-- Los movimientos creados por documentos se corrigen desde su propio flujo.
create or replace function public.control_anular_movimiento(
  p_movimiento_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  m record;
  v_actual integer;
  v_nuevo integer;
begin
  if public.rol_usuario_actual() <> 'control' then
    raise exception 'Solo Control puede anular movimientos manuales';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'Debes indicar el motivo de la anulación';
  end if;

  select * into m from public.movimientos where id = p_movimiento_id for update;
  if not found then raise exception 'El movimiento no existe'; end if;
  if m.anulado then raise exception 'El movimiento ya fue anulado'; end if;
  if m.tipo in ('transferencia_envio', 'transferencia_recibo')
     or exists (select 1 from public.documentos_inventario d where d.id = m.grupo_id) then
    raise exception 'Este movimiento pertenece a un documento y debe corregirse desde Control';
  end if;

  select cantidad into v_actual from public.inventario
  where producto_id = m.producto_id and entidad_id = m.entidad_id for update;

  if m.tipo = 'entrada' then
    if coalesce(v_actual, 0) < m.cantidad then
      raise exception 'No se puede anular: esas unidades ya salieron. Realiza un conteo controlado';
    end if;
    update public.inventario set cantidad = cantidad - m.cantidad, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;
  elsif m.tipo = 'salida' then
    insert into public.inventario (producto_id, entidad_id, cantidad)
    values (m.producto_id, m.entidad_id, m.cantidad)
    on conflict (producto_id, entidad_id) do update
    set cantidad = public.inventario.cantidad + excluded.cantidad, updated_at = now();
  elsif m.tipo = 'ajuste' then
    if m.cantidad_anterior is null then
      raise exception 'El ajuste no conserva el stock anterior; corrígelo mediante conteo';
    end if;
    v_nuevo := coalesce(v_actual, 0) - (m.cantidad - m.cantidad_anterior);
    if v_nuevo < 0 then
      raise exception 'La anulación dejaría stock negativo; corrígelo mediante conteo';
    end if;
    update public.inventario set cantidad = v_nuevo, updated_at = now()
    where producto_id = m.producto_id and entidad_id = m.entidad_id;
  else
    raise exception 'Tipo de movimiento no anulable';
  end if;

  update public.movimientos
  set anulado = true, anulado_por = auth.uid(), anulado_at = now(),
      motivo_anulacion = btrim(p_motivo)
  where id = m.id;
end;
$$;

-- Se deshabilita el RPC legado que recibía transferencias automáticamente.
revoke execute on function public.registrar_movimiento(uuid, uuid, public.tipo_movimiento, integer, text, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.anular_movimiento(uuid, text)
  from public, anon, authenticated;
-- Las tomas físicas pasan exclusivamente por conteos revisados.
revoke execute on function public.importar_stock(uuid, jsonb, text, boolean)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- 8. Vista de stock: físico, reservado, tránsito y disponible
-- ------------------------------------------------------------
create or replace view public.vista_stock_operativo
with (security_invoker = true) as
select
  c.producto_id,
  c.almacen_id,
  p.sku,
  p.nombre as producto,
  p.categoria_id,
  p.categoria,
  p.subcategoria_id,
  p.subcategoria,
  p.talla,
  p.color,
  p.precio,
  a.nombre as almacen,
  a.tipo as almacen_tipo,
  c.ubicacion,
  c.stock_minimo,
  c.stock_maximo,
  c.stock_seguridad,
  c.punto_reposicion,
  coalesce(i.cantidad, 0) as stock_fisico,
  coalesce(res.reservado, 0) as stock_reservado,
  greatest(coalesce(i.cantidad, 0) - coalesce(res.reservado, 0), 0) as stock_disponible,
  coalesce(te.entrada, 0) as transito_entrada,
  coalesce(ts.salida, 0) as transito_salida,
  (coalesce(i.cantidad, 0) <= c.stock_minimo) as bajo_minimo,
  greatest(c.punto_reposicion - (coalesce(i.cantidad, 0) + coalesce(te.entrada, 0)), 0) as sugerido_reponer,
  i.updated_at
from public.producto_almacen_config c
join public.productos p on p.id = c.producto_id and p.activo
join public.almacenes a on a.id = c.almacen_id and a.activo
left join public.inventario i on i.producto_id = c.producto_id and i.entidad_id = c.almacen_id
left join lateral (
  select sum(coalesce(l.cantidad_preparada, l.cantidad_aprobada, 0))::integer reservado
  from public.documentos_inventario d
  join public.documento_inventario_lineas l on l.documento_id = d.id
  where d.tipo = 'transferencia' and d.origen_id = c.almacen_id
    and d.estado in ('aprobado', 'preparando') and l.producto_id = c.producto_id
) res on true
left join lateral (
  select sum(coalesce(l.cantidad_despachada, 0))::integer entrada
  from public.documentos_inventario d
  join public.documento_inventario_lineas l on l.documento_id = d.id
  where d.tipo = 'transferencia' and d.destino_id = c.almacen_id
    and d.estado in ('despachado', 'en_transito') and l.producto_id = c.producto_id
) te on true
left join lateral (
  select sum(coalesce(l.cantidad_despachada, 0))::integer salida
  from public.documentos_inventario d
  join public.documento_inventario_lineas l on l.documento_id = d.id
  where d.tipo = 'transferencia' and d.origen_id = c.almacen_id
    and d.estado in ('despachado', 'en_transito') and l.producto_id = c.producto_id
) ts on true
where c.activo;

-- SECURITY DEFINER debe pertenecer al propietario de las tablas en Supabase.
-- Así los clientes nunca requieren permisos directos de escritura.
alter function public.rol_usuario_actual() owner to postgres;
alter function public.usuario_puede_almacen(uuid, boolean) owner to postgres;
alter function public.admin_asignar_almacenes(uuid, uuid[]) owner to postgres;
alter function public.sembrar_config_producto_almacen() owner to postgres;
alter function public.sembrar_config_nuevo_almacen() owner to postgres;
alter function public.auditar_producto_maestro() owner to postgres;
alter function public.guardar_config_producto_almacen(jsonb) owner to postgres;
alter function public.puede_ver_documento(uuid) owner to postgres;
alter function public.numero_documento_inventario(text) owner to postgres;
alter function public.registrar_evento_documento(uuid, text, text, text) owner to postgres;
alter function public.conteo_abierto_producto(uuid, uuid) owner to postgres;
alter function public.crear_solicitud_reposicion(uuid, jsonb, text, text, uuid) owner to postgres;
alter function public.resolver_solicitud_reposicion(uuid, boolean, uuid, jsonb, text, uuid) owner to postgres;
alter function public.crear_transferencia_directa(uuid, uuid, jsonb, text, uuid) owner to postgres;
alter function public.guardar_preparacion_transferencia(uuid, jsonb, text) owner to postgres;
alter function public.despachar_transferencia(uuid, text) owner to postgres;
alter function public.marcar_transferencia_en_transito(uuid, text) owner to postgres;
alter function public.recibir_transferencia(uuid, jsonb, text) owner to postgres;
alter function public.cerrar_incidencia_transferencia(uuid, text) owner to postgres;
alter function public.crear_conteo_inventario(uuid, uuid[], text, uuid) owner to postgres;
alter function public.guardar_conteo_inventario(uuid, jsonb, boolean, text) owner to postgres;
alter function public.guardar_reconteo_inventario(uuid, jsonb, text) owner to postgres;
alter function public.resolver_conteo_inventario(uuid, boolean, text) owner to postgres;
alter function public.registrar_movimiento_manual(uuid, uuid, public.tipo_movimiento, integer, text) owner to postgres;
alter function public.control_anular_movimiento(uuid, text) owner to postgres;

-- ------------------------------------------------------------
-- 9. Privilegios
-- ------------------------------------------------------------
revoke all on public.perfil_almacenes from public, anon;
revoke insert, update, delete on public.perfil_almacenes from authenticated;
grant select on public.perfil_almacenes to authenticated;

revoke all on public.producto_almacen_config from public, anon;
revoke insert, update, delete on public.producto_almacen_config from authenticated;
grant select on public.producto_almacen_config to authenticated;

revoke all on public.productos_maestro_cambios from public, anon;
revoke insert, update, delete on public.productos_maestro_cambios from authenticated;
grant select on public.productos_maestro_cambios to authenticated;

revoke all on public.documentos_inventario from public, anon;
revoke all on public.documento_inventario_lineas from public, anon;
revoke all on public.documento_inventario_eventos from public, anon;
revoke insert, update, delete on public.documentos_inventario from authenticated;
revoke insert, update, delete on public.documento_inventario_lineas from authenticated;
revoke insert, update, delete on public.documento_inventario_eventos from authenticated;
grant select on public.documentos_inventario to authenticated;
grant select on public.documento_inventario_lineas to authenticated;
grant select on public.documento_inventario_eventos to authenticated;
grant select on public.vista_stock_operativo to authenticated;

revoke execute on function public.rol_usuario_actual() from public, anon;
revoke execute on function public.usuario_puede_almacen(uuid, boolean) from public, anon;
grant execute on function public.rol_usuario_actual() to authenticated;
grant execute on function public.usuario_puede_almacen(uuid, boolean) to authenticated;

revoke execute on function public.admin_asignar_almacenes(uuid, uuid[]) from public, anon;
revoke execute on function public.guardar_config_producto_almacen(jsonb) from public, anon;
revoke execute on function public.crear_solicitud_reposicion(uuid, jsonb, text, text, uuid) from public, anon;
revoke execute on function public.resolver_solicitud_reposicion(uuid, boolean, uuid, jsonb, text, uuid) from public, anon;
revoke execute on function public.crear_transferencia_directa(uuid, uuid, jsonb, text, uuid) from public, anon;
revoke execute on function public.guardar_preparacion_transferencia(uuid, jsonb, text) from public, anon;
revoke execute on function public.despachar_transferencia(uuid, text) from public, anon;
revoke execute on function public.marcar_transferencia_en_transito(uuid, text) from public, anon;
revoke execute on function public.recibir_transferencia(uuid, jsonb, text) from public, anon;
revoke execute on function public.cerrar_incidencia_transferencia(uuid, text) from public, anon;
revoke execute on function public.crear_conteo_inventario(uuid, uuid[], text, uuid) from public, anon;
revoke execute on function public.guardar_conteo_inventario(uuid, jsonb, boolean, text) from public, anon;
revoke execute on function public.guardar_reconteo_inventario(uuid, jsonb, text) from public, anon;
revoke execute on function public.resolver_conteo_inventario(uuid, boolean, text) from public, anon;
revoke execute on function public.registrar_movimiento_manual(uuid, uuid, public.tipo_movimiento, integer, text) from public, anon;
revoke execute on function public.control_anular_movimiento(uuid, text) from public, anon;

grant execute on function public.admin_asignar_almacenes(uuid, uuid[]) to authenticated;
grant execute on function public.guardar_config_producto_almacen(jsonb) to authenticated;
grant execute on function public.crear_solicitud_reposicion(uuid, jsonb, text, text, uuid) to authenticated;
grant execute on function public.resolver_solicitud_reposicion(uuid, boolean, uuid, jsonb, text, uuid) to authenticated;
grant execute on function public.crear_transferencia_directa(uuid, uuid, jsonb, text, uuid) to authenticated;
grant execute on function public.guardar_preparacion_transferencia(uuid, jsonb, text) to authenticated;
grant execute on function public.despachar_transferencia(uuid, text) to authenticated;
grant execute on function public.marcar_transferencia_en_transito(uuid, text) to authenticated;
grant execute on function public.recibir_transferencia(uuid, jsonb, text) to authenticated;
grant execute on function public.cerrar_incidencia_transferencia(uuid, text) to authenticated;
grant execute on function public.crear_conteo_inventario(uuid, uuid[], text, uuid) to authenticated;
grant execute on function public.guardar_conteo_inventario(uuid, jsonb, boolean, text) to authenticated;
grant execute on function public.guardar_reconteo_inventario(uuid, jsonb, text) to authenticated;
grant execute on function public.resolver_conteo_inventario(uuid, boolean, text) to authenticated;
grant execute on function public.registrar_movimiento_manual(uuid, uuid, public.tipo_movimiento, integer, text) to authenticated;
grant execute on function public.control_anular_movimiento(uuid, text) to authenticated;

revoke execute on function public.numero_documento_inventario(text) from public, anon, authenticated;
revoke execute on function public.registrar_evento_documento(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.conteo_abierto_producto(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.puede_ver_documento(uuid) from public, anon;
grant execute on function public.puede_ver_documento(uuid) to authenticated;
revoke execute on function public.sembrar_config_producto_almacen() from public, anon, authenticated;
revoke execute on function public.sembrar_config_nuevo_almacen() from public, anon, authenticated;
revoke execute on function public.auditar_producto_maestro() from public, anon, authenticated;
