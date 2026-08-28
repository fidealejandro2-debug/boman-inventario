-- ============================================================
-- BOMAN INVENTARIO - Integridad de stock y reversiones v20
-- Separa anulacion fiscal, devolucion fisica y reversion tecnica;
-- aplica capacidades multiempresa y crea kardex de cuarentena.
-- Ejecutar una sola vez DESPUES de v19.
-- Ejecutar sin otra migracion/verificacion abierta y, de ser posible, fuera
-- del horario de cargas XML, recepciones y movimientos de inventario.
-- ============================================================

-- IMPORTANTE: PostgreSQL puede exigir confirmar los nuevos valores enum antes
-- de usarlos. Si informa "unsafe use of new value", ejecuta primero solamente
-- estas cinco sentencias y luego vuelve a ejecutar el archivo completo.
alter type public.tipo_movimiento add value if not exists 'devolucion_venta';
alter type public.tipo_movimiento add value if not exists 'venta_xml_reversa';
alter type public.tipo_movimiento add value if not exists 'transferencia_retorno';
alter type public.tipo_movimiento add value if not exists 'cuarentena_liberacion';
alter type public.tipo_movimiento add value if not exists 'movimiento_manual_reversa';

-- Orden preventivo de bloqueos para instalaciones con usuarios conectados.
-- Las operaciones normales escriben primero factura/cuarentena y despues el
-- kardex. Tomar los bloqueos DDL en ese mismo orden evita el ciclo que puede
-- producir un deadlock durante la migracion.
alter table public.documentos_venta_xml
  add column if not exists anulacion_stock_estado text not null default 'sin_anulacion',
  add column if not exists ultima_devolucion_at timestamptz;
alter table public.inventario_cuarentena
  add column if not exists updated_at timestamptz not null default now();

-- ------------------------------------------------------------
-- 1. Capacidades efectivas por empresa y almacen
-- ------------------------------------------------------------
create or replace function public.usuario_puede_capacidad_empresa(
  p_empresa_id uuid,
  p_almacen_id uuid,
  p_capacidad text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_empresa_id is not null
    and p_almacen_id is not null
    and p_capacidad in ('ventas', 'compras', 'custodia')
    and public.usuario_puede_empresa(p_empresa_id, true)
    and public.usuario_puede_almacen(p_almacen_id, true)
    and exists (
      select 1
      from public.empresa_almacenes ea
      join public.empresas e on e.id = ea.empresa_id and e.activo
      join public.almacenes a on a.id = ea.almacen_id and a.activo
      where ea.empresa_id = p_empresa_id
        and ea.almacen_id = p_almacen_id
        and ea.custodia_inventario
        and case p_capacidad
          when 'ventas' then ea.permite_ventas
          when 'compras' then ea.permite_compras
          else true
        end
    );
$$;

-- Corrige el clasificador de v18: una empresa indicada expresamente por el
-- documento prevalece sobre la operadora predeterminada del almacen.
create or replace function public.clasificar_contexto_empresa()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa_id uuid;
  v_almacen_id uuid;
begin
  if tg_table_name = 'documentos_venta_xml' then
    if new.empresa_id is null then
      select ef.empresa_id into v_empresa_id
      from public.emisores_facturacion ef
      join public.empresas e on e.id = ef.empresa_id and e.activo
      where ef.ruc = new.emisor_ruc and ef.activo;
      new.empresa_id := v_empresa_id;
    end if;
    return new;
  end if;

  if tg_table_name = 'documentos_inventario' then
    if new.empresa_responsable_id is null then
      v_almacen_id := coalesce(new.destino_id, new.origen_id);
      select ea.empresa_id into v_empresa_id
      from public.empresa_almacenes ea
      join public.empresas e on e.id = ea.empresa_id and e.activo
      where ea.almacen_id = v_almacen_id and ea.es_operadora_principal;
      new.empresa_responsable_id := v_empresa_id;
    end if;
    return new;
  end if;

  if tg_table_name = 'movimientos' then
    if new.empresa_id is not null then return new; end if;
    if new.grupo_id is not null then
      select d.empresa_id into v_empresa_id
      from public.documentos_venta_xml d where d.id = new.grupo_id;
      if v_empresa_id is null then
        select d.empresa_responsable_id into v_empresa_id
        from public.documentos_inventario d where d.id = new.grupo_id;
      end if;
    end if;
    if v_empresa_id is null then
      select ea.empresa_id into v_empresa_id
      from public.empresa_almacenes ea
      join public.empresas e on e.id = ea.empresa_id and e.activo
      where ea.almacen_id = new.entidad_id and ea.es_operadora_principal;
    end if;
    new.empresa_id := v_empresa_id;
    return new;
  end if;
  return new;
end;
$$;

create or replace function public.validar_capacidad_movimiento_v20()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- La reclasificacion historica atribuye registros ya ejecutados; no intenta
  -- autorizar retroactivamente una operacion nueva.
  if current_setting('boman.reclasificando_multiempresa', true) = '1' then
    return new;
  end if;
  -- La clasificacion de v18 se ejecuta antes por orden alfabetico del trigger.
  -- Un movimiento sin empresa queda pendiente y no se le inventa titularidad.
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
    'salida', 'ajuste', 'cuarentena_liberacion', 'movimiento_manual_reversa'
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
      where ea.almacen_id = new.entidad_destino_id
        and ea.custodia_inventario
    ) then
      raise exception 'El otro almacen de la transferencia no tiene una empresa custodio habilitada';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validar_capacidad_movimiento_v20 on public.movimientos;
create trigger trg_validar_capacidad_movimiento_v20
before insert or update of empresa_id, entidad_id, entidad_destino_id, tipo
on public.movimientos
for each row execute function public.validar_capacidad_movimiento_v20();

-- Corrige la clasificacion historica de v16 sin reescribir su RPC completa.
create or replace function public.clasificar_retorno_incidencia_v20()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.tipo::text = 'transferencia_recibo'
     and new.nota like 'Retorno confirmado de incidencia %' then
    new.tipo := 'transferencia_retorno'::public.tipo_movimiento;
  elsif new.tipo::text = 'entrada'
        and new.nota like 'Regularizacion incidencia %' then
    new.tipo := 'cuarentena_liberacion'::public.tipo_movimiento;
  elsif new.tipo::text = 'entrada'
        and new.nota like 'Regularización incidencia %' then
    new.tipo := 'cuarentena_liberacion'::public.tipo_movimiento;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_clasificar_retorno_incidencia_v20 on public.movimientos;
create trigger trg_clasificar_retorno_incidencia_v20
before insert on public.movimientos
for each row execute function public.clasificar_retorno_incidencia_v20();

-- ------------------------------------------------------------
-- 1.1 Administracion de tiendas/bodegas y clasificacion historica
-- ------------------------------------------------------------

-- Este bloqueo se toma despues de movimientos porque las funciones de v18
-- actualizan el kardex antes de escribir su evento de configuracion. Mantener
-- el mismo orden evita cruzarse con una edicion de empresa en curso.
alter table public.configuracion_multiempresa_eventos
  drop constraint if exists configuracion_multiempresa_eventos_tipo_check;
alter table public.configuracion_multiempresa_eventos
  add constraint configuracion_multiempresa_eventos_tipo_check check (tipo in (
    'empresa_creada', 'empresa_actualizada', 'almacenes_asignados',
    'usuarios_asignados', 'clasificacion_automatica',
    'establecimientos_asignados', 'almacen_guardado',
    'pendientes_reclasificados'
  ));

create or replace function public.admin_reclasificar_pendientes_multiempresa()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_documentos integer;
  v_movimientos integer;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede reclasificar historicos';
  end if;
  perform set_config('boman.reclasificando_multiempresa', '1', true);

  update public.documentos_inventario d
  set empresa_responsable_id = ea.empresa_id
  from public.empresa_almacenes ea
  where d.empresa_responsable_id is null
    and ea.es_operadora_principal
    -- Mantiene la regla instalada en v18: en documentos con destino, la
    -- operadora del destino asume la responsabilidad operativa automatica.
    and ea.almacen_id = coalesce(d.destino_id, d.origen_id);
  get diagnostics v_documentos = row_count;

  update public.movimientos m
  set empresa_id = ea.empresa_id
  from public.empresa_almacenes ea
  where m.empresa_id is null
    and ea.es_operadora_principal
    and ea.almacen_id = m.entidad_id;
  get diagnostics v_movimientos = row_count;

  insert into public.configuracion_multiempresa_eventos(tipo, detalle, usuario_id)
  values (
    'pendientes_reclasificados',
    jsonb_build_object('documentos', v_documentos, 'movimientos', v_movimientos),
    auth.uid()
  );
  return jsonb_build_object(
    'documentos', v_documentos,
    'movimientos', v_movimientos,
    'mensaje', 'Pendientes historicos reclasificados'
  );
end;
$$;

create or replace function public.admin_guardar_almacen_v20(
  p_almacen_id uuid,
  p_nombre text,
  p_codigo text,
  p_tipo text,
  p_activo boolean,
  p_empresa_operadora_id uuid,
  p_permite_ventas boolean default true,
  p_permite_compras boolean default true,
  p_custodia_inventario boolean default true
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_antes jsonb;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede crear o editar tiendas y bodegas';
  end if;
  if btrim(coalesce(p_nombre, '')) = '' then raise exception 'El nombre es obligatorio'; end if;
  if upper(btrim(coalesce(p_codigo, ''))) !~ '^[A-Z0-9][A-Z0-9-]{1,39}$' then
    raise exception 'El codigo debe usar entre 2 y 40 letras, numeros o guiones';
  end if;
  if p_tipo not in ('bodega', 'tienda') then raise exception 'El tipo de almacen no es valido'; end if;
  if not exists (
    select 1 from public.empresas where id = p_empresa_operadora_id and activo
  ) then raise exception 'Selecciona una empresa operadora activa'; end if;

  if p_almacen_id is null then
    insert into public.almacenes(nombre, codigo, tipo, activo)
    values (
      btrim(p_nombre), upper(btrim(p_codigo)), p_tipo, coalesce(p_activo, true)
    ) returning id into v_id;
  else
    select to_jsonb(a) into v_antes
    from public.almacenes a where a.id = p_almacen_id for update;
    if not found then raise exception 'La tienda o bodega no existe'; end if;
    if not coalesce(p_activo, true) and exists (
      select 1 from public.inventario i
      where i.entidad_id = p_almacen_id and i.cantidad > 0
      union all
      select 1 from public.inventario_cuarentena q
      where q.almacen_id = p_almacen_id and q.cantidad > 0
      union all
      select 1 from public.documentos_inventario d
      where (d.origen_id = p_almacen_id or d.destino_id = p_almacen_id)
        and d.estado not in (
          'rechazado', 'recibido', 'cerrado_con_diferencia', 'aplicado', 'anulado'
        )
    ) then
      raise exception 'No puedes desactivar: existen saldos o documentos abiertos en esta ubicacion';
    end if;
    update public.almacenes
    set nombre = btrim(p_nombre), codigo = upper(btrim(p_codigo)),
        tipo = p_tipo, activo = coalesce(p_activo, true)
    where id = p_almacen_id
    returning id into v_id;
  end if;

  -- La seleccion explicita reemplaza a la operadora principal anterior; los
  -- demas vinculos se conservan como relaciones compartidas.
  update public.empresa_almacenes
  set es_operadora_principal = false, actualizado_por = auth.uid(), updated_at = now()
  where almacen_id = v_id and empresa_id <> p_empresa_operadora_id
    and es_operadora_principal;

  insert into public.empresa_almacenes as ea(
    empresa_id, almacen_id, es_operadora_principal,
    permite_ventas, permite_compras, custodia_inventario, actualizado_por
  ) values (
    p_empresa_operadora_id, v_id, true,
    coalesce(p_permite_ventas, true), coalesce(p_permite_compras, true),
    coalesce(p_custodia_inventario, true), auth.uid()
  )
  on conflict (empresa_id, almacen_id) do update
  set es_operadora_principal = true,
      permite_ventas = excluded.permite_ventas,
      permite_compras = excluded.permite_compras,
      custodia_inventario = excluded.custodia_inventario,
      actualizado_por = auth.uid(), updated_at = now();

  insert into public.configuracion_multiempresa_eventos(
    tipo, empresa_id, detalle, usuario_id
  ) values (
    'almacen_guardado', p_empresa_operadora_id,
    jsonb_build_object(
      'antes', v_antes,
      'despues', (select to_jsonb(a) from public.almacenes a where a.id = v_id)
    ), auth.uid()
  );
  perform public.admin_reclasificar_pendientes_multiempresa();
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 2. Metadatos de saldo e idempotencia para nuevos movimientos
-- ------------------------------------------------------------
alter table public.movimientos
  add column if not exists saldo_anterior integer,
  add column if not exists saldo_posterior integer,
  add column if not exists movimiento_reversa_id uuid references public.movimientos(id),
  add column if not exists idempotency_key uuid,
  add column if not exists documento_tipo text;

create unique index if not exists uq_movimientos_idempotency_key
  on public.movimientos(idempotency_key)
  where idempotency_key is not null;
create index if not exists idx_movimientos_reversa
  on public.movimientos(movimiento_reversa_id)
  where movimiento_reversa_id is not null;

-- Punto unico para los nuevos cambios de stock. Las migraciones siguientes
-- trasladaran aqui los RPC historicos de forma gradual y verificable.
create or replace function public.aplicar_movimiento_stock_v20(
  p_producto_id uuid,
  p_almacen_id uuid,
  p_empresa_id uuid,
  p_tipo public.tipo_movimiento,
  p_delta integer,
  p_documento_id uuid,
  p_documento_tipo text,
  p_nota text,
  p_entidad_destino_id uuid default null,
  p_movimiento_reversa_id uuid default null,
  p_idempotency_key uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_movimiento_id uuid;
  v_anterior integer;
  v_posterior integer;
begin
  if p_delta = 0 then raise exception 'El movimiento de stock no puede ser cero'; end if;
  if p_producto_id is null or p_almacen_id is null or p_empresa_id is null then
    raise exception 'El movimiento requiere producto, almacen y empresa';
  end if;
  if btrim(coalesce(p_documento_tipo, '')) = '' or p_documento_id is null then
    raise exception 'El movimiento requiere un documento de origen';
  end if;

  if p_idempotency_key is not null then
    select id, saldo_anterior, saldo_posterior
    into v_movimiento_id, v_anterior, v_posterior
    from public.movimientos where idempotency_key = p_idempotency_key;
    if found then
      return jsonb_build_object(
        'movimiento_id', v_movimiento_id, 'saldo_anterior', v_anterior,
        'saldo_posterior', v_posterior, 'duplicado', true
      );
    end if;
  end if;
  if public.conteo_abierto_producto(p_almacen_id, p_producto_id) then
    raise exception 'Hay un conteo abierto para el producto en el almacen';
  end if;

  insert into public.inventario(producto_id, entidad_id, cantidad)
  values (p_producto_id, p_almacen_id, 0)
  on conflict (producto_id, entidad_id) do nothing;
  select cantidad into v_anterior
  from public.inventario
  where producto_id = p_producto_id and entidad_id = p_almacen_id
  for update;
  v_posterior := v_anterior + p_delta;
  if v_posterior < 0 then raise exception 'Stock insuficiente para aplicar el movimiento'; end if;

  update public.inventario
  set cantidad = v_posterior, updated_at = now()
  where producto_id = p_producto_id and entidad_id = p_almacen_id;

  insert into public.movimientos (
    producto_id, entidad_id, entidad_destino_id, tipo, cantidad,
    cantidad_anterior, saldo_anterior, saldo_posterior,
    movimiento_reversa_id, nota, usuario_id, grupo_id, empresa_id,
    documento_tipo, idempotency_key
  ) values (
    p_producto_id, p_almacen_id, p_entidad_destino_id, p_tipo, abs(p_delta),
    v_anterior, v_anterior, v_posterior,
    p_movimiento_reversa_id, nullif(btrim(p_nota), ''), auth.uid(),
    p_documento_id, p_empresa_id, btrim(p_documento_tipo), p_idempotency_key
  ) returning id into v_movimiento_id;

  return jsonb_build_object(
    'movimiento_id', v_movimiento_id, 'saldo_anterior', v_anterior,
    'saldo_posterior', v_posterior, 'duplicado', false
  );
end;
$$;

-- ------------------------------------------------------------
-- 3. Kardex completo de cuarentena
-- ------------------------------------------------------------
create table if not exists public.inventario_cuarentena_movimientos (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references public.productos(id),
  almacen_id uuid not null references public.almacenes(id),
  direccion text not null check (direccion in ('entrada', 'salida')),
  tipo text not null,
  cantidad integer not null check (cantidad > 0),
  saldo_anterior integer not null check (saldo_anterior >= 0),
  saldo_posterior integer not null check (saldo_posterior >= 0),
  documento_tipo text,
  documento_id uuid,
  detalle text,
  usuario_id uuid references public.perfiles(id),
  idempotency_key uuid unique,
  created_at timestamptz not null default now(),
  check (
    (direccion = 'entrada' and saldo_posterior = saldo_anterior + cantidad)
    or (direccion = 'salida' and saldo_posterior = saldo_anterior - cantidad)
  )
);

create index if not exists idx_cuarentena_movimientos_producto_fecha
  on public.inventario_cuarentena_movimientos(producto_id, almacen_id, created_at desc);
create index if not exists idx_cuarentena_movimientos_documento
  on public.inventario_cuarentena_movimientos(documento_tipo, documento_id);

-- Saldo inicial para instalaciones que ya tenian cuarentena antes de v20.
insert into public.inventario_cuarentena_movimientos (
  producto_id, almacen_id, direccion, tipo, cantidad,
  saldo_anterior, saldo_posterior, detalle, idempotency_key
)
select q.producto_id, q.almacen_id, 'entrada', 'saldo_inicial_v20', q.cantidad,
       0, q.cantidad, 'Saldo existente al instalar v20',
       md5('v20-cuarentena-' || q.producto_id::text || '-' || q.almacen_id::text)::uuid
from public.inventario_cuarentena q
where q.cantidad > 0
on conflict (idempotency_key) do nothing;

create or replace function public.auditar_saldo_cuarentena_v20()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anterior integer := case when tg_op = 'INSERT' then 0 else old.cantidad end;
  v_posterior integer := new.cantidad;
  v_delta integer;
  v_tipo text;
  v_documento_tipo text;
  v_documento_id uuid;
  v_detalle text;
begin
  v_delta := v_posterior - v_anterior;
  if v_delta = 0 then return new; end if;

  v_tipo := coalesce(nullif(current_setting('boman.cuarentena_tipo', true), ''),
                     'actualizacion_sistema');
  v_documento_tipo := nullif(current_setting('boman.cuarentena_documento_tipo', true), '');
  begin
    v_documento_id := nullif(current_setting('boman.cuarentena_documento_id', true), '')::uuid;
  exception when invalid_text_representation then
    v_documento_id := null;
  end;
  v_detalle := nullif(current_setting('boman.cuarentena_detalle', true), '');

  insert into public.inventario_cuarentena_movimientos (
    producto_id, almacen_id, direccion, tipo, cantidad,
    saldo_anterior, saldo_posterior, documento_tipo, documento_id,
    detalle, usuario_id
  ) values (
    new.producto_id, new.almacen_id,
    case when v_delta > 0 then 'entrada' else 'salida' end,
    v_tipo, abs(v_delta), v_anterior, v_posterior,
    v_documento_tipo, v_documento_id, v_detalle, auth.uid()
  );
  return new;
end;
$$;

drop trigger if exists trg_auditar_saldo_cuarentena_v20
  on public.inventario_cuarentena;
create trigger trg_auditar_saldo_cuarentena_v20
after insert or update of cantidad on public.inventario_cuarentena
for each row execute function public.auditar_saldo_cuarentena_v20();

alter table public.inventario_cuarentena_movimientos enable row level security;
drop policy if exists "leer_cuarentena_movimientos_v20"
  on public.inventario_cuarentena_movimientos;
create policy "leer_cuarentena_movimientos_v20"
on public.inventario_cuarentena_movimientos for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
);

-- ------------------------------------------------------------
-- 4. Devoluciones fisicas de ventas XML
-- ------------------------------------------------------------
create sequence if not exists public.seq_devolucion_venta_xml;

create table if not exists public.devoluciones_venta_xml (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  documento_venta_id uuid not null references public.documentos_venta_xml(id),
  empresa_id uuid not null references public.empresas(id),
  almacen_id uuid not null references public.almacenes(id),
  estado text not null default 'aplicada' check (estado in ('aplicada', 'anulada')),
  motivo text not null check (btrim(motivo) <> ''),
  idempotency_key uuid not null unique,
  creado_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now(),
  anulada_por uuid references public.perfiles(id),
  anulada_at timestamptz,
  motivo_anulacion text
);

create table if not exists public.devolucion_venta_xml_lineas (
  id uuid primary key default gen_random_uuid(),
  devolucion_id uuid not null references public.devoluciones_venta_xml(id) on delete restrict,
  producto_id uuid not null references public.productos(id),
  cantidad integer not null check (cantidad > 0),
  destino_estado text not null check (destino_estado in ('disponible', 'cuarentena')),
  saldo_anterior integer not null check (saldo_anterior >= 0),
  saldo_posterior integer not null check (saldo_posterior >= 0),
  unique (devolucion_id, producto_id, destino_estado)
);

create index if not exists idx_devoluciones_venta_documento_fecha
  on public.devoluciones_venta_xml(documento_venta_id, created_at desc);
create index if not exists idx_devolucion_venta_lineas_producto
  on public.devolucion_venta_xml_lineas(producto_id, devolucion_id);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'documentos_venta_xml_anulacion_stock_estado_check'
      and conrelid = 'public.documentos_venta_xml'::regclass
  ) then
    alter table public.documentos_venta_xml
      add constraint documentos_venta_xml_anulacion_stock_estado_check check (
        anulacion_stock_estado in (
          'sin_anulacion', 'sin_retorno', 'devuelto_parcial',
          'devuelto_total', 'reversion_tecnica', 'reversion_tecnica_legacy'
        )
      );
  end if;
end;
$$;

-- Reconoce anulaciones ejecutadas con v14: esas si reintegraron stock.
update public.documentos_venta_xml d
set anulacion_stock_estado = 'reversion_tecnica_legacy'
where d.anulado and d.anulacion_stock_estado = 'sin_anulacion'
  and exists (
    select 1 from public.movimientos m
    where m.grupo_id = d.id and m.tipo::text = 'venta_xml' and m.anulado
  );

create or replace function public.puede_ver_devolucion_venta_xml(
  p_devolucion_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.devoluciones_venta_xml d
    where d.id = p_devolucion_id
      and public.usuario_puede_empresa(d.empresa_id, false)
      and public.usuario_puede_almacen(d.almacen_id, false)
  );
$$;

alter table public.devoluciones_venta_xml enable row level security;
alter table public.devolucion_venta_xml_lineas enable row level security;

drop policy if exists "leer_devoluciones_venta_xml" on public.devoluciones_venta_xml;
create policy "leer_devoluciones_venta_xml"
on public.devoluciones_venta_xml for select to authenticated using (
  public.usuario_puede_empresa(empresa_id, false)
  and public.usuario_puede_almacen(almacen_id, false)
);

drop policy if exists "leer_devolucion_venta_xml_lineas"
  on public.devolucion_venta_xml_lineas;
create policy "leer_devolucion_venta_xml_lineas"
on public.devolucion_venta_xml_lineas for select to authenticated using (
  public.puede_ver_devolucion_venta_xml(devolucion_id)
);

create or replace function public.consultar_saldo_devolucion_venta_xml(
  p_documento_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d public.documentos_venta_xml%rowtype;
  v_lineas jsonb;
begin
  select * into d from public.documentos_venta_xml where id = p_documento_id;
  if not found then raise exception 'La factura XML no existe'; end if;
  if not public.usuario_puede_almacen(d.almacen_id, false) then
    raise exception 'No tienes acceso a la factura';
  end if;
  if d.anulacion_stock_estado in ('reversion_tecnica', 'reversion_tecnica_legacy') then
    raise exception 'La importacion fue revertida tecnicamente y no admite devoluciones';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'producto_id', s.producto_id,
    'sku', p.sku,
    'producto', p.nombre,
    'vendido', s.vendido,
    'devuelto', coalesce(r.devuelto, 0),
    'pendiente', greatest(s.vendido - coalesce(r.devuelto, 0), 0)
  ) order by p.sku), '[]'::jsonb)
  into v_lineas
  from (
    select a.producto_id, sum(a.cantidad)::integer vendido
    from public.documento_venta_xml_lineas l
    join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
    where l.documento_id = d.id and l.afecta_inventario
    group by a.producto_id
  ) s
  join public.productos p on p.id = s.producto_id
  left join lateral (
    select sum(dl.cantidad)::integer devuelto
    from public.devolucion_venta_xml_lineas dl
    join public.devoluciones_venta_xml dv on dv.id = dl.devolucion_id
    where dv.documento_venta_id = d.id and dv.estado = 'aplicada'
      and dl.producto_id = s.producto_id
  ) r on true;

  return jsonb_build_object(
    'documento_id', d.id,
    'numero_documento', d.numero_documento,
    'almacen_id', d.almacen_id,
    'lineas', v_lineas
  );
end;
$$;

create or replace function public.registrar_devolucion_venta_xml(
  p_documento_id uuid,
  p_items jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_venta_xml%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_devolucion_id uuid;
  v_numero text;
  it record;
  v_vendido integer;
  v_devuelto integer;
  v_anterior integer;
  v_posterior integer;
  v_total integer := 0;
  v_total_devuelto integer;
  v_movimiento jsonb;
begin
  if v_rol not in ('admin', 'control', 'tienda', 'bodega') then
    raise exception 'No tienes permiso para registrar devoluciones de venta';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'El motivo de la devolucion es obligatorio'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La devolucion debe contener productos';
  end if;

  select id into v_devolucion_id
  from public.devoluciones_venta_xml where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_devolucion_id, 'duplicado', true,
      'mensaje', 'La devolucion ya estaba aplicada');
  end if;

  select * into d from public.documentos_venta_xml
  where id = p_documento_id for update;
  if not found then raise exception 'La factura XML no existe'; end if;
  if d.empresa_id is null then raise exception 'La factura no tiene empresa responsable'; end if;
  if d.anulacion_stock_estado in ('reversion_tecnica', 'reversion_tecnica_legacy') then
    raise exception 'La importacion fue revertida tecnicamente';
  end if;
  if not public.usuario_puede_capacidad_empresa(d.empresa_id, d.almacen_id, 'ventas') then
    raise exception 'No tienes ventas y custodia habilitadas para esta empresa y almacen';
  end if;
  if exists (
    select producto_id, destino_estado
    from jsonb_to_recordset(p_items) x(
      producto_id uuid, cantidad integer, destino_estado text
    )
    group by producto_id, destino_estado having count(*) > 1
  ) then raise exception 'La devolucion contiene lineas repetidas'; end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(
      producto_id uuid, cantidad integer, destino_estado text
    )
    where x.producto_id is null or coalesce(x.cantidad, 0) <= 0
      or x.destino_estado not in ('disponible', 'cuarentena')
  ) then raise exception 'La devolucion contiene una linea invalida'; end if;

  -- Valida el total por producto antes de aplicar cualquier saldo. Un mismo
  -- producto puede dividirse entre disponible y cuarentena, pero la suma de
  -- ambos destinos nunca puede superar lo vendido menos devoluciones previas.
  if exists (
    select 1
    from (
      select x.producto_id, sum(x.cantidad)::integer cantidad
      from jsonb_to_recordset(p_items) x(
        producto_id uuid, cantidad integer, destino_estado text
      )
      group by x.producto_id
    ) nueva
    left join lateral (
      select coalesce(sum(a.cantidad), 0)::integer vendido
      from public.documento_venta_xml_lineas l
      join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
      where l.documento_id = d.id and l.afecta_inventario
        and a.producto_id = nueva.producto_id
    ) venta on true
    left join lateral (
      select coalesce(sum(dl.cantidad), 0)::integer devuelto
      from public.devolucion_venta_xml_lineas dl
      join public.devoluciones_venta_xml dv on dv.id = dl.devolucion_id
      where dv.documento_venta_id = d.id and dv.estado = 'aplicada'
        and dl.producto_id = nueva.producto_id
    ) anterior on true
    where venta.vendido = 0
       or anterior.devuelto + nueva.cantidad > venta.vendido
  ) then
    raise exception 'La devolucion supera el saldo pendiente de uno de los productos';
  end if;

  v_numero := 'DV-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY')
    || '-' || lpad(nextval('public.seq_devolucion_venta_xml')::text, 6, '0');
  insert into public.devoluciones_venta_xml (
    numero, documento_venta_id, empresa_id, almacen_id, motivo,
    idempotency_key, creado_por
  ) values (
    v_numero, d.id, d.empresa_id, d.almacen_id, btrim(p_motivo),
    p_idempotency_key, auth.uid()
  ) returning id into v_devolucion_id;

  for it in
    select producto_id, destino_estado, sum(cantidad)::integer cantidad
    from jsonb_to_recordset(p_items) x(
      producto_id uuid, cantidad integer, destino_estado text
    )
    group by producto_id, destino_estado
    order by producto_id, destino_estado
  loop
    select coalesce(sum(a.cantidad), 0)::integer into v_vendido
    from public.documento_venta_xml_lineas l
    join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
    where l.documento_id = d.id and l.afecta_inventario
      and a.producto_id = it.producto_id;

    select coalesce(sum(dl.cantidad), 0)::integer into v_devuelto
    from public.devolucion_venta_xml_lineas dl
    join public.devoluciones_venta_xml dv on dv.id = dl.devolucion_id
    where dv.documento_venta_id = d.id and dv.estado = 'aplicada'
      and dl.producto_id = it.producto_id;

    if v_vendido = 0 or v_devuelto + it.cantidad > v_vendido then
      raise exception 'La cantidad devuelta supera lo vendido para uno de los productos';
    end if;
    if public.conteo_abierto_producto(d.almacen_id, it.producto_id) then
      raise exception 'Hay un conteo abierto para uno de los productos devueltos';
    end if;

    if it.destino_estado = 'disponible' then
      v_movimiento := public.aplicar_movimiento_stock_v20(
        it.producto_id, d.almacen_id, d.empresa_id,
        'devolucion_venta'::public.tipo_movimiento, it.cantidad,
        v_devolucion_id, 'devolucion_venta_xml',
        'Devolucion ' || v_numero || ' de factura ' || d.numero_documento
          || ' - ' || btrim(p_motivo),
        null, null, null
      );
      v_anterior := (v_movimiento->>'saldo_anterior')::integer;
      v_posterior := (v_movimiento->>'saldo_posterior')::integer;
    else
      perform set_config('boman.cuarentena_tipo', 'devolucion_venta', true);
      perform set_config('boman.cuarentena_documento_tipo', 'devolucion_venta_xml', true);
      perform set_config('boman.cuarentena_documento_id', v_devolucion_id::text, true);
      perform set_config('boman.cuarentena_detalle', btrim(p_motivo), true);

      insert into public.inventario_cuarentena as q(producto_id, almacen_id, cantidad)
      values (it.producto_id, d.almacen_id, it.cantidad)
      on conflict (producto_id, almacen_id) do update
      set cantidad = q.cantidad + excluded.cantidad, updated_at = now();
      select cantidad - it.cantidad, cantidad into v_anterior, v_posterior
      from public.inventario_cuarentena
      where producto_id = it.producto_id and almacen_id = d.almacen_id;
    end if;

    insert into public.devolucion_venta_xml_lineas (
      devolucion_id, producto_id, cantidad, destino_estado,
      saldo_anterior, saldo_posterior
    ) values (
      v_devolucion_id, it.producto_id, it.cantidad, it.destino_estado,
      v_anterior, v_posterior
    );
    v_total := v_total + it.cantidad;
  end loop;

  select coalesce(sum(dl.cantidad), 0)::integer into v_total_devuelto
  from public.devolucion_venta_xml_lineas dl
  join public.devoluciones_venta_xml dv on dv.id = dl.devolucion_id
  where dv.documento_venta_id = d.id and dv.estado = 'aplicada';

  update public.documentos_venta_xml
  set ultima_devolucion_at = now(),
      anulacion_stock_estado = case
        when v_total_devuelto >= unidades_inventario then 'devuelto_total'
        else 'devuelto_parcial'
      end
  where id = d.id;

  return jsonb_build_object(
    'id', v_devolucion_id, 'numero', v_numero, 'duplicado', false,
    'unidades', v_total,
    'mensaje', 'Devolucion fisica aplicada correctamente'
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Anulacion fiscal sin stock y reversion tecnica controlada
-- ------------------------------------------------------------
create table if not exists public.reversiones_tecnicas_venta_xml (
  id uuid primary key default gen_random_uuid(),
  documento_venta_id uuid not null unique references public.documentos_venta_xml(id),
  motivo text not null check (btrim(motivo) <> ''),
  idempotency_key uuid not null unique,
  realizado_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now()
);

alter table public.reversiones_tecnicas_venta_xml enable row level security;
drop policy if exists "leer_reversiones_tecnicas_venta_xml"
  on public.reversiones_tecnicas_venta_xml;
create policy "leer_reversiones_tecnicas_venta_xml"
on public.reversiones_tecnicas_venta_xml for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);

-- Anulacion compensatoria: conserva el movimiento original y crea su reversa.
-- Administracion y Control pueden usarla solo en entradas, salidas o ajustes
-- manuales; los documentos operativos se corrigen desde su propio flujo.
create or replace function public.control_anular_movimiento(
  p_movimiento_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.movimientos%rowtype;
  v_empresa_id uuid;
  v_delta_original integer;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden anular movimientos manuales';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'Debes indicar el motivo de la anulacion';
  end if;
  select * into m from public.movimientos where id = p_movimiento_id for update;
  if not found then raise exception 'El movimiento no existe'; end if;
  if m.anulado then raise exception 'El movimiento ya fue anulado'; end if;
  if m.tipo::text not in ('entrada', 'salida', 'ajuste') then
    raise exception 'Este movimiento se corrige desde su documento de origen';
  end if;
  if exists (select 1 from public.documentos_inventario d where d.id = m.grupo_id)
     or exists (select 1 from public.documentos_venta_xml d where d.id = m.grupo_id)
     or exists (select 1 from public.devoluciones_venta_xml d where d.id = m.grupo_id)
     or exists (select 1 from public.reversiones_tecnicas_venta_xml d where d.id = m.grupo_id) then
    raise exception 'Este movimiento pertenece a un documento y debe corregirse desde ese flujo';
  end if;

  v_empresa_id := m.empresa_id;
  if v_empresa_id is null then
    select ea.empresa_id into v_empresa_id
    from public.empresa_almacenes ea
    where ea.almacen_id = m.entidad_id and ea.es_operadora_principal;
  end if;
  if v_empresa_id is null then
    raise exception 'Asigna primero una empresa operadora principal al almacen';
  end if;

  v_delta_original := case m.tipo::text
    when 'entrada' then m.cantidad
    when 'salida' then -m.cantidad
    when 'ajuste' then m.cantidad - coalesce(m.cantidad_anterior, m.cantidad)
  end;
  if v_delta_original = 0 then
    raise exception 'El movimiento no produjo una variacion reversible';
  end if;

  perform public.aplicar_movimiento_stock_v20(
    m.producto_id, m.entidad_id, v_empresa_id,
    'movimiento_manual_reversa'::public.tipo_movimiento,
    -v_delta_original, m.id, 'movimiento_manual',
    'Reversa de movimiento manual - ' || btrim(p_motivo),
    m.entidad_destino_id, m.id, null
  );

  update public.movimientos
  set anulado = true, anulado_por = auth.uid(), anulado_at = now(),
      motivo_anulacion = btrim(p_motivo)
  where id = m.id;
end;
$$;

create or replace function public.admin_anular_factura_venta_xml(
  p_documento_id uuid,
  p_motivo text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_venta_xml%rowtype;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede registrar la anulacion fiscal';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'Debes indicar el motivo de la anulacion fiscal';
  end if;
  select * into d from public.documentos_venta_xml
  where id = p_documento_id for update;
  if not found then raise exception 'La factura XML no existe'; end if;
  if d.anulado then raise exception 'La factura XML ya fue anulada'; end if;
  update public.documentos_venta_xml
  set anulado = true,
      motivo_anulacion = btrim(p_motivo),
      anulado_por = auth.uid(),
      anulado_at = now(),
      anulacion_stock_estado = case
        when anulacion_stock_estado in ('devuelto_parcial', 'devuelto_total')
          then anulacion_stock_estado
        else 'sin_retorno'
      end
  where id = d.id;

  return jsonb_build_object(
    'id', d.id,
    'numero_documento', d.numero_documento,
    'unidades_reintegradas', 0,
    'requiere_devolucion', d.unidades_inventario > 0,
    'mensaje', 'Anulacion fiscal registrada. El stock no cambio; registra una devolucion fisica si la mercaderia regreso.'
  );
end;
$$;

create or replace function public.admin_revertir_importacion_venta_xml(
  p_documento_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_venta_xml%rowtype;
  v_reversion_id uuid;
  it record;
  v_total integer := 0;
  v_movimiento_original uuid;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede revertir una importacion XML';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'El motivo tecnico es obligatorio'; end if;

  select id into v_reversion_id
  from public.reversiones_tecnicas_venta_xml where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_reversion_id, 'duplicado', true,
      'mensaje', 'La reversion tecnica ya estaba aplicada');
  end if;

  select * into d from public.documentos_venta_xml
  where id = p_documento_id for update;
  if not found then raise exception 'La factura XML no existe'; end if;
  if d.anulacion_stock_estado in ('reversion_tecnica', 'reversion_tecnica_legacy') then
    raise exception 'La importacion ya fue revertida';
  end if;
  if exists (
    select 1 from public.devoluciones_venta_xml dv
    where dv.documento_venta_id = d.id and dv.estado = 'aplicada'
  ) then raise exception 'La factura tiene devoluciones fisicas; no puede revertirse tecnicamente'; end if;

  if exists (
    select 1
    from (
      select distinct a.producto_id
      from public.documento_venta_xml_lineas l
      join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
      where l.documento_id = d.id and l.afecta_inventario
    ) p
    join public.movimientos m on m.producto_id = p.producto_id
      and m.entidad_id = d.almacen_id
      and m.created_at > d.created_at
      and m.grupo_id is distinct from d.id
      and not coalesce(m.anulado, false)
  ) then
    raise exception 'Existen movimientos posteriores. Usa devolucion fisica o conteo controlado; no reversion tecnica';
  end if;

  insert into public.reversiones_tecnicas_venta_xml (
    documento_venta_id, motivo, idempotency_key, realizado_por
  ) values (d.id, btrim(p_motivo), p_idempotency_key, auth.uid())
  returning id into v_reversion_id;

  for it in
    select a.producto_id, sum(a.cantidad)::integer cantidad
    from public.documento_venta_xml_lineas l
    join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
    where l.documento_id = d.id and l.afecta_inventario
    group by a.producto_id
    order by a.producto_id
  loop
    select id into v_movimiento_original
    from public.movimientos
    where grupo_id = d.id and producto_id = it.producto_id
      and tipo::text = 'venta_xml' and not anulado
    order by created_at limit 1 for update;

    perform public.aplicar_movimiento_stock_v20(
      it.producto_id, d.almacen_id, d.empresa_id,
      'venta_xml_reversa'::public.tipo_movimiento, it.cantidad,
      v_reversion_id, 'reversion_tecnica_venta_xml',
      'Reversion tecnica factura ' || d.numero_documento || ' - ' || btrim(p_motivo),
      null, v_movimiento_original, null
    );
    v_total := v_total + it.cantidad;
  end loop;

  update public.movimientos
  set anulado = true, anulado_por = auth.uid(), anulado_at = now(),
      motivo_anulacion = 'Reversion tecnica: ' || btrim(p_motivo)
  where grupo_id = d.id and tipo::text = 'venta_xml' and not anulado;

  update public.documentos_venta_xml
  set anulacion_stock_estado = 'reversion_tecnica',
      nota = concat_ws(E'\n', nota, 'Reversion tecnica: ' || btrim(p_motivo))
  where id = d.id;

  return jsonb_build_object(
    'id', v_reversion_id, 'duplicado', false, 'unidades_reintegradas', v_total,
    'mensaje', 'Importacion revertida tecnicamente con movimientos compensatorios'
  );
end;
$$;

-- ------------------------------------------------------------
-- 6. Ventas XML v20: exige empresa, ventas y custodia habilitadas
-- ------------------------------------------------------------
create or replace function public.aplicar_factura_venta_xml_v20(
  p_documento jsonb,
  p_almacen_id uuid,
  p_asignaciones jsonb,
  p_nota text default null,
  p_confirmar_codigo_no_estandar boolean default false,
  p_codigo_nota text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa_id uuid;
begin
  select ef.empresa_id into v_empresa_id
  from public.emisores_facturacion ef
  join public.empresas e on e.id = ef.empresa_id and e.activo
  where ef.ruc = nullif(btrim(p_documento->>'emisor_ruc'), '') and ef.activo;
  if v_empresa_id is null then
    raise exception 'Configura primero la empresa y sus establecimientos para este RUC';
  end if;
  if not public.usuario_puede_capacidad_empresa(v_empresa_id, p_almacen_id, 'ventas') then
    raise exception 'No tienes ventas y custodia habilitadas para esta empresa y almacen';
  end if;
  return public.aplicar_factura_venta_xml_v19(
    p_documento, p_almacen_id, p_asignaciones, p_nota,
    p_confirmar_codigo_no_estandar, p_codigo_nota
  );
end;
$$;

-- ------------------------------------------------------------
-- 7. Propiedad, privilegios y recarga de PostgREST
-- ------------------------------------------------------------
alter function public.usuario_puede_capacidad_empresa(uuid, uuid, text) owner to postgres;
alter function public.clasificar_contexto_empresa() owner to postgres;
alter function public.validar_capacidad_movimiento_v20() owner to postgres;
alter function public.clasificar_retorno_incidencia_v20() owner to postgres;
alter function public.admin_reclasificar_pendientes_multiempresa() owner to postgres;
alter function public.admin_guardar_almacen_v20(uuid, text, text, text, boolean, uuid, boolean, boolean, boolean) owner to postgres;
alter function public.aplicar_movimiento_stock_v20(uuid, uuid, uuid, public.tipo_movimiento, integer, uuid, text, text, uuid, uuid, uuid) owner to postgres;
alter function public.auditar_saldo_cuarentena_v20() owner to postgres;
alter function public.puede_ver_devolucion_venta_xml(uuid) owner to postgres;
alter function public.consultar_saldo_devolucion_venta_xml(uuid) owner to postgres;
alter function public.registrar_devolucion_venta_xml(uuid, jsonb, text, uuid) owner to postgres;
alter function public.admin_anular_factura_venta_xml(uuid, text) owner to postgres;
alter function public.admin_revertir_importacion_venta_xml(uuid, text, uuid) owner to postgres;
alter function public.aplicar_factura_venta_xml_v20(jsonb, uuid, jsonb, text, boolean, text) owner to postgres;
alter function public.control_anular_movimiento(uuid, text) owner to postgres;

revoke all on public.inventario_cuarentena_movimientos from public, anon;
revoke all on public.devoluciones_venta_xml from public, anon;
revoke all on public.devolucion_venta_xml_lineas from public, anon;
revoke all on public.reversiones_tecnicas_venta_xml from public, anon;
revoke insert, update, delete on public.inventario_cuarentena_movimientos from authenticated;
revoke insert, update, delete on public.devoluciones_venta_xml from authenticated;
revoke insert, update, delete on public.devolucion_venta_xml_lineas from authenticated;
revoke insert, update, delete on public.reversiones_tecnicas_venta_xml from authenticated;
grant select on public.inventario_cuarentena_movimientos to authenticated;
grant select on public.devoluciones_venta_xml to authenticated;
grant select on public.devolucion_venta_xml_lineas to authenticated;
grant select on public.reversiones_tecnicas_venta_xml to authenticated;

revoke execute on function public.usuario_puede_capacidad_empresa(uuid, uuid, text)
  from public, anon;
revoke execute on function public.admin_reclasificar_pendientes_multiempresa()
  from public, anon;
revoke execute on function public.admin_guardar_almacen_v20(uuid, text, text, text, boolean, uuid, boolean, boolean, boolean)
  from public, anon;
revoke execute on function public.puede_ver_devolucion_venta_xml(uuid)
  from public, anon;
revoke execute on function public.consultar_saldo_devolucion_venta_xml(uuid)
  from public, anon;
revoke execute on function public.registrar_devolucion_venta_xml(uuid, jsonb, text, uuid)
  from public, anon;
revoke execute on function public.admin_anular_factura_venta_xml(uuid, text)
  from public, anon;
revoke execute on function public.admin_revertir_importacion_venta_xml(uuid, text, uuid)
  from public, anon;
revoke execute on function public.aplicar_factura_venta_xml_v20(jsonb, uuid, jsonb, text, boolean, text)
  from public, anon;
revoke execute on function public.control_anular_movimiento(uuid, text)
  from public, anon;
grant execute on function public.usuario_puede_capacidad_empresa(uuid, uuid, text)
  to authenticated;
grant execute on function public.admin_reclasificar_pendientes_multiempresa()
  to authenticated;
grant execute on function public.admin_guardar_almacen_v20(uuid, text, text, text, boolean, uuid, boolean, boolean, boolean)
  to authenticated;
grant execute on function public.puede_ver_devolucion_venta_xml(uuid)
  to authenticated;
grant execute on function public.consultar_saldo_devolucion_venta_xml(uuid)
  to authenticated;
grant execute on function public.registrar_devolucion_venta_xml(uuid, jsonb, text, uuid)
  to authenticated;
grant execute on function public.admin_anular_factura_venta_xml(uuid, text)
  to authenticated;
grant execute on function public.admin_revertir_importacion_venta_xml(uuid, text, uuid)
  to authenticated;
grant execute on function public.aplicar_factura_venta_xml_v20(jsonb, uuid, jsonb, text, boolean, text)
  to authenticated;
grant execute on function public.control_anular_movimiento(uuid, text)
  to authenticated;

revoke execute on function public.validar_capacidad_movimiento_v20()
  from public, anon, authenticated;
revoke execute on function public.clasificar_retorno_incidencia_v20()
  from public, anon, authenticated;
revoke execute on function public.auditar_saldo_cuarentena_v20()
  from public, anon, authenticated;
revoke execute on function public.aplicar_movimiento_stock_v20(uuid, uuid, uuid, public.tipo_movimiento, integer, uuid, text, text, uuid, uuid, uuid)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
