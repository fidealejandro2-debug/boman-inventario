-- ============================================================
-- BOMAN INVENTARIO - Ordenes y ejecucion de produccion v24
-- Planifica, aprueba, entrega materiales a proceso, registra mermas,
-- devuelve sobrantes e ingresa producto terminado con costo real.
-- Ejecutar una sola vez DESPUES de v23.
-- ============================================================

-- IMPORTANTE: si PostgreSQL informa "unsafe use of new value", ejecuta
-- primero solamente estas tres sentencias y luego el archivo completo.
alter type public.tipo_movimiento add value if not exists 'produccion_salida_material';
alter type public.tipo_movimiento add value if not exists 'produccion_retorno_material';
alter type public.tipo_movimiento add value if not exists 'produccion_ingreso_terminado';

-- Extiende la defensa central de V20: aunque las operaciones publicas ya
-- validan capacidad, ningun movimiento productivo puede insertarse para una
-- empresa que no tenga custodia en el almacen afectado.
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
    ) then
      raise exception 'La empresa no tiene habilitadas ventas y custodia en este almacen';
    end if;
  elsif new.tipo::text = 'entrada' then
    if not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = new.empresa_id and ea.almacen_id = new.entidad_id
        and ea.permite_compras and ea.custodia_inventario
    ) then
      raise exception 'La empresa no tiene habilitadas compras y custodia en este almacen';
    end if;
  elsif new.tipo::text in (
    'salida', 'ajuste', 'cuarentena_liberacion', 'movimiento_manual_reversa',
    'produccion_salida_material', 'produccion_retorno_material',
    'produccion_ingreso_terminado'
  ) then
    if not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = new.empresa_id and ea.almacen_id = new.entidad_id
        and ea.custodia_inventario
    ) then
      raise exception 'La empresa no tiene custodia habilitada en este almacen';
    end if;
  elsif new.tipo::text in (
    'transferencia_envio', 'transferencia_recibo', 'transferencia_retorno'
  ) then
    if not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = new.empresa_id and ea.almacen_id = new.entidad_id
        and ea.custodia_inventario
    ) then
      raise exception 'La empresa no tiene custodia habilitada en el almacen del movimiento';
    end if;
    if new.entidad_destino_id is not null and not exists (
      select 1 from public.empresa_almacenes ea
      where ea.almacen_id = new.entidad_destino_id and ea.custodia_inventario
    ) then
      raise exception 'El otro almacen de la transferencia no tiene una empresa custodio habilitada';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.validar_tipo_componente_formula_v24()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tipo text;
begin
  select tipo_inventario into v_tipo
  from public.productos where id = new.producto_id and activo;
  if not found then raise exception 'El componente no existe o esta inactivo'; end if;
  if v_tipo not in ('materia_prima', 'insumo', 'empaque', 'subproducto') then
    raise exception 'Los productos terminados no pueden usarse como material. Clasificalo primero como materia prima, insumo, empaque o subproducto';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validar_tipo_componente_formula_v24
  on public.formula_produccion_componentes;
create trigger trg_validar_tipo_componente_formula_v24
before insert or update of producto_id on public.formula_produccion_componentes
for each row execute function public.validar_tipo_componente_formula_v24();

-- ------------------------------------------------------------
-- 1. Cabecera, materiales, entregas y trazabilidad
-- ------------------------------------------------------------
create sequence if not exists public.seq_orden_produccion;
create sequence if not exists public.seq_entrega_produccion;

create table if not exists public.ordenes_produccion (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  formula_id uuid not null references public.formulas_produccion(id) on delete restrict,
  producto_resultado_id uuid not null references public.productos(id) on delete restrict,
  almacen_materiales_id uuid not null references public.almacenes(id) on delete restrict,
  almacen_terminado_id uuid not null references public.almacenes(id) on delete restrict,
  estado text not null default 'pendiente_aprobacion' check (estado in (
    'pendiente_aprobacion', 'aprobada', 'en_proceso', 'completada',
    'rechazada', 'cancelada'
  )),
  formula_codigo text not null,
  formula_version integer not null check (formula_version > 0),
  formula_rendimiento numeric(18,6) not null check (formula_rendimiento > 0),
  cantidad_planificada integer not null check (cantidad_planificada > 0),
  cantidad_conforme integer not null default 0 check (cantidad_conforme >= 0),
  cantidad_no_conforme integer not null default 0 check (cantidad_no_conforme >= 0),
  fecha_planificada date,
  prioridad text not null default 'normal' check (prioridad in ('normal', 'urgente')),
  nota text,
  costo_materiales_estimado numeric(18,6) not null default 0 check (costo_materiales_estimado >= 0),
  costo_mano_obra_estimado numeric(18,6) not null default 0 check (costo_mano_obra_estimado >= 0),
  costo_indirecto_estimado numeric(18,6) not null default 0 check (costo_indirecto_estimado >= 0),
  costo_total_estimado numeric(18,6) not null default 0 check (costo_total_estimado >= 0),
  costo_materiales_real numeric(18,6),
  costo_mano_obra_real numeric(18,6),
  costo_indirecto_real numeric(18,6),
  costo_total_real numeric(18,6),
  costo_unitario_real numeric(18,6),
  idempotency_key uuid not null unique,
  finalizacion_idempotency_key uuid unique,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  aprobado_por uuid references public.perfiles(id) on delete restrict,
  iniciado_por uuid references public.perfiles(id) on delete restrict,
  completado_por uuid references public.perfiles(id) on delete restrict,
  cancelado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  aprobado_at timestamptz,
  iniciado_at timestamptz,
  completado_at timestamptz,
  cancelado_at timestamptz,
  motivo_cancelacion text,
  version integer not null default 1
);

create table if not exists public.orden_produccion_materiales (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references public.ordenes_produccion(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  unidad_medida text not null references public.unidades_medida_produccion(codigo),
  cantidad_teorica numeric(18,6) not null check (cantidad_teorica > 0),
  merma_teorica_porcentaje numeric(7,4) not null default 0
    check (merma_teorica_porcentaje between 0 and 100),
  cantidad_planificada integer not null check (cantidad_planificada > 0),
  cantidad_entregada integer not null default 0 check (cantidad_entregada >= 0),
  cantidad_consumida integer not null default 0 check (cantidad_consumida >= 0),
  cantidad_merma integer not null default 0 check (cantidad_merma >= 0),
  cantidad_devuelta integer not null default 0 check (cantidad_devuelta >= 0),
  costo_unitario_referencia numeric(18,6) not null default 0
    check (costo_unitario_referencia >= 0),
  costo_real_linea numeric(18,6),
  observacion text,
  unique (orden_id, producto_id),
  check (cantidad_consumida + cantidad_merma + cantidad_devuelta <= cantidad_entregada)
);

create table if not exists public.entregas_materiales_produccion (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  orden_id uuid not null references public.ordenes_produccion(id) on delete restrict,
  idempotency_key uuid not null unique,
  permite_exceso boolean not null default false,
  nota text,
  entregado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.entrega_materiales_produccion_lineas (
  id uuid primary key default gen_random_uuid(),
  entrega_id uuid not null references public.entregas_materiales_produccion(id) on delete restrict,
  orden_material_id uuid not null references public.orden_produccion_materiales(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  cantidad integer not null check (cantidad > 0),
  movimiento_id uuid not null references public.movimientos(id) on delete restrict,
  unique (entrega_id, orden_material_id)
);

create table if not exists public.orden_produccion_eventos (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references public.ordenes_produccion(id) on delete restrict,
  tipo text not null check (tipo in (
    'creada', 'aprobada', 'rechazada', 'materiales_entregados',
    'completada', 'cancelada'
  )),
  estado_anterior text,
  estado_nuevo text not null,
  detalle text,
  datos jsonb not null default '{}'::jsonb,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_ordenes_produccion_estado_fecha
  on public.ordenes_produccion(estado, created_at desc);
create index if not exists idx_ordenes_produccion_empresa_fecha
  on public.ordenes_produccion(empresa_id, created_at desc);
create index if not exists idx_ordenes_produccion_almacen_materiales
  on public.ordenes_produccion(almacen_materiales_id, estado);
create index if not exists idx_orden_produccion_material_producto
  on public.orden_produccion_materiales(producto_id, orden_id);
create index if not exists idx_entregas_produccion_orden_fecha
  on public.entregas_materiales_produccion(orden_id, created_at desc);
create index if not exists idx_orden_produccion_eventos_fecha
  on public.orden_produccion_eventos(orden_id, created_at desc);

comment on column public.orden_produccion_materiales.cantidad_teorica is
  'Necesidad decimal calculada desde la formula antes de redondear a la unidad base de stock.';
comment on column public.orden_produccion_materiales.cantidad_planificada is
  'Cantidad fisica entera, redondeada hacia arriba, reservada en la unidad base del producto.';

-- ------------------------------------------------------------
-- 2. Acceso y RLS
-- ------------------------------------------------------------
create or replace function public.puede_ver_orden_produccion_v24(p_orden_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.ordenes_produccion o
    where o.id = p_orden_id
      and public.usuario_puede_empresa(o.empresa_id, false)
      and (
        public.usuario_puede_almacen(o.almacen_materiales_id, false)
        or public.usuario_puede_almacen(o.almacen_terminado_id, false)
      )
  );
$$;

alter table public.ordenes_produccion enable row level security;
alter table public.orden_produccion_materiales enable row level security;
alter table public.entregas_materiales_produccion enable row level security;
alter table public.entrega_materiales_produccion_lineas enable row level security;
alter table public.orden_produccion_eventos enable row level security;

drop policy if exists "leer_ordenes_produccion_v24" on public.ordenes_produccion;
create policy "leer_ordenes_produccion_v24"
on public.ordenes_produccion for select to authenticated using (
  public.puede_ver_orden_produccion_v24(id)
);

drop policy if exists "leer_materiales_produccion_v24" on public.orden_produccion_materiales;
create policy "leer_materiales_produccion_v24"
on public.orden_produccion_materiales for select to authenticated using (
  public.puede_ver_orden_produccion_v24(orden_id)
);

drop policy if exists "leer_entregas_produccion_v24" on public.entregas_materiales_produccion;
create policy "leer_entregas_produccion_v24"
on public.entregas_materiales_produccion for select to authenticated using (
  public.puede_ver_orden_produccion_v24(orden_id)
);

drop policy if exists "leer_entrega_lineas_produccion_v24"
  on public.entrega_materiales_produccion_lineas;
create policy "leer_entrega_lineas_produccion_v24"
on public.entrega_materiales_produccion_lineas for select to authenticated using (
  exists (
    select 1 from public.entregas_materiales_produccion e
    where e.id = entrega_id and public.puede_ver_orden_produccion_v24(e.orden_id)
  )
);

drop policy if exists "leer_eventos_produccion_v24" on public.orden_produccion_eventos;
create policy "leer_eventos_produccion_v24"
on public.orden_produccion_eventos for select to authenticated using (
  public.puede_ver_orden_produccion_v24(orden_id)
);

-- ------------------------------------------------------------
-- 3. Crear y resolver la orden
-- ------------------------------------------------------------
create or replace function public.crear_orden_produccion_v24(
  p_formula_id uuid,
  p_empresa_id uuid,
  p_almacen_materiales_id uuid,
  p_almacen_terminado_id uuid,
  p_cantidad_planificada integer,
  p_fecha_planificada date,
  p_prioridad text,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.formulas_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_id uuid;
  v_numero text;
  v_factor numeric;
  v_materiales numeric;
  v_mano_obra numeric;
  v_indirectos numeric;
begin
  if v_rol not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para crear ordenes de produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 24)
  );
  select id, numero into v_id, v_numero
  from public.ordenes_produccion where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_id, 'numero', v_numero, 'duplicado', true);
  end if;
  if coalesce(p_cantidad_planificada, 0) <= 0 then
    raise exception 'La cantidad planificada debe ser mayor que cero';
  end if;
  if coalesce(p_prioridad, '') not in ('normal', 'urgente') then
    raise exception 'La prioridad no es valida';
  end if;

  select * into f from public.formulas_produccion where id = p_formula_id;
  if not found or f.estado <> 'activa' then
    raise exception 'La formula no existe o no esta activa';
  end if;
  if not exists (
    select 1 from public.empresas e
    where e.id = p_empresa_id and e.grupo_id = f.grupo_id and e.activo
  ) then raise exception 'La empresa no pertenece al grupo de la formula'; end if;
  if not public.usuario_puede_capacidad_empresa(
    p_empresa_id, p_almacen_materiales_id, 'custodia'
  ) then raise exception 'No tienes custodia habilitada en el almacen de materiales'; end if;
  if not public.usuario_puede_capacidad_empresa(
    p_empresa_id, p_almacen_terminado_id, 'custodia'
  ) then raise exception 'No tienes custodia habilitada en el almacen de producto terminado'; end if;

  v_factor := p_cantidad_planificada::numeric / f.rendimiento_base;
  select
    coalesce(sum(
      ceil(c.cantidad_base * v_factor * (1 + c.merma_porcentaje / 100))
        * coalesce(cp.costo_referencia, 0)
    ), 0),
    round(f.costo_mano_obra_lote * v_factor, 6),
    round(f.costo_indirecto_lote * v_factor, 6)
  into v_materiales, v_mano_obra, v_indirectos
  from public.formula_produccion_componentes c
  left join public.vista_costos_producto_empresa_v23 cp
    on cp.empresa_id = p_empresa_id and cp.producto_id = c.producto_id
  where c.formula_id = f.id
  group by f.costo_mano_obra_lote, f.costo_indirecto_lote;

  v_numero := 'OP-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY')
    || '-' || lpad(nextval('public.seq_orden_produccion')::text, 6, '0');
  insert into public.ordenes_produccion(
    numero, grupo_id, empresa_id, formula_id, producto_resultado_id,
    almacen_materiales_id, almacen_terminado_id, formula_codigo,
    formula_version, formula_rendimiento, cantidad_planificada,
    fecha_planificada, prioridad, nota, costo_materiales_estimado,
    costo_mano_obra_estimado, costo_indirecto_estimado,
    costo_total_estimado, idempotency_key, creado_por
  ) values (
    v_numero, f.grupo_id, p_empresa_id, f.id, f.producto_resultado_id,
    p_almacen_materiales_id, p_almacen_terminado_id, f.codigo,
    f.version, f.rendimiento_base, p_cantidad_planificada,
    p_fecha_planificada, p_prioridad, nullif(btrim(p_nota), ''),
    round(v_materiales, 6), coalesce(v_mano_obra, 0), coalesce(v_indirectos, 0),
    round(v_materiales + coalesce(v_mano_obra, 0) + coalesce(v_indirectos, 0), 6),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;

  insert into public.orden_produccion_materiales(
    orden_id, producto_id, unidad_medida, cantidad_teorica,
    merma_teorica_porcentaje, cantidad_planificada,
    costo_unitario_referencia, observacion
  )
  select v_id, c.producto_id, p.unidad_medida,
         round(c.cantidad_base * v_factor, 6), c.merma_porcentaje,
         ceil(c.cantidad_base * v_factor * (1 + c.merma_porcentaje / 100))::integer,
         coalesce(cp.costo_referencia, 0), c.observacion
  from public.formula_produccion_componentes c
  join public.productos p on p.id = c.producto_id and p.activo
  left join public.vista_costos_producto_empresa_v23 cp
    on cp.empresa_id = p_empresa_id and cp.producto_id = c.producto_id
  where c.formula_id = f.id;

  if not exists (
    select 1 from public.orden_produccion_materiales where orden_id = v_id
  ) then raise exception 'La formula no contiene materiales validos'; end if;

  insert into public.orden_produccion_eventos(
    orden_id, tipo, estado_anterior, estado_nuevo, detalle, datos, usuario_id
  ) values (
    v_id, 'creada', null, 'pendiente_aprobacion',
    coalesce(nullif(btrim(p_nota), ''), 'Orden de produccion creada'),
    jsonb_build_object('cantidad_planificada', p_cantidad_planificada,
      'formula_id', f.id, 'formula_version', f.version), auth.uid()
  );
  return jsonb_build_object('id', v_id, 'numero', v_numero, 'duplicado', false);
end;
$$;

create or replace function public.resolver_orden_produccion_v24(
  p_orden_id uuid,
  p_aprobar boolean,
  p_nota text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_estado text;
  v_faltante record;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden resolver ordenes de produccion';
  end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'La resolucion requiere una nota de al menos 5 caracteres';
  end if;
  if p_aprobar is null then raise exception 'Indica si la orden se aprueba o se rechaza'; end if;
  select * into o from public.ordenes_produccion where id = p_orden_id for update;
  if not found then raise exception 'La orden de produccion no existe'; end if;
  if o.estado <> 'pendiente_aprobacion' then
    raise exception 'La orden ya fue resuelta';
  end if;
  if p_aprobar and o.creado_por = auth.uid() and v_rol <> 'admin' then
    raise exception 'Quien preparo la orden no puede aprobarla; requiere otro revisor';
  end if;
  if p_aprobar and not exists (
    select 1 from public.formulas_produccion f
    where f.id = o.formula_id and f.estado = 'activa'
  ) then raise exception 'La formula dejo de estar activa; crea una orden con la version vigente'; end if;
  if p_aprobar and (
    not exists (
      select 1 from public.productos p
      where p.id = o.producto_resultado_id and p.activo
    ) or exists (
      select 1
      from public.orden_produccion_materiales m
      join public.productos p on p.id = m.producto_id
      where m.orden_id = o.id and not p.activo
    )
  ) then raise exception 'El resultado o uno de los materiales esta inactivo'; end if;
  if p_aprobar then
    -- El costo se congela al aprobar, no al preparar el borrador. Asi una
    -- compra o correccion de costo ocurrida durante la revision queda incluida.
    update public.orden_produccion_materiales m
    set costo_unitario_referencia = coalesce(cp.costo_referencia, 0)
    from public.vista_costos_producto_empresa_v23 cp
    where m.orden_id = o.id and cp.empresa_id = o.empresa_id
      and cp.producto_id = m.producto_id;

    update public.ordenes_produccion op
    set costo_materiales_estimado = t.materiales,
        costo_total_estimado = t.materiales
          + op.costo_mano_obra_estimado + op.costo_indirecto_estimado,
        updated_at = now()
    from (
      select orden_id,
             round(sum(cantidad_planificada * costo_unitario_referencia), 6) materiales
      from public.orden_produccion_materiales
      where orden_id = o.id group by orden_id
    ) t
    where op.id = t.orden_id;
  end if;
  if p_aprobar and exists (
    select 1 from public.orden_produccion_materiales
    where orden_id = o.id and costo_unitario_referencia <= 0
  ) then raise exception 'Todos los materiales deben tener costo de compra o costo estandar antes de aprobar'; end if;

  if p_aprobar then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(o.almacen_materiales_id::text, 2401)
    );
    select m.producto_id, p.sku,
           m.cantidad_planificada,
           coalesce(i.cantidad, 0) - coalesce(r.reservado, 0) as disponible
    into v_faltante
    from public.orden_produccion_materiales m
    join public.productos p on p.id = m.producto_id
    left join public.inventario i
      on i.producto_id = m.producto_id and i.entidad_id = o.almacen_materiales_id
    left join lateral (
      select sum(greatest(om.cantidad_planificada - om.cantidad_entregada, 0))::integer reservado
      from public.orden_produccion_materiales om
      join public.ordenes_produccion oo on oo.id = om.orden_id
      where oo.almacen_materiales_id = o.almacen_materiales_id
        and oo.estado in ('aprobada', 'en_proceso')
        and oo.id <> o.id and om.producto_id = m.producto_id
    ) r on true
    where m.orden_id = o.id
      and coalesce(i.cantidad, 0) - coalesce(r.reservado, 0) < m.cantidad_planificada
    order by p.sku limit 1;
    if found then
      raise exception 'Stock disponible insuficiente para %: requiere %, disponible %',
        v_faltante.sku, v_faltante.cantidad_planificada,
        greatest(v_faltante.disponible, 0);
    end if;
    v_estado := 'aprobada';
  else
    v_estado := 'rechazada';
  end if;

  update public.ordenes_produccion
  set estado = v_estado, aprobado_por = auth.uid(), aprobado_at = now(),
      updated_at = now(), version = version + 1,
      nota = concat_ws(E'\n', nota, btrim(p_nota))
  where id = o.id;
  insert into public.orden_produccion_eventos(
    orden_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (
    o.id, case when p_aprobar then 'aprobada' else 'rechazada' end,
    o.estado, v_estado, btrim(p_nota), auth.uid()
  );
  return v_estado;
end;
$$;

-- ------------------------------------------------------------
-- 4. Entrega de materiales: disponible -> trabajo en proceso
-- ------------------------------------------------------------
create or replace function public.entregar_materiales_produccion_v24(
  p_orden_id uuid,
  p_items jsonb,
  p_nota text,
  p_permitir_exceso boolean,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_entrega_id uuid;
  v_numero text;
  it record;
  v_movimiento jsonb;
  v_movimiento_id uuid;
  v_total integer := 0;
begin
  if v_rol not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para entregar materiales a produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'La entrega debe contener materiales';
  end if;
  if exists (
    select orden_material_id from jsonb_to_recordset(p_items) x(orden_material_id uuid)
    group by orden_material_id having count(*) > 1
  ) then raise exception 'La entrega contiene materiales repetidos'; end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(orden_material_id uuid, cantidad integer)
    where x.orden_material_id is null or coalesce(x.cantidad, 0) <= 0
  ) then raise exception 'La entrega contiene cantidades invalidas'; end if;
  if coalesce(p_permitir_exceso, false) and v_rol not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden autorizar exceso sobre la formula';
  end if;
  if coalesce(p_permitir_exceso, false) and length(btrim(coalesce(p_nota, ''))) < 8 then
    raise exception 'La entrega en exceso requiere una justificacion de al menos 8 caracteres';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 2402)
  );
  select id, numero into v_entrega_id, v_numero
  from public.entregas_materiales_produccion where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_entrega_id, 'numero', v_numero, 'duplicado', true);
  end if;

  select * into o from public.ordenes_produccion where id = p_orden_id for update;
  if not found then raise exception 'La orden de produccion no existe'; end if;
  if o.estado not in ('aprobada', 'en_proceso') then
    raise exception 'La orden no admite entrega de materiales';
  end if;
  if not public.usuario_puede_capacidad_empresa(
    o.empresa_id, o.almacen_materiales_id, 'custodia'
  ) then raise exception 'No tienes custodia habilitada en el almacen de materiales'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(o.almacen_materiales_id::text, 2401)
  );
  if exists (
    select 1
    from jsonb_to_recordset(p_items) x(orden_material_id uuid, cantidad integer)
    left join public.orden_produccion_materiales m
      on m.id = x.orden_material_id and m.orden_id = o.id
    left join public.productos p on p.id = m.producto_id and p.activo
    where m.id is null
      or p.id is null
      or (not coalesce(p_permitir_exceso, false)
          and m.cantidad_entregada + x.cantidad > m.cantidad_planificada)
  ) then raise exception 'Un material no pertenece a la orden o supera la cantidad planificada'; end if;

  v_numero := 'EP-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY')
    || '-' || lpad(nextval('public.seq_entrega_produccion')::text, 6, '0');
  insert into public.entregas_materiales_produccion(
    numero, orden_id, idempotency_key, permite_exceso, nota, entregado_por
  ) values (
    v_numero, o.id, p_idempotency_key, coalesce(p_permitir_exceso, false),
    nullif(btrim(p_nota), ''), auth.uid()
  ) returning id into v_entrega_id;

  for it in
    select m.id as orden_material_id, m.producto_id, x.cantidad
    from jsonb_to_recordset(p_items) x(orden_material_id uuid, cantidad integer)
    join public.orden_produccion_materiales m
      on m.id = x.orden_material_id and m.orden_id = o.id
    order by m.producto_id
  loop
    v_movimiento := public.aplicar_movimiento_stock_v20(
      it.producto_id, o.almacen_materiales_id, o.empresa_id,
      'produccion_salida_material'::public.tipo_movimiento, -it.cantidad,
      v_entrega_id, 'entrega_materiales_produccion',
      'Entrega ' || v_numero || ' a orden ' || o.numero
        || coalesce(' - ' || nullif(btrim(p_nota), ''), ''),
      null, null,
      md5('v24-entrega-' || v_entrega_id::text || '-' || it.producto_id::text)::uuid
    );
    v_movimiento_id := (v_movimiento->>'movimiento_id')::uuid;
    insert into public.entrega_materiales_produccion_lineas(
      entrega_id, orden_material_id, producto_id, cantidad, movimiento_id
    ) values (
      v_entrega_id, it.orden_material_id, it.producto_id, it.cantidad, v_movimiento_id
    );
    update public.orden_produccion_materiales
    set cantidad_entregada = cantidad_entregada + it.cantidad
    where id = it.orden_material_id;
    v_total := v_total + it.cantidad;
  end loop;

  update public.ordenes_produccion
  set estado = 'en_proceso',
      iniciado_por = coalesce(iniciado_por, auth.uid()),
      iniciado_at = coalesce(iniciado_at, now()),
      updated_at = now(), version = version + 1
  where id = o.id;
  insert into public.orden_produccion_eventos(
    orden_id, tipo, estado_anterior, estado_nuevo, detalle, datos, usuario_id
  ) values (
    o.id, 'materiales_entregados', o.estado, 'en_proceso',
    coalesce(nullif(btrim(p_nota), ''), 'Materiales entregados a proceso'),
    jsonb_build_object('entrega_id', v_entrega_id, 'numero', v_numero,
      'unidades_base', v_total, 'exceso_autorizado', coalesce(p_permitir_exceso, false)),
    auth.uid()
  );
  return jsonb_build_object(
    'id', v_entrega_id, 'numero', v_numero, 'unidades_base', v_total,
    'duplicado', false
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Finalizacion: consumo/merma/retorno e ingreso del resultado
-- ------------------------------------------------------------
create or replace function public.finalizar_orden_produccion_v24(
  p_orden_id uuid,
  p_materiales jsonb,
  p_cantidad_conforme integer,
  p_cantidad_no_conforme integer,
  p_costo_mano_obra_real numeric,
  p_costo_indirecto_real numeric,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  it record;
  v_devuelta integer;
  v_costo_materiales numeric := 0;
  v_costo_total numeric;
  v_costo_unitario numeric;
  v_movimiento jsonb;
begin
  if v_rol not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para finalizar produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if coalesce(p_cantidad_conforme, 0) < 0 or coalesce(p_cantidad_no_conforme, 0) < 0
     or coalesce(p_cantidad_conforme, 0) + coalesce(p_cantidad_no_conforme, 0) <= 0 then
    raise exception 'Registra al menos una unidad producida, conforme o no conforme';
  end if;
  if coalesce(p_costo_mano_obra_real, 0) < 0 or coalesce(p_costo_indirecto_real, 0) < 0 then
    raise exception 'Los costos reales no pueden ser negativos';
  end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'El cierre requiere una nota de al menos 5 caracteres';
  end if;
  if p_materiales is null or jsonb_typeof(p_materiales) <> 'array' then
    raise exception 'El detalle de materiales no es valido';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 2403)
  );
  select * into o from public.ordenes_produccion where id = p_orden_id for update;
  if not found then raise exception 'La orden de produccion no existe'; end if;
  if o.finalizacion_idempotency_key = p_idempotency_key and o.estado = 'completada' then
    return jsonb_build_object('id', o.id, 'numero', o.numero, 'duplicado', true);
  end if;
  if o.estado <> 'en_proceso' then raise exception 'La orden no esta en proceso'; end if;
  if not exists (
    select 1 from public.productos p
    where p.id = o.producto_resultado_id and p.activo
  ) then raise exception 'El producto resultado esta inactivo'; end if;
  if not public.usuario_puede_capacidad_empresa(
    o.empresa_id, o.almacen_materiales_id, 'custodia'
  ) or not public.usuario_puede_capacidad_empresa(
    o.empresa_id, o.almacen_terminado_id, 'custodia'
  ) then raise exception 'No tienes custodia habilitada en los almacenes de la orden'; end if;
  if exists (
    select 1 from public.orden_produccion_materiales
    where orden_id = o.id and cantidad_entregada = 0
  ) then raise exception 'Todos los materiales de la formula deben haberse entregado antes del cierre'; end if;
  if (p_cantidad_conforme + p_cantidad_no_conforme <> o.cantidad_planificada)
     and length(btrim(coalesce(p_nota, ''))) < 10 then
    raise exception 'La diferencia contra el plan requiere una explicacion de al menos 10 caracteres';
  end if;
  if exists (
    select orden_material_id
    from jsonb_to_recordset(p_materiales) x(orden_material_id uuid)
    group by orden_material_id having count(*) > 1
  ) then raise exception 'El cierre contiene materiales repetidos'; end if;
  if (
    select count(*) from jsonb_to_recordset(p_materiales) x(orden_material_id uuid)
  ) <> (
    select count(*) from public.orden_produccion_materiales where orden_id = o.id
  ) then raise exception 'Debes clasificar todos los materiales entregados'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_materiales) x(
      orden_material_id uuid, cantidad_consumida integer, cantidad_merma integer
    )
    left join public.orden_produccion_materiales m
      on m.id = x.orden_material_id and m.orden_id = o.id
    where m.id is null or coalesce(x.cantidad_consumida, 0) < 0
      or coalesce(x.cantidad_merma, 0) < 0
      or coalesce(x.cantidad_consumida, 0) + coalesce(x.cantidad_merma, 0)
         > m.cantidad_entregada
  ) then raise exception 'La clasificacion de materiales supera lo entregado o es invalida'; end if;

  for it in
    select m.*, x.cantidad_consumida, x.cantidad_merma
    from jsonb_to_recordset(p_materiales) x(
      orden_material_id uuid, cantidad_consumida integer, cantidad_merma integer
    )
    join public.orden_produccion_materiales m
      on m.id = x.orden_material_id and m.orden_id = o.id
    order by m.producto_id
  loop
    v_devuelta := it.cantidad_entregada
      - it.cantidad_consumida - it.cantidad_merma;
    if v_devuelta > 0 then
      v_movimiento := public.aplicar_movimiento_stock_v20(
        it.producto_id, o.almacen_materiales_id, o.empresa_id,
        'produccion_retorno_material'::public.tipo_movimiento, v_devuelta,
        o.id, 'orden_produccion',
        'Retorno de material sobrante de orden ' || o.numero,
        null, null,
        md5('v24-retorno-' || o.id::text || '-' || it.producto_id::text)::uuid
      );
    end if;
    update public.orden_produccion_materiales
    set cantidad_consumida = it.cantidad_consumida,
        cantidad_merma = it.cantidad_merma,
        cantidad_devuelta = v_devuelta,
        costo_real_linea = round(
          (it.cantidad_consumida + it.cantidad_merma)
            * it.costo_unitario_referencia, 6
        )
    where id = it.id;
    v_costo_materiales := v_costo_materiales
      + (it.cantidad_consumida + it.cantidad_merma) * it.costo_unitario_referencia;
  end loop;

  if p_cantidad_conforme > 0 then
    v_movimiento := public.aplicar_movimiento_stock_v20(
      o.producto_resultado_id, o.almacen_terminado_id, o.empresa_id,
      'produccion_ingreso_terminado'::public.tipo_movimiento, p_cantidad_conforme,
      o.id, 'orden_produccion', 'Ingreso conforme de orden ' || o.numero,
      null, null, md5('v24-resultado-' || o.id::text)::uuid
    );
  end if;

  if p_cantidad_no_conforme > 0 then
    perform set_config('boman.cuarentena_tipo', 'produccion_no_conforme', true);
    perform set_config('boman.cuarentena_documento_tipo', 'orden_produccion', true);
    perform set_config('boman.cuarentena_documento_id', o.id::text, true);
    perform set_config(
      'boman.cuarentena_detalle',
      'Produccion no conforme de orden ' || o.numero || ' - ' || btrim(p_nota), true
    );
    insert into public.inventario_cuarentena as q(producto_id, almacen_id, cantidad)
    values (o.producto_resultado_id, o.almacen_terminado_id, p_cantidad_no_conforme)
    on conflict (producto_id, almacen_id) do update
    set cantidad = q.cantidad + excluded.cantidad, updated_at = now();
  end if;

  v_costo_total := round(v_costo_materiales + coalesce(p_costo_mano_obra_real, 0)
    + coalesce(p_costo_indirecto_real, 0), 6);
  v_costo_unitario := round(
    v_costo_total / nullif(p_cantidad_conforme + p_cantidad_no_conforme, 0), 6
  );
  update public.ordenes_produccion
  set estado = 'completada', cantidad_conforme = p_cantidad_conforme,
      cantidad_no_conforme = p_cantidad_no_conforme,
      costo_materiales_real = round(v_costo_materiales, 6),
      costo_mano_obra_real = coalesce(p_costo_mano_obra_real, 0),
      costo_indirecto_real = coalesce(p_costo_indirecto_real, 0),
      costo_total_real = v_costo_total, costo_unitario_real = v_costo_unitario,
      finalizacion_idempotency_key = p_idempotency_key,
      completado_por = auth.uid(), completado_at = now(), updated_at = now(),
      version = version + 1, nota = concat_ws(E'\n', nota, btrim(p_nota))
  where id = o.id;

  insert into public.orden_produccion_eventos(
    orden_id, tipo, estado_anterior, estado_nuevo, detalle, datos, usuario_id
  ) values (
    o.id, 'completada', o.estado, 'completada', btrim(p_nota),
    jsonb_build_object(
      'cantidad_conforme', p_cantidad_conforme,
      'cantidad_no_conforme', p_cantidad_no_conforme,
      'costo_materiales_real', round(v_costo_materiales, 6),
      'costo_total_real', v_costo_total,
      'costo_unitario_real', v_costo_unitario
    ), auth.uid()
  );
  return jsonb_build_object(
    'id', o.id, 'numero', o.numero, 'duplicado', false,
    'cantidad_conforme', p_cantidad_conforme,
    'cantidad_no_conforme', p_cantidad_no_conforme,
    'costo_total_real', v_costo_total,
    'costo_unitario_real', v_costo_unitario
  );
end;
$$;

-- Cancelar una orden iniciada devuelve todo el material entregado. Por eso
-- requiere Administracion y confirmacion explicita de retorno fisico.
create or replace function public.cancelar_orden_produccion_v24(
  p_orden_id uuid,
  p_motivo text,
  p_confirmar_retorno_fisico boolean,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  it record;
  v_retorno integer;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden cancelar produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 8 then
    raise exception 'La cancelacion requiere un motivo de al menos 8 caracteres';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 2404)
  );
  select * into o from public.ordenes_produccion where id = p_orden_id for update;
  if not found then raise exception 'La orden de produccion no existe'; end if;
  if o.estado = 'cancelada' then
    return jsonb_build_object('id', o.id, 'numero', o.numero, 'duplicado', true);
  end if;
  if o.estado not in ('pendiente_aprobacion', 'aprobada', 'en_proceso') then
    raise exception 'La orden ya no puede cancelarse';
  end if;
  if o.estado = 'en_proceso' and v_rol <> 'admin' then
    raise exception 'Solo Administracion puede cancelar una orden con materiales entregados';
  end if;
  if o.estado = 'en_proceso' and not coalesce(p_confirmar_retorno_fisico, false) then
    raise exception 'Confirma que todo el material entregado regreso fisicamente al almacen';
  end if;

  if o.estado = 'en_proceso' then
    for it in
      select * from public.orden_produccion_materiales
      where orden_id = o.id order by producto_id
    loop
      v_retorno := it.cantidad_entregada - it.cantidad_devuelta;
      if v_retorno > 0 then
        perform public.aplicar_movimiento_stock_v20(
          it.producto_id, o.almacen_materiales_id, o.empresa_id,
          'produccion_retorno_material'::public.tipo_movimiento, v_retorno,
          o.id, 'cancelacion_orden_produccion',
          'Retorno fisico por cancelacion de orden ' || o.numero || ' - ' || btrim(p_motivo),
          null, null,
          md5('v24-cancelar-' || p_idempotency_key::text || '-' || it.producto_id::text)::uuid
        );
        update public.orden_produccion_materiales
        set cantidad_devuelta = cantidad_devuelta + v_retorno
        where id = it.id;
      end if;
    end loop;
  end if;

  update public.ordenes_produccion
  set estado = 'cancelada', cancelado_por = auth.uid(), cancelado_at = now(),
      motivo_cancelacion = btrim(p_motivo), updated_at = now(), version = version + 1
  where id = o.id;
  insert into public.orden_produccion_eventos(
    orden_id, tipo, estado_anterior, estado_nuevo, detalle, datos, usuario_id
  ) values (
    o.id, 'cancelada', o.estado, 'cancelada', btrim(p_motivo),
    jsonb_build_object('retorno_fisico_confirmado', coalesce(p_confirmar_retorno_fisico, false),
      'idempotency_key', p_idempotency_key), auth.uid()
  );
  return jsonb_build_object('id', o.id, 'numero', o.numero, 'duplicado', false);
end;
$$;

-- ------------------------------------------------------------
-- 6. Vistas de seguimiento, reservas y costo real
-- ------------------------------------------------------------
create or replace view public.vista_ordenes_produccion_v24
with (security_invoker = true) as
select
  o.id, o.numero, o.grupo_id, o.empresa_id, e.codigo as empresa_codigo,
  e.razon_social, o.formula_id, o.formula_codigo, o.formula_version,
  o.producto_resultado_id, p.sku as resultado_sku,
  p.nombre as resultado_producto, p.unidad_medida as resultado_unidad,
  o.almacen_materiales_id, am.nombre as almacen_materiales,
  o.almacen_terminado_id, at.nombre as almacen_terminado,
  o.estado, o.cantidad_planificada, o.cantidad_conforme,
  o.cantidad_no_conforme, o.fecha_planificada, o.prioridad,
  o.costo_total_estimado, o.costo_total_real, o.costo_unitario_real,
  coalesce(m.materiales, 0) as materiales,
  coalesce(m.planificado, 0) as unidades_base_planificadas,
  coalesce(m.entregado, 0) as unidades_base_entregadas,
  coalesce(m.en_proceso, 0) as unidades_base_en_proceso,
  o.creado_por, o.aprobado_por, o.iniciado_por, o.completado_por,
  o.created_at, o.updated_at, o.version
from public.ordenes_produccion o
join public.empresas e on e.id = o.empresa_id
join public.productos p on p.id = o.producto_resultado_id
join public.almacenes am on am.id = o.almacen_materiales_id
join public.almacenes at on at.id = o.almacen_terminado_id
left join lateral (
  select count(*)::integer materiales,
         sum(om.cantidad_planificada)::integer planificado,
         sum(om.cantidad_entregada)::integer entregado,
         sum(om.cantidad_entregada - om.cantidad_consumida
           - om.cantidad_merma - om.cantidad_devuelta)::integer en_proceso
  from public.orden_produccion_materiales om where om.orden_id = o.id
) m on true;

create or replace view public.vista_materiales_orden_produccion_v24
with (security_invoker = true) as
select
  m.id as orden_material_id, m.orden_id, o.numero, o.estado,
  o.empresa_id, o.almacen_materiales_id, m.producto_id,
  p.sku, p.nombre as producto, p.unidad_medida,
  m.cantidad_teorica, m.merma_teorica_porcentaje,
  m.cantidad_planificada, m.cantidad_entregada,
  m.cantidad_consumida, m.cantidad_merma, m.cantidad_devuelta,
  greatest(m.cantidad_planificada - m.cantidad_entregada, 0) as pendiente_entrega,
  coalesce(i.cantidad, 0) as stock_fisico,
  coalesce(r.reservado, 0) as reservado_produccion,
  greatest(coalesce(i.cantidad, 0) - coalesce(r.reservado, 0), 0) as stock_disponible,
  m.costo_unitario_referencia, m.costo_real_linea
from public.orden_produccion_materiales m
join public.ordenes_produccion o on o.id = m.orden_id
join public.productos p on p.id = m.producto_id
left join public.inventario i
  on i.producto_id = m.producto_id and i.entidad_id = o.almacen_materiales_id
left join lateral (
  select sum(greatest(om.cantidad_planificada - om.cantidad_entregada, 0))::integer reservado
  from public.orden_produccion_materiales om
  join public.ordenes_produccion oo on oo.id = om.orden_id
  where oo.almacen_materiales_id = o.almacen_materiales_id
    and oo.estado in ('aprobada', 'en_proceso')
    and om.producto_id = m.producto_id
) r on true;

-- ------------------------------------------------------------
-- 7. Propiedad, privilegios y recarga de PostgREST
-- ------------------------------------------------------------
alter function public.validar_capacidad_movimiento_v20() owner to postgres;
alter function public.validar_tipo_componente_formula_v24() owner to postgres;
alter function public.puede_ver_orden_produccion_v24(uuid) owner to postgres;
alter function public.crear_orden_produccion_v24(uuid, uuid, uuid, uuid, integer, date, text, text, uuid) owner to postgres;
alter function public.resolver_orden_produccion_v24(uuid, boolean, text) owner to postgres;
alter function public.entregar_materiales_produccion_v24(uuid, jsonb, text, boolean, uuid) owner to postgres;
alter function public.finalizar_orden_produccion_v24(uuid, jsonb, integer, integer, numeric, numeric, text, uuid) owner to postgres;
alter function public.cancelar_orden_produccion_v24(uuid, text, boolean, uuid) owner to postgres;

revoke all on public.ordenes_produccion from public, anon;
revoke all on public.orden_produccion_materiales from public, anon;
revoke all on public.entregas_materiales_produccion from public, anon;
revoke all on public.entrega_materiales_produccion_lineas from public, anon;
revoke all on public.orden_produccion_eventos from public, anon;
revoke insert, update, delete on public.ordenes_produccion from authenticated;
revoke insert, update, delete on public.orden_produccion_materiales from authenticated;
revoke insert, update, delete on public.entregas_materiales_produccion from authenticated;
revoke insert, update, delete on public.entrega_materiales_produccion_lineas from authenticated;
revoke insert, update, delete on public.orden_produccion_eventos from authenticated;
grant select on public.ordenes_produccion to authenticated;
grant select on public.orden_produccion_materiales to authenticated;
grant select on public.entregas_materiales_produccion to authenticated;
grant select on public.entrega_materiales_produccion_lineas to authenticated;
grant select on public.orden_produccion_eventos to authenticated;
revoke all on public.vista_ordenes_produccion_v24 from public, anon;
revoke all on public.vista_materiales_orden_produccion_v24 from public, anon;
grant select on public.vista_ordenes_produccion_v24 to authenticated;
grant select on public.vista_materiales_orden_produccion_v24 to authenticated;

revoke execute on function public.puede_ver_orden_produccion_v24(uuid)
  from public, anon;
revoke execute on function public.crear_orden_produccion_v24(uuid, uuid, uuid, uuid, integer, date, text, text, uuid)
  from public, anon;
revoke execute on function public.resolver_orden_produccion_v24(uuid, boolean, text)
  from public, anon;
revoke execute on function public.entregar_materiales_produccion_v24(uuid, jsonb, text, boolean, uuid)
  from public, anon;
revoke execute on function public.finalizar_orden_produccion_v24(uuid, jsonb, integer, integer, numeric, numeric, text, uuid)
  from public, anon;
revoke execute on function public.cancelar_orden_produccion_v24(uuid, text, boolean, uuid)
  from public, anon;
grant execute on function public.puede_ver_orden_produccion_v24(uuid)
  to authenticated;
grant execute on function public.crear_orden_produccion_v24(uuid, uuid, uuid, uuid, integer, date, text, text, uuid)
  to authenticated;
grant execute on function public.resolver_orden_produccion_v24(uuid, boolean, text)
  to authenticated;
grant execute on function public.entregar_materiales_produccion_v24(uuid, jsonb, text, boolean, uuid)
  to authenticated;
grant execute on function public.finalizar_orden_produccion_v24(uuid, jsonb, integer, integer, numeric, numeric, text, uuid)
  to authenticated;
grant execute on function public.cancelar_orden_produccion_v24(uuid, text, boolean, uuid)
  to authenticated;

revoke execute on function public.validar_tipo_componente_formula_v24()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
