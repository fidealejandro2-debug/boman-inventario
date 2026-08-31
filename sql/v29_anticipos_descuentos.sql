-- ============================================================
-- BOMAN INVENTARIO - Anticipos y descuentos v29
-- Controla solicitud, aprobacion y desembolso de anticipos; centraliza
-- descuentos documentados, cuotas, prioridades, topes y aplicaciones.
-- Ejecutar una sola vez DESPUES de v28.
-- ============================================================

-- Art. 90 del Codigo del Trabajo: anticipos y compras de articulos de la
-- empresa se retienen hasta el porcentaje mensual configurado. Se separa
-- del tope operativo global y de las obligaciones judiciales/IESS.
alter table public.nomina_parametros
  add column if not exists tope_retencion_empleador_pct numeric(6,4)
    not null default 10.0000
    check (tope_retencion_empleador_pct > 0
      and tope_retencion_empleador_pct <= 10.0000);

-- ------------------------------------------------------------
-- 1. Anticipos y programas de descuento
-- ------------------------------------------------------------
create table if not exists public.anticipos (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  empresa_pagadora_id uuid not null references public.empresas(id) on delete restrict,
  fecha date not null,
  monto numeric(14,2) not null check (monto > 0),
  motivo text not null check (btrim(motivo) <> ''),
  cuotas integer not null check (cuotas between 1 and 120),
  fecha_primera_cuota date not null,
  documento_respaldo_id uuid references public.empleado_documentos(id) on delete restrict,
  estado text not null default 'solicitado' check (estado in (
    'solicitado', 'aprobado', 'rechazado', 'desembolsado', 'anulado'
  )),
  idempotency_key uuid not null unique,
  solicitado_por uuid not null references public.perfiles(id) on delete restrict,
  aprobado_por uuid references public.perfiles(id) on delete restrict,
  aprobado_at timestamptz,
  rechazado_por uuid references public.perfiles(id) on delete restrict,
  rechazado_at timestamptz,
  desembolsado_por uuid references public.perfiles(id) on delete restrict,
  desembolsado_at timestamptz,
  forma_desembolso text check (forma_desembolso in ('transferencia', 'efectivo', 'cheque')),
  referencia_desembolso text,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,
  motivo_resolucion text,
  motivo_anulacion text,
  descuento_programado_id uuid,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fecha_primera_cuota >= date_trunc('month', fecha)::date),
  check (
    (estado = 'aprobado' and aprobado_por is not null and aprobado_at is not null)
    or estado <> 'aprobado'
  ),
  check (
    (estado = 'rechazado' and rechazado_por is not null and rechazado_at is not null)
    or estado <> 'rechazado'
  ),
  check (
    (estado = 'desembolsado' and desembolsado_por is not null
      and desembolsado_at is not null and forma_desembolso is not null
      and descuento_programado_id is not null)
    or estado <> 'desembolsado'
  ),
  check (
    (estado = 'anulado' and anulado_por is not null and anulado_at is not null
      and btrim(coalesce(motivo_anulacion, '')) <> '')
    or estado <> 'anulado'
  )
);

create table if not exists public.descuentos_programados (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  empresa_acreedora_id uuid references public.empresas(id) on delete restrict,
  origen text not null check (origen in (
    'anticipo', 'prestamo_iess', 'prestamo_quirografario',
    'prestamo_hipotecario', 'prestamo_empresa', 'multa', 'judicial',
    'uniforme', 'consumo_interno', 'otro'
  )),
  categoria_tope text not null check (categoria_tope in (
    'judicial', 'iess', 'empleador'
  )),
  origen_id uuid,
  descripcion text not null check (btrim(descripcion) <> ''),
  monto_total numeric(14,2) not null check (monto_total > 0),
  monto_aplicado numeric(14,2) not null default 0 check (monto_aplicado >= 0),
  monto_condonado numeric(14,2) not null default 0 check (monto_condonado >= 0),
  saldo numeric(14,2) generated always as (
    monto_total - monto_aplicado - monto_condonado
  ) stored,
  cuotas_total integer not null check (cuotas_total between 1 and 120),
  cuotas_pagadas integer not null default 0 check (cuotas_pagadas >= 0),
  monto_cuota numeric(14,2) not null check (monto_cuota > 0),
  fecha_inicio date not null,
  fecha_fin date not null,
  documento_respaldo_id uuid references public.empleado_documentos(id) on delete restrict,
  estado text not null default 'vigente' check (estado in (
    'vigente', 'pagado', 'suspendido', 'condonado', 'anulado'
  )),
  prioridad integer not null check (prioridad between 1 and 999),
  idempotency_key uuid not null unique,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fecha_fin >= fecha_inicio),
  check (monto_aplicado + monto_condonado <= monto_total),
  check (cuotas_pagadas <= cuotas_total),
  check (
    (categoria_tope = 'judicial' and origen = 'judicial' and prioridad between 1 and 9)
    or (categoria_tope = 'iess'
      and origen in ('prestamo_iess', 'prestamo_quirografario', 'prestamo_hipotecario')
      and prioridad between 10 and 19)
    or (categoria_tope = 'empleador'
      and origen in ('anticipo', 'prestamo_empresa', 'multa', 'uniforme',
        'consumo_interno', 'otro') and prioridad >= 20)
  ),
  check (estado <> 'pagado' or saldo = 0),
  check (estado <> 'condonado' or saldo = 0)
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'anticipos_descuento_programado_fkey'
      and conrelid = 'public.anticipos'::regclass
  ) then
    alter table public.anticipos
      add constraint anticipos_descuento_programado_fkey
      foreign key (descuento_programado_id)
      references public.descuentos_programados(id) on delete restrict;
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'novedades_empleado_descuento_id_fkey'
      and conrelid = 'public.novedades_empleado'::regclass
  ) then
    alter table public.novedades_empleado
      add constraint novedades_empleado_descuento_id_fkey
      foreign key (descuento_id)
      references public.descuentos_programados(id) on delete restrict;
  end if;
end;
$$;

create unique index if not exists uq_descuentos_origen_v29
  on public.descuentos_programados(origen, origen_id)
  where origen_id is not null and estado <> 'anulado';

create table if not exists public.descuento_programado_cuotas (
  id uuid primary key default gen_random_uuid(),
  descuento_programado_id uuid not null
    references public.descuentos_programados(id) on delete restrict,
  numero integer not null check (numero > 0),
  fecha_prevista date not null,
  monto numeric(14,2) not null check (monto > 0),
  monto_aplicado numeric(14,2) not null default 0 check (monto_aplicado >= 0),
  saldo numeric(14,2) generated always as (monto - monto_aplicado) stored,
  estado text not null default 'pendiente' check (estado in (
    'pendiente', 'parcial', 'aplicada', 'diferida', 'condonada', 'anulada'
  )),
  diferimientos integer not null default 0 check (diferimientos >= 0),
  ultima_gestion_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (descuento_programado_id, numero),
  check (monto_aplicado <= monto),
  check (estado <> 'aplicada' or saldo = 0)
);

-- Cabecera de una corrida del motor para un empleado y periodo. V30 agrega
-- la FK de nomina_rol_linea_id cuando exista nomina_rol_lineas.
create table if not exists public.descuento_aplicacion_lotes (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  anio integer not null check (anio between 2000 and 2200),
  mes integer not null check (mes between 1 and 12),
  nomina_rol_linea_id uuid not null,
  remuneracion_base numeric(14,2) not null check (remuneracion_base >= 0),
  neto_disponible_inicial numeric(14,2) not null check (neto_disponible_inicial >= 0),
  tope_global numeric(14,2) not null check (tope_global >= 0),
  tope_empleador numeric(14,2) not null check (tope_empleador >= 0),
  tope_multas numeric(14,2) not null check (tope_multas >= 0),
  total_judicial numeric(14,2) not null default 0 check (total_judicial >= 0),
  total_iess numeric(14,2) not null default 0 check (total_iess >= 0),
  total_empleador numeric(14,2) not null default 0 check (total_empleador >= 0),
  total_multas numeric(14,2) not null default 0 check (total_multas >= 0),
  total_aplicado numeric(14,2) not null default 0 check (total_aplicado >= 0),
  total_diferido numeric(14,2) not null default 0 check (total_diferido >= 0),
  estado text not null default 'aplicado' check (estado in ('aplicado', 'revertido')),
  idempotency_key uuid not null unique,
  aplicado_por uuid not null references public.perfiles(id) on delete restrict,
  aplicado_at timestamptz not null default now(),
  revertido_por uuid references public.perfiles(id) on delete restrict,
  revertido_at timestamptz,
  motivo_reversion text,
  check (total_aplicado = total_judicial + total_iess + total_empleador),
  check (total_multas <= total_empleador),
  check (total_aplicado <= neto_disponible_inicial),
  check (
    (estado = 'aplicado' and revertido_por is null and revertido_at is null)
    or (estado = 'revertido' and revertido_por is not null
      and revertido_at is not null and btrim(coalesce(motivo_reversion, '')) <> '')
  )
);

create unique index if not exists uq_descuento_lote_periodo_activo_v29
  on public.descuento_aplicacion_lotes(empleado_id, anio, mes)
  where estado = 'aplicado';

create table if not exists public.descuento_aplicaciones (
  id uuid primary key default gen_random_uuid(),
  lote_id uuid not null references public.descuento_aplicacion_lotes(id) on delete restrict,
  descuento_programado_id uuid not null
    references public.descuentos_programados(id) on delete restrict,
  cuota_id uuid not null references public.descuento_programado_cuotas(id) on delete restrict,
  categoria_tope text not null check (categoria_tope in ('judicial', 'iess', 'empleador')),
  prioridad integer not null,
  monto_pendiente numeric(14,2) not null check (monto_pendiente > 0),
  monto_aplicado numeric(14,2) not null check (monto_aplicado >= 0),
  monto_diferido numeric(14,2) not null check (monto_diferido >= 0),
  motivo_diferimiento text,
  estado text not null default 'aplicada' check (estado in ('aplicada', 'revertida')),
  created_at timestamptz not null default now(),
  check (monto_aplicado + monto_diferido = monto_pendiente),
  check (monto_diferido = 0 or btrim(coalesce(motivo_diferimiento, '')) <> ''),
  unique (lote_id, cuota_id)
);

create index if not exists idx_anticipos_empleado_estado_v29
  on public.anticipos(empleado_id, estado, fecha desc);
create index if not exists idx_anticipos_empresa_fecha_v29
  on public.anticipos(empresa_pagadora_id, fecha desc);
create index if not exists idx_descuentos_empleado_estado_v29
  on public.descuentos_programados(empleado_id, estado, prioridad, fecha_inicio);
create index if not exists idx_descuento_cuotas_vencimiento_v29
  on public.descuento_programado_cuotas(fecha_prevista, estado, descuento_programado_id);
create index if not exists idx_descuento_aplicaciones_programa_v29
  on public.descuento_aplicaciones(descuento_programado_id, created_at);

comment on column public.descuentos_programados.categoria_tope is
  'Judicial se atiende primero; IESS usa el tope operativo; empleador usa ademas el limite mensual del Art. 90.';
comment on table public.descuento_aplicacion_lotes is
  'Instantanea del motor por empleado/periodo. V30 relaciona nomina_rol_linea_id con el rol congelado.';

-- ------------------------------------------------------------
-- 2. Auditoria compartida y acceso estricto
-- ------------------------------------------------------------
alter table public.nomina_eventos
  drop constraint if exists nomina_eventos_entidad_check;
alter table public.nomina_eventos
  add constraint nomina_eventos_entidad_check check (entidad in (
    'empleado', 'afiliacion', 'compensacion', 'documento', 'parametros',
    'calendario_feriados', 'periodos_vacaciones', 'ausencia', 'novedad',
    'anticipo', 'descuento', 'descuento_aplicacion'
  ));

alter table public.anticipos enable row level security;
alter table public.descuentos_programados enable row level security;
alter table public.descuento_programado_cuotas enable row level security;
alter table public.descuento_aplicacion_lotes enable row level security;
alter table public.descuento_aplicaciones enable row level security;

drop policy if exists "leer_anticipos_v29" on public.anticipos;
create policy "leer_anticipos_v29" on public.anticipos
for select to authenticated using (public.usuario_puede_nomina(false));
drop policy if exists "leer_descuentos_v29" on public.descuentos_programados;
create policy "leer_descuentos_v29" on public.descuentos_programados
for select to authenticated using (public.usuario_puede_nomina(false));
drop policy if exists "leer_descuento_cuotas_v29" on public.descuento_programado_cuotas;
create policy "leer_descuento_cuotas_v29" on public.descuento_programado_cuotas
for select to authenticated using (public.usuario_puede_nomina(false));
drop policy if exists "leer_descuento_lotes_v29" on public.descuento_aplicacion_lotes;
create policy "leer_descuento_lotes_v29" on public.descuento_aplicacion_lotes
for select to authenticated using (public.usuario_puede_nomina(false));
drop policy if exists "leer_descuento_aplicaciones_v29" on public.descuento_aplicaciones;
create policy "leer_descuento_aplicaciones_v29" on public.descuento_aplicaciones
for select to authenticated using (public.usuario_puede_nomina(false));

-- ------------------------------------------------------------
-- 3. Constructor interno de programas y cuotas
-- ------------------------------------------------------------
create or replace function public.crear_programa_descuento_v29(
  p_empleado_id uuid,
  p_empresa_acreedora_id uuid,
  p_origen text,
  p_origen_id uuid,
  p_descripcion text,
  p_monto_total numeric,
  p_cuotas integer,
  p_fecha_inicio date,
  p_documento_respaldo_id uuid,
  p_prioridad integer,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.empleados%rowtype;
  v_id uuid;
  v_categoria text;
  v_prioridad integer;
  v_cuota_base numeric(14,2);
  v_monto numeric(14,2);
  v_acumulado numeric(14,2) := 0;
  v_i integer;
  v_fecha date;
  v_origen_id uuid;
begin
  select * into e from public.empleados where id = p_empleado_id for update;
  if not found then raise exception 'El empleado no existe'; end if;
  if e.estado <> 'activo' then raise exception 'El empleado no esta activo'; end if;
  if p_origen not in (
    'anticipo', 'prestamo_iess', 'prestamo_quirografario',
    'prestamo_hipotecario', 'prestamo_empresa', 'multa', 'judicial',
    'uniforme', 'consumo_interno', 'otro'
  ) then raise exception 'El origen del descuento no es valido'; end if;
  if coalesce(p_monto_total, 0) <= 0 then raise exception 'El monto debe ser mayor a cero'; end if;
  if p_cuotas not between 1 and 120 then raise exception 'Las cuotas deben estar entre 1 y 120'; end if;
  if p_fecha_inicio is null then raise exception 'La fecha de inicio es obligatoria'; end if;
  if btrim(coalesce(p_descripcion, '')) = '' then raise exception 'La descripcion es obligatoria'; end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;

  if p_empresa_acreedora_id is not null and not exists (
    select 1 from public.empresas ep
    where ep.id = p_empresa_acreedora_id and ep.grupo_id = e.grupo_id and ep.activo
  ) then raise exception 'La empresa acreedora no pertenece al grupo del empleado'; end if;
  if p_documento_respaldo_id is null and p_origen <> 'anticipo' then
    raise exception 'El descuento requiere un documento de respaldo';
  end if;
  if p_documento_respaldo_id is not null and not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_respaldo_id and d.empleado_id = e.id and d.activo
  ) then raise exception 'El documento no pertenece al empleado o esta inactivo'; end if;
  -- Si el llamador no tiene una entidad propia, el documento funciona como
  -- origen verificable. Evita registrar dos veces la misma obligacion con
  -- claves de idempotencia diferentes.
  v_origen_id := coalesce(
    p_origen_id,
    case when p_origen <> 'otro' then p_documento_respaldo_id end
  );
  if v_origen_id is not null and exists (
    select 1 from public.descuentos_programados d
    where d.origen = p_origen and d.origen_id = v_origen_id and d.estado <> 'anulado'
  ) then raise exception 'El documento origen ya tiene un descuento programado'; end if;

  v_categoria := case
    when p_origen = 'judicial' then 'judicial'
    when p_origen in ('prestamo_iess', 'prestamo_quirografario', 'prestamo_hipotecario')
      then 'iess'
    else 'empleador'
  end;
  v_prioridad := coalesce(p_prioridad, case v_categoria
    when 'judicial' then 1 when 'iess' then 10
    else case when p_origen = 'anticipo' then 20
      when p_origen = 'multa' then 30 else 40 end end);
  if (v_categoria = 'judicial' and v_prioridad not between 1 and 9)
     or (v_categoria = 'iess' and v_prioridad not between 10 and 19)
     or (v_categoria = 'empleador' and v_prioridad < 20) then
    raise exception 'La prioridad no corresponde a la categoria legal del descuento';
  end if;

  v_cuota_base := trunc((p_monto_total / p_cuotas)::numeric, 2);
  if v_cuota_base <= 0 then raise exception 'El numero de cuotas produce valores menores a un centavo'; end if;

  insert into public.descuentos_programados(
    grupo_id, empleado_id, empresa_acreedora_id, origen, categoria_tope,
    origen_id, descripcion, monto_total, cuotas_total, monto_cuota,
    fecha_inicio, fecha_fin, documento_respaldo_id, prioridad,
    idempotency_key, creado_por
  ) values (
    e.grupo_id, e.id, p_empresa_acreedora_id, p_origen, v_categoria,
    v_origen_id, btrim(p_descripcion), round(p_monto_total, 2), p_cuotas,
    v_cuota_base, date_trunc('month', p_fecha_inicio)::date,
    (date_trunc('month', p_fecha_inicio) + make_interval(months => p_cuotas - 1))::date,
    p_documento_respaldo_id, v_prioridad, p_idempotency_key, auth.uid()
  ) returning id into v_id;

  for v_i in 1..p_cuotas loop
    v_fecha := (date_trunc('month', p_fecha_inicio)
      + make_interval(months => v_i - 1))::date;
    v_monto := case when v_i = p_cuotas
      then round(p_monto_total, 2) - v_acumulado else v_cuota_base end;
    insert into public.descuento_programado_cuotas(
      descuento_programado_id, numero, fecha_prevista, monto
    ) values (v_id, v_i, v_fecha, v_monto);
    v_acumulado := v_acumulado + v_monto;
  end loop;
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 4. Registro directo de obligaciones documentadas
-- ------------------------------------------------------------
create or replace function public.registrar_descuento_programado_v29(
  p_empleado_id uuid,
  p_empresa_acreedora_id uuid,
  p_origen text,
  p_origen_id uuid,
  p_descripcion text,
  p_monto_total numeric,
  p_cuotas integer,
  p_fecha_inicio date,
  p_documento_respaldo_id uuid,
  p_prioridad integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede registrar descuentos';
  end if;
  if p_origen = 'anticipo' then
    raise exception 'Los anticipos se generan al confirmar su desembolso';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.descuentos_programados
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('id', v_id, 'duplicado', true); end if;

  v_id := public.crear_programa_descuento_v29(
    p_empleado_id, p_empresa_acreedora_id, p_origen, p_origen_id,
    p_descripcion, p_monto_total, p_cuotas, p_fecha_inicio,
    p_documento_respaldo_id, p_prioridad, p_idempotency_key
  );
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_nuevo, detalle, datos,
    usuario_id, idempotency_key
  ) values (
    'descuento', v_id, p_empleado_id, 'descuento_programado', 'vigente',
    btrim(p_descripcion), jsonb_build_object(
      'origen', p_origen, 'monto_total', round(p_monto_total, 2),
      'cuotas', p_cuotas, 'fecha_inicio', p_fecha_inicio
    ), auth.uid(), gen_random_uuid()
  ) returning id into v_evento_id;
  return jsonb_build_object('id', v_id, 'evento_id', v_evento_id,
    'duplicado', false, 'mensaje', 'Descuento programado correctamente');
end;
$$;

-- ------------------------------------------------------------
-- 5. Flujo de anticipos
-- ------------------------------------------------------------
create or replace function public.solicitar_anticipo_v29(
  p_empleado_id uuid,
  p_empresa_pagadora_id uuid,
  p_fecha date,
  p_monto numeric,
  p_motivo text,
  p_cuotas integer,
  p_fecha_primera_cuota date,
  p_documento_respaldo_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.empleados%rowtype;
  v_id uuid;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede registrar anticipos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.anticipos where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('id', v_id, 'duplicado', true); end if;
  select * into e from public.empleados where id = p_empleado_id for update;
  if not found then raise exception 'El empleado no existe'; end if;
  if e.estado <> 'activo' then raise exception 'El empleado no esta activo'; end if;
  if not exists (
    select 1 from public.empresas ep
    where ep.id = p_empresa_pagadora_id and ep.grupo_id = e.grupo_id and ep.activo
  ) then raise exception 'La empresa pagadora no pertenece al grupo del empleado'; end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'El monto debe ser mayor a cero'; end if;
  if p_cuotas not between 1 and 120 then raise exception 'Las cuotas deben estar entre 1 y 120'; end if;
  if p_fecha is null or p_fecha_primera_cuota is null
     or p_fecha_primera_cuota < date_trunc('month', p_fecha)::date then
    raise exception 'Las fechas del anticipo no son validas';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'El motivo es obligatorio'; end if;
  if p_documento_respaldo_id is not null and not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_respaldo_id and d.empleado_id = e.id and d.activo
  ) then raise exception 'El documento no pertenece al empleado o esta inactivo'; end if;

  insert into public.anticipos(
    grupo_id, empleado_id, empresa_pagadora_id, fecha, monto, motivo,
    cuotas, fecha_primera_cuota, documento_respaldo_id,
    idempotency_key, solicitado_por
  ) values (
    e.grupo_id, e.id, p_empresa_pagadora_id, p_fecha, round(p_monto, 2),
    btrim(p_motivo), p_cuotas, p_fecha_primera_cuota,
    p_documento_respaldo_id, p_idempotency_key, auth.uid()
  ) returning id into v_id;
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_nuevo, detalle, datos,
    usuario_id, idempotency_key
  ) values (
    'anticipo', v_id, e.id, 'anticipo_solicitado', 'solicitado', btrim(p_motivo),
    jsonb_build_object('monto', round(p_monto, 2), 'cuotas', p_cuotas,
      'empresa_pagadora_id', p_empresa_pagadora_id),
    auth.uid(), gen_random_uuid()
  ) returning id into v_evento_id;
  return jsonb_build_object('id', v_id, 'evento_id', v_evento_id,
    'estado', 'solicitado', 'duplicado', false);
end;
$$;

create or replace function public.resolver_anticipo_v29(
  p_anticipo_id uuid,
  p_aprobar boolean,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.anticipos%rowtype;
  v_evento_id uuid;
  v_rol text := public.rol_usuario_actual();
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede resolver anticipos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into a from public.anticipos where id = p_anticipo_id for update;
  if not found then raise exception 'El anticipo no existe'; end if;
  if a.estado <> 'solicitado' then raise exception 'El anticipo ya fue resuelto'; end if;
  if a.solicitado_por = auth.uid() and v_rol <> 'admin' then
    raise exception 'Quien solicita un anticipo no puede aprobarlo ni rechazarlo';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'La resolucion requiere una observacion';
  end if;
  if coalesce(p_aprobar, false) and a.documento_respaldo_id is null then
    raise exception 'Adjunta la solicitud o autorizacion firmada antes de aprobar';
  end if;
  if coalesce(p_aprobar, false) and not exists (
    select 1 from public.empleado_documentos d
    where d.id = a.documento_respaldo_id
      and d.empleado_id = a.empleado_id and d.activo
  ) then
    raise exception 'La solicitud firmada ya no esta activa o no pertenece al empleado';
  end if;
  if a.solicitado_por = auth.uid() and v_rol = 'admin'
     and length(btrim(p_motivo)) < 10 then
    raise exception 'La excepcion Admin requiere una justificacion de al menos 10 caracteres';
  end if;

  if coalesce(p_aprobar, false) then
    update public.anticipos
    set estado = 'aprobado', aprobado_por = auth.uid(), aprobado_at = now(),
        motivo_resolucion = btrim(p_motivo), version = version + 1,
        updated_at = now()
    where id = a.id;
  else
    update public.anticipos
    set estado = 'rechazado', rechazado_por = auth.uid(), rechazado_at = now(),
        motivo_resolucion = btrim(p_motivo), version = version + 1,
        updated_at = now()
    where id = a.id;
  end if;
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, usuario_id, idempotency_key
  ) values (
    'anticipo', a.id, a.empleado_id,
    case when coalesce(p_aprobar, false) then 'anticipo_aprobado' else 'anticipo_rechazado' end,
    'solicitado', case when coalesce(p_aprobar, false) then 'aprobado' else 'rechazado' end,
    btrim(p_motivo), auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object('id', a.id, 'evento_id', v_evento_id,
    'estado', case when coalesce(p_aprobar, false) then 'aprobado' else 'rechazado' end,
    'duplicado', false);
end;
$$;

create or replace function public.desembolsar_anticipo_v29(
  p_anticipo_id uuid,
  p_forma_desembolso text,
  p_referencia text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.anticipos%rowtype;
  v_descuento_id uuid;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede confirmar desembolsos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  if p_forma_desembolso not in ('transferencia', 'efectivo', 'cheque') then
    raise exception 'La forma de desembolso no es valida';
  end if;
  if btrim(coalesce(p_referencia, '')) = '' then
    raise exception 'El desembolso requiere comprobante o referencia';
  end if;
  select * into a from public.anticipos where id = p_anticipo_id for update;
  if not found then raise exception 'El anticipo no existe'; end if;
  if a.estado <> 'aprobado' then raise exception 'Solo un anticipo aprobado puede desembolsarse'; end if;
  if a.documento_respaldo_id is null then
    raise exception 'El anticipo aprobado no tiene solicitud o autorizacion firmada';
  end if;

  v_descuento_id := public.crear_programa_descuento_v29(
    a.empleado_id, a.empresa_pagadora_id, 'anticipo', a.id,
    'Recuperacion de anticipo: ' || a.motivo, a.monto, a.cuotas,
    a.fecha_primera_cuota, a.documento_respaldo_id, 20, gen_random_uuid()
  );
  update public.anticipos
  set estado = 'desembolsado', desembolsado_por = auth.uid(), desembolsado_at = now(),
      forma_desembolso = p_forma_desembolso,
      referencia_desembolso = btrim(p_referencia),
      descuento_programado_id = v_descuento_id,
      version = version + 1, updated_at = now()
  where id = a.id;
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    'anticipo', a.id, a.empleado_id, 'anticipo_desembolsado', 'aprobado',
    'desembolsado', 'Anticipo desembolsado y descuento programado',
    jsonb_build_object('descuento_programado_id', v_descuento_id,
      'forma', p_forma_desembolso, 'referencia', btrim(p_referencia)),
    auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object('id', a.id, 'descuento_programado_id', v_descuento_id,
    'evento_id', v_evento_id, 'estado', 'desembolsado', 'duplicado', false);
end;
$$;

create or replace function public.anular_anticipo_v29(
  p_anticipo_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.anticipos%rowtype;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede anular anticipos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La anulacion requiere un motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into a from public.anticipos where id = p_anticipo_id for update;
  if not found then raise exception 'El anticipo no existe'; end if;
  if a.estado not in ('solicitado', 'aprobado') then
    raise exception 'Un anticipo desembolsado no se anula; suspende o resuelve su saldo documentadamente';
  end if;
  update public.anticipos
  set estado = 'anulado', anulado_por = auth.uid(), anulado_at = now(),
      motivo_anulacion = btrim(p_motivo), version = version + 1,
      updated_at = now()
  where id = a.id;
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, usuario_id, idempotency_key
  ) values (
    'anticipo', a.id, a.empleado_id, 'anticipo_anulado', a.estado, 'anulado',
    btrim(p_motivo), auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object('id', a.id, 'evento_id', v_evento_id,
    'estado', 'anulado', 'duplicado', false);
end;
$$;

-- ------------------------------------------------------------
-- 6. Estado administrativo de descuentos
-- ------------------------------------------------------------
create or replace function public.resolver_descuento_programado_v29(
  p_descuento_id uuid,
  p_accion text,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.descuentos_programados%rowtype;
  v_estado text;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede gestionar descuentos';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La gestion requiere un motivo de al menos 10 caracteres';
  end if;
  if p_accion not in ('suspender', 'reactivar', 'condonar') then
    raise exception 'La accion del descuento no es valida';
  end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into d from public.descuentos_programados
  where id = p_descuento_id for update;
  if not found then raise exception 'El descuento programado no existe'; end if;

  if p_accion = 'suspender' then
    if d.estado <> 'vigente' then raise exception 'Solo un descuento vigente puede suspenderse'; end if;
    v_estado := 'suspendido';
  elsif p_accion = 'reactivar' then
    if d.estado <> 'suspendido' then raise exception 'Solo un descuento suspendido puede reactivarse'; end if;
    v_estado := 'vigente';
  else
    if public.rol_usuario_actual() <> 'admin' then
      raise exception 'Solo Administracion puede condonar un saldo';
    end if;
    if d.categoria_tope in ('judicial', 'iess') then
      raise exception 'Una obligacion judicial o IESS no puede condonarse desde el ERP';
    end if;
    if d.estado not in ('vigente', 'suspendido') or d.saldo <= 0 then
      raise exception 'El descuento no tiene saldo condonable';
    end if;
    v_estado := 'condonado';
  end if;

  if p_accion = 'condonar' then
    update public.descuentos_programados
    set monto_condonado = monto_condonado + saldo, estado = 'condonado',
        actualizado_por = auth.uid(), updated_at = now()
    where id = d.id;
    update public.descuento_programado_cuotas
    set estado = 'condonada', updated_at = now()
    where descuento_programado_id = d.id and saldo > 0
      and estado in ('pendiente', 'parcial', 'diferida');
  else
    update public.descuentos_programados
    set estado = v_estado, actualizado_por = auth.uid(), updated_at = now()
    where id = d.id;
  end if;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, usuario_id, idempotency_key
  ) values (
    'descuento', d.id, d.empleado_id, 'descuento_' || p_accion,
    d.estado, v_estado, btrim(p_motivo), auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object('id', d.id, 'evento_id', v_evento_id,
    'estado', v_estado, 'duplicado', false);
end;
$$;

-- Convierte una sancion economica ya notificada en cuotas de Nomina. La
-- novedad sigue siendo la fuente y nunca se duplica por reintentos.
create or replace function public.registrar_descuento_multa_v29(
  p_novedad_id uuid,
  p_cuotas integer,
  p_fecha_inicio date,
  p_documento_respaldo_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.novedades_empleado%rowtype;
  v_documento_id uuid;
  v_descuento_id uuid;
  v_evento_id uuid;
  v_tope numeric;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede programar una multa';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;

  select * into n
  from public.novedades_empleado
  where id = p_novedad_id
  for update;
  if not found then raise exception 'La novedad disciplinaria no existe'; end if;
  if n.descuento_id is not null then
    return jsonb_build_object(
      'id', n.descuento_id, 'novedad_id', n.id, 'duplicado', true
    );
  end if;
  if n.tipo <> 'sancion_economica' or not n.genera_descuento
     or n.monto_descuento is null then
    raise exception 'La novedad no corresponde a una sancion economica';
  end if;
  if n.estado not in ('notificada', 'con_descargo', 'archivada') then
    raise exception 'La sancion debe estar notificada antes de generar el descuento';
  end if;
  if p_cuotas not between 1 and 120 or p_fecha_inicio is null then
    raise exception 'Las cuotas o la fecha de inicio no son validas';
  end if;

  v_documento_id := coalesce(p_documento_respaldo_id, n.documento_pdf_id);
  if v_documento_id is null then
    raise exception 'Adjunta el documento de la sancion antes de generar el descuento';
  end if;
  if not exists (
    select 1 from public.empleado_documentos d
    where d.id = v_documento_id and d.empleado_id = n.empleado_id and d.activo
  ) then
    raise exception 'El respaldo de la sancion no pertenece al empleado o esta inactivo';
  end if;

  -- V28 valido el monto al crear la novedad. Se vuelve a comprobar contra
  -- el parametro historico para detectar datos alterados fuera de los RPC.
  v_tope := public.tope_multa_empleado_v28(n.empleado_id, n.fecha_hechos);
  if v_tope is null or n.monto_descuento > v_tope then
    raise exception 'La multa supera el tope configurado o no tiene remuneracion base';
  end if;

  v_descuento_id := public.crear_programa_descuento_v29(
    n.empleado_id, n.empresa_id, 'multa', n.id,
    'Sancion economica ' || n.anio::text || '-'
      || lpad(n.numero::text, 4, '0') || ': ' || n.asunto,
    n.monto_descuento, p_cuotas, p_fecha_inicio,
    v_documento_id, 30, p_idempotency_key
  );

  update public.novedades_empleado
  set descuento_id = v_descuento_id,
      actualizado_por = auth.uid(), updated_at = now()
  where id = n.id;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_nuevo, detalle, datos,
    usuario_id, idempotency_key
  ) values (
    'descuento', v_descuento_id, n.empleado_id,
    'multa_programada', 'vigente',
    'Descuento generado desde novedad disciplinaria',
    jsonb_build_object(
      'novedad_id', n.id, 'monto', n.monto_descuento,
      'cuotas', p_cuotas, 'fecha_inicio', p_fecha_inicio
    ), auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;

  return jsonb_build_object(
    'id', v_descuento_id, 'novedad_id', n.id,
    'evento_id', v_evento_id, 'duplicado', false,
    'mensaje', 'Multa programada correctamente'
  );
end;
$$;

-- Permite corregir una multa antes de que haya afectado un rol. Si ya hubo
-- retencion, primero debe revertirse el calculo del periodo abierto en v30;
-- una nomina cerrada nunca se reescribe.
create or replace function public.revertir_descuento_multa_v29(
  p_novedad_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.novedades_empleado%rowtype;
  d public.descuentos_programados%rowtype;
  v_evento_id uuid;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede revertir el descuento de una multa';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La reversion requiere un motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id
  from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true);
  end if;

  select * into n from public.novedades_empleado
  where id = p_novedad_id for update;
  if not found then raise exception 'La novedad disciplinaria no existe'; end if;
  if n.descuento_id is null then
    raise exception 'La novedad no tiene un descuento asociado';
  end if;
  select * into d from public.descuentos_programados
  where id = n.descuento_id for update;
  if not found or d.origen <> 'multa' or d.origen_id <> n.id then
    raise exception 'El descuento enlazado no corresponde a esta multa';
  end if;
  if d.monto_aplicado > 0 then
    raise exception 'La multa ya afecto un rol; revierte primero el calculo del periodo abierto';
  end if;
  if d.estado not in ('vigente', 'suspendido') then
    raise exception 'El descuento de la multa no se puede revertir en su estado actual';
  end if;

  update public.descuento_programado_cuotas
  set estado = 'anulada', updated_at = now()
  where descuento_programado_id = d.id
    and estado in ('pendiente', 'parcial', 'diferida');
  update public.descuentos_programados
  set estado = 'anulado', actualizado_por = auth.uid(), updated_at = now()
  where id = d.id;
  update public.novedades_empleado
  set descuento_id = null, actualizado_por = auth.uid(), updated_at = now()
  where id = n.id;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    'descuento', d.id, n.empleado_id, 'multa_descuento_revertido',
    d.estado, 'anulado', btrim(p_motivo),
    jsonb_build_object('novedad_id', n.id), auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;

  return jsonb_build_object(
    'id', d.id, 'novedad_id', n.id, 'evento_id', v_evento_id,
    'estado', 'anulado', 'duplicado', false
  );
end;
$$;

-- ------------------------------------------------------------
-- 7. Motor interno de aplicacion para v30
-- ------------------------------------------------------------
create or replace function public.aplicar_descuentos_periodo_v29(
  p_empleado_id uuid,
  p_anio integer,
  p_mes integer,
  p_remuneracion_base numeric,
  p_neto_disponible numeric,
  p_nomina_rol_linea_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lote_id uuid;
  v_param public.nomina_parametros%rowtype;
  v_fin_mes date;
  v_tope_global numeric(14,2);
  v_tope_empleador numeric(14,2);
  v_tope_multas numeric(14,2);
  v_total_judicial numeric(14,2) := 0;
  v_total_iess numeric(14,2) := 0;
  v_total_empleador numeric(14,2) := 0;
  v_total_multas numeric(14,2) := 0;
  v_total_aplicado numeric(14,2) := 0;
  v_total_no_judicial numeric(14,2) := 0;
  v_total_diferido numeric(14,2) := 0;
  v_disponible numeric(14,2);
  v_cap_categoria numeric(14,2);
  v_pendiente numeric(14,2);
  v_aplicar numeric(14,2);
  v_diferido numeric(14,2);
  v_motivo text;
  it record;
begin
  -- Funcion interna: v30 la invoca dentro del calculo atomico del rol.
  if auth.uid() is null or not public.usuario_puede_nomina(true) then
    raise exception 'No tiene permiso para aplicar descuentos de Nomina';
  end if;
  if p_idempotency_key is null or p_nomina_rol_linea_id is null then
    raise exception 'La aplicacion requiere idempotencia y linea de rol';
  end if;
  select id into v_lote_id from public.descuento_aplicacion_lotes
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('lote_id', v_lote_id, 'duplicado', true); end if;
  if p_anio not between 2000 and 2200 or p_mes not between 1 and 12 then
    raise exception 'El periodo no es valido';
  end if;
  if coalesce(p_remuneracion_base, -1) < 0 or coalesce(p_neto_disponible, -1) < 0 then
    raise exception 'La remuneracion y el neto disponible no pueden ser negativos';
  end if;
  if exists (
    select 1 from public.descuento_aplicacion_lotes l
    where l.empleado_id = p_empleado_id and l.anio = p_anio and l.mes = p_mes
      and l.estado = 'aplicado'
  ) then raise exception 'El empleado ya tiene descuentos aplicados en este periodo'; end if;
  perform 1 from public.empleados where id = p_empleado_id for update;
  if not found then raise exception 'El empleado no existe'; end if;
  select * into v_param from public.nomina_parametros where anio = p_anio;
  if not found then raise exception 'Configura los parametros de Nomina del anio %', p_anio; end if;

  v_fin_mes := (make_date(p_anio, p_mes, 1) + interval '1 month - 1 day')::date;
  v_tope_global := round(p_remuneracion_base * v_param.tope_descuento_total_pct / 100, 2);
  v_tope_empleador := round(p_remuneracion_base * v_param.tope_retencion_empleador_pct / 100, 2);
  v_tope_multas := round(p_remuneracion_base * v_param.tope_multa_pct / 100, 2);
  v_disponible := round(p_neto_disponible, 2);

  insert into public.descuento_aplicacion_lotes(
    empleado_id, anio, mes, nomina_rol_linea_id, remuneracion_base,
    neto_disponible_inicial, tope_global, tope_empleador, tope_multas,
    idempotency_key, aplicado_por
  ) values (
    p_empleado_id, p_anio, p_mes, p_nomina_rol_linea_id,
    round(p_remuneracion_base, 2), round(p_neto_disponible, 2),
    v_tope_global, v_tope_empleador, v_tope_multas,
    p_idempotency_key, auth.uid()
  ) returning id into v_lote_id;

  for it in
    select c.id as cuota_id, c.monto, c.monto_aplicado as cuota_aplicado,
           d.id as descuento_id, d.origen, d.categoria_tope, d.prioridad
    from public.descuento_programado_cuotas c
    join public.descuentos_programados d on d.id = c.descuento_programado_id
    where d.empleado_id = p_empleado_id and d.estado = 'vigente'
      and d.fecha_inicio <= v_fin_mes and c.fecha_prevista <= v_fin_mes
      and c.estado in ('pendiente', 'parcial', 'diferida') and c.saldo > 0
    order by d.prioridad, c.fecha_prevista, d.created_at, c.numero
    for update of c, d
  loop
    v_pendiente := it.monto - it.cuota_aplicado;
    v_cap_categoria := 0;
    v_motivo := null;

    if it.categoria_tope = 'judicial' then
      v_cap_categoria := v_disponible;
      if v_disponible < v_pendiente then
        v_motivo := 'Neto insuficiente para cubrir completamente la orden judicial';
      end if;
    elsif it.categoria_tope = 'iess' then
      v_cap_categoria := least(
        v_disponible,
        greatest(v_tope_global - v_total_no_judicial, 0)
      );
      if v_cap_categoria < v_pendiente then
        v_motivo := 'Diferido por tope operativo o neto disponible';
      end if;
    else
      v_cap_categoria := least(
        v_disponible,
        greatest(v_tope_global - v_total_no_judicial, 0),
        greatest(v_tope_empleador - v_total_empleador, 0)
      );
      if it.origen = 'multa' then
        v_cap_categoria := least(
          v_cap_categoria, greatest(v_tope_multas - v_total_multas, 0)
        );
      end if;
      if v_cap_categoria < v_pendiente then
        v_motivo := case when it.origen = 'multa'
          then 'Diferido por tope de multa, retencion del empleador o neto disponible'
          else 'Diferido por tope de retencion del empleador o neto disponible' end;
      end if;
    end if;

    v_aplicar := least(v_pendiente, greatest(v_cap_categoria, 0));
    v_diferido := v_pendiente - v_aplicar;
    if v_diferido > 0 and v_motivo is null then
      v_motivo := 'Diferido por saldo disponible';
    end if;

    insert into public.descuento_aplicaciones(
      lote_id, descuento_programado_id, cuota_id, categoria_tope,
      prioridad, monto_pendiente, monto_aplicado, monto_diferido,
      motivo_diferimiento
    ) values (
      v_lote_id, it.descuento_id, it.cuota_id, it.categoria_tope,
      it.prioridad, v_pendiente, v_aplicar, v_diferido, v_motivo
    );

    if v_aplicar > 0 then
      update public.descuento_programado_cuotas
      set monto_aplicado = monto_aplicado + v_aplicar,
          estado = case when saldo - v_aplicar = 0 then 'aplicada' else 'parcial' end,
          diferimientos = diferimientos + case when v_diferido > 0 then 1 else 0 end,
          ultima_gestion_at = now(), updated_at = now()
      where id = it.cuota_id;
      update public.descuentos_programados
      set monto_aplicado = monto_aplicado + v_aplicar,
          actualizado_por = auth.uid(), updated_at = now()
      where id = it.descuento_id;
      v_disponible := v_disponible - v_aplicar;
      v_total_aplicado := v_total_aplicado + v_aplicar;
      if it.categoria_tope = 'judicial' then
        v_total_judicial := v_total_judicial + v_aplicar;
      elsif it.categoria_tope = 'iess' then
        v_total_iess := v_total_iess + v_aplicar;
        v_total_no_judicial := v_total_no_judicial + v_aplicar;
      else
        v_total_empleador := v_total_empleador + v_aplicar;
        v_total_no_judicial := v_total_no_judicial + v_aplicar;
        if it.origen = 'multa' then v_total_multas := v_total_multas + v_aplicar; end if;
      end if;
    else
      update public.descuento_programado_cuotas
      set estado = 'diferida', diferimientos = diferimientos + 1,
          ultima_gestion_at = now(), updated_at = now()
      where id = it.cuota_id;
    end if;
    v_total_diferido := v_total_diferido + v_diferido;
  end loop;

  update public.descuentos_programados d
  set cuotas_pagadas = x.pagadas,
      estado = case when d.saldo = 0 then 'pagado' else d.estado end,
      updated_at = now()
  from (
    select c.descuento_programado_id,
           count(*) filter (where c.estado = 'aplicada')::integer pagadas
    from public.descuento_programado_cuotas c
    where c.descuento_programado_id in (
      select distinct a.descuento_programado_id
      from public.descuento_aplicaciones a where a.lote_id = v_lote_id
    )
    group by c.descuento_programado_id
  ) x
  where d.id = x.descuento_programado_id;

  update public.descuento_aplicacion_lotes
  set total_judicial = v_total_judicial, total_iess = v_total_iess,
      total_empleador = v_total_empleador, total_multas = v_total_multas,
      total_aplicado = v_total_aplicado, total_diferido = v_total_diferido
  where id = v_lote_id;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_nuevo, detalle, datos,
    usuario_id, idempotency_key
  ) values (
    'descuento_aplicacion', v_lote_id, p_empleado_id,
    'descuentos_aplicados_periodo', 'aplicado',
    'Motor de descuentos aplicado al rol',
    jsonb_build_object(
      'anio', p_anio, 'mes', p_mes, 'total_aplicado', v_total_aplicado,
      'total_diferido', v_total_diferido, 'judicial', v_total_judicial,
      'iess', v_total_iess, 'empleador', v_total_empleador,
      'neto_restante', v_disponible
    ), auth.uid(), gen_random_uuid()
  );
  return jsonb_build_object(
    'lote_id', v_lote_id, 'duplicado', false,
    'total_aplicado', v_total_aplicado, 'total_diferido', v_total_diferido,
    'judicial', v_total_judicial, 'iess', v_total_iess,
    'empleador', v_total_empleador, 'multas', v_total_multas,
    'neto_restante', v_disponible
  );
end;
$$;

create or replace function public.revertir_aplicacion_descuentos_v29(
  p_lote_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.descuento_aplicacion_lotes%rowtype;
  a record;
  v_evento_id uuid;
begin
  -- Interna para que v30 pueda recalcular solamente periodos abiertos.
  if auth.uid() is null or not public.usuario_puede_nomina(true) then
    raise exception 'No tiene permiso para revertir descuentos de Nomina';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La reversion requiere un motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into l from public.descuento_aplicacion_lotes where id = p_lote_id for update;
  if not found then raise exception 'La aplicacion de descuentos no existe'; end if;
  if l.estado <> 'aplicado' then raise exception 'La aplicacion ya fue revertida'; end if;

  for a in
    select * from public.descuento_aplicaciones
    where lote_id = l.id and estado = 'aplicada'
    order by id for update
  loop
    if a.monto_aplicado > 0 then
      update public.descuento_programado_cuotas
      set monto_aplicado = monto_aplicado - a.monto_aplicado,
          estado = case when monto_aplicado - a.monto_aplicado = 0
            then 'pendiente' else 'parcial' end,
          updated_at = now()
      where id = a.cuota_id;
      update public.descuentos_programados
      set monto_aplicado = monto_aplicado - a.monto_aplicado,
          estado = case when estado = 'pagado' then 'vigente' else estado end,
          actualizado_por = auth.uid(), updated_at = now()
      where id = a.descuento_programado_id;
    end if;
    update public.descuento_aplicaciones set estado = 'revertida' where id = a.id;
  end loop;

  update public.descuentos_programados d
  set cuotas_pagadas = x.pagadas, updated_at = now()
  from (
    select c.descuento_programado_id,
           count(*) filter (where c.estado = 'aplicada')::integer pagadas
    from public.descuento_programado_cuotas c
    where c.descuento_programado_id in (
      select distinct a.descuento_programado_id
      from public.descuento_aplicaciones a where a.lote_id = l.id
    )
    group by c.descuento_programado_id
  ) x
  where d.id = x.descuento_programado_id;

  update public.descuento_aplicacion_lotes
  set estado = 'revertido', revertido_por = auth.uid(), revertido_at = now(),
      motivo_reversion = btrim(p_motivo)
  where id = l.id;
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, usuario_id, idempotency_key
  ) values (
    'descuento_aplicacion', l.id, l.empleado_id,
    'descuentos_periodo_revertidos', 'aplicado', 'revertido',
    btrim(p_motivo), auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object('lote_id', l.id, 'evento_id', v_evento_id,
    'estado', 'revertido', 'duplicado', false);
end;
$$;

-- ------------------------------------------------------------
-- 8. Vistas para v30 y futura interfaz v31
-- ------------------------------------------------------------
create or replace view public.vista_anticipos_v29
with (security_invoker = true) as
select
  a.id, a.grupo_id, a.empleado_id, e.identificacion,
  e.apellidos, e.nombres, a.empresa_pagadora_id,
  ep.razon_social as empresa_pagadora, a.fecha, a.monto, a.motivo,
  a.cuotas, a.fecha_primera_cuota, a.estado, a.documento_respaldo_id,
  a.descuento_programado_id, d.monto_aplicado, d.saldo,
  a.solicitado_por, a.aprobado_por, a.desembolsado_por,
  a.created_at as solicitado_at, a.aprobado_at, a.desembolsado_at
from public.anticipos a
join public.empleados e on e.id = a.empleado_id
join public.empresas ep on ep.id = a.empresa_pagadora_id
left join public.descuentos_programados d on d.id = a.descuento_programado_id;

create or replace view public.vista_descuentos_programados_v29
with (security_invoker = true) as
select
  d.id, d.grupo_id, d.empleado_id, e.identificacion,
  e.apellidos, e.nombres, d.empresa_acreedora_id,
  ep.razon_social as empresa_acreedora, d.origen, d.categoria_tope,
  d.origen_id, d.descripcion, d.monto_total, d.monto_aplicado,
  d.monto_condonado, d.saldo, d.cuotas_total, d.cuotas_pagadas,
  d.monto_cuota, d.fecha_inicio, d.fecha_fin, d.estado, d.prioridad,
  d.documento_respaldo_id,
  count(c.id) filter (where c.estado in ('pendiente', 'parcial', 'diferida'))
    as cuotas_pendientes,
  min(c.fecha_prevista) filter (where c.saldo > 0) as cuota_pendiente_mas_antigua,
  coalesce(sum(c.saldo) filter (where c.saldo > 0), 0)::numeric(14,2)
    as saldo_cuotas
from public.descuentos_programados d
join public.empleados e on e.id = d.empleado_id
left join public.empresas ep on ep.id = d.empresa_acreedora_id
left join public.descuento_programado_cuotas c on c.descuento_programado_id = d.id
group by d.id, e.id, ep.id;

-- ------------------------------------------------------------
-- 9. Propiedad y privilegios
-- ------------------------------------------------------------
alter function public.crear_programa_descuento_v29(uuid, uuid, text, uuid, text, numeric, integer, date, uuid, integer, uuid) owner to postgres;
alter function public.registrar_descuento_programado_v29(uuid, uuid, text, uuid, text, numeric, integer, date, uuid, integer, uuid) owner to postgres;
alter function public.solicitar_anticipo_v29(uuid, uuid, date, numeric, text, integer, date, uuid, uuid) owner to postgres;
alter function public.resolver_anticipo_v29(uuid, boolean, text, uuid) owner to postgres;
alter function public.desembolsar_anticipo_v29(uuid, text, text, uuid) owner to postgres;
alter function public.anular_anticipo_v29(uuid, text, uuid) owner to postgres;
alter function public.resolver_descuento_programado_v29(uuid, text, text, uuid) owner to postgres;
alter function public.registrar_descuento_multa_v29(uuid, integer, date, uuid, uuid) owner to postgres;
alter function public.revertir_descuento_multa_v29(uuid, text, uuid) owner to postgres;
alter function public.aplicar_descuentos_periodo_v29(uuid, integer, integer, numeric, numeric, uuid, uuid) owner to postgres;
alter function public.revertir_aplicacion_descuentos_v29(uuid, text, uuid) owner to postgres;

revoke all on public.anticipos from public, anon;
revoke all on public.descuentos_programados from public, anon;
revoke all on public.descuento_programado_cuotas from public, anon;
revoke all on public.descuento_aplicacion_lotes from public, anon;
revoke all on public.descuento_aplicaciones from public, anon;
revoke insert, update, delete on public.anticipos from authenticated;
revoke insert, update, delete on public.descuentos_programados from authenticated;
revoke insert, update, delete on public.descuento_programado_cuotas from authenticated;
revoke insert, update, delete on public.descuento_aplicacion_lotes from authenticated;
revoke insert, update, delete on public.descuento_aplicaciones from authenticated;
grant select on public.anticipos to authenticated;
grant select on public.descuentos_programados to authenticated;
grant select on public.descuento_programado_cuotas to authenticated;
grant select on public.descuento_aplicacion_lotes to authenticated;
grant select on public.descuento_aplicaciones to authenticated;
grant select on public.vista_anticipos_v29 to authenticated;
grant select on public.vista_descuentos_programados_v29 to authenticated;

revoke execute on function public.crear_programa_descuento_v29(uuid, uuid, text, uuid, text, numeric, integer, date, uuid, integer, uuid)
  from public, anon, authenticated;
revoke execute on function public.registrar_descuento_programado_v29(uuid, uuid, text, uuid, text, numeric, integer, date, uuid, integer, uuid)
  from public, anon;
revoke execute on function public.solicitar_anticipo_v29(uuid, uuid, date, numeric, text, integer, date, uuid, uuid)
  from public, anon;
revoke execute on function public.resolver_anticipo_v29(uuid, boolean, text, uuid)
  from public, anon;
revoke execute on function public.desembolsar_anticipo_v29(uuid, text, text, uuid)
  from public, anon;
revoke execute on function public.anular_anticipo_v29(uuid, text, uuid)
  from public, anon;
revoke execute on function public.resolver_descuento_programado_v29(uuid, text, text, uuid)
  from public, anon;
revoke execute on function public.registrar_descuento_multa_v29(uuid, integer, date, uuid, uuid)
  from public, anon;
revoke execute on function public.revertir_descuento_multa_v29(uuid, text, uuid)
  from public, anon;
revoke execute on function public.aplicar_descuentos_periodo_v29(uuid, integer, integer, numeric, numeric, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.revertir_aplicacion_descuentos_v29(uuid, text, uuid)
  from public, anon, authenticated;

grant execute on function public.registrar_descuento_programado_v29(uuid, uuid, text, uuid, text, numeric, integer, date, uuid, integer, uuid)
  to authenticated;
grant execute on function public.solicitar_anticipo_v29(uuid, uuid, date, numeric, text, integer, date, uuid, uuid)
  to authenticated;
grant execute on function public.resolver_anticipo_v29(uuid, boolean, text, uuid)
  to authenticated;
grant execute on function public.desembolsar_anticipo_v29(uuid, text, text, uuid)
  to authenticated;
grant execute on function public.anular_anticipo_v29(uuid, text, uuid)
  to authenticated;
grant execute on function public.resolver_descuento_programado_v29(uuid, text, text, uuid)
  to authenticated;
grant execute on function public.registrar_descuento_multa_v29(uuid, integer, date, uuid, uuid)
  to authenticated;
grant execute on function public.revertir_descuento_multa_v29(uuid, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';
