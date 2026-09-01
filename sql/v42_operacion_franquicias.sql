-- ============================================================
-- BOMAN INVENTARIO - Operacion de franquicias v42
-- Aisla cada franquicia por almacen, incorpora venta simple, diario de caja,
-- ajustes auditados y reutiliza el flujo existente de reposicion.
-- Ejecutar una sola vez DESPUES de v41.
-- ============================================================

-- Si PostgreSQL informa "unsafe use of new value", ejecuta primero solamente
-- estas dos sentencias, confirma la transaccion y luego ejecuta el archivo.
alter type public.rol_usuario add value if not exists 'franquiciado';
alter type public.rol_usuario add value if not exists 'vendedor_franquicia';

-- ------------------------------------------------------------
-- 1. Configuracion y permisos
-- ------------------------------------------------------------
create table if not exists public.franquicias (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  codigo text not null check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  ciudad text,
  activo boolean not null default true,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, codigo),
  unique (almacen_id)
);

create index if not exists idx_franquicias_empresa_v42
  on public.franquicias(empresa_id, activo);

insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('franquicia.acceder', 'Franquicias', 'Panel de franquicia',
   'Abre la operacion aislada del local franquiciado.', 120),
  ('franquicia.ventas', 'Franquicias', 'Registrar ventas',
   'Registra ventas simples y descuenta automaticamente el stock del local.', 121),
  ('franquicia.caja', 'Franquicias', 'Diario de ingresos y egresos',
   'Consulta la caja y registra movimientos internos distintos de ventas.', 122),
  ('franquicia.inventario', 'Franquicias', 'Ajustar inventario',
   'Registra entradas y salidas manuales justificadas del local.', 123),
  ('franquicia.reposicion', 'Franquicias', 'Solicitar reposicion',
   'Solicita mercaderia y confirma la recepcion en el local.', 124)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

-- Completa la matriz para todos los roles configurables, incluidos los nuevos.
insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.activo
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos set permitido = true, updated_at = now()
where rol::text = 'franquiciado'
  and permiso_codigo in (
    'inventario.acceder', 'operaciones.acceder',
    'franquicia.acceder', 'franquicia.ventas', 'franquicia.caja',
    'franquicia.inventario', 'franquicia.reposicion'
  );

update public.rol_permisos set permitido = true, updated_at = now()
where rol::text = 'vendedor_franquicia'
  and permiso_codigo in (
    'inventario.acceder', 'franquicia.acceder', 'franquicia.ventas'
  );

create or replace view public.vista_matriz_permisos_v35
with (security_invoker = true) as
select
  r.rol::text as rol,
  ps.codigo as permiso_codigo,
  ps.modulo,
  ps.nombre,
  ps.descripcion,
  ps.orden,
  case when r.rol::text = 'admin' then true else coalesce(rp.permitido, false) end
    as permitido,
  r.rol::text <> 'admin' as configurable,
  rp.updated_at
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema ps
left join public.rol_permisos rp
  on rp.rol = r.rol and rp.permiso_codigo = ps.codigo
where ps.activo;

create or replace function public.franquicia_usuario_actual_v42()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select f.id
  from public.perfiles p
  join public.perfil_almacenes pa on pa.perfil_id = p.id
  join public.franquicias f on f.almacen_id = pa.almacen_id and f.activo
  join public.empresas e on e.id = f.empresa_id and e.activo
  join public.almacenes a on a.id = f.almacen_id and a.activo
  where p.id = auth.uid() and p.activo
    and p.rol::text in ('franquiciado', 'vendedor_franquicia')
  limit 1;
$$;

create or replace function public.usuario_puede_franquicia_v42(
  p_franquicia_id uuid,
  p_escritura boolean default false,
  p_solo_titular boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text in ('admin', 'control')
        or (not p_escritura and p.rol::text = 'gerencia')
        or (
          p.rol::text = 'franquiciado'
          and public.franquicia_usuario_actual_v42() = p_franquicia_id
        )
        or (
          not p_solo_titular
          and p.rol::text = 'vendedor_franquicia'
          and public.franquicia_usuario_actual_v42() = p_franquicia_id
        )
      )
  );
$$;

create or replace function public.admin_guardar_franquicia_v42(
  p_franquicia_id uuid,
  p_grupo_id uuid,
  p_empresa_id uuid,
  p_almacen_id uuid,
  p_codigo text,
  p_nombre text,
  p_ciudad text,
  p_activo boolean
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede configurar franquicias';
  end if;
  if btrim(coalesce(p_codigo, '')) = '' or btrim(coalesce(p_nombre, '')) = '' then
    raise exception 'El codigo y el nombre son obligatorios';
  end if;
  if not exists (
    select 1 from public.empresas e
    where e.id = p_empresa_id and e.grupo_id = p_grupo_id and e.activo
  ) then raise exception 'La empresa no pertenece al grupo o esta inactiva'; end if;
  if not exists (
    select 1 from public.almacenes a where a.id = p_almacen_id and a.activo
  ) then raise exception 'El almacen no existe o esta inactivo'; end if;
  if not exists (
    select 1 from public.empresa_almacenes ea
    where ea.empresa_id = p_empresa_id and ea.almacen_id = p_almacen_id
      and ea.es_operadora_principal and ea.permite_ventas
      and ea.custodia_inventario
  ) then
    raise exception 'La empresa debe ser operadora principal, permitir ventas y custodiar inventario en el almacen';
  end if;

  if p_franquicia_id is null then
    insert into public.franquicias (
      grupo_id, empresa_id, almacen_id, codigo, nombre, ciudad, activo,
      creado_por, actualizado_por
    ) values (
      p_grupo_id, p_empresa_id, p_almacen_id, upper(btrim(p_codigo)),
      btrim(p_nombre), nullif(btrim(p_ciudad), ''), coalesce(p_activo, true),
      auth.uid(), auth.uid()
    ) returning id into v_id;
  else
    update public.franquicias set
      grupo_id = p_grupo_id, empresa_id = p_empresa_id,
      almacen_id = p_almacen_id, codigo = upper(btrim(p_codigo)),
      nombre = btrim(p_nombre), ciudad = nullif(btrim(p_ciudad), ''),
      activo = coalesce(p_activo, true), actualizado_por = auth.uid(),
      updated_at = now()
    where id = p_franquicia_id returning id into v_id;
    if not found then raise exception 'La franquicia no existe'; end if;
  end if;
  return v_id;
end;
$$;

-- Los dos roles de franquicia deben quedar ligados a un unico local activo.
create or replace function public.admin_guardar_usuario_v42(
  p_perfil_id uuid,
  p_nombre_completo text,
  p_rol public.rol_usuario,
  p_almacen_ids uuid[],
  p_activo boolean
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_ids uuid[];
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo un administrador activo puede modificar usuarios';
  end if;
  select coalesce(array_agg(x order by primera_posicion), array[]::uuid[])
  into v_ids
  from (
    select x, min(posicion) primera_posicion
    from unnest(coalesce(p_almacen_ids, array[]::uuid[]))
      with ordinality entrada(x, posicion)
    where x is not null group by x
  ) unicos;

  if p_activo and p_rol::text in ('franquiciado', 'vendedor_franquicia') then
    if cardinality(v_ids) <> 1 then
      raise exception 'Los usuarios de franquicia deben tener exactamente un local asignado';
    end if;
    if not exists (
      select 1 from public.franquicias f
      where f.almacen_id = v_ids[1] and f.activo
    ) then raise exception 'Configura primero una franquicia activa para ese local'; end if;
  end if;

  perform public.admin_guardar_usuario_v37(
    p_perfil_id, p_nombre_completo, p_rol, v_ids, p_activo
  );
end;
$$;

-- ------------------------------------------------------------
-- 2. Venta simple y descuento automatico de stock
-- ------------------------------------------------------------
create table if not exists public.ventas_franquicia (
  id uuid primary key default gen_random_uuid(),
  franquicia_id uuid not null references public.franquicias(id) on delete restrict,
  numero integer not null check (numero > 0),
  fecha date not null,
  estado text not null default 'registrada' check (estado in ('registrada', 'anulada')),
  medio_pago text not null check (medio_pago in ('efectivo', 'transferencia', 'tarjeta', 'mixto', 'otro')),
  subtotal numeric(14,2) not null check (subtotal >= 0),
  descuento numeric(14,2) not null default 0 check (descuento >= 0),
  total numeric(14,2) not null check (total >= 0),
  referencia text,
  nota text,
  idempotency_key uuid not null unique,
  creada_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  anulada_por uuid references public.perfiles(id) on delete restrict,
  anulada_at timestamptz,
  motivo_anulacion text,
  unique (franquicia_id, numero),
  check (total = subtotal - descuento)
);

create table if not exists public.venta_franquicia_lineas (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references public.ventas_franquicia(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  cantidad integer not null check (cantidad > 0),
  precio_unitario numeric(14,2) not null check (precio_unitario >= 0),
  descuento numeric(14,2) not null default 0 check (descuento >= 0),
  total numeric(14,2) not null check (total >= 0),
  unique (venta_id, producto_id),
  check (total = round(cantidad * precio_unitario - descuento, 2))
);

create index if not exists idx_ventas_franquicia_fecha_v42
  on public.ventas_franquicia(franquicia_id, fecha desc, numero desc);

-- ------------------------------------------------------------
-- 3. Diario de ingresos y egresos (control interno)
-- ------------------------------------------------------------
create table if not exists public.franquicia_caja_movimientos (
  id uuid primary key default gen_random_uuid(),
  franquicia_id uuid not null references public.franquicias(id) on delete restrict,
  fecha date not null,
  tipo text not null check (tipo in ('ingreso', 'egreso')),
  categoria text not null check (btrim(categoria) <> ''),
  concepto text not null check (btrim(concepto) <> ''),
  monto numeric(14,2) not null check (monto > 0),
  medio_pago text not null check (medio_pago in ('efectivo', 'transferencia', 'tarjeta', 'mixto', 'otro')),
  referencia text,
  venta_id uuid references public.ventas_franquicia(id) on delete restrict,
  estado text not null default 'vigente' check (estado in ('vigente', 'revertido')),
  reversa_de_id uuid unique references public.franquicia_caja_movimientos(id) on delete restrict,
  motivo_reversa text,
  idempotency_key uuid not null unique,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (venta_id)
);

create index if not exists idx_caja_franquicia_fecha_v42
  on public.franquicia_caja_movimientos(franquicia_id, fecha desc, created_at desc);

create table if not exists public.ajustes_inventario_franquicia (
  id uuid primary key default gen_random_uuid(),
  franquicia_id uuid not null references public.franquicias(id) on delete restrict,
  fecha date not null,
  tipo text not null check (tipo in ('entrada', 'salida')),
  motivo text not null check (char_length(btrim(motivo)) >= 5),
  idempotency_key uuid not null unique,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.ajuste_inventario_franquicia_lineas (
  id uuid primary key default gen_random_uuid(),
  ajuste_id uuid not null references public.ajustes_inventario_franquicia(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  cantidad integer not null check (cantidad > 0),
  unique (ajuste_id, producto_id)
);

create or replace function public.registrar_venta_franquicia_v42(
  p_fecha date,
  p_items jsonb,
  p_medio_pago text,
  p_descuento numeric,
  p_referencia text,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_franquicia public.franquicias%rowtype;
  v_venta_id uuid;
  v_numero integer;
  v_subtotal numeric(14,2);
  v_descuento numeric(14,2) := round(coalesce(p_descuento, 0), 2);
  v_total numeric(14,2);
  it record;
begin
  if public.rol_usuario_actual() not in ('franquiciado', 'vendedor_franquicia') then
    raise exception 'No tienes permiso para registrar ventas de franquicia';
  end if;
  if not public.usuario_tiene_permiso_v35('franquicia.ventas') then
    raise exception 'El rol no tiene habilitado el registro de ventas';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into v_franquicia from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'El usuario no tiene una franquicia activa asignada'; end if;
  if p_fecha is null or p_fecha > current_date then raise exception 'La fecha de venta no es valida'; end if;
  if p_medio_pago not in ('efectivo', 'transferencia', 'tarjeta', 'mixto', 'otro') then
    raise exception 'El medio de pago no es valido';
  end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta debe tener productos';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items)
      x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric)
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or coalesce(x.cantidad, 0) <= 0
      or coalesce(x.precio_unitario, -1) < 0 or coalesce(x.descuento, 0) < 0
      or coalesce(x.descuento, 0) > x.cantidad * x.precio_unitario
  ) then raise exception 'La venta contiene productos, cantidades o valores invalidos'; end if;
  if exists (
    select producto_id from jsonb_to_recordset(p_items)
      x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric)
    group by producto_id having count(*) > 1
  ) then raise exception 'La venta contiene productos repetidos'; end if;

  select id into v_venta_id from public.ventas_franquicia
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('id', v_venta_id, 'duplicado', true); end if;

  select round(sum(x.cantidad * x.precio_unitario - coalesce(x.descuento, 0)), 2)
  into v_subtotal
  from jsonb_to_recordset(p_items)
    x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric);
  if v_descuento < 0 or v_descuento > v_subtotal then
    raise exception 'El descuento general no es valido';
  end if;
  v_total := v_subtotal - v_descuento;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_franquicia.id::text, 42));
  select coalesce(max(numero), 0) + 1 into v_numero
  from public.ventas_franquicia where franquicia_id = v_franquicia.id;
  insert into public.ventas_franquicia (
    franquicia_id, numero, fecha, medio_pago, subtotal, descuento, total,
    referencia, nota, idempotency_key, creada_por
  ) values (
    v_franquicia.id, v_numero, p_fecha, p_medio_pago, v_subtotal,
    v_descuento, v_total, nullif(btrim(p_referencia), ''),
    nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid()
  ) returning id into v_venta_id;

  insert into public.venta_franquicia_lineas
    (venta_id, producto_id, cantidad, precio_unitario, descuento, total)
  select v_venta_id, x.producto_id, x.cantidad, round(x.precio_unitario, 2),
         round(coalesce(x.descuento, 0), 2),
         round(x.cantidad * x.precio_unitario - coalesce(x.descuento, 0), 2)
  from jsonb_to_recordset(p_items)
    x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric);

  for it in select * from public.venta_franquicia_lineas where venta_id = v_venta_id order by producto_id
  loop
    perform public.aplicar_movimiento_stock_v20(
      it.producto_id, v_franquicia.almacen_id, v_franquicia.empresa_id,
      'salida'::public.tipo_movimiento, -it.cantidad, v_venta_id,
      'venta_franquicia', 'Venta franquicia #' || v_numero,
      null, null, gen_random_uuid()
    );
  end loop;

  if v_total > 0 then
    insert into public.franquicia_caja_movimientos (
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, venta_id, idempotency_key, creado_por
    ) values (
      v_franquicia.id, p_fecha, 'ingreso', 'venta',
      'Venta #' || v_numero, v_total, p_medio_pago,
      nullif(btrim(p_referencia), ''), v_venta_id, gen_random_uuid(), auth.uid()
    );
  end if;
  return jsonb_build_object('id', v_venta_id, 'numero', v_numero,
    'total', v_total, 'duplicado', false);
end;
$$;

create or replace function public.registrar_caja_franquicia_v42(
  p_fecha date,
  p_tipo text,
  p_categoria text,
  p_concepto text,
  p_monto numeric,
  p_medio_pago text,
  p_referencia text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_franquicia_id uuid; v_id uuid;
begin
  if public.rol_usuario_actual() <> 'franquiciado'
     or not public.usuario_tiene_permiso_v35('franquicia.caja') then
    raise exception 'Solo el franquiciado puede registrar movimientos de caja';
  end if;
  v_franquicia_id := public.franquicia_usuario_actual_v42();
  if v_franquicia_id is null then raise exception 'No tienes una franquicia activa asignada'; end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.franquicia_caja_movimientos where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  if p_fecha is null or p_fecha > current_date then raise exception 'La fecha no es valida'; end if;
  if p_tipo not in ('ingreso', 'egreso') then raise exception 'El tipo no es valido'; end if;
  if btrim(coalesce(p_categoria, '')) = '' or btrim(coalesce(p_concepto, '')) = '' then
    raise exception 'La categoria y el concepto son obligatorios';
  end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_medio_pago not in ('efectivo', 'transferencia', 'tarjeta', 'mixto', 'otro') then
    raise exception 'El medio de pago no es valido';
  end if;
  insert into public.franquicia_caja_movimientos (
    franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
    referencia, idempotency_key, creado_por
  ) values (
    v_franquicia_id, p_fecha, p_tipo, btrim(p_categoria), btrim(p_concepto),
    round(p_monto, 2), p_medio_pago, nullif(btrim(p_referencia), ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.revertir_caja_franquicia_v42(
  p_movimiento_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare m public.franquicia_caja_movimientos%rowtype; v_id uuid;
begin
  if public.rol_usuario_actual() not in ('admin', 'franquiciado') then
    raise exception 'No tienes permiso para revertir caja';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Explica el motivo de la reversa'; end if;
  select id into v_id from public.franquicia_caja_movimientos where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  select * into m from public.franquicia_caja_movimientos where id = p_movimiento_id for update;
  if not found then raise exception 'El movimiento no existe'; end if;
  if not public.usuario_puede_franquicia_v42(m.franquicia_id, true, true) then
    raise exception 'No tienes acceso a esta caja';
  end if;
  if m.estado <> 'vigente' or m.reversa_de_id is not null then raise exception 'El movimiento ya fue revertido'; end if;
  update public.franquicia_caja_movimientos
  set estado = 'revertido', motivo_reversa = btrim(p_motivo)
  where id = m.id;
  insert into public.franquicia_caja_movimientos (
    franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
    referencia, reversa_de_id, motivo_reversa, idempotency_key, creado_por
  ) values (
    m.franquicia_id, current_date,
    case when m.tipo = 'ingreso' then 'egreso' else 'ingreso' end,
    'reversa', 'Reversa: ' || m.concepto, m.monto, m.medio_pago,
    m.referencia, m.id, btrim(p_motivo), p_idempotency_key, auth.uid()
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.registrar_ajuste_franquicia_v42(
  p_fecha date,
  p_tipo text,
  p_items jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_franquicia public.franquicias%rowtype; v_id uuid; it record;
begin
  if public.rol_usuario_actual() <> 'franquiciado'
     or not public.usuario_tiene_permiso_v35('franquicia.inventario') then
    raise exception 'Solo el franquiciado puede ajustar el inventario';
  end if;
  select * into v_franquicia from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'No tienes una franquicia activa asignada'; end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.ajustes_inventario_franquicia where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  if p_fecha is null or p_fecha > current_date then raise exception 'La fecha no es valida'; end if;
  if p_tipo not in ('entrada', 'salida') then raise exception 'El tipo de ajuste no es valido'; end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Explica el motivo del ajuste'; end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El ajuste debe tener productos';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer)
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or coalesce(x.cantidad, 0) <= 0
  ) then raise exception 'El ajuste contiene lineas invalidas'; end if;
  if exists (
    select producto_id from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer)
    group by producto_id having count(*) > 1
  ) then raise exception 'El ajuste contiene productos repetidos'; end if;

  insert into public.ajustes_inventario_franquicia
    (franquicia_id, fecha, tipo, motivo, idempotency_key, creado_por)
  values (v_franquicia.id, p_fecha, p_tipo, btrim(p_motivo), p_idempotency_key, auth.uid())
  returning id into v_id;
  insert into public.ajuste_inventario_franquicia_lineas
    (ajuste_id, producto_id, cantidad)
  select v_id, producto_id, cantidad
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer);

  for it in select * from public.ajuste_inventario_franquicia_lineas where ajuste_id = v_id order by producto_id
  loop
    perform public.aplicar_movimiento_stock_v20(
      it.producto_id, v_franquicia.almacen_id, v_franquicia.empresa_id,
      'ajuste'::public.tipo_movimiento,
      case when p_tipo = 'entrada' then it.cantidad else -it.cantidad end,
      v_id, 'ajuste_franquicia', btrim(p_motivo), null, null, gen_random_uuid()
    );
  end loop;
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 4. Reposicion: titular solicita/recibe; vendedor no opera documentos
-- ------------------------------------------------------------
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
      and public.rol_usuario_actual() <> 'vendedor_franquicia'
      and (
        public.usuario_puede_almacen(d.origen_id, false)
        or public.usuario_puede_almacen(d.destino_id, false)
        or (d.tipo = 'solicitud_reposicion'
            and public.rol_usuario_actual() in ('bodega', 'logistica'))
      )
  );
$$;

drop policy if exists "leer_documentos_inventario" on public.documentos_inventario;
create policy "leer_documentos_inventario"
on public.documentos_inventario for select to authenticated using (
  public.puede_ver_documento(id)
);

-- Mantiene el motor probado y agrega exclusivamente al titular de franquicia.
create or replace function public.crear_solicitud_reposicion_v42(
  p_destino_id uuid,
  p_items jsonb,
  p_prioridad text,
  p_nota text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.rol_usuario_actual() = 'franquiciado' then
    if not public.usuario_tiene_permiso_v35('franquicia.reposicion')
       or p_destino_id <> (select almacen_id from public.franquicias where id = public.franquicia_usuario_actual_v42()) then
      raise exception 'Solo puedes solicitar reposicion para tu franquicia';
    end if;
  elsif public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para solicitar reposicion';
  end if;
  return public.crear_solicitud_reposicion(
    p_destino_id, p_items, p_prioridad, p_nota, p_idempotency_key
  );
end;
$$;

-- La funcion historica valida el rol; se sustituye temporalmente dentro de un
-- wrapper no seria seguro. Por eso la interfaz usa v42 y v42 habilita el rol
-- en el motor historico mediante una recreacion textual posterior a instalar.
-- Se conserva una funcion de recepcion dedicada que delega solo despues de
-- validar que el destino es exactamente el local del titular.
create or replace function public.recibir_transferencia_franquicia_v42(
  p_documento_id uuid,
  p_items jsonb,
  p_nota text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare d public.documentos_inventario%rowtype;
begin
  if public.rol_usuario_actual() <> 'franquiciado' then
    raise exception 'Solo el franquiciado puede confirmar la recepcion';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id;
  if not found or d.destino_id <> (
    select almacen_id from public.franquicias where id = public.franquicia_usuario_actual_v42()
  ) then raise exception 'La transferencia no pertenece a tu franquicia'; end if;
  -- El motor historico no admite el nuevo rol. Se usa una marca local leida por
  -- la version v42 de recibir_transferencia instalada al final del archivo.
  perform set_config('boman.recepcion_franquicia_v42', '1', true);
  return public.recibir_transferencia(p_documento_id, p_items, p_nota);
end;
$$;

-- Inserta el nuevo rol en las dos validaciones de los motores existentes sin
-- cambiar sus reglas de stock. pg_get_functiondef conserva el resto intacto.
do $$
declare v_oid oid; v_def text;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='crear_solicitud_reposicion'
  order by p.oid desc limit 1;
  v_def := pg_get_functiondef(v_oid);
  v_def := replace(v_def,
    'v_rol not in (''admin'', ''control'', ''bodega'', ''tienda'')',
    'v_rol not in (''admin'', ''control'', ''bodega'', ''tienda'', ''franquiciado'')');
  execute v_def;

  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='recibir_transferencia'
  order by p.oid desc limit 1;
  v_def := pg_get_functiondef(v_oid);
  v_def := replace(v_def,
    'public.rol_usuario_actual() not in (''admin'', ''control'', ''bodega'', ''tienda'')',
    'public.rol_usuario_actual() not in (''admin'', ''control'', ''bodega'', ''tienda'', ''franquiciado'')');
  execute v_def;
end;
$$;

-- ------------------------------------------------------------
-- 5. Vistas, RLS y privilegios
-- ------------------------------------------------------------
create or replace view public.vista_ventas_franquicia_v42
with (security_invoker = true) as
select v.id, v.franquicia_id, f.nombre franquicia, f.almacen_id,
       v.numero, v.fecha, v.estado, v.medio_pago, v.subtotal,
       v.descuento, v.total, v.referencia, v.nota, v.creada_por,
       p.nombre_completo vendedor, v.created_at,
       coalesce(sum(l.cantidad), 0)::integer unidades
from public.ventas_franquicia v
join public.franquicias f on f.id = v.franquicia_id
join public.perfiles p on p.id = v.creada_por
left join public.venta_franquicia_lineas l on l.venta_id = v.id
group by v.id, f.id, p.id;

create or replace view public.vista_caja_franquicia_v42
with (security_invoker = true) as
select m.*, f.nombre franquicia,
       sum(case when m.estado = 'vigente' and m.tipo = 'ingreso' then m.monto
                when m.estado = 'vigente' and m.tipo = 'egreso' then -m.monto
                else 0 end)
         over (partition by m.franquicia_id order by m.fecha, m.created_at, m.id)
         as saldo_acumulado
from public.franquicia_caja_movimientos m
join public.franquicias f on f.id = m.franquicia_id;

alter table public.franquicias enable row level security;
alter table public.ventas_franquicia enable row level security;
alter table public.venta_franquicia_lineas enable row level security;
alter table public.franquicia_caja_movimientos enable row level security;
alter table public.ajustes_inventario_franquicia enable row level security;
alter table public.ajuste_inventario_franquicia_lineas enable row level security;

drop policy if exists "leer_franquicias_v42" on public.franquicias;
create policy "leer_franquicias_v42" on public.franquicias for select to authenticated using (
  public.usuario_puede_franquicia_v42(id, false, false)
  or public.rol_usuario_actual() in ('admin', 'control', 'gerencia', 'bodega', 'logistica')
);
drop policy if exists "leer_ventas_franquicia_v42" on public.ventas_franquicia;
create policy "leer_ventas_franquicia_v42" on public.ventas_franquicia for select to authenticated using (
  public.usuario_puede_franquicia_v42(franquicia_id, false, false)
);
drop policy if exists "leer_lineas_venta_franquicia_v42" on public.venta_franquicia_lineas;
create policy "leer_lineas_venta_franquicia_v42" on public.venta_franquicia_lineas for select to authenticated using (
  exists (select 1 from public.ventas_franquicia v where v.id = venta_id)
);
drop policy if exists "leer_caja_franquicia_v42" on public.franquicia_caja_movimientos;
create policy "leer_caja_franquicia_v42" on public.franquicia_caja_movimientos for select to authenticated using (
  public.usuario_puede_franquicia_v42(franquicia_id, false, true)
);
drop policy if exists "leer_ajustes_franquicia_v42" on public.ajustes_inventario_franquicia;
create policy "leer_ajustes_franquicia_v42" on public.ajustes_inventario_franquicia for select to authenticated using (
  public.usuario_puede_franquicia_v42(franquicia_id, false, true)
);
drop policy if exists "leer_lineas_ajuste_franquicia_v42" on public.ajuste_inventario_franquicia_lineas;
create policy "leer_lineas_ajuste_franquicia_v42" on public.ajuste_inventario_franquicia_lineas for select to authenticated using (
  exists (select 1 from public.ajustes_inventario_franquicia a where a.id = ajuste_id)
);

revoke all on public.franquicias, public.ventas_franquicia,
  public.venta_franquicia_lineas, public.franquicia_caja_movimientos,
  public.ajustes_inventario_franquicia,
  public.ajuste_inventario_franquicia_lineas from public, anon;
revoke insert, update, delete on public.franquicias, public.ventas_franquicia,
  public.venta_franquicia_lineas, public.franquicia_caja_movimientos,
  public.ajustes_inventario_franquicia,
  public.ajuste_inventario_franquicia_lineas from authenticated;
grant select on public.franquicias, public.ventas_franquicia,
  public.venta_franquicia_lineas, public.franquicia_caja_movimientos,
  public.ajustes_inventario_franquicia,
  public.ajuste_inventario_franquicia_lineas to authenticated;
grant select on public.vista_ventas_franquicia_v42,
  public.vista_caja_franquicia_v42 to authenticated;

alter function public.franquicia_usuario_actual_v42() owner to postgres;
alter function public.usuario_puede_franquicia_v42(uuid,boolean,boolean) owner to postgres;
alter function public.admin_guardar_franquicia_v42(uuid,uuid,uuid,uuid,text,text,text,boolean) owner to postgres;
alter function public.admin_guardar_usuario_v42(uuid,text,public.rol_usuario,uuid[],boolean) owner to postgres;
alter function public.registrar_venta_franquicia_v42(date,jsonb,text,numeric,text,text,uuid) owner to postgres;
alter function public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid) owner to postgres;
alter function public.revertir_caja_franquicia_v42(uuid,text,uuid) owner to postgres;
alter function public.registrar_ajuste_franquicia_v42(date,text,jsonb,text,uuid) owner to postgres;
alter function public.crear_solicitud_reposicion_v42(uuid,jsonb,text,text,uuid) owner to postgres;
alter function public.recibir_transferencia_franquicia_v42(uuid,jsonb,text) owner to postgres;

revoke execute on function public.franquicia_usuario_actual_v42() from public, anon;
revoke execute on function public.usuario_puede_franquicia_v42(uuid,boolean,boolean) from public, anon;
revoke execute on function public.admin_guardar_franquicia_v42(uuid,uuid,uuid,uuid,text,text,text,boolean) from public, anon;
revoke execute on function public.admin_guardar_usuario_v42(uuid,text,public.rol_usuario,uuid[],boolean) from public, anon;
revoke execute on function public.registrar_venta_franquicia_v42(date,jsonb,text,numeric,text,text,uuid) from public, anon;
revoke execute on function public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid) from public, anon;
revoke execute on function public.revertir_caja_franquicia_v42(uuid,text,uuid) from public, anon;
revoke execute on function public.registrar_ajuste_franquicia_v42(date,text,jsonb,text,uuid) from public, anon;
revoke execute on function public.crear_solicitud_reposicion_v42(uuid,jsonb,text,text,uuid) from public, anon;
revoke execute on function public.recibir_transferencia_franquicia_v42(uuid,jsonb,text) from public, anon;

grant execute on function public.franquicia_usuario_actual_v42() to authenticated;
grant execute on function public.usuario_puede_franquicia_v42(uuid,boolean,boolean) to authenticated;
grant execute on function public.admin_guardar_franquicia_v42(uuid,uuid,uuid,uuid,text,text,text,boolean) to authenticated;
grant execute on function public.admin_guardar_usuario_v42(uuid,text,public.rol_usuario,uuid[],boolean) to authenticated;
grant execute on function public.registrar_venta_franquicia_v42(date,jsonb,text,numeric,text,text,uuid) to authenticated;
grant execute on function public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid) to authenticated;
grant execute on function public.revertir_caja_franquicia_v42(uuid,text,uuid) to authenticated;
grant execute on function public.registrar_ajuste_franquicia_v42(date,text,jsonb,text,uuid) to authenticated;
grant execute on function public.crear_solicitud_reposicion_v42(uuid,jsonb,text,text,uuid) to authenticated;
grant execute on function public.recibir_transferencia_franquicia_v42(uuid,jsonb,text) to authenticated;

comment on table public.franquicia_caja_movimientos is
  'Diario operativo de control interno; no sustituye contabilidad ni registros tributarios.';

notify pgrst, 'reload schema';
