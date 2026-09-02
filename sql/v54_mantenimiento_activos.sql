-- ============================================================
-- BOMAN INVENTARIO - v54: mantenimiento de maquinaria y activos
--
-- Registro maestro, plan preventivo simple, ordenes de trabajo, costos,
-- tiempo detenido, trazabilidad y alertas en el centro de notificaciones.
-- Ejecutar una sola vez DESPUES de v53.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Permisos configurables
-- ------------------------------------------------------------
insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('mantenimiento.acceder', 'Mantenimiento', 'Consultar activos y mantenimiento',
   'Consulta maquinaria, activos, vencimientos y ordenes de trabajo.', 150),
  ('mantenimiento.editar', 'Mantenimiento', 'Gestionar mantenimiento',
   'Crea activos, programa ordenes y registra ejecucion, costos y cierres.', 151)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.activo
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos
set permitido = true, updated_at = now()
where permiso_codigo = 'mantenimiento.acceder'
  and rol::text in ('bodega', 'logistica', 'gerencia', 'control');

update public.rol_permisos
set permitido = true, updated_at = now()
where permiso_codigo = 'mantenimiento.editar'
  and rol::text in ('bodega', 'logistica', 'control');

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

-- ------------------------------------------------------------
-- 2. Maestro y ordenes
-- ------------------------------------------------------------
create table if not exists public.activos_mantenimiento (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  almacen_id uuid references public.almacenes(id) on delete restrict,
  codigo text not null check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  categoria text not null check (categoria in (
    'maquinaria', 'vehiculo', 'equipo', 'herramienta', 'infraestructura', 'otro'
  )),
  marca text,
  modelo text,
  numero_serie text,
  ubicacion text,
  responsable_id uuid references public.perfiles(id) on delete set null,
  criticidad text not null default 'media'
    check (criticidad in ('baja', 'media', 'alta', 'critica')),
  estado text not null default 'operativo'
    check (estado in ('operativo', 'detenido', 'mantenimiento', 'fuera_servicio', 'baja')),
  fecha_adquisicion date,
  valor_adquisicion numeric(14,2) check (valor_adquisicion is null or valor_adquisicion >= 0),
  garantia_hasta date,
  tipo_medidor text not null default 'ninguno'
    check (tipo_medidor in ('ninguno', 'horas', 'kilometros', 'ciclos')),
  lectura_actual numeric(14,2) not null default 0 check (lectura_actual >= 0),
  frecuencia_mantenimiento_dias integer
    check (frecuencia_mantenimiento_dias is null or frecuencia_mantenimiento_dias > 0),
  frecuencia_mantenimiento_uso numeric(14,2)
    check (frecuencia_mantenimiento_uso is null or frecuencia_mantenimiento_uso > 0),
  ultimo_mantenimiento_fecha date,
  ultima_lectura_mantenimiento numeric(14,2)
    check (ultima_lectura_mantenimiento is null or ultima_lectura_mantenimiento >= 0),
  proximo_mantenimiento_fecha date,
  proxima_lectura_mantenimiento numeric(14,2)
    check (proxima_lectura_mantenimiento is null or proxima_lectura_mantenimiento >= 0),
  notas text,
  activo boolean not null default true,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, codigo)
);

create sequence if not exists public.orden_mantenimiento_numero_v54_seq;

create table if not exists public.ordenes_mantenimiento (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  activo_id uuid not null references public.activos_mantenimiento(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  almacen_id uuid references public.almacenes(id) on delete restrict,
  tipo text not null check (tipo in ('preventivo', 'correctivo', 'inspeccion', 'calibracion')),
  prioridad text not null default 'normal'
    check (prioridad in ('baja', 'normal', 'alta', 'urgente')),
  estado text not null default 'solicitada'
    check (estado in ('solicitada', 'programada', 'en_proceso', 'en_espera', 'completada', 'cancelada')),
  fecha_solicitud date not null default ((now() at time zone 'America/Guayaquil')::date),
  fecha_programada date,
  inicio_at timestamptz,
  fin_at timestamptz,
  descripcion text not null check (btrim(descripcion) <> ''),
  diagnostico text,
  trabajo_realizado text,
  proveedor text,
  responsable_id uuid references public.perfiles(id) on delete set null,
  costo_estimado numeric(14,2) not null default 0 check (costo_estimado >= 0),
  costo_real numeric(14,2) check (costo_real is null or costo_real >= 0),
  minutos_fuera_servicio integer check (minutos_fuera_servicio is null or minutos_fuera_servicio >= 0),
  lectura_cierre numeric(14,2) check (lectura_cierre is null or lectura_cierre >= 0),
  cancelacion_motivo text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mantenimiento_eventos (
  id uuid primary key default gen_random_uuid(),
  entidad_tipo text not null check (entidad_tipo in ('activo', 'orden')),
  entidad_id uuid not null,
  tipo text not null check (btrim(tipo) <> ''),
  estado_anterior text,
  estado_nuevo text,
  detalle text not null check (btrim(detalle) <> ''),
  datos jsonb not null default '{}'::jsonb,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_activos_mantenimiento_empresa_v54
  on public.activos_mantenimiento(empresa_id, estado, activo);
create index if not exists idx_activos_mantenimiento_almacen_v54
  on public.activos_mantenimiento(almacen_id, activo);
create index if not exists idx_activos_mantenimiento_proximo_v54
  on public.activos_mantenimiento(proximo_mantenimiento_fecha)
  where activo and estado <> 'baja';
create index if not exists idx_ordenes_mantenimiento_activo_v54
  on public.ordenes_mantenimiento(activo_id, created_at desc);
create index if not exists idx_ordenes_mantenimiento_pendientes_v54
  on public.ordenes_mantenimiento(fecha_programada, prioridad)
  where estado in ('solicitada', 'programada', 'en_proceso', 'en_espera');
create index if not exists idx_mantenimiento_eventos_entidad_v54
  on public.mantenimiento_eventos(entidad_tipo, entidad_id, created_at desc);

-- ------------------------------------------------------------
-- 3. Alcance y vistas
-- ------------------------------------------------------------
create or replace function public.puede_ver_activo_mantenimiento_v54(
  p_activo_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.activos_mantenimiento a
    where a.id = p_activo_id
      and public.usuario_tiene_permiso_v35(
        case when p_escritura then 'mantenimiento.editar' else 'mantenimiento.acceder' end
      )
      and (
        public.usuario_puede_empresa(a.empresa_id, p_escritura)
        or (a.almacen_id is not null and public.usuario_puede_almacen(a.almacen_id, p_escritura))
      )
  );
$$;

create or replace view public.vista_activos_mantenimiento_v54
with (security_invoker = true) as
select
  a.*,
  e.codigo as empresa_codigo,
  e.razon_social as empresa,
  al.nombre as almacen,
  p.nombre_completo as responsable,
  case
    when not a.activo or a.estado = 'baja' then 'inactivo'
    when a.proximo_mantenimiento_fecha < (now() at time zone 'America/Guayaquil')::date
      or (a.proxima_lectura_mantenimiento is not null
        and a.lectura_actual >= a.proxima_lectura_mantenimiento) then 'vencido'
    when a.proximo_mantenimiento_fecha <= (now() at time zone 'America/Guayaquil')::date + 30
      or (a.proxima_lectura_mantenimiento is not null
        and a.lectura_actual >= a.proxima_lectura_mantenimiento * 0.9) then 'proximo'
    when a.proximo_mantenimiento_fecha is null
      and a.proxima_lectura_mantenimiento is null then 'sin_plan'
    else 'al_dia'
  end as estado_plan,
  (select count(*)
   from public.ordenes_mantenimiento o
   where o.activo_id = a.id
     and o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')) as ordenes_abiertas
from public.activos_mantenimiento a
join public.empresas e on e.id = a.empresa_id
left join public.almacenes al on al.id = a.almacen_id
left join public.perfiles p on p.id = a.responsable_id;

create or replace view public.vista_ordenes_mantenimiento_v54
with (security_invoker = true) as
select
  o.*,
  a.codigo as activo_codigo,
  a.nombre as activo_nombre,
  a.categoria as activo_categoria,
  a.criticidad as activo_criticidad,
  e.codigo as empresa_codigo,
  e.razon_social as empresa,
  al.nombre as almacen,
  p.nombre_completo as responsable,
  case when o.estado in ('solicitada', 'programada')
      and o.fecha_programada < (now() at time zone 'America/Guayaquil')::date
    then true else false end as atrasada
from public.ordenes_mantenimiento o
join public.activos_mantenimiento a on a.id = o.activo_id
join public.empresas e on e.id = o.empresa_id
left join public.almacenes al on al.id = o.almacen_id
left join public.perfiles p on p.id = o.responsable_id;

-- ------------------------------------------------------------
-- 4. RPC de activos
-- ------------------------------------------------------------
create or replace function public.guardar_activo_mantenimiento_v54(
  p_id uuid,
  p_datos jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_empresa uuid := nullif(p_datos->>'empresa_id', '')::uuid;
  v_almacen uuid := nullif(p_datos->>'almacen_id', '')::uuid;
  v_grupo uuid;
  v_anterior public.activos_mantenimiento%rowtype;
begin
  if v_uid is null or not public.usuario_tiene_permiso_v35('mantenimiento.editar') then
    raise exception 'No tienes permiso para gestionar activos';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'El motivo es obligatorio'; end if;

  select me.entidad_id into v_id
  from public.mantenimiento_eventos me
  where me.idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  if btrim(coalesce(p_datos->>'codigo', '')) = ''
     or btrim(coalesce(p_datos->>'nombre', '')) = '' then
    raise exception 'El codigo y el nombre son obligatorios';
  end if;
  if coalesce(p_datos->>'categoria', '') not in
     ('maquinaria', 'vehiculo', 'equipo', 'herramienta', 'infraestructura', 'otro') then
    raise exception 'Categoria de activo no valida';
  end if;
  if coalesce(p_datos->>'criticidad', 'media') not in ('baja', 'media', 'alta', 'critica') then
    raise exception 'Criticidad no valida';
  end if;
  if coalesce(p_datos->>'estado', 'operativo') not in
     ('operativo', 'detenido', 'mantenimiento', 'fuera_servicio', 'baja') then
    raise exception 'Estado del activo no valido';
  end if;

  select e.grupo_id into v_grupo
  from public.empresas e
  where e.id = v_empresa and e.activo
    and public.usuario_puede_empresa(e.id, true);
  if not found then raise exception 'La empresa no existe o no puedes operarla'; end if;

  if v_almacen is not null and (
    not public.usuario_puede_almacen(v_almacen, true)
    or not exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = v_empresa and ea.almacen_id = v_almacen
    )
  ) then raise exception 'El almacen no pertenece a la empresa o no puedes operarlo'; end if;

  if p_id is null then
    insert into public.activos_mantenimiento (
      grupo_id, empresa_id, almacen_id, codigo, nombre, categoria,
      marca, modelo, numero_serie, ubicacion, responsable_id, criticidad, estado,
      fecha_adquisicion, valor_adquisicion, garantia_hasta, tipo_medidor,
      lectura_actual, frecuencia_mantenimiento_dias, frecuencia_mantenimiento_uso,
      proximo_mantenimiento_fecha, proxima_lectura_mantenimiento, notas,
      creado_por, actualizado_por
    ) values (
      v_grupo, v_empresa, v_almacen, upper(btrim(p_datos->>'codigo')),
      btrim(p_datos->>'nombre'), p_datos->>'categoria',
      nullif(btrim(p_datos->>'marca'), ''), nullif(btrim(p_datos->>'modelo'), ''),
      nullif(btrim(p_datos->>'numero_serie'), ''), nullif(btrim(p_datos->>'ubicacion'), ''),
      nullif(p_datos->>'responsable_id', '')::uuid,
      coalesce(p_datos->>'criticidad', 'media'), coalesce(p_datos->>'estado', 'operativo'),
      nullif(p_datos->>'fecha_adquisicion', '')::date,
      nullif(p_datos->>'valor_adquisicion', '')::numeric,
      nullif(p_datos->>'garantia_hasta', '')::date,
      coalesce(p_datos->>'tipo_medidor', 'ninguno'),
      coalesce(nullif(p_datos->>'lectura_actual', '')::numeric, 0),
      nullif(p_datos->>'frecuencia_mantenimiento_dias', '')::integer,
      nullif(p_datos->>'frecuencia_mantenimiento_uso', '')::numeric,
      nullif(p_datos->>'proximo_mantenimiento_fecha', '')::date,
      nullif(p_datos->>'proxima_lectura_mantenimiento', '')::numeric,
      nullif(btrim(p_datos->>'notas'), ''), v_uid, v_uid
    ) returning id into v_id;
  else
    select * into v_anterior
    from public.activos_mantenimiento a
    where a.id = p_id for update;
    if not found or not public.puede_ver_activo_mantenimiento_v54(p_id, true) then
      raise exception 'El activo no existe o no puedes modificarlo';
    end if;
    if (v_anterior.empresa_id <> v_empresa
        or v_anterior.almacen_id is distinct from v_almacen)
       and exists (
         select 1 from public.ordenes_mantenimiento o
         where o.activo_id = p_id
           and o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
       ) then
      raise exception 'No puedes cambiar empresa o almacen mientras exista una orden abierta';
    end if;

    update public.activos_mantenimiento set
      grupo_id = v_grupo, empresa_id = v_empresa, almacen_id = v_almacen,
      codigo = upper(btrim(p_datos->>'codigo')), nombre = btrim(p_datos->>'nombre'),
      categoria = p_datos->>'categoria', marca = nullif(btrim(p_datos->>'marca'), ''),
      modelo = nullif(btrim(p_datos->>'modelo'), ''),
      numero_serie = nullif(btrim(p_datos->>'numero_serie'), ''),
      ubicacion = nullif(btrim(p_datos->>'ubicacion'), ''),
      responsable_id = nullif(p_datos->>'responsable_id', '')::uuid,
      criticidad = coalesce(p_datos->>'criticidad', 'media'),
      estado = coalesce(p_datos->>'estado', 'operativo'),
      fecha_adquisicion = nullif(p_datos->>'fecha_adquisicion', '')::date,
      valor_adquisicion = nullif(p_datos->>'valor_adquisicion', '')::numeric,
      garantia_hasta = nullif(p_datos->>'garantia_hasta', '')::date,
      tipo_medidor = coalesce(p_datos->>'tipo_medidor', 'ninguno'),
      lectura_actual = coalesce(nullif(p_datos->>'lectura_actual', '')::numeric, 0),
      frecuencia_mantenimiento_dias = nullif(p_datos->>'frecuencia_mantenimiento_dias', '')::integer,
      frecuencia_mantenimiento_uso = nullif(p_datos->>'frecuencia_mantenimiento_uso', '')::numeric,
      proximo_mantenimiento_fecha = nullif(p_datos->>'proximo_mantenimiento_fecha', '')::date,
      proxima_lectura_mantenimiento = nullif(p_datos->>'proxima_lectura_mantenimiento', '')::numeric,
      notas = nullif(btrim(p_datos->>'notas'), ''),
      activo = coalesce((p_datos->>'activo')::boolean, activo),
      actualizado_por = v_uid, updated_at = now()
    where id = p_id returning id into v_id;
  end if;

  insert into public.mantenimiento_eventos (
    entidad_tipo, entidad_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    'activo', v_id, case when p_id is null then 'activo_creado' else 'activo_actualizado' end,
    case when p_id is null then null else v_anterior.estado end,
    coalesce(p_datos->>'estado', 'operativo'), btrim(p_motivo), p_datos,
    v_uid, p_idempotency_key
  );
  return v_id;
end;
$fn$;

-- ------------------------------------------------------------
-- 5. RPC de ordenes y flujo controlado
-- ------------------------------------------------------------
create or replace function public.crear_orden_mantenimiento_v54(
  p_activo_id uuid,
  p_tipo text,
  p_prioridad text,
  p_fecha_programada date,
  p_descripcion text,
  p_responsable_id uuid,
  p_costo_estimado numeric,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_activo public.activos_mantenimiento%rowtype;
  v_numero text;
begin
  if v_uid is null or not public.puede_ver_activo_mantenimiento_v54(p_activo_id, true) then
    raise exception 'No tienes permiso para programar este activo';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select me.entidad_id into v_id from public.mantenimiento_eventos me
  where me.idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  if p_tipo not in ('preventivo', 'correctivo', 'inspeccion', 'calibracion') then
    raise exception 'Tipo de mantenimiento no valido';
  end if;
  if p_prioridad not in ('baja', 'normal', 'alta', 'urgente') then
    raise exception 'Prioridad no valida';
  end if;
  if btrim(coalesce(p_descripcion, '')) = '' then
    raise exception 'La descripcion del trabajo es obligatoria';
  end if;
  if coalesce(p_costo_estimado, 0) < 0 then raise exception 'El costo no puede ser negativo'; end if;

  select * into v_activo from public.activos_mantenimiento
  where id = p_activo_id and activo and estado <> 'baja' for update;
  if not found then raise exception 'El activo esta inactivo o dado de baja'; end if;

  if exists (
    select 1 from public.ordenes_mantenimiento o
    where o.activo_id = p_activo_id
      and o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
  ) then raise exception 'El activo ya tiene una orden de mantenimiento abierta'; end if;

  v_numero := 'MT-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY') || '-' ||
    lpad(nextval('public.orden_mantenimiento_numero_v54_seq')::text, 6, '0');

  insert into public.ordenes_mantenimiento (
    numero, activo_id, empresa_id, almacen_id, tipo, prioridad,
    fecha_programada, descripcion, responsable_id, costo_estimado,
    creado_por, actualizado_por
  ) values (
    v_numero, p_activo_id, v_activo.empresa_id, v_activo.almacen_id,
    p_tipo, p_prioridad, p_fecha_programada, btrim(p_descripcion),
    p_responsable_id, coalesce(p_costo_estimado, 0), v_uid, v_uid
  ) returning id into v_id;

  insert into public.mantenimiento_eventos (
    entidad_tipo, entidad_id, tipo, estado_nuevo, detalle, datos,
    usuario_id, idempotency_key
  ) values (
    'orden', v_id, 'orden_creada', 'solicitada',
    'Orden ' || v_numero || ' creada para ' || v_activo.codigo,
    jsonb_build_object('activo_id', p_activo_id, 'tipo', p_tipo,
      'prioridad', p_prioridad, 'fecha_programada', p_fecha_programada),
    v_uid, p_idempotency_key
  );

  insert into public.notificaciones_comunicados as n (
    origen_clave, origen_tipo, grupo_id, empresa_id, almacen_id,
    permiso_requerido, modulo, nivel, titulo, mensaje, href, creado_por
  ) values (
    'mantenimiento:orden:' || v_id::text, 'mantenimiento_orden', v_activo.grupo_id,
    v_activo.empresa_id, v_activo.almacen_id, 'mantenimiento.acceder',
    'Mantenimiento', case when p_prioridad = 'urgente' then 'critica' else 'accion' end,
    'Orden ' || v_numero || ' · ' || v_activo.codigo,
    btrim(p_descripcion), '/mantenimiento', v_uid
  ) on conflict (origen_clave) do update set
    activo = true, nivel = excluded.nivel, titulo = excluded.titulo,
    mensaje = excluded.mensaje, updated_at = now();
  return v_id;
end;
$fn$;

create or replace function public.cambiar_estado_orden_mantenimiento_v54(
  p_orden_id uuid,
  p_estado text,
  p_datos jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_orden public.ordenes_mantenimiento%rowtype;
  v_activo public.activos_mantenimiento%rowtype;
  v_id uuid;
  v_costo numeric;
  v_lectura numeric;
  v_trabajo text;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'El motivo es obligatorio'; end if;
  select me.entidad_id into v_id from public.mantenimiento_eventos me
  where me.idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  select * into v_orden from public.ordenes_mantenimiento
  where id = p_orden_id for update;
  if not found or not public.puede_ver_activo_mantenimiento_v54(v_orden.activo_id, true) then
    raise exception 'La orden no existe o no puedes modificarla';
  end if;
  if p_estado not in ('programada', 'en_proceso', 'en_espera', 'completada', 'cancelada') then
    raise exception 'Estado destino no valido';
  end if;
  if not (
    (v_orden.estado = 'solicitada' and p_estado in ('programada', 'en_proceso', 'cancelada'))
    or (v_orden.estado = 'programada' and p_estado in ('en_proceso', 'cancelada'))
    or (v_orden.estado = 'en_proceso' and p_estado in ('en_espera', 'completada', 'cancelada'))
    or (v_orden.estado = 'en_espera' and p_estado in ('en_proceso', 'completada', 'cancelada'))
  ) then raise exception 'Transicion no permitida de % a %', v_orden.estado, p_estado; end if;

  select * into v_activo from public.activos_mantenimiento
  where id = v_orden.activo_id for update;
  v_costo := nullif(p_datos->>'costo_real', '')::numeric;
  v_lectura := nullif(p_datos->>'lectura_cierre', '')::numeric;
  v_trabajo := nullif(btrim(p_datos->>'trabajo_realizado'), '');

  if p_estado = 'completada' and v_trabajo is null then
    raise exception 'Describe el trabajo realizado antes de completar';
  end if;
  if coalesce(v_costo, 0) < 0 then raise exception 'El costo real no puede ser negativo'; end if;
  if v_lectura is not null and v_lectura < v_activo.lectura_actual then
    raise exception 'La lectura de cierre no puede ser menor a la lectura actual';
  end if;
  if p_estado = 'cancelada' and btrim(coalesce(p_datos->>'cancelacion_motivo', '')) = '' then
    raise exception 'La cancelacion exige una justificacion';
  end if;

  update public.ordenes_mantenimiento set
    estado = p_estado,
    fecha_programada = case when p_estado = 'programada'
      then coalesce(nullif(p_datos->>'fecha_programada', '')::date, fecha_programada)
      else fecha_programada end,
    inicio_at = case when p_estado = 'en_proceso' then coalesce(inicio_at, now()) else inicio_at end,
    fin_at = case when p_estado in ('completada', 'cancelada') then now() else fin_at end,
    diagnostico = coalesce(nullif(btrim(p_datos->>'diagnostico'), ''), diagnostico),
    trabajo_realizado = coalesce(v_trabajo, trabajo_realizado),
    proveedor = coalesce(nullif(btrim(p_datos->>'proveedor'), ''), proveedor),
    costo_real = case when p_estado = 'completada' then coalesce(v_costo, 0) else costo_real end,
    minutos_fuera_servicio = coalesce(
      nullif(p_datos->>'minutos_fuera_servicio', '')::integer, minutos_fuera_servicio),
    lectura_cierre = coalesce(v_lectura, lectura_cierre),
    cancelacion_motivo = case when p_estado = 'cancelada'
      then btrim(p_datos->>'cancelacion_motivo') else cancelacion_motivo end,
    actualizado_por = v_uid, updated_at = now()
  where id = p_orden_id;

  if p_estado = 'en_proceso' then
    update public.activos_mantenimiento set estado = 'mantenimiento',
      actualizado_por = v_uid, updated_at = now()
    where id = v_activo.id;
  elsif p_estado = 'completada' then
    update public.activos_mantenimiento set
      estado = 'operativo',
      lectura_actual = coalesce(v_lectura, lectura_actual),
      ultimo_mantenimiento_fecha = (now() at time zone 'America/Guayaquil')::date,
      ultima_lectura_mantenimiento = coalesce(v_lectura, lectura_actual),
      proximo_mantenimiento_fecha = case
        when frecuencia_mantenimiento_dias is not null then
          (now() at time zone 'America/Guayaquil')::date + frecuencia_mantenimiento_dias
        else proximo_mantenimiento_fecha end,
      proxima_lectura_mantenimiento = case
        when frecuencia_mantenimiento_uso is not null then
          coalesce(v_lectura, lectura_actual) + frecuencia_mantenimiento_uso
        else proxima_lectura_mantenimiento end,
      actualizado_por = v_uid, updated_at = now()
    where id = v_activo.id;
  elsif p_estado = 'cancelada' and v_activo.estado = 'mantenimiento' then
    update public.activos_mantenimiento set estado = 'operativo',
      actualizado_por = v_uid, updated_at = now()
    where id = v_activo.id;
  end if;

  update public.notificaciones_comunicados set
    activo = p_estado not in ('completada', 'cancelada'),
    nivel = case when v_orden.prioridad = 'urgente' then 'critica' else 'accion' end,
    mensaje = 'Orden ' || v_orden.numero || ' en estado ' || replace(p_estado, '_', ' ') ||
      '. ' || btrim(p_motivo), updated_at = now()
  where origen_clave = 'mantenimiento:orden:' || p_orden_id::text;

  insert into public.mantenimiento_eventos (
    entidad_tipo, entidad_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    'orden', p_orden_id, 'estado_cambiado', v_orden.estado, p_estado,
    btrim(p_motivo), coalesce(p_datos, '{}'::jsonb), v_uid, p_idempotency_key
  );
  return p_orden_id;
end;
$fn$;

-- Genera o apaga alertas preventivas segun la fecha/lectura actual.
create or replace function public.sincronizar_alertas_mantenimiento_v54()
returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_total integer := 0;
begin
  if v_uid is null or not public.usuario_tiene_permiso_v35('mantenimiento.acceder') then
    return 0;
  end if;

  insert into public.notificaciones_comunicados as n (
    origen_clave, origen_tipo, grupo_id, empresa_id, almacen_id,
    permiso_requerido, modulo, nivel, titulo, mensaje, href, creado_por
  )
  select
    'mantenimiento:activo:' || a.id::text || ':vencimiento', 'mantenimiento_activo',
    a.grupo_id, a.empresa_id, a.almacen_id, 'mantenimiento.acceder', 'Mantenimiento',
    case when a.proximo_mantenimiento_fecha < (now() at time zone 'America/Guayaquil')::date
       or (a.proxima_lectura_mantenimiento is not null
         and a.lectura_actual >= a.proxima_lectura_mantenimiento)
      then 'critica' else 'alerta' end,
    case when a.proximo_mantenimiento_fecha < (now() at time zone 'America/Guayaquil')::date
       or (a.proxima_lectura_mantenimiento is not null
         and a.lectura_actual >= a.proxima_lectura_mantenimiento)
      then 'Mantenimiento vencido · ' else 'Mantenimiento proximo · ' end || a.codigo,
    a.nombre || case when a.proximo_mantenimiento_fecha is not null
      then ' · fecha ' || to_char(a.proximo_mantenimiento_fecha, 'DD/MM/YYYY')
      else ' · lectura objetivo ' || a.proxima_lectura_mantenimiento::text end,
    '/mantenimiento', v_uid
  from public.activos_mantenimiento a
  where a.activo and a.estado <> 'baja'
    and public.puede_ver_activo_mantenimiento_v54(a.id, false)
    and (
      a.proximo_mantenimiento_fecha <= (now() at time zone 'America/Guayaquil')::date + 30
      or (a.proxima_lectura_mantenimiento is not null
        and a.lectura_actual >= a.proxima_lectura_mantenimiento * 0.9)
    )
    and not exists (
      select 1 from public.ordenes_mantenimiento o
      where o.activo_id = a.id
        and o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
    )
  on conflict (origen_clave) do update set
    activo = true, nivel = excluded.nivel, titulo = excluded.titulo,
    mensaje = excluded.mensaje, updated_at = now();
  get diagnostics v_total = row_count;

  update public.notificaciones_comunicados n set activo = false, updated_at = now()
  where n.origen_tipo = 'mantenimiento_activo' and n.activo
    and exists (
      select 1 from public.activos_mantenimiento a
      where n.origen_clave = 'mantenimiento:activo:' || a.id::text || ':vencimiento'
        and public.puede_ver_activo_mantenimiento_v54(a.id, false)
        and (
          not a.activo or a.estado = 'baja'
          or (
            (a.proximo_mantenimiento_fecha is null
              or a.proximo_mantenimiento_fecha > (now() at time zone 'America/Guayaquil')::date + 30)
            and (a.proxima_lectura_mantenimiento is null
              or a.lectura_actual < a.proxima_lectura_mantenimiento * 0.9)
          )
          or exists (
            select 1 from public.ordenes_mantenimiento o
            where o.activo_id = a.id
              and o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
          )
        )
    );
  return v_total;
end;
$fn$;

create or replace function public.resumen_mantenimiento_v54()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when not public.usuario_tiene_permiso_v35('mantenimiento.acceder')
    then jsonb_build_object('activos', 0, 'detenidos', 0, 'vencidos', 0,
      'proximos', 0, 'ordenes_abiertas', 0, 'ordenes_atrasadas', 0)
    else jsonb_build_object(
      'activos', count(*) filter (where a.activo and a.estado <> 'baja'),
      'detenidos', count(*) filter (where a.activo and a.estado in ('detenido', 'fuera_servicio')),
      'vencidos', count(*) filter (where a.activo and a.estado <> 'baja' and (
        a.proximo_mantenimiento_fecha < (now() at time zone 'America/Guayaquil')::date
        or (a.proxima_lectura_mantenimiento is not null
          and a.lectura_actual >= a.proxima_lectura_mantenimiento))),
      'proximos', count(*) filter (where a.activo and a.estado <> 'baja'
        and a.proximo_mantenimiento_fecha between
          (now() at time zone 'America/Guayaquil')::date
          and (now() at time zone 'America/Guayaquil')::date + 30),
      'ordenes_abiertas', (select count(*) from public.ordenes_mantenimiento o
        where o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
          and public.puede_ver_activo_mantenimiento_v54(o.activo_id, false)),
      'ordenes_atrasadas', (select count(*) from public.ordenes_mantenimiento o
        where o.estado in ('solicitada', 'programada')
          and o.fecha_programada < (now() at time zone 'America/Guayaquil')::date
          and public.puede_ver_activo_mantenimiento_v54(o.activo_id, false))
    ) end
  from public.activos_mantenimiento a
  where public.puede_ver_activo_mantenimiento_v54(a.id, false);
$$;

-- ------------------------------------------------------------
-- 6. RLS, propietarios y privilegios
-- ------------------------------------------------------------
alter table public.activos_mantenimiento enable row level security;
alter table public.ordenes_mantenimiento enable row level security;
alter table public.mantenimiento_eventos enable row level security;

drop policy if exists "leer_activos_mantenimiento_v54" on public.activos_mantenimiento;
create policy "leer_activos_mantenimiento_v54"
on public.activos_mantenimiento for select to authenticated
using (public.puede_ver_activo_mantenimiento_v54(id, false));

drop policy if exists "leer_ordenes_mantenimiento_v54" on public.ordenes_mantenimiento;
create policy "leer_ordenes_mantenimiento_v54"
on public.ordenes_mantenimiento for select to authenticated
using (public.puede_ver_activo_mantenimiento_v54(activo_id, false));

drop policy if exists "leer_eventos_mantenimiento_v54" on public.mantenimiento_eventos;
create policy "leer_eventos_mantenimiento_v54"
on public.mantenimiento_eventos for select to authenticated using (
  public.usuario_tiene_permiso_v35('mantenimiento.acceder') and (
    (entidad_tipo = 'activo' and public.puede_ver_activo_mantenimiento_v54(entidad_id, false))
    or (entidad_tipo = 'orden' and exists (
      select 1 from public.ordenes_mantenimiento o
      where o.id = entidad_id
        and public.puede_ver_activo_mantenimiento_v54(o.activo_id, false)
    ))
  )
);

alter function public.puede_ver_activo_mantenimiento_v54(uuid, boolean) owner to postgres;
alter function public.guardar_activo_mantenimiento_v54(uuid, jsonb, text, uuid) owner to postgres;
alter function public.crear_orden_mantenimiento_v54(uuid, text, text, date, text, uuid, numeric, uuid) owner to postgres;
alter function public.cambiar_estado_orden_mantenimiento_v54(uuid, text, jsonb, text, uuid) owner to postgres;
alter function public.sincronizar_alertas_mantenimiento_v54() owner to postgres;
alter function public.resumen_mantenimiento_v54() owner to postgres;

revoke all on public.activos_mantenimiento from public, anon;
revoke all on public.ordenes_mantenimiento from public, anon;
revoke all on public.mantenimiento_eventos from public, anon;
revoke insert, update, delete on public.activos_mantenimiento from authenticated;
revoke insert, update, delete on public.ordenes_mantenimiento from authenticated;
revoke insert, update, delete on public.mantenimiento_eventos from authenticated;
grant select on public.activos_mantenimiento to authenticated;
grant select on public.ordenes_mantenimiento to authenticated;
grant select on public.mantenimiento_eventos to authenticated;
grant select on public.vista_activos_mantenimiento_v54 to authenticated;
grant select on public.vista_ordenes_mantenimiento_v54 to authenticated;

revoke execute on function public.puede_ver_activo_mantenimiento_v54(uuid, boolean) from public, anon;
revoke execute on function public.guardar_activo_mantenimiento_v54(uuid, jsonb, text, uuid) from public, anon;
revoke execute on function public.crear_orden_mantenimiento_v54(uuid, text, text, date, text, uuid, numeric, uuid) from public, anon;
revoke execute on function public.cambiar_estado_orden_mantenimiento_v54(uuid, text, jsonb, text, uuid) from public, anon;
revoke execute on function public.sincronizar_alertas_mantenimiento_v54() from public, anon;
revoke execute on function public.resumen_mantenimiento_v54() from public, anon;
grant execute on function public.puede_ver_activo_mantenimiento_v54(uuid, boolean) to authenticated;
grant execute on function public.guardar_activo_mantenimiento_v54(uuid, jsonb, text, uuid) to authenticated;
grant execute on function public.crear_orden_mantenimiento_v54(uuid, text, text, date, text, uuid, numeric, uuid) to authenticated;
grant execute on function public.cambiar_estado_orden_mantenimiento_v54(uuid, text, jsonb, text, uuid) to authenticated;
grant execute on function public.sincronizar_alertas_mantenimiento_v54() to authenticated;
grant execute on function public.resumen_mantenimiento_v54() to authenticated;

notify pgrst, 'reload schema';
