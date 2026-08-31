-- ============================================================
-- BOMAN INVENTARIO - Ausencias y vacaciones v27
-- Calendarios confirmados, periodos por aniversario, consumo FIFO y
-- trazabilidad completa de solicitudes, aprobaciones y anulaciones.
-- Ejecutar una sola vez DESPUES de v26.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Calendarios de feriados confirmables por grupo economico
-- ------------------------------------------------------------
create table if not exists public.feriados_anios (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  anio integer not null check (anio between 2000 and 2200),
  estado text not null default 'borrador'
    check (estado in ('borrador', 'confirmado')),
  nota text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  confirmado_por uuid references public.perfiles(id) on delete restrict,
  confirmado_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, anio),
  unique (id, grupo_id, anio),
  check (
    (estado = 'borrador' and confirmado_por is null and confirmado_at is null)
    or (estado = 'confirmado' and confirmado_por is not null and confirmado_at is not null)
  )
);

create table if not exists public.feriados (
  id uuid primary key default gen_random_uuid(),
  feriados_anio_id uuid not null,
  grupo_id uuid not null,
  anio integer not null check (anio between 2000 and 2200),
  fecha date not null,
  nombre text not null check (btrim(nombre) <> ''),
  tipo text not null check (tipo in ('nacional', 'local')),
  almacen_id uuid references public.almacenes(id) on delete restrict,
  activo boolean not null default true,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (feriados_anio_id, grupo_id, anio)
    references public.feriados_anios(id, grupo_id, anio) on delete restrict,
  check (extract(year from fecha)::integer = anio),
  check (
    (tipo = 'nacional' and almacen_id is null)
    or (tipo = 'local' and almacen_id is not null)
  )
);

create unique index if not exists uq_feriados_nacionales_v27
  on public.feriados(grupo_id, fecha)
  where tipo = 'nacional';
create unique index if not exists uq_feriados_locales_v27
  on public.feriados(grupo_id, fecha, almacen_id)
  where tipo = 'local';
create index if not exists idx_feriados_calculo_v27
  on public.feriados(grupo_id, fecha, activo, almacen_id);

-- ------------------------------------------------------------
-- 2. Periodos de vacaciones y aplicaciones FIFO
-- ------------------------------------------------------------
create table if not exists public.vacaciones_periodos (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  periodo_desde date not null,
  periodo_hasta date not null,
  anos_servicio integer not null check (anos_servicio > 0),
  dias_derecho numeric(7,2) not null check (dias_derecho > 0),
  dias_tomados numeric(7,2) not null default 0 check (dias_tomados >= 0),
  dias_pagados numeric(7,2) not null default 0 check (dias_pagados >= 0),
  dias_saldo numeric(7,2) generated always as (
    dias_derecho - dias_tomados - dias_pagados
  ) stored,
  estado text not null default 'abierto'
    check (estado in ('abierto', 'agotado', 'liquidado', 'caducado')),
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (empleado_id, anos_servicio),
  unique (empleado_id, periodo_desde),
  check (periodo_hasta >= periodo_desde),
  check (dias_tomados + dias_pagados <= dias_derecho),
  check (
    (estado = 'agotado' and dias_derecho = dias_tomados + dias_pagados)
    or estado <> 'agotado'
  )
);

create table if not exists public.ausencias (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  almacen_id uuid references public.almacenes(id) on delete restrict,
  tipo text not null check (tipo in (
    'vacaciones', 'enfermedad_iess', 'enfermedad_particular',
    'permiso_con_sueldo', 'permiso_sin_sueldo', 'maternidad',
    'paternidad', 'lactancia', 'calamidad_domestica',
    'falta_injustificada', 'suspension_disciplinaria'
  )),
  fecha_desde date not null,
  fecha_hasta date not null,
  horas numeric(7,2) check (horas is null or horas > 0),
  dias_calendario numeric(7,2) not null check (dias_calendario >= 0),
  dias_habiles numeric(7,2) not null check (dias_habiles >= 0),
  vacaciones_periodo_id uuid references public.vacaciones_periodos(id) on delete restrict,
  documento_respaldo_id uuid references public.empleado_documentos(id) on delete restrict,
  observacion text,
  estado text not null default 'solicitada'
    check (estado in ('solicitada', 'aprobada', 'rechazada', 'anulada')),
  idempotency_key uuid not null unique,
  solicitado_por uuid not null references public.perfiles(id) on delete restrict,
  solicitado_at timestamptz not null default now(),
  aprobado_por uuid references public.perfiles(id) on delete restrict,
  aprobado_at timestamptz,
  rechazado_por uuid references public.perfiles(id) on delete restrict,
  rechazado_at timestamptz,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,
  motivo_resolucion text,
  motivo_anulacion text,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fecha_hasta >= fecha_desde),
  check (horas is null or fecha_desde = fecha_hasta),
  check (
    (horas is null and dias_calendario > 0)
    or (horas is not null and dias_calendario = 0 and dias_habiles = 0)
  ),
  check (tipo <> 'vacaciones' or horas is null),
  check (
    (estado = 'aprobada' and aprobado_por is not null and aprobado_at is not null)
    or estado <> 'aprobada'
  ),
  check (
    (estado = 'rechazada' and rechazado_por is not null and rechazado_at is not null)
    or estado <> 'rechazada'
  ),
  check (
    (estado = 'anulada' and anulado_por is not null and anulado_at is not null)
    or estado <> 'anulada'
  )
);

create table if not exists public.ausencia_vacaciones_aplicaciones (
  id uuid primary key default gen_random_uuid(),
  ausencia_id uuid not null references public.ausencias(id) on delete restrict,
  vacaciones_periodo_id uuid not null references public.vacaciones_periodos(id) on delete restrict,
  orden_fifo integer not null check (orden_fifo > 0),
  dias_aplicados numeric(7,2) not null check (dias_aplicados > 0),
  estado text not null default 'aplicada'
    check (estado in ('aplicada', 'revertida')),
  aplicado_por uuid not null references public.perfiles(id) on delete restrict,
  aplicado_at timestamptz not null default now(),
  revertido_por uuid references public.perfiles(id) on delete restrict,
  revertido_at timestamptz,
  motivo_reversion text,
  unique (ausencia_id, vacaciones_periodo_id),
  unique (ausencia_id, orden_fifo),
  check (
    (estado = 'aplicada' and revertido_por is null and revertido_at is null)
    or (estado = 'revertida' and revertido_por is not null and revertido_at is not null
      and btrim(coalesce(motivo_reversion, '')) <> '')
  )
);

-- Amplia la auditoria transversal creada por v26 sin reescribir su historia.
alter table public.nomina_eventos
  add column if not exists estado_anterior text,
  add column if not exists estado_nuevo text,
  add column if not exists datos jsonb not null default '{}'::jsonb,
  add column if not exists idempotency_key uuid;

alter table public.nomina_eventos
  drop constraint if exists nomina_eventos_entidad_check;
alter table public.nomina_eventos
  add constraint nomina_eventos_entidad_check check (entidad in (
    'empleado', 'afiliacion', 'compensacion', 'documento', 'parametros',
    'calendario_feriados', 'periodos_vacaciones', 'ausencia'
  ));

create unique index if not exists uq_nomina_eventos_idempotency_v27
  on public.nomina_eventos(idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_vacaciones_periodos_fifo_v27
  on public.vacaciones_periodos(empleado_id, periodo_desde, estado);
create index if not exists idx_ausencias_empleado_fechas_v27
  on public.ausencias(empleado_id, fecha_desde, fecha_hasta, estado);
create index if not exists idx_ausencias_grupo_estado_v27
  on public.ausencias(grupo_id, estado, fecha_desde);
create index if not exists idx_ausencia_aplicaciones_periodo_v27
  on public.ausencia_vacaciones_aplicaciones(vacaciones_periodo_id, estado);
create index if not exists idx_nomina_ausencias_eventos_v27
  on public.nomina_eventos(entidad, entidad_id, created_at desc)
  where entidad in ('calendario_feriados', 'periodos_vacaciones', 'ausencia');

comment on column public.ausencias.dias_calendario is
  'Dias consecutivos de la ausencia. En vacaciones incluye fines de semana y feriados.';
comment on column public.ausencias.dias_habiles is
  'Dias laborables estandar lunes-viernes, excluidos feriados confirmados; no reduce el saldo vacacional.';
comment on table public.ausencia_vacaciones_aplicaciones is
  'Detalle inmutable del consumo FIFO. Una ausencia puede consumir mas de un periodo anual.';

-- ------------------------------------------------------------
-- 3. Acceso estricto de nomina
-- ------------------------------------------------------------
alter table public.feriados_anios enable row level security;
alter table public.feriados enable row level security;
alter table public.vacaciones_periodos enable row level security;
alter table public.ausencias enable row level security;
alter table public.ausencia_vacaciones_aplicaciones enable row level security;

drop policy if exists "leer_feriados_anios_v27" on public.feriados_anios;
create policy "leer_feriados_anios_v27"
on public.feriados_anios for select to authenticated using (
  public.usuario_puede_nomina(false)
);
drop policy if exists "leer_feriados_v27" on public.feriados;
create policy "leer_feriados_v27"
on public.feriados for select to authenticated using (
  public.usuario_puede_nomina(false)
);
drop policy if exists "leer_vacaciones_periodos_v27" on public.vacaciones_periodos;
create policy "leer_vacaciones_periodos_v27"
on public.vacaciones_periodos for select to authenticated using (
  public.usuario_puede_nomina(false)
);
drop policy if exists "leer_ausencias_v27" on public.ausencias;
create policy "leer_ausencias_v27"
on public.ausencias for select to authenticated using (
  public.usuario_puede_nomina(false)
);
drop policy if exists "leer_ausencia_aplicaciones_v27"
  on public.ausencia_vacaciones_aplicaciones;
create policy "leer_ausencia_aplicaciones_v27"
on public.ausencia_vacaciones_aplicaciones for select to authenticated using (
  public.usuario_puede_nomina(false)
);

-- ------------------------------------------------------------
-- 4. Calendario confirmado y calculo de dias habiles
-- ------------------------------------------------------------
create or replace function public.validar_calendarios_feriados_v27(
  p_grupo_id uuid,
  p_fecha_desde date,
  p_fecha_hasta date
) returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_anio integer;
begin
  if p_grupo_id is null or p_fecha_desde is null or p_fecha_hasta is null
     or p_fecha_hasta < p_fecha_desde then
    raise exception 'El rango para calcular dias habiles no es valido';
  end if;

  for v_anio in
    select generate_series(
      extract(year from p_fecha_desde)::integer,
      extract(year from p_fecha_hasta)::integer
    )
  loop
    if not exists (
      select 1 from public.feriados_anios f
      where f.grupo_id = p_grupo_id and f.anio = v_anio
        and f.estado = 'confirmado'
    ) then
      raise exception 'Confirma el calendario de feriados del anio % antes de registrar la ausencia',
        v_anio;
    end if;
  end loop;
end;
$$;

create or replace function public.calcular_dias_habiles_v27(
  p_grupo_id uuid,
  p_fecha_desde date,
  p_fecha_hasta date,
  p_almacen_id uuid default null
) returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_total integer;
begin
  if not public.usuario_puede_nomina(false) then
    raise exception 'No tiene acceso al calendario de Nomina';
  end if;
  perform public.validar_calendarios_feriados_v27(
    p_grupo_id, p_fecha_desde, p_fecha_hasta
  );

  select count(*)::integer into v_total
  from generate_series(p_fecha_desde, p_fecha_hasta, interval '1 day') d(fecha)
  where extract(isodow from d.fecha) between 1 and 5
    and not exists (
      select 1
      from public.feriados f
      join public.feriados_anios fa on fa.id = f.feriados_anio_id
      where f.grupo_id = p_grupo_id
        and f.fecha = d.fecha::date
        and f.activo
        and fa.estado = 'confirmado'
        and (
          f.tipo = 'nacional'
          or (f.tipo = 'local' and f.almacen_id = p_almacen_id)
        )
    );
  return v_total;
end;
$$;

create or replace function public.configurar_feriados_v27(
  p_grupo_id uuid,
  p_anio integer,
  p_items jsonb,
  p_confirmar boolean,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_calendario_id uuid;
  v_total integer;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede configurar feriados';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  select id into v_evento_id
  from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true);
  end if;
  if p_anio is null or p_anio not between 2000 and 2200 then
    raise exception 'El anio del calendario no es valido';
  end if;
  if not exists (
    select 1 from public.grupos_economicos g
    where g.id = p_grupo_id and g.activo
  ) then
    raise exception 'El grupo economico no existe o esta inactivo';
  end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'La lista de feriados no es valida';
  end if;
  if coalesce(p_confirmar, false) and btrim(coalesce(p_nota, '')) = '' then
    raise exception 'La confirmacion del calendario requiere una nota de control';
  end if;
  if coalesce(p_confirmar, false) and not exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      fecha date, nombre text, tipo text, almacen_id uuid
    )
    where x.tipo = 'nacional'
  ) then
    raise exception 'Un calendario confirmado debe contener feriados nacionales';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      fecha date, nombre text, tipo text, almacen_id uuid
    )
    left join public.almacenes a on a.id = x.almacen_id and a.activo
    where x.fecha is null
       or extract(year from x.fecha)::integer <> p_anio
       or btrim(coalesce(x.nombre, '')) = ''
       or x.tipo not in ('nacional', 'local')
       or (x.tipo = 'nacional' and x.almacen_id is not null)
       or (x.tipo = 'local' and (x.almacen_id is null or a.id is null))
       or (x.tipo = 'local' and not exists (
         select 1
         from public.empresa_almacenes ea
         join public.empresas e on e.id = ea.empresa_id and e.activo
         where ea.almacen_id = x.almacen_id and e.grupo_id = p_grupo_id
       ))
  ) then
    raise exception 'Existe un feriado invalido o un almacen ajeno al grupo';
  end if;
  if exists (
    select fecha, tipo, almacen_id
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      fecha date, nombre text, tipo text, almacen_id uuid
    )
    group by fecha, tipo, almacen_id having count(*) > 1
  ) then
    raise exception 'La lista contiene feriados repetidos';
  end if;

  insert into public.feriados_anios as fa(
    grupo_id, anio, estado, nota, creado_por, confirmado_por, confirmado_at
  ) values (
    p_grupo_id, p_anio,
    case when coalesce(p_confirmar, false) then 'confirmado' else 'borrador' end,
    nullif(btrim(p_nota), ''), auth.uid(),
    case when coalesce(p_confirmar, false) then auth.uid() end,
    case when coalesce(p_confirmar, false) then now() end
  )
  on conflict (grupo_id, anio) do update
  set estado = excluded.estado,
      nota = excluded.nota,
      confirmado_por = excluded.confirmado_por,
      confirmado_at = excluded.confirmado_at,
      updated_at = now()
  returning id into v_calendario_id;

  update public.feriados
  set activo = false, actualizado_por = auth.uid(), updated_at = now()
  where feriados_anio_id = v_calendario_id;

  insert into public.feriados as f(
    feriados_anio_id, grupo_id, anio, fecha, nombre, tipo, almacen_id,
    activo, creado_por, actualizado_por
  )
  select v_calendario_id, p_grupo_id, p_anio, x.fecha,
         btrim(x.nombre), x.tipo, x.almacen_id, true, auth.uid(), auth.uid()
  from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
    fecha date, nombre text, tipo text, almacen_id uuid
  )
  where x.tipo = 'nacional'
  on conflict (grupo_id, fecha) where tipo = 'nacional' do update
  set feriados_anio_id = excluded.feriados_anio_id,
      anio = excluded.anio, nombre = excluded.nombre,
      activo = true, actualizado_por = auth.uid(), updated_at = now();

  -- Los feriados locales tienen una clave parcial distinta y se actualizan
  -- por separado para no confundir una fecha nacional con una local.
  insert into public.feriados as f(
    feriados_anio_id, grupo_id, anio, fecha, nombre, tipo, almacen_id,
    activo, creado_por, actualizado_por
  )
  select v_calendario_id, p_grupo_id, p_anio, x.fecha,
         btrim(x.nombre), x.tipo, x.almacen_id, true, auth.uid(), auth.uid()
  from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
    fecha date, nombre text, tipo text, almacen_id uuid
  )
  where x.tipo = 'local'
  on conflict (grupo_id, fecha, almacen_id) where tipo = 'local' do update
  set feriados_anio_id = excluded.feriados_anio_id,
      anio = excluded.anio, nombre = excluded.nombre,
      activo = true, actualizado_por = auth.uid(), updated_at = now();

  select count(*)::integer into v_total
  from public.feriados
  where feriados_anio_id = v_calendario_id and activo;

  insert into public.nomina_eventos(
    entidad, entidad_id, tipo, estado_nuevo, detalle, datos,
    usuario_id, idempotency_key
  ) values (
    'calendario_feriados', v_calendario_id,
    case when coalesce(p_confirmar, false) then 'calendario_confirmado'
      else 'calendario_guardado' end,
    case when coalesce(p_confirmar, false) then 'confirmado' else 'borrador' end,
    coalesce(nullif(btrim(p_nota), ''), 'Calendario de feriados actualizado'),
    jsonb_build_object('anio', p_anio, 'feriados_activos', v_total),
    auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;

  return jsonb_build_object(
    'calendario_id', v_calendario_id, 'evento_id', v_evento_id,
    'feriados_activos', v_total, 'confirmado', coalesce(p_confirmar, false),
    'duplicado', false
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Generacion de derechos por aniversario real
-- ------------------------------------------------------------
create or replace function public.asegurar_periodos_vacaciones_v27(
  p_empleado_id uuid,
  p_hasta date
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.empleados%rowtype;
  v_hasta date;
  v_anios integer;
  v_i integer;
  v_desde date;
  v_hasta_periodo date;
  v_edad integer;
  v_dias numeric(7,2);
  v_insertados integer := 0;
begin
  select * into e from public.empleados
  where id = p_empleado_id for update;
  if not found then raise exception 'El empleado no existe'; end if;
  if e.fecha_ingreso_real is null then
    raise exception 'El empleado no tiene fecha de ingreso real';
  end if;
  if e.tipo_contrato = 'servicios_profesionales' then
    raise exception 'Servicios profesionales no genera vacaciones laborales automaticamente';
  end if;
  v_hasta := least(coalesce(p_hasta, current_date), coalesce(e.fecha_salida, p_hasta, current_date));
  if v_hasta < e.fecha_ingreso_real then return 0; end if;
  v_anios := extract(year from age(v_hasta, e.fecha_ingreso_real))::integer;

  for v_i in 1..v_anios loop
    v_desde := (e.fecha_ingreso_real + make_interval(years => v_i - 1))::date;
    v_hasta_periodo := (e.fecha_ingreso_real + make_interval(years => v_i))::date - 1;
    v_edad := case when e.fecha_nacimiento is null then 99 else
      extract(year from age(v_hasta_periodo + 1, e.fecha_nacimiento))::integer end;
    v_dias := greatest(
      case when v_edad < 16 then 20 when v_edad < 18 then 18 else 15 end,
      least(30, 15 + greatest(v_i - 5, 0))
    );

    insert into public.vacaciones_periodos(
      empleado_id, periodo_desde, periodo_hasta, anos_servicio,
      dias_derecho, creado_por
    ) values (
      e.id, v_desde, v_hasta_periodo, v_i, v_dias, auth.uid()
    ) on conflict (empleado_id, anos_servicio) do nothing;
    if found then v_insertados := v_insertados + 1; end if;
  end loop;
  return v_insertados;
end;
$$;

create or replace function public.generar_periodos_vacaciones_v27(
  p_empleado_id uuid,
  p_hasta date,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.empleados%rowtype;
  v_insertados integer;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede generar periodos de vacaciones';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;
  select * into e from public.empleados where id = p_empleado_id;
  if not found then raise exception 'El empleado no existe'; end if;

  v_insertados := public.asegurar_periodos_vacaciones_v27(p_empleado_id, p_hasta);
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, detalle, datos,
    usuario_id, idempotency_key
  ) values (
    'periodos_vacaciones', e.id, e.id, 'periodos_generados',
    'Periodos de vacaciones generados por aniversario de ingreso real',
    jsonb_build_object('hasta', p_hasta, 'insertados', v_insertados),
    auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object(
    'empleado_id', e.id, 'periodos_insertados', v_insertados,
    'evento_id', v_evento_id, 'duplicado', false
  );
end;
$$;

-- ------------------------------------------------------------
-- 6. Solicitud, resolucion y anulacion compensatoria
-- ------------------------------------------------------------
create or replace function public.solicitar_ausencia_v27(
  p_empleado_id uuid,
  p_tipo text,
  p_fecha_desde date,
  p_fecha_hasta date,
  p_horas numeric,
  p_almacen_id uuid,
  p_documento_respaldo_id uuid,
  p_observacion text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.empleados%rowtype;
  v_ausencia_id uuid;
  v_dias_calendario numeric(7,2);
  v_dias_habiles numeric(7,2);
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede registrar ausencias';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_ausencia_id from public.ausencias
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_ausencia_id, 'duplicado', true,
      'mensaje', 'La solicitud ya estaba registrada');
  end if;
  if p_tipo not in (
    'vacaciones', 'enfermedad_iess', 'enfermedad_particular',
    'permiso_con_sueldo', 'permiso_sin_sueldo', 'maternidad',
    'paternidad', 'lactancia', 'calamidad_domestica',
    'falta_injustificada', 'suspension_disciplinaria'
  ) then raise exception 'El tipo de ausencia no es valido'; end if;
  if p_fecha_desde is null or p_fecha_hasta is null or p_fecha_hasta < p_fecha_desde then
    raise exception 'El rango de la ausencia no es valido';
  end if;
  if p_horas is not null and (p_horas <= 0 or p_horas > 24 or p_fecha_desde <> p_fecha_hasta) then
    raise exception 'Una ausencia por horas debe ocurrir en un solo dia y no superar 24 horas';
  end if;
  if p_tipo = 'vacaciones' and p_horas is not null then
    raise exception 'Las vacaciones se registran en dias calendario completos';
  end if;

  select * into e from public.empleados where id = p_empleado_id for update;
  if not found then raise exception 'El empleado no existe'; end if;
  if e.estado <> 'activo' then raise exception 'El empleado no esta activo'; end if;
  if p_tipo = 'vacaciones' and e.tipo_contrato = 'servicios_profesionales' then
    raise exception 'Servicios profesionales no genera vacaciones laborales automaticamente';
  end if;
  if p_fecha_desde < e.fecha_ingreso_real then
    raise exception 'La ausencia no puede iniciar antes del ingreso real';
  end if;
  if e.fecha_salida is not null and p_fecha_hasta > e.fecha_salida then
    raise exception 'La ausencia no puede terminar despues de la salida del empleado';
  end if;

  if p_almacen_id is not null and not exists (
    select 1
    from public.empresa_almacenes ea
    join public.empresas ep on ep.id = ea.empresa_id and ep.activo
    join public.almacenes a on a.id = ea.almacen_id and a.activo
    where ea.almacen_id = p_almacen_id and ep.grupo_id = e.grupo_id
  ) then raise exception 'El almacen de la ausencia no pertenece al grupo del empleado'; end if;

  if p_documento_respaldo_id is not null and not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_respaldo_id and d.empleado_id = e.id and d.activo
  ) then raise exception 'El documento de respaldo no pertenece al empleado o esta inactivo'; end if;
  if p_tipo in (
    'enfermedad_iess', 'enfermedad_particular', 'maternidad',
    'paternidad', 'calamidad_domestica', 'suspension_disciplinaria'
  ) and p_documento_respaldo_id is null then
    raise exception 'Este tipo de ausencia requiere un documento de respaldo';
  end if;
  if exists (
    select 1 from public.ausencias a
    where a.empleado_id = e.id and a.estado in ('solicitada', 'aprobada')
      and daterange(a.fecha_desde, a.fecha_hasta, '[]')
          && daterange(p_fecha_desde, p_fecha_hasta, '[]')
  ) then raise exception 'El empleado ya tiene una ausencia que se cruza con estas fechas'; end if;

  perform public.validar_calendarios_feriados_v27(
    e.grupo_id, p_fecha_desde, p_fecha_hasta
  );
  if p_horas is null then
    v_dias_calendario := p_fecha_hasta - p_fecha_desde + 1;
    v_dias_habiles := public.calcular_dias_habiles_v27(
      e.grupo_id, p_fecha_desde, p_fecha_hasta, p_almacen_id
    );
  else
    v_dias_calendario := 0;
    v_dias_habiles := 0;
  end if;

  insert into public.ausencias(
    grupo_id, empleado_id, almacen_id, tipo, fecha_desde, fecha_hasta,
    horas, dias_calendario, dias_habiles, documento_respaldo_id,
    observacion, idempotency_key, solicitado_por
  ) values (
    e.grupo_id, e.id, p_almacen_id, p_tipo, p_fecha_desde, p_fecha_hasta,
    p_horas, v_dias_calendario, v_dias_habiles, p_documento_respaldo_id,
    nullif(btrim(p_observacion), ''), p_idempotency_key, auth.uid()
  ) returning id into v_ausencia_id;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_nuevo, detalle,
    datos, usuario_id, idempotency_key
  ) values (
    'ausencia', v_ausencia_id, e.id, 'solicitada', 'Solicitud de ausencia registrada',
    jsonb_build_object(
      'tipo', p_tipo, 'fecha_desde', p_fecha_desde,
      'fecha_hasta', p_fecha_hasta, 'horas', p_horas,
      'dias_calendario', v_dias_calendario, 'dias_habiles', v_dias_habiles
    ), auth.uid(), gen_random_uuid()
  ) returning id into v_evento_id;

  return jsonb_build_object(
    'id', v_ausencia_id, 'evento_id', v_evento_id,
    'dias_calendario', v_dias_calendario, 'dias_habiles', v_dias_habiles,
    'duplicado', false, 'mensaje', 'Solicitud registrada para aprobacion'
  );
end;
$$;

create or replace function public.resolver_ausencia_v27(
  p_ausencia_id uuid,
  p_aprobar boolean,
  p_observacion text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.ausencias%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_evento_id uuid;
  v_restante numeric(7,2);
  v_aplicar numeric(7,2);
  v_orden integer := 0;
  v_primero uuid;
  p record;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede resolver ausencias';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;

  select * into a from public.ausencias where id = p_ausencia_id for update;
  if not found then raise exception 'La ausencia no existe'; end if;
  perform 1 from public.empleados where id = a.empleado_id for update;
  if a.estado <> 'solicitada' then raise exception 'La ausencia ya fue resuelta'; end if;
  if coalesce(p_aprobar, false) and a.solicitado_por = auth.uid() and v_rol <> 'admin' then
    raise exception 'Quien solicita una ausencia no puede aprobarla';
  end if;
  if coalesce(p_aprobar, false) and a.solicitado_por = auth.uid()
     and v_rol = 'admin' and length(btrim(coalesce(p_observacion, ''))) < 10 then
    raise exception 'La excepcion de autoaprobacion Admin requiere una justificacion de al menos 10 caracteres';
  end if;

  if not coalesce(p_aprobar, false) then
    if btrim(coalesce(p_observacion, '')) = '' then
      raise exception 'El rechazo requiere un motivo';
    end if;
    update public.ausencias
    set estado = 'rechazada', rechazado_por = auth.uid(), rechazado_at = now(),
        motivo_resolucion = btrim(p_observacion), version = version + 1,
        updated_at = now()
    where id = a.id;
    insert into public.nomina_eventos(
      entidad, entidad_id, empleado_id, tipo, estado_anterior,
      estado_nuevo, detalle, usuario_id, idempotency_key
    ) values (
      'ausencia', a.id, a.empleado_id, 'rechazada', 'solicitada', 'rechazada',
      btrim(p_observacion), auth.uid(), p_idempotency_key
    ) returning id into v_evento_id;
    return jsonb_build_object('id', a.id, 'evento_id', v_evento_id,
      'estado', 'rechazada', 'duplicado', false);
  end if;

  if exists (
    select 1 from public.ausencias otra
    where otra.empleado_id = a.empleado_id and otra.id <> a.id
      and otra.estado = 'aprobada'
      and daterange(otra.fecha_desde, otra.fecha_hasta, '[]')
          && daterange(a.fecha_desde, a.fecha_hasta, '[]')
  ) then raise exception 'Existe otra ausencia aprobada que se cruza con estas fechas'; end if;

  if a.tipo = 'vacaciones' then
    perform public.asegurar_periodos_vacaciones_v27(a.empleado_id, a.fecha_desde);
    v_restante := a.dias_calendario;
    for p in
      select vp.id, vp.dias_saldo
      from public.vacaciones_periodos vp
      where vp.empleado_id = a.empleado_id
        and vp.estado in ('abierto', 'agotado')
        and vp.dias_saldo > 0
        and vp.periodo_hasta < a.fecha_desde
      order by vp.periodo_desde, vp.id
      for update
    loop
      exit when v_restante <= 0;
      v_aplicar := least(v_restante, p.dias_saldo);
      v_orden := v_orden + 1;
      if v_primero is null then v_primero := p.id; end if;
      insert into public.ausencia_vacaciones_aplicaciones(
        ausencia_id, vacaciones_periodo_id, orden_fifo,
        dias_aplicados, aplicado_por
      ) values (a.id, p.id, v_orden, v_aplicar, auth.uid());
      update public.vacaciones_periodos
      set dias_tomados = dias_tomados + v_aplicar,
          estado = case when dias_derecho = dias_tomados + dias_pagados + v_aplicar
            then 'agotado' else 'abierto' end,
          updated_at = now()
      where id = p.id;
      v_restante := v_restante - v_aplicar;
    end loop;
    if v_restante > 0 then
      raise exception 'Saldo vacacional insuficiente. Faltan % dias calendario', v_restante;
    end if;
  end if;

  update public.ausencias
  set estado = 'aprobada', aprobado_por = auth.uid(), aprobado_at = now(),
      motivo_resolucion = nullif(btrim(p_observacion), ''),
      vacaciones_periodo_id = v_primero,
      version = version + 1, updated_at = now()
  where id = a.id;
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior,
    estado_nuevo, detalle, datos, usuario_id, idempotency_key
  ) values (
    'ausencia', a.id, a.empleado_id, 'aprobada', 'solicitada', 'aprobada',
    coalesce(nullif(btrim(p_observacion), ''), 'Ausencia aprobada'),
    jsonb_build_object('periodos_fifo', v_orden, 'dias_vacaciones',
      case when a.tipo = 'vacaciones' then a.dias_calendario else 0 end,
      'excepcion_admin', a.solicitado_por = auth.uid()),
    auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object('id', a.id, 'evento_id', v_evento_id,
    'estado', 'aprobada', 'periodos_fifo', v_orden, 'duplicado', false);
end;
$$;

create or replace function public.anular_ausencia_v27(
  p_ausencia_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.ausencias%rowtype;
  ap record;
  v_restituidos numeric(7,2) := 0;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede anular ausencias';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La anulacion requiere un motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;

  select * into a from public.ausencias where id = p_ausencia_id for update;
  if not found then raise exception 'La ausencia no existe'; end if;
  perform 1 from public.empleados where id = a.empleado_id for update;
  if a.estado not in ('solicitada', 'aprobada') then
    raise exception 'Solo una ausencia solicitada o aprobada puede anularse';
  end if;

  if a.estado = 'aprobada' and a.tipo = 'vacaciones' then
    for ap in
      select av.id, av.vacaciones_periodo_id, av.dias_aplicados
      from public.ausencia_vacaciones_aplicaciones av
      where av.ausencia_id = a.id and av.estado = 'aplicada'
      order by av.orden_fifo desc
      for update
    loop
      perform 1 from public.vacaciones_periodos
      where id = ap.vacaciones_periodo_id for update;
      update public.vacaciones_periodos
      set dias_tomados = dias_tomados - ap.dias_aplicados,
          estado = case when estado in ('liquidado', 'caducado') then estado
            else 'abierto' end,
          updated_at = now()
      where id = ap.vacaciones_periodo_id;
      update public.ausencia_vacaciones_aplicaciones
      set estado = 'revertida', revertido_por = auth.uid(), revertido_at = now(),
          motivo_reversion = btrim(p_motivo)
      where id = ap.id;
      v_restituidos := v_restituidos + ap.dias_aplicados;
    end loop;
  end if;

  update public.ausencias
  set estado = 'anulada', anulado_por = auth.uid(), anulado_at = now(),
      motivo_anulacion = btrim(p_motivo), version = version + 1,
      updated_at = now()
  where id = a.id;
  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior,
    estado_nuevo, detalle, datos, usuario_id, idempotency_key
  ) values (
    'ausencia', a.id, a.empleado_id, 'anulada', a.estado, 'anulada',
    btrim(p_motivo), jsonb_build_object('dias_restituidos', v_restituidos),
    auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;
  return jsonb_build_object('id', a.id, 'evento_id', v_evento_id,
    'estado', 'anulada', 'dias_restituidos', v_restituidos, 'duplicado', false);
end;
$$;

-- ------------------------------------------------------------
-- 7. Vistas de control para v30 y futura interfaz v31
-- ------------------------------------------------------------
create or replace view public.vista_saldos_vacaciones_v27
with (security_invoker = true) as
select
  e.id as empleado_id,
  e.grupo_id,
  e.identificacion,
  e.apellidos,
  e.nombres,
  e.fecha_ingreso_real,
  coalesce(sum(vp.dias_derecho), 0)::numeric(9,2) as dias_derecho,
  coalesce(sum(vp.dias_tomados), 0)::numeric(9,2) as dias_tomados,
  coalesce(sum(vp.dias_pagados), 0)::numeric(9,2) as dias_pagados,
  coalesce(sum(vp.dias_saldo), 0)::numeric(9,2) as dias_saldo,
  count(vp.id) filter (where vp.dias_saldo > 0) as periodos_con_saldo,
  min(vp.periodo_desde) filter (where vp.dias_saldo > 0) as saldo_mas_antiguo_desde,
  count(vp.id) filter (where vp.dias_saldo > 0) > 3 as alerta_mas_tres_periodos
from public.empleados e
left join public.vacaciones_periodos vp on vp.empleado_id = e.id
  and vp.estado not in ('liquidado', 'caducado')
group by e.id;

create or replace view public.vista_ausencias_v27
with (security_invoker = true) as
select
  a.id,
  a.grupo_id,
  a.empleado_id,
  e.identificacion,
  e.apellidos,
  e.nombres,
  a.almacen_id,
  al.nombre as almacen,
  a.tipo,
  a.fecha_desde,
  a.fecha_hasta,
  a.horas,
  a.dias_calendario,
  a.dias_habiles,
  a.estado,
  a.documento_respaldo_id,
  a.observacion,
  a.solicitado_por,
  a.aprobado_por,
  a.solicitado_at,
  a.aprobado_at,
  coalesce(sum(av.dias_aplicados) filter (where av.estado = 'aplicada'), 0)::numeric(9,2)
    as dias_vacaciones_aplicados,
  count(av.id) filter (where av.estado = 'aplicada') as periodos_fifo_usados
from public.ausencias a
join public.empleados e on e.id = a.empleado_id
left join public.almacenes al on al.id = a.almacen_id
left join public.ausencia_vacaciones_aplicaciones av on av.ausencia_id = a.id
group by a.id, e.id, al.id;

-- ------------------------------------------------------------
-- 8. Propiedad, privilegios y recarga de PostgREST
-- ------------------------------------------------------------
alter function public.validar_calendarios_feriados_v27(uuid, date, date) owner to postgres;
alter function public.calcular_dias_habiles_v27(uuid, date, date, uuid) owner to postgres;
alter function public.configurar_feriados_v27(uuid, integer, jsonb, boolean, text, uuid) owner to postgres;
alter function public.asegurar_periodos_vacaciones_v27(uuid, date) owner to postgres;
alter function public.generar_periodos_vacaciones_v27(uuid, date, uuid) owner to postgres;
alter function public.solicitar_ausencia_v27(uuid, text, date, date, numeric, uuid, uuid, text, uuid) owner to postgres;
alter function public.resolver_ausencia_v27(uuid, boolean, text, uuid) owner to postgres;
alter function public.anular_ausencia_v27(uuid, text, uuid) owner to postgres;

revoke all on public.feriados_anios from public, anon;
revoke all on public.feriados from public, anon;
revoke all on public.vacaciones_periodos from public, anon;
revoke all on public.ausencias from public, anon;
revoke all on public.ausencia_vacaciones_aplicaciones from public, anon;
revoke insert, update, delete on public.feriados_anios from authenticated;
revoke insert, update, delete on public.feriados from authenticated;
revoke insert, update, delete on public.vacaciones_periodos from authenticated;
revoke insert, update, delete on public.ausencias from authenticated;
revoke insert, update, delete on public.ausencia_vacaciones_aplicaciones from authenticated;
grant select on public.feriados_anios to authenticated;
grant select on public.feriados to authenticated;
grant select on public.vacaciones_periodos to authenticated;
grant select on public.ausencias to authenticated;
grant select on public.ausencia_vacaciones_aplicaciones to authenticated;
grant select on public.vista_saldos_vacaciones_v27 to authenticated;
grant select on public.vista_ausencias_v27 to authenticated;

revoke execute on function public.validar_calendarios_feriados_v27(uuid, date, date)
  from public, anon, authenticated;
revoke execute on function public.calcular_dias_habiles_v27(uuid, date, date, uuid)
  from public, anon;
revoke execute on function public.configurar_feriados_v27(uuid, integer, jsonb, boolean, text, uuid)
  from public, anon;
revoke execute on function public.asegurar_periodos_vacaciones_v27(uuid, date)
  from public, anon, authenticated;
revoke execute on function public.generar_periodos_vacaciones_v27(uuid, date, uuid)
  from public, anon;
revoke execute on function public.solicitar_ausencia_v27(uuid, text, date, date, numeric, uuid, uuid, text, uuid)
  from public, anon;
revoke execute on function public.resolver_ausencia_v27(uuid, boolean, text, uuid)
  from public, anon;
revoke execute on function public.anular_ausencia_v27(uuid, text, uuid)
  from public, anon;
grant execute on function public.calcular_dias_habiles_v27(uuid, date, date, uuid)
  to authenticated;
grant execute on function public.configurar_feriados_v27(uuid, integer, jsonb, boolean, text, uuid)
  to authenticated;
grant execute on function public.generar_periodos_vacaciones_v27(uuid, date, uuid)
  to authenticated;
grant execute on function public.solicitar_ausencia_v27(uuid, text, date, date, numeric, uuid, uuid, text, uuid)
  to authenticated;
grant execute on function public.resolver_ausencia_v27(uuid, boolean, text, uuid)
  to authenticated;
grant execute on function public.anular_ausencia_v27(uuid, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';
