-- ============================================================
-- BOMAN INVENTARIO - Rutas, etapas y lotes de produccion v25
-- Agrega seguimiento secuencial del proceso, responsables internos o
-- maquila, evidencia por etapa y lote auditable del producto terminado.
-- Ejecutar una sola vez DESPUES de v24.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Rutas versionadas y relacion con formulas
-- ------------------------------------------------------------
create table if not exists public.rutas_produccion (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  codigo text not null check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  version integer not null check (version > 0),
  estado text not null default 'borrador'
    check (estado in ('borrador', 'activa', 'inactiva')),
  descripcion text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  aprobado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  aprobado_at timestamptz,
  unique (grupo_id, codigo, version)
);

create unique index if not exists uq_rutas_produccion_activa
  on public.rutas_produccion(grupo_id, codigo)
  where estado = 'activa';

create table if not exists public.ruta_produccion_etapas (
  id uuid primary key default gen_random_uuid(),
  ruta_id uuid not null references public.rutas_produccion(id) on delete restrict,
  secuencia integer not null check (secuencia > 0),
  codigo text not null check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  modalidad text not null default 'interna'
    check (modalidad in ('interna', 'maquila', 'control_calidad')),
  requiere_evidencia boolean not null default true,
  costo_estimado numeric(18,6) not null default 0 check (costo_estimado >= 0),
  instrucciones text,
  unique (ruta_id, secuencia),
  unique (ruta_id, codigo)
);

create table if not exists public.formula_rutas_produccion (
  formula_id uuid primary key references public.formulas_produccion(id) on delete restrict,
  ruta_id uuid not null references public.rutas_produccion(id) on delete restrict,
  asignado_por uuid not null references public.perfiles(id) on delete restrict,
  motivo text not null check (btrim(motivo) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ruta_produccion_eventos (
  id uuid primary key default gen_random_uuid(),
  ruta_id uuid not null references public.rutas_produccion(id) on delete restrict,
  tipo text not null check (tipo in (
    'creada', 'actualizada', 'activada', 'inactivada', 'formula_asignada'
  )),
  detalle text not null,
  datos jsonb not null default '{}'::jsonb,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_rutas_produccion_grupo_estado
  on public.rutas_produccion(grupo_id, estado, codigo);
create index if not exists idx_ruta_etapas_ruta_secuencia
  on public.ruta_produccion_etapas(ruta_id, secuencia);
create index if not exists idx_formula_rutas_ruta
  on public.formula_rutas_produccion(ruta_id, formula_id);
create index if not exists idx_ruta_eventos_fecha
  on public.ruta_produccion_eventos(ruta_id, created_at desc);

-- ------------------------------------------------------------
-- 2. Instantanea de etapas por orden y lote de resultado
-- ------------------------------------------------------------
alter table public.ordenes_produccion
  add column if not exists ruta_id uuid references public.rutas_produccion(id) on delete restrict,
  add column if not exists ruta_codigo text,
  add column if not exists ruta_version integer,
  add column if not exists costo_etapas_estimado numeric(18,6) not null default 0,
  add column if not exists costo_etapas_real numeric(18,6);

create table if not exists public.orden_produccion_etapas (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references public.ordenes_produccion(id) on delete restrict,
  ruta_etapa_id uuid references public.ruta_produccion_etapas(id) on delete restrict,
  secuencia integer not null check (secuencia > 0),
  codigo text not null check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  modalidad text not null check (modalidad in ('interna', 'maquila', 'control_calidad')),
  requiere_evidencia boolean not null default true,
  instrucciones text,
  estado text not null default 'pendiente'
    check (estado in ('pendiente', 'en_proceso', 'completada', 'omitida')),
  responsable_perfil_id uuid references public.perfiles(id) on delete restrict,
  proveedor_id uuid references public.proveedores(id) on delete restrict,
  cantidad_procesada integer check (cantidad_procesada is null or cantidad_procesada > 0),
  cantidad_no_conforme integer not null default 0 check (cantidad_no_conforme >= 0),
  costo_estimado numeric(18,6) not null default 0 check (costo_estimado >= 0),
  costo_real numeric(18,6) check (costo_real is null or costo_real >= 0),
  nota_inicio text,
  evidencia_cierre text,
  iniciar_idempotency_key uuid unique,
  completar_idempotency_key uuid unique,
  iniciado_por uuid references public.perfiles(id) on delete restrict,
  completado_por uuid references public.perfiles(id) on delete restrict,
  iniciado_at timestamptz,
  completado_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (orden_id, secuencia),
  check (responsable_perfil_id is null or proveedor_id is null),
  check (
    cantidad_procesada is null
    or cantidad_no_conforme <= cantidad_procesada
  )
);

create table if not exists public.orden_produccion_etapa_eventos (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references public.ordenes_produccion(id) on delete restrict,
  etapa_id uuid not null references public.orden_produccion_etapas(id) on delete restrict,
  tipo text not null check (tipo in ('iniciada', 'completada', 'omitida')),
  estado_anterior text not null,
  estado_nuevo text not null,
  detalle text not null,
  datos jsonb not null default '{}'::jsonb,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create sequence if not exists public.seq_lote_produccion;

create table if not exists public.lotes_produccion (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  orden_id uuid not null unique references public.ordenes_produccion(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  estado_calidad text not null
    check (estado_calidad in ('liberado', 'cuarentena', 'mixto')),
  cantidad_conforme integer not null check (cantidad_conforme >= 0),
  cantidad_no_conforme integer not null check (cantidad_no_conforme >= 0),
  costo_unitario_real numeric(18,6) check (costo_unitario_real is null or costo_unitario_real >= 0),
  fecha_produccion date not null,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (cantidad_conforme + cantidad_no_conforme > 0)
);

create index if not exists idx_orden_etapas_orden_estado
  on public.orden_produccion_etapas(orden_id, estado, secuencia);
create index if not exists idx_orden_etapas_responsable
  on public.orden_produccion_etapas(responsable_perfil_id, estado)
  where responsable_perfil_id is not null;
create index if not exists idx_orden_etapas_proveedor
  on public.orden_produccion_etapas(proveedor_id, estado)
  where proveedor_id is not null;
create index if not exists idx_etapa_eventos_fecha
  on public.orden_produccion_etapa_eventos(orden_id, created_at desc);
create index if not exists idx_lotes_produccion_producto_fecha
  on public.lotes_produccion(producto_id, fecha_produccion desc);
create index if not exists idx_lotes_produccion_empresa_fecha
  on public.lotes_produccion(empresa_id, fecha_produccion desc);

comment on table public.lotes_produccion is
  'Trazabilidad del resultado de una orden. No representa saldo disponible por lote; el saldo fisico continua en inventario.';
comment on table public.orden_produccion_etapas is
  'Instantanea inmutable de la ruta aplicable al crear la orden; cambios futuros de la ruta no alteran ordenes existentes.';

-- V24 recalcula materiales al aprobar. Este trigger conserva el costo de la
-- ruta en el total estimado sin depender del orden de las actualizaciones.
create or replace function public.normalizar_costo_estimado_orden_v25()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.costo_total_estimado := round(
    coalesce(new.costo_materiales_estimado, 0)
      + coalesce(new.costo_mano_obra_estimado, 0)
      + coalesce(new.costo_indirecto_estimado, 0)
      + coalesce(new.costo_etapas_estimado, 0), 6
  );
  return new;
end;
$$;

drop trigger if exists trg_normalizar_costo_estimado_orden_v25
  on public.ordenes_produccion;
create trigger trg_normalizar_costo_estimado_orden_v25
before insert or update of costo_materiales_estimado,
  costo_mano_obra_estimado, costo_indirecto_estimado, costo_etapas_estimado
on public.ordenes_produccion
for each row execute function public.normalizar_costo_estimado_orden_v25();

-- ------------------------------------------------------------
-- 3. Acceso y RLS
-- ------------------------------------------------------------
alter table public.rutas_produccion enable row level security;
alter table public.ruta_produccion_etapas enable row level security;
alter table public.formula_rutas_produccion enable row level security;
alter table public.ruta_produccion_eventos enable row level security;
alter table public.orden_produccion_etapas enable row level security;
alter table public.orden_produccion_etapa_eventos enable row level security;
alter table public.lotes_produccion enable row level security;

drop policy if exists "leer_rutas_produccion_v25" on public.rutas_produccion;
create policy "leer_rutas_produccion_v25"
on public.rutas_produccion for select to authenticated using (
  public.usuario_puede_grupo_produccion(grupo_id)
);

drop policy if exists "leer_ruta_etapas_v25" on public.ruta_produccion_etapas;
create policy "leer_ruta_etapas_v25"
on public.ruta_produccion_etapas for select to authenticated using (
  exists (
    select 1 from public.rutas_produccion r
    where r.id = ruta_id and public.usuario_puede_grupo_produccion(r.grupo_id)
  )
);

drop policy if exists "leer_formula_rutas_v25" on public.formula_rutas_produccion;
create policy "leer_formula_rutas_v25"
on public.formula_rutas_produccion for select to authenticated using (
  exists (
    select 1 from public.formulas_produccion f
    where f.id = formula_id and public.usuario_puede_grupo_produccion(f.grupo_id)
  )
);

drop policy if exists "leer_ruta_eventos_v25" on public.ruta_produccion_eventos;
create policy "leer_ruta_eventos_v25"
on public.ruta_produccion_eventos for select to authenticated using (
  exists (
    select 1 from public.rutas_produccion r
    where r.id = ruta_id and public.usuario_puede_grupo_produccion(r.grupo_id)
  )
);

drop policy if exists "leer_orden_etapas_v25" on public.orden_produccion_etapas;
create policy "leer_orden_etapas_v25"
on public.orden_produccion_etapas for select to authenticated using (
  public.puede_ver_orden_produccion_v24(orden_id)
);

drop policy if exists "leer_orden_etapa_eventos_v25"
  on public.orden_produccion_etapa_eventos;
create policy "leer_orden_etapa_eventos_v25"
on public.orden_produccion_etapa_eventos for select to authenticated using (
  public.puede_ver_orden_produccion_v24(orden_id)
);

drop policy if exists "leer_lotes_produccion_v25" on public.lotes_produccion;
create policy "leer_lotes_produccion_v25"
on public.lotes_produccion for select to authenticated using (
  public.puede_ver_orden_produccion_v24(orden_id)
);

-- ------------------------------------------------------------
-- 4. Administracion versionada de rutas
-- ------------------------------------------------------------
create or replace function public.guardar_ruta_produccion_v25(
  p_ruta_id uuid,
  p_grupo_id uuid,
  p_codigo text,
  p_nombre text,
  p_descripcion text,
  p_etapas jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol text := public.rol_usuario_actual();
  v_id uuid;
  v_version integer;
  v_antes jsonb;
  v_tipo_evento text;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden configurar rutas de produccion';
  end if;
  if not public.usuario_puede_grupo_produccion(p_grupo_id) then
    raise exception 'No tienes acceso al grupo economico';
  end if;
  if btrim(coalesce(p_codigo, '')) = '' or btrim(coalesce(p_nombre, '')) = '' then
    raise exception 'El codigo y el nombre de la ruta son obligatorios';
  end if;
  if jsonb_typeof(coalesce(p_etapas, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_etapas, '[]'::jsonb)) = 0 then
    raise exception 'La ruta debe contener al menos una etapa';
  end if;
  if jsonb_array_length(p_etapas) > 30 then
    raise exception 'Una ruta no puede superar 30 etapas';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_etapas) x(
      secuencia integer, codigo text, nombre text, modalidad text,
      requiere_evidencia boolean, costo_estimado numeric, instrucciones text
    )
    where coalesce(x.secuencia, 0) <= 0
       or btrim(coalesce(x.codigo, '')) = ''
       or btrim(coalesce(x.nombre, '')) = ''
       or x.modalidad not in ('interna', 'maquila', 'control_calidad')
       or coalesce(x.costo_estimado, 0) < 0
  ) then raise exception 'Existe una etapa con datos invalidos'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_etapas) x(secuencia integer, codigo text)
    group by secuencia having count(*) > 1
  ) or exists (
    select 1
    from jsonb_to_recordset(p_etapas) x(secuencia integer, codigo text)
    group by upper(btrim(codigo)) having count(*) > 1
  ) then raise exception 'La ruta contiene secuencias o codigos repetidos'; end if;
  if (
    select min(secuencia) = 1 and max(secuencia) = count(*)
    from jsonb_to_recordset(p_etapas) x(secuencia integer)
  ) is not true then
    raise exception 'Las etapas deben usar una secuencia continua desde 1';
  end if;

  if p_ruta_id is null then
    select coalesce(max(version), 0) + 1 into v_version
    from public.rutas_produccion
    where grupo_id = p_grupo_id and codigo = upper(btrim(p_codigo));
    insert into public.rutas_produccion(
      grupo_id, codigo, nombre, version, descripcion, creado_por
    ) values (
      p_grupo_id, upper(btrim(p_codigo)), btrim(p_nombre), v_version,
      nullif(btrim(p_descripcion), ''), auth.uid()
    ) returning id into v_id;
    v_tipo_evento := 'creada';
  else
    select to_jsonb(r) into v_antes
    from public.rutas_produccion r where r.id = p_ruta_id for update;
    if not found then raise exception 'La ruta no existe'; end if;
    if v_antes->>'estado' <> 'borrador' then
      raise exception 'Solo una ruta en borrador puede editarse; crea una nueva version';
    end if;
    if (v_antes->>'grupo_id')::uuid <> p_grupo_id then
      raise exception 'El grupo de una version existente no puede cambiar';
    end if;
    update public.rutas_produccion
    set codigo = upper(btrim(p_codigo)), nombre = btrim(p_nombre),
        descripcion = nullif(btrim(p_descripcion), ''), updated_at = now()
    where id = p_ruta_id returning id, version into v_id, v_version;
    delete from public.ruta_produccion_etapas where ruta_id = v_id;
    v_tipo_evento := 'actualizada';
  end if;

  insert into public.ruta_produccion_etapas(
    ruta_id, secuencia, codigo, nombre, modalidad, requiere_evidencia,
    costo_estimado, instrucciones
  )
  select v_id, x.secuencia, upper(btrim(x.codigo)), btrim(x.nombre),
         x.modalidad, coalesce(x.requiere_evidencia, true),
         coalesce(x.costo_estimado, 0), nullif(btrim(x.instrucciones), '')
  from jsonb_to_recordset(p_etapas) x(
    secuencia integer, codigo text, nombre text, modalidad text,
    requiere_evidencia boolean, costo_estimado numeric, instrucciones text
  ) order by x.secuencia;

  insert into public.ruta_produccion_eventos(
    ruta_id, tipo, detalle, datos, usuario_id
  ) values (
    v_id, v_tipo_evento,
    case when v_tipo_evento = 'creada' then 'Ruta creada en borrador'
         else 'Borrador de ruta actualizado' end,
    jsonb_build_object('antes', v_antes, 'etapas', p_etapas), auth.uid()
  );
  return v_id;
end;
$$;

create or replace function public.resolver_ruta_produccion_v25(
  p_ruta_id uuid,
  p_activar boolean,
  p_nota text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.rutas_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_anteriores uuid[];
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden resolver rutas';
  end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'La resolucion requiere una nota de al menos 5 caracteres';
  end if;
  select * into r from public.rutas_produccion where id = p_ruta_id for update;
  if not found then raise exception 'La ruta no existe'; end if;
  if p_activar then
    if r.estado <> 'borrador' then raise exception 'Solo un borrador puede activarse'; end if;
    if r.creado_por = auth.uid() and v_rol <> 'admin' then
      raise exception 'Quien preparo la ruta no puede aprobarla; requiere otro revisor';
    end if;
    if not exists (
      select 1 from public.ruta_produccion_etapas where ruta_id = r.id
    ) then raise exception 'La ruta no tiene etapas'; end if;

    select array_agg(id) into v_anteriores
    from public.rutas_produccion
    where grupo_id = r.grupo_id and codigo = r.codigo
      and estado = 'activa' and id <> r.id;

    update public.rutas_produccion
    set estado = 'inactiva', updated_at = now()
    where id = any(coalesce(v_anteriores, array[]::uuid[]));
    update public.formula_rutas_produccion
    set ruta_id = r.id, asignado_por = auth.uid(),
        motivo = 'Migracion automatica a ruta ' || r.codigo || ' v' || r.version,
        updated_at = now()
    where ruta_id = any(coalesce(v_anteriores, array[]::uuid[]));

    update public.rutas_produccion
    set estado = 'activa', aprobado_por = auth.uid(), aprobado_at = now(),
        updated_at = now()
    where id = r.id;
  else
    if r.estado <> 'activa' then raise exception 'Solo una ruta activa puede inactivarse'; end if;
    if exists (
      select 1 from public.formula_rutas_produccion where ruta_id = r.id
    ) then
      raise exception 'La ruta esta asignada a formulas. Activa una nueva version para migrarlas automaticamente';
    end if;
    update public.rutas_produccion
    set estado = 'inactiva', updated_at = now() where id = r.id;
  end if;

  insert into public.ruta_produccion_eventos(
    ruta_id, tipo, detalle, datos, usuario_id
  ) values (
    r.id, case when p_activar then 'activada' else 'inactivada' end,
    btrim(p_nota), jsonb_build_object('version', r.version), auth.uid()
  );
  return case when p_activar then 'Ruta activada' else 'Ruta inactivada' end;
end;
$$;

create or replace function public.asignar_ruta_formula_v25(
  p_formula_id uuid,
  p_ruta_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.formulas_produccion%rowtype;
  r public.rutas_produccion%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden asignar rutas';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then
    raise exception 'La asignacion requiere un motivo de al menos 5 caracteres';
  end if;
  select * into f from public.formulas_produccion where id = p_formula_id;
  if not found or f.estado <> 'activa' then
    raise exception 'La formula no existe o no esta activa';
  end if;
  select * into r from public.rutas_produccion where id = p_ruta_id;
  if not found or r.estado <> 'activa' then
    raise exception 'La ruta no existe o no esta activa';
  end if;
  if f.grupo_id <> r.grupo_id then
    raise exception 'La formula y la ruta deben pertenecer al mismo grupo';
  end if;

  insert into public.formula_rutas_produccion as fr(
    formula_id, ruta_id, asignado_por, motivo
  ) values (f.id, r.id, auth.uid(), btrim(p_motivo))
  on conflict (formula_id) do update
  set ruta_id = excluded.ruta_id, asignado_por = auth.uid(),
      motivo = excluded.motivo, updated_at = now();

  insert into public.ruta_produccion_eventos(
    ruta_id, tipo, detalle, datos, usuario_id
  ) values (
    r.id, 'formula_asignada', btrim(p_motivo),
    jsonb_build_object('formula_id', f.id, 'formula_codigo', f.codigo,
      'formula_version', f.version), auth.uid()
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Instantanea automatica, etapas y lote
-- ------------------------------------------------------------
create or replace function public.sembrar_etapas_orden_v25(p_orden_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.ordenes_produccion%rowtype;
  r public.rutas_produccion%rowtype;
  v_total integer := 0;
  v_estado text;
begin
  select * into o from public.ordenes_produccion where id = p_orden_id for update;
  if not found then raise exception 'La orden de produccion no existe'; end if;
  if exists (select 1 from public.orden_produccion_etapas where orden_id = o.id) then
    return 0;
  end if;

  select rp.* into r
  from public.formula_rutas_produccion fr
  join public.rutas_produccion rp on rp.id = fr.ruta_id and rp.estado = 'activa'
  where fr.formula_id = o.formula_id;

  if found then
    update public.ordenes_produccion
    set ruta_id = r.id, ruta_codigo = r.codigo, ruta_version = r.version,
        costo_etapas_estimado = (
          select coalesce(sum(e.costo_estimado), 0)
          from public.ruta_produccion_etapas e where e.ruta_id = r.id
        ),
        updated_at = now()
    where id = o.id;
    insert into public.orden_produccion_etapas(
      orden_id, ruta_etapa_id, secuencia, codigo, nombre, modalidad,
      requiere_evidencia, instrucciones, costo_estimado, estado,
      cantidad_procesada, cantidad_no_conforme, iniciado_por, completado_por,
      iniciado_at, completado_at, evidencia_cierre
    )
    select o.id, e.id, e.secuencia, e.codigo, e.nombre, e.modalidad,
           e.requiere_evidencia, e.instrucciones, e.costo_estimado,
           case when o.estado = 'completada' then 'completada'
                when o.estado in ('rechazada', 'cancelada') then 'omitida'
                else 'pendiente' end,
           case when o.estado = 'completada' then o.cantidad_planificada end,
           case when o.estado = 'completada' then o.cantidad_no_conforme else 0 end,
           case when o.estado = 'completada' then o.completado_por end,
           case when o.estado = 'completada' then o.completado_por end,
           case when o.estado = 'completada' then coalesce(o.iniciado_at, o.created_at) end,
           case when o.estado = 'completada' then o.completado_at end,
           case when o.estado = 'completada' then 'Etapa reconstruida al instalar V25'
                when o.estado in ('rechazada', 'cancelada') then 'Orden cerrada antes de V25' end
    from public.ruta_produccion_etapas e
    where e.ruta_id = r.id order by e.secuencia;
  else
    v_estado := case when o.estado = 'completada' then 'completada'
                     when o.estado in ('rechazada', 'cancelada') then 'omitida'
                     else 'pendiente' end;
    insert into public.orden_produccion_etapas(
      orden_id, secuencia, codigo, nombre, modalidad, requiere_evidencia,
      instrucciones, estado, cantidad_procesada, cantidad_no_conforme,
      iniciado_por, completado_por, iniciado_at, completado_at, evidencia_cierre
    ) values (
      o.id, 1, 'PRODUCCION', 'Produccion general', 'interna', true,
      'Etapa temporal. Asigna una ruta activa a la formula para las proximas ordenes.',
      v_estado,
      case when o.estado = 'completada' then o.cantidad_planificada end,
      case when o.estado = 'completada' then o.cantidad_no_conforme else 0 end,
      case when o.estado = 'completada' then o.completado_por end,
      case when o.estado = 'completada' then o.completado_por end,
      case when o.estado = 'completada' then coalesce(o.iniciado_at, o.created_at) end,
      case when o.estado = 'completada' then o.completado_at end,
      case when o.estado = 'completada' then 'Etapa general reconstruida al instalar V25'
           when o.estado in ('rechazada', 'cancelada') then 'Orden cerrada antes de V25' end
    );
  end if;
  get diagnostics v_total = row_count;
  return v_total;
end;
$$;

create or replace function public.preparar_etapas_orden_v25()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.sembrar_etapas_orden_v25(new.id);
  return new;
end;
$$;

drop trigger if exists trg_preparar_etapas_orden_v25 on public.ordenes_produccion;
create trigger trg_preparar_etapas_orden_v25
after insert on public.ordenes_produccion
for each row execute function public.preparar_etapas_orden_v25();

do $$
declare
  x record;
begin
  for x in
    select id from public.ordenes_produccion o
    where not exists (
      select 1 from public.orden_produccion_etapas e where e.orden_id = o.id
    ) order by created_at, id
  loop
    perform public.sembrar_etapas_orden_v25(x.id);
  end loop;
end;
$$;

create or replace function public.validar_cierre_etapas_v25()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_costo_etapas numeric(18,6);
begin
  if new.estado = 'completada' and old.estado <> 'completada' then
    if not exists (
      select 1 from public.orden_produccion_etapas e
      where e.orden_id = new.id and e.estado = 'completada'
    ) then
      raise exception 'La orden requiere al menos una etapa completada antes del cierre';
    end if;
    if exists (
      select 1 from public.orden_produccion_etapas e
      where e.orden_id = new.id and e.estado in ('pendiente', 'en_proceso')
    ) then
      raise exception 'Completa u omite justificadamente todas las etapas antes de finalizar la produccion';
    end if;
    select coalesce(sum(e.costo_real), 0) into v_costo_etapas
    from public.orden_produccion_etapas e where e.orden_id = new.id;
    new.costo_etapas_real := v_costo_etapas;
    new.costo_total_real := coalesce(new.costo_total_real, 0) + v_costo_etapas;
    new.costo_unitario_real := round(
      new.costo_total_real
        / nullif(new.cantidad_conforme + new.cantidad_no_conforme, 0), 6
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validar_cierre_etapas_v25 on public.ordenes_produccion;
create trigger trg_validar_cierre_etapas_v25
before update of estado on public.ordenes_produccion
for each row execute function public.validar_cierre_etapas_v25();

create or replace function public.generar_lote_produccion_v25()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_codigo text;
begin
  if new.estado = 'completada' and old.estado <> 'completada' then
    v_codigo := 'LP-'
      || to_char(coalesce(new.completado_at, now()) at time zone 'America/Guayaquil', 'YYYY')
      || '-' || lpad(nextval('public.seq_lote_produccion')::text, 7, '0');
    insert into public.lotes_produccion(
      codigo, orden_id, empresa_id, producto_id, almacen_id, estado_calidad,
      cantidad_conforme, cantidad_no_conforme, costo_unitario_real,
      fecha_produccion, creado_por
    ) values (
      v_codigo, new.id, new.empresa_id, new.producto_resultado_id,
      new.almacen_terminado_id,
      case when new.cantidad_no_conforme = 0 then 'liberado'
           when new.cantidad_conforme = 0 then 'cuarentena' else 'mixto' end,
      new.cantidad_conforme, new.cantidad_no_conforme, new.costo_unitario_real,
      (coalesce(new.completado_at, now()) at time zone 'America/Guayaquil')::date,
      coalesce(new.completado_por, auth.uid())
    ) on conflict (orden_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_generar_lote_produccion_v25 on public.ordenes_produccion;
create trigger trg_generar_lote_produccion_v25
after update of estado on public.ordenes_produccion
for each row execute function public.generar_lote_produccion_v25();

insert into public.lotes_produccion(
  codigo, orden_id, empresa_id, producto_id, almacen_id, estado_calidad,
  cantidad_conforme, cantidad_no_conforme, costo_unitario_real,
  fecha_produccion, creado_por
)
select 'LP-V24-' || upper(substr(replace(o.id::text, '-', ''), 1, 12)),
       o.id, o.empresa_id, o.producto_resultado_id, o.almacen_terminado_id,
       case when o.cantidad_no_conforme = 0 then 'liberado'
            when o.cantidad_conforme = 0 then 'cuarentena' else 'mixto' end,
       o.cantidad_conforme, o.cantidad_no_conforme, o.costo_unitario_real,
       (coalesce(o.completado_at, o.updated_at) at time zone 'America/Guayaquil')::date,
       o.completado_por
from public.ordenes_produccion o
where o.estado = 'completada' and o.completado_por is not null
on conflict (orden_id) do nothing;

-- ------------------------------------------------------------
-- 6. Operacion auditada de cada etapa
-- ------------------------------------------------------------
create or replace function public.iniciar_etapa_produccion_v25(
  p_etapa_id uuid,
  p_responsable_perfil_id uuid,
  p_proveedor_id uuid,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.orden_produccion_etapas%rowtype;
  o public.ordenes_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_responsable uuid;
begin
  if v_rol not in ('admin', 'control', 'bodega', 'logistica') then
    raise exception 'No tienes permiso para iniciar etapas de produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into e from public.orden_produccion_etapas where id = p_etapa_id for update;
  if not found then raise exception 'La etapa no existe'; end if;
  if e.iniciar_idempotency_key = p_idempotency_key then
    return jsonb_build_object('id', e.id, 'duplicado', true, 'estado', e.estado);
  end if;
  if e.estado <> 'pendiente' then raise exception 'La etapa ya fue iniciada o cerrada'; end if;
  select * into o from public.ordenes_produccion where id = e.orden_id for update;
  if o.estado <> 'en_proceso' then
    raise exception 'Primero entrega materiales para poner la orden en proceso';
  end if;
  if not public.usuario_puede_empresa(o.empresa_id, true)
     or not public.usuario_puede_almacen(o.almacen_materiales_id, true) then
    raise exception 'No tienes acceso operativo a esta orden';
  end if;
  if exists (
    select 1 from public.orden_produccion_etapas anterior
    where anterior.orden_id = e.orden_id and anterior.secuencia < e.secuencia
      and anterior.estado not in ('completada', 'omitida')
  ) then raise exception 'Debes cerrar primero la etapa anterior'; end if;

  if e.modalidad = 'maquila' then
    if p_proveedor_id is null then raise exception 'Selecciona el proveedor de maquila'; end if;
    if p_responsable_perfil_id is not null then
      raise exception 'Una etapa de maquila no puede asignarse simultaneamente a un usuario interno';
    end if;
    if not exists (
      select 1 from public.proveedores p
      join public.proveedor_empresas pe on pe.proveedor_id = p.id
      where p.id = p_proveedor_id and p.activo
        and pe.empresa_id = o.empresa_id and pe.activo
    ) then raise exception 'El proveedor no esta habilitado para la empresa de la orden'; end if;
    v_responsable := null;
  else
    if p_proveedor_id is not null then
      raise exception 'Solo una etapa de maquila admite proveedor externo';
    end if;
    v_responsable := coalesce(p_responsable_perfil_id, auth.uid());
    if not exists (
      select 1 from public.perfiles p where p.id = v_responsable and p.activo
    ) then raise exception 'El responsable interno no existe o esta inactivo'; end if;
  end if;

  update public.orden_produccion_etapas
  set estado = 'en_proceso', responsable_perfil_id = v_responsable,
      proveedor_id = p_proveedor_id, nota_inicio = nullif(btrim(p_nota), ''),
      iniciar_idempotency_key = p_idempotency_key, iniciado_por = auth.uid(),
      iniciado_at = now(), updated_at = now()
  where id = e.id;
  insert into public.orden_produccion_etapa_eventos(
    orden_id, etapa_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id
  ) values (
    o.id, e.id, 'iniciada', 'pendiente', 'en_proceso',
    coalesce(nullif(btrim(p_nota), ''), 'Etapa iniciada'),
    jsonb_build_object('responsable_perfil_id', v_responsable,
      'proveedor_id', p_proveedor_id), auth.uid()
  );
  return jsonb_build_object('id', e.id, 'duplicado', false, 'estado', 'en_proceso');
end;
$$;

create or replace function public.completar_etapa_produccion_v25(
  p_etapa_id uuid,
  p_cantidad_procesada integer,
  p_cantidad_no_conforme integer,
  p_costo_real numeric,
  p_evidencia text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.orden_produccion_etapas%rowtype;
  o public.ordenes_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
begin
  if v_rol not in ('admin', 'control', 'bodega', 'logistica') then
    raise exception 'No tienes permiso para completar etapas de produccion';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into e from public.orden_produccion_etapas where id = p_etapa_id for update;
  if not found then raise exception 'La etapa no existe'; end if;
  if e.completar_idempotency_key = p_idempotency_key then
    return jsonb_build_object('id', e.id, 'duplicado', true, 'estado', e.estado);
  end if;
  if e.estado <> 'en_proceso' then raise exception 'La etapa no esta en proceso'; end if;
  select * into o from public.ordenes_produccion where id = e.orden_id for update;
  if o.estado <> 'en_proceso' then raise exception 'La orden ya no esta en proceso'; end if;
  if not public.usuario_puede_empresa(o.empresa_id, true)
     or not public.usuario_puede_almacen(o.almacen_materiales_id, true) then
    raise exception 'No tienes acceso operativo a esta orden';
  end if;
  if coalesce(p_cantidad_procesada, 0) <= 0
     or p_cantidad_procesada > o.cantidad_planificada then
    raise exception 'La cantidad procesada debe estar entre 1 y la cantidad planificada';
  end if;
  if coalesce(p_cantidad_no_conforme, 0) < 0
     or p_cantidad_no_conforme > p_cantidad_procesada then
    raise exception 'La cantidad no conforme no puede superar lo procesado';
  end if;
  if coalesce(p_costo_real, 0) < 0 then raise exception 'El costo real no puede ser negativo'; end if;
  if e.requiere_evidencia and length(btrim(coalesce(p_evidencia, ''))) < 5 then
    raise exception 'La etapa requiere evidencia de al menos 5 caracteres';
  end if;

  update public.orden_produccion_etapas
  set estado = 'completada', cantidad_procesada = p_cantidad_procesada,
      cantidad_no_conforme = coalesce(p_cantidad_no_conforme, 0),
      costo_real = coalesce(p_costo_real, 0),
      evidencia_cierre = nullif(btrim(p_evidencia), ''),
      completar_idempotency_key = p_idempotency_key,
      completado_por = auth.uid(), completado_at = now(), updated_at = now()
  where id = e.id;
  insert into public.orden_produccion_etapa_eventos(
    orden_id, etapa_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id
  ) values (
    o.id, e.id, 'completada', 'en_proceso', 'completada',
    coalesce(nullif(btrim(p_evidencia), ''), 'Etapa completada'),
    jsonb_build_object('cantidad_procesada', p_cantidad_procesada,
      'cantidad_no_conforme', coalesce(p_cantidad_no_conforme, 0),
      'costo_real', coalesce(p_costo_real, 0)), auth.uid()
  );
  return jsonb_build_object('id', e.id, 'duplicado', false, 'estado', 'completada');
end;
$$;

create or replace function public.omitir_etapa_produccion_v25(
  p_etapa_id uuid,
  p_motivo text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.orden_produccion_etapas%rowtype;
  o public.ordenes_produccion%rowtype;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede omitir una etapa planificada';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La omision requiere una justificacion de al menos 10 caracteres';
  end if;
  select * into e from public.orden_produccion_etapas where id = p_etapa_id for update;
  if not found then raise exception 'La etapa no existe'; end if;
  if e.estado <> 'pendiente' then raise exception 'Solo una etapa pendiente puede omitirse'; end if;
  select * into o from public.ordenes_produccion where id = e.orden_id for update;
  if o.estado <> 'en_proceso' then raise exception 'La orden no esta en proceso'; end if;
  if exists (
    select 1 from public.orden_produccion_etapas anterior
    where anterior.orden_id = e.orden_id and anterior.secuencia < e.secuencia
      and anterior.estado not in ('completada', 'omitida')
  ) then raise exception 'Debes cerrar primero la etapa anterior'; end if;

  update public.orden_produccion_etapas
  set estado = 'omitida', evidencia_cierre = btrim(p_motivo),
      completado_por = auth.uid(), completado_at = now(), updated_at = now()
  where id = e.id;
  insert into public.orden_produccion_etapa_eventos(
    orden_id, etapa_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id
  ) values (
    o.id, e.id, 'omitida', 'pendiente', 'omitida', btrim(p_motivo),
    jsonb_build_object('excepcion_admin', true), auth.uid()
  );
  return 'Etapa omitida con excepcion administrativa auditada';
end;
$$;

-- ------------------------------------------------------------
-- 7. Vistas de seguimiento
-- ------------------------------------------------------------
create or replace view public.vista_rutas_produccion_v25
with (security_invoker = true) as
select
  r.id, r.grupo_id, g.codigo as grupo_codigo, r.codigo, r.nombre,
  r.version, r.estado, r.descripcion, r.created_at,
  coalesce(et.etapas, 0)::integer as etapas,
  coalesce(et.costo_estimado, 0)::numeric(18,6) as costo_etapas_estimado,
  coalesce(fa.formulas, 0)::integer as formulas_asignadas
from public.rutas_produccion r
join public.grupos_economicos g on g.id = r.grupo_id
left join lateral (
  select count(*) etapas, sum(e.costo_estimado) costo_estimado
  from public.ruta_produccion_etapas e where e.ruta_id = r.id
) et on true
left join lateral (
  select count(*) formulas
  from public.formula_rutas_produccion fr where fr.ruta_id = r.id
) fa on true;

create or replace view public.vista_seguimiento_produccion_v25
with (security_invoker = true) as
select
  o.id as orden_id, o.numero, o.empresa_id, emp.codigo as empresa_codigo,
  o.producto_resultado_id, p.sku as resultado_sku, p.nombre as resultado_producto,
  o.estado, o.ruta_id, o.ruta_codigo, o.ruta_version,
  count(e.id)::integer as etapas_total,
  count(e.id) filter (where e.estado = 'completada')::integer as etapas_completadas,
  count(e.id) filter (where e.estado = 'omitida')::integer as etapas_omitidas,
  count(e.id) filter (where e.estado = 'en_proceso')::integer as etapas_en_proceso,
  min(e.secuencia) filter (where e.estado in ('pendiente', 'en_proceso')) as secuencia_actual,
  coalesce(sum(e.costo_real), 0)::numeric(18,6) as costo_etapas_real,
  l.codigo as lote_codigo, l.estado_calidad as lote_estado_calidad,
  o.created_at, o.fecha_planificada, o.completado_at
from public.ordenes_produccion o
join public.empresas emp on emp.id = o.empresa_id
join public.productos p on p.id = o.producto_resultado_id
left join public.orden_produccion_etapas e on e.orden_id = o.id
left join public.lotes_produccion l on l.orden_id = o.id
group by o.id, emp.id, p.id, l.id;

-- ------------------------------------------------------------
-- 8. Propiedad, privilegios y recarga de PostgREST
-- ------------------------------------------------------------
alter function public.guardar_ruta_produccion_v25(uuid,uuid,text,text,text,jsonb) owner to postgres;
alter function public.normalizar_costo_estimado_orden_v25() owner to postgres;
alter function public.resolver_ruta_produccion_v25(uuid,boolean,text) owner to postgres;
alter function public.asignar_ruta_formula_v25(uuid,uuid,text) owner to postgres;
alter function public.sembrar_etapas_orden_v25(uuid) owner to postgres;
alter function public.preparar_etapas_orden_v25() owner to postgres;
alter function public.validar_cierre_etapas_v25() owner to postgres;
alter function public.generar_lote_produccion_v25() owner to postgres;
alter function public.iniciar_etapa_produccion_v25(uuid,uuid,uuid,text,uuid) owner to postgres;
alter function public.completar_etapa_produccion_v25(uuid,integer,integer,numeric,text,uuid) owner to postgres;
alter function public.omitir_etapa_produccion_v25(uuid,text) owner to postgres;

revoke all on public.rutas_produccion from public, anon;
revoke all on public.ruta_produccion_etapas from public, anon;
revoke all on public.formula_rutas_produccion from public, anon;
revoke all on public.ruta_produccion_eventos from public, anon;
revoke all on public.orden_produccion_etapas from public, anon;
revoke all on public.orden_produccion_etapa_eventos from public, anon;
revoke all on public.lotes_produccion from public, anon;
revoke insert, update, delete on public.rutas_produccion from authenticated;
revoke insert, update, delete on public.ruta_produccion_etapas from authenticated;
revoke insert, update, delete on public.formula_rutas_produccion from authenticated;
revoke insert, update, delete on public.ruta_produccion_eventos from authenticated;
revoke insert, update, delete on public.orden_produccion_etapas from authenticated;
revoke insert, update, delete on public.orden_produccion_etapa_eventos from authenticated;
revoke insert, update, delete on public.lotes_produccion from authenticated;
grant select on public.rutas_produccion to authenticated;
grant select on public.ruta_produccion_etapas to authenticated;
grant select on public.formula_rutas_produccion to authenticated;
grant select on public.ruta_produccion_eventos to authenticated;
grant select on public.orden_produccion_etapas to authenticated;
grant select on public.orden_produccion_etapa_eventos to authenticated;
grant select on public.lotes_produccion to authenticated;
grant select on public.vista_rutas_produccion_v25 to authenticated;
grant select on public.vista_seguimiento_produccion_v25 to authenticated;

revoke execute on function public.guardar_ruta_produccion_v25(uuid,uuid,text,text,text,jsonb)
  from public, anon;
revoke execute on function public.resolver_ruta_produccion_v25(uuid,boolean,text)
  from public, anon;
revoke execute on function public.asignar_ruta_formula_v25(uuid,uuid,text)
  from public, anon;
revoke execute on function public.iniciar_etapa_produccion_v25(uuid,uuid,uuid,text,uuid)
  from public, anon;
revoke execute on function public.completar_etapa_produccion_v25(uuid,integer,integer,numeric,text,uuid)
  from public, anon;
revoke execute on function public.omitir_etapa_produccion_v25(uuid,text)
  from public, anon;
grant execute on function public.guardar_ruta_produccion_v25(uuid,uuid,text,text,text,jsonb)
  to authenticated;
grant execute on function public.resolver_ruta_produccion_v25(uuid,boolean,text)
  to authenticated;
grant execute on function public.asignar_ruta_formula_v25(uuid,uuid,text)
  to authenticated;
grant execute on function public.iniciar_etapa_produccion_v25(uuid,uuid,uuid,text,uuid)
  to authenticated;
grant execute on function public.completar_etapa_produccion_v25(uuid,integer,integer,numeric,text,uuid)
  to authenticated;
grant execute on function public.omitir_etapa_produccion_v25(uuid,text)
  to authenticated;

revoke execute on function public.sembrar_etapas_orden_v25(uuid)
  from public, anon, authenticated;
revoke execute on function public.normalizar_costo_estimado_orden_v25()
  from public, anon, authenticated;
revoke execute on function public.preparar_etapas_orden_v25()
  from public, anon, authenticated;
revoke execute on function public.validar_cierre_etapas_v25()
  from public, anon, authenticated;
revoke execute on function public.generar_lote_produccion_v25()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
