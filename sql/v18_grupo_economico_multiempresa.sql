-- ============================================================
-- BOMAN INVENTARIO - Grupo economico y operacion multiempresa v18
-- Separa la operacion fisica consolidada de la responsabilidad legal
-- de cada RUC sin dividir el catalogo ni el stock actual.
-- Ejecutar una sola vez DESPUES de v17.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Grupo economico, empresas legales y unidades operativas
-- ------------------------------------------------------------
create table if not exists public.grupos_economicos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  moneda text not null default 'USD' check (moneda ~ '^[A-Z]{3}$'),
  pais text not null default 'EC' check (pais ~ '^[A-Z]{2}$'),
  zona_horaria text not null default 'America/Guayaquil',
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.grupos_economicos (codigo, nombre)
values ('BOMAN', 'Grupo Economico Boman')
on conflict (codigo) do nothing;

create table if not exists public.empresas (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id),
  codigo text not null check (btrim(codigo) <> ''),
  ruc text not null check (ruc ~ '^[0-9]{13}$'),
  razon_social text not null check (btrim(razon_social) <> ''),
  nombre_comercial text,
  tipo text not null check (tipo in (
    'cia_ltda', 'sas', 'persona_natural', 'establecimiento_individual', 'otro'
  )),
  obligado_contabilidad boolean not null default false,
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id),
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, codigo),
  unique (ruc)
);

-- Una tienda o bodega puede trabajar para varios RUC. Solo una empresa puede
-- ser su operadora principal para clasificar automaticamente la operacion.
create table if not exists public.empresa_almacenes (
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  es_operadora_principal boolean not null default false,
  permite_ventas boolean not null default true,
  permite_compras boolean not null default true,
  custodia_inventario boolean not null default true,
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (empresa_id, almacen_id)
);

create unique index if not exists uq_empresa_almacenes_operadora_principal
  on public.empresa_almacenes(almacen_id)
  where es_operadora_principal;

create table if not exists public.perfil_empresas (
  perfil_id uuid not null references public.perfiles(id) on delete cascade,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  puede_operar boolean not null default true,
  asignado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  primary key (perfil_id, empresa_id)
);

create table if not exists public.configuracion_multiempresa_eventos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in (
    'empresa_creada', 'empresa_actualizada', 'almacenes_asignados',
    'usuarios_asignados', 'clasificacion_automatica'
  )),
  empresa_id uuid references public.empresas(id) on delete restrict,
  detalle jsonb not null default '{}'::jsonb,
  usuario_id uuid references public.perfiles(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_empresas_grupo_activo
  on public.empresas(grupo_id, activo, razon_social);
create index if not exists idx_empresa_almacenes_almacen
  on public.empresa_almacenes(almacen_id, empresa_id);
create index if not exists idx_perfil_empresas_empresa
  on public.perfil_empresas(empresa_id, perfil_id);
create index if not exists idx_config_multiempresa_fecha
  on public.configuracion_multiempresa_eventos(created_at desc);

-- ------------------------------------------------------------
-- 2. Contexto legal en documentos existentes
-- ------------------------------------------------------------
alter table public.emisores_facturacion
  add column if not exists empresa_id uuid references public.empresas(id) on delete restrict;

alter table public.documentos_venta_xml
  add column if not exists empresa_id uuid references public.empresas(id) on delete restrict;

alter table public.documentos_inventario
  add column if not exists empresa_responsable_id uuid references public.empresas(id) on delete restrict;

alter table public.movimientos
  add column if not exists empresa_id uuid references public.empresas(id) on delete restrict;

create index if not exists idx_emisores_facturacion_empresa
  on public.emisores_facturacion(empresa_id);
create index if not exists idx_documentos_venta_xml_empresa_fecha
  on public.documentos_venta_xml(empresa_id, fecha_emision desc);
create index if not exists idx_documentos_inventario_empresa
  on public.documentos_inventario(empresa_responsable_id, created_at desc);
create index if not exists idx_movimientos_empresa_fecha
  on public.movimientos(empresa_id, created_at desc);

comment on column public.documentos_inventario.empresa_responsable_id is
  'Empresa responsable del documento operativo; no implica por si sola propiedad contable del stock.';
comment on column public.movimientos.empresa_id is
  'Atribucion operativa/legal del movimiento. La propiedad contable se implementa en un libro separado.';

-- ------------------------------------------------------------
-- 3. Acceso por empresa
-- ------------------------------------------------------------
create or replace function public.usuario_puede_empresa(
  p_empresa_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_empresa_id is not null and exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text in ('admin', 'control')
        or (not p_escritura and p.rol::text = 'gerencia')
        or exists (
          select 1
          from public.perfil_empresas pe
          where pe.perfil_id = p.id
            and pe.empresa_id = p_empresa_id
            and (not p_escritura or pe.puede_operar)
        )
        or exists (
          select 1
          from public.empresa_almacenes ea
          where ea.empresa_id = p_empresa_id
            and public.usuario_puede_almacen(ea.almacen_id, p_escritura)
        )
      )
  );
$$;

alter table public.grupos_economicos enable row level security;
alter table public.empresas enable row level security;
alter table public.empresa_almacenes enable row level security;
alter table public.perfil_empresas enable row level security;
alter table public.configuracion_multiempresa_eventos enable row level security;

drop policy if exists "leer_grupos_economicos" on public.grupos_economicos;
create policy "leer_grupos_economicos"
on public.grupos_economicos for select to authenticated using (activo);

drop policy if exists "leer_empresas" on public.empresas;
create policy "leer_empresas"
on public.empresas for select to authenticated using (
  public.usuario_puede_empresa(id, false)
);

drop policy if exists "leer_empresa_almacenes" on public.empresa_almacenes;
create policy "leer_empresa_almacenes"
on public.empresa_almacenes for select to authenticated using (
  public.usuario_puede_empresa(empresa_id, false)
  or public.usuario_puede_almacen(almacen_id, false)
);

drop policy if exists "leer_perfil_empresas" on public.perfil_empresas;
create policy "leer_perfil_empresas"
on public.perfil_empresas for select to authenticated using (
  perfil_id = auth.uid()
  or public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);

drop policy if exists "leer_configuracion_multiempresa_eventos" on public.configuracion_multiempresa_eventos;
create policy "leer_configuracion_multiempresa_eventos"
on public.configuracion_multiempresa_eventos for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);

-- ------------------------------------------------------------
-- 4. Administracion auditada de empresas y asignaciones
-- ------------------------------------------------------------
create or replace function public.admin_guardar_empresa(
  p_empresa_id uuid,
  p_grupo_id uuid,
  p_codigo text,
  p_ruc text,
  p_razon_social text,
  p_nombre_comercial text,
  p_tipo text,
  p_obligado_contabilidad boolean,
  p_activo boolean
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_antes jsonb;
  v_tipo_evento text;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede configurar empresas y RUC';
  end if;
  if not exists (
    select 1 from public.grupos_economicos where id = p_grupo_id and activo
  ) then raise exception 'El grupo economico no existe o esta inactivo'; end if;
  if btrim(coalesce(p_codigo, '')) = '' then raise exception 'El codigo de empresa es obligatorio'; end if;
  if btrim(coalesce(p_ruc, '')) !~ '^[0-9]{13}$' then raise exception 'El RUC debe tener 13 digitos'; end if;
  if btrim(coalesce(p_razon_social, '')) = '' then raise exception 'La razon social es obligatoria'; end if;
  if p_tipo not in ('cia_ltda', 'sas', 'persona_natural', 'establecimiento_individual', 'otro') then
    raise exception 'El tipo de empresa no es valido';
  end if;

  if p_empresa_id is null then
    insert into public.empresas (
      grupo_id, codigo, ruc, razon_social, nombre_comercial, tipo,
      obligado_contabilidad, activo, creado_por, actualizado_por
    ) values (
      p_grupo_id, upper(btrim(p_codigo)), btrim(p_ruc), btrim(p_razon_social),
      nullif(btrim(p_nombre_comercial), ''), p_tipo,
      coalesce(p_obligado_contabilidad, false), coalesce(p_activo, true),
      auth.uid(), auth.uid()
    ) returning id into v_id;
    v_tipo_evento := 'empresa_creada';
  else
    select to_jsonb(e) into v_antes
    from public.empresas e where e.id = p_empresa_id for update;
    if not found then raise exception 'La empresa no existe'; end if;

    if (v_antes->>'ruc') <> btrim(p_ruc) and exists (
      select 1 from public.documentos_venta_xml where empresa_id = p_empresa_id
    ) then
      raise exception 'El RUC no puede cambiar porque ya tiene facturas. Crea una empresa nueva para el nuevo RUC';
    end if;

    update public.empresas
    set grupo_id = p_grupo_id,
        codigo = upper(btrim(p_codigo)),
        ruc = btrim(p_ruc),
        razon_social = btrim(p_razon_social),
        nombre_comercial = nullif(btrim(p_nombre_comercial), ''),
        tipo = p_tipo,
        obligado_contabilidad = coalesce(p_obligado_contabilidad, false),
        activo = coalesce(p_activo, true),
        actualizado_por = auth.uid(),
        updated_at = now()
    where id = p_empresa_id
    returning id into v_id;
    v_tipo_evento := 'empresa_actualizada';
  end if;

  -- Vincula automaticamente el emisor y todo su historial XML por RUC.
  update public.emisores_facturacion
  set empresa_id = v_id, updated_at = now()
  where ruc = btrim(p_ruc);

  update public.documentos_venta_xml
  set empresa_id = v_id
  where emisor_ruc = btrim(p_ruc)
    and empresa_id is distinct from v_id;

  insert into public.configuracion_multiempresa_eventos
    (tipo, empresa_id, detalle, usuario_id)
  values (
    v_tipo_evento, v_id,
    jsonb_build_object(
      'antes', v_antes,
      'despues', (select to_jsonb(e) from public.empresas e where e.id = v_id)
    ),
    auth.uid()
  );
  return v_id;
end;
$$;

create or replace function public.admin_configurar_empresa_almacenes(
  p_empresa_id uuid,
  p_items jsonb
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede asignar tiendas y bodegas';
  end if;
  if not exists (select 1 from public.empresas where id = p_empresa_id) then
    raise exception 'La empresa no existe';
  end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'La configuracion de almacenes no es valida';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      almacen_id uuid, es_operadora_principal boolean, permite_ventas boolean,
      permite_compras boolean, custodia_inventario boolean
    )
    left join public.almacenes a on a.id = x.almacen_id and a.activo
    where x.almacen_id is null or a.id is null
  ) then raise exception 'Uno de los almacenes no existe o esta inactivo'; end if;
  if exists (
    select almacen_id
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(almacen_id uuid)
    group by almacen_id having count(*) > 1
  ) then raise exception 'La lista contiene almacenes repetidos'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      almacen_id uuid, es_operadora_principal boolean
    )
    join public.empresa_almacenes ea on ea.almacen_id = x.almacen_id
      and ea.es_operadora_principal and ea.empresa_id <> p_empresa_id
    where coalesce(x.es_operadora_principal, false)
  ) then raise exception 'Uno de los almacenes ya tiene otra empresa operadora principal'; end if;

  delete from public.empresa_almacenes where empresa_id = p_empresa_id;
  insert into public.empresa_almacenes (
    empresa_id, almacen_id, es_operadora_principal, permite_ventas,
    permite_compras, custodia_inventario, actualizado_por
  )
  select p_empresa_id, x.almacen_id, coalesce(x.es_operadora_principal, false),
         coalesce(x.permite_ventas, true), coalesce(x.permite_compras, true),
         coalesce(x.custodia_inventario, true), auth.uid()
  from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
    almacen_id uuid, es_operadora_principal boolean, permite_ventas boolean,
    permite_compras boolean, custodia_inventario boolean
  );
  get diagnostics v_total = row_count;

  -- Clasifica documentos fisicos solo cuando esta empresa es la operadora
  -- principal. Esto atribuye responsabilidad operativa, no propiedad contable.
  update public.documentos_inventario d
  set empresa_responsable_id = p_empresa_id
  where d.empresa_responsable_id is null
    and exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = p_empresa_id and ea.es_operadora_principal
        and ea.almacen_id = coalesce(d.destino_id, d.origen_id)
    );

  update public.movimientos m
  set empresa_id = p_empresa_id
  where m.empresa_id is null
    and exists (
      select 1 from public.empresa_almacenes ea
      where ea.empresa_id = p_empresa_id and ea.es_operadora_principal
        and ea.almacen_id = m.entidad_id
    );

  insert into public.configuracion_multiempresa_eventos
    (tipo, empresa_id, detalle, usuario_id)
  values (
    'almacenes_asignados', p_empresa_id,
    jsonb_build_object('almacenes', coalesce(p_items, '[]'::jsonb)), auth.uid()
  );
  return v_total;
end;
$$;

create or replace function public.admin_asignar_empresas_perfil(
  p_perfil_id uuid,
  p_items jsonb
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede asignar empresas a usuarios';
  end if;
  if not exists (select 1 from public.perfiles where id = p_perfil_id and activo) then
    raise exception 'El usuario no existe o esta inactivo';
  end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'La lista de empresas no es valida';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      empresa_id uuid, puede_operar boolean
    )
    left join public.empresas e on e.id = x.empresa_id and e.activo
    where x.empresa_id is null or e.id is null
  ) then raise exception 'Una empresa asignada no existe o esta inactiva'; end if;

  delete from public.perfil_empresas where perfil_id = p_perfil_id;
  insert into public.perfil_empresas (perfil_id, empresa_id, puede_operar, asignado_por)
  select p_perfil_id, x.empresa_id, bool_or(coalesce(x.puede_operar, true)), auth.uid()
  from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
    empresa_id uuid, puede_operar boolean
  )
  group by x.empresa_id;
  get diagnostics v_total = row_count;

  insert into public.configuracion_multiempresa_eventos
    (tipo, detalle, usuario_id)
  values (
    'usuarios_asignados',
    jsonb_build_object('perfil_id', p_perfil_id, 'empresas', coalesce(p_items, '[]'::jsonb)),
    auth.uid()
  );
  return v_total;
end;
$$;

-- Guarda cabecera y almacenes en una sola transaccion. Si una asignacion
-- falla, tampoco queda creada o modificada parcialmente la empresa.
create or replace function public.admin_guardar_empresa_completa(
  p_empresa_id uuid,
  p_grupo_id uuid,
  p_codigo text,
  p_ruc text,
  p_razon_social text,
  p_nombre_comercial text,
  p_tipo text,
  p_obligado_contabilidad boolean,
  p_activo boolean,
  p_almacenes jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := public.admin_guardar_empresa(
    p_empresa_id, p_grupo_id, p_codigo, p_ruc, p_razon_social,
    p_nombre_comercial, p_tipo, p_obligado_contabilidad, p_activo
  );
  perform public.admin_configurar_empresa_almacenes(v_id, p_almacenes);
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 5. Clasificacion automatica de nuevos documentos
-- ------------------------------------------------------------
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
      select e.empresa_id into v_empresa_id
      from public.emisores_facturacion e
      join public.empresas c on c.id = e.empresa_id and c.activo
      where e.ruc = new.emisor_ruc and e.activo;
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
    if new.empresa_id is null and new.grupo_id is not null then
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

drop trigger if exists trg_clasificar_empresa_venta_xml on public.documentos_venta_xml;
create trigger trg_clasificar_empresa_venta_xml
before insert on public.documentos_venta_xml
for each row execute function public.clasificar_contexto_empresa();

drop trigger if exists trg_clasificar_empresa_documento_inventario on public.documentos_inventario;
create trigger trg_clasificar_empresa_documento_inventario
before insert on public.documentos_inventario
for each row execute function public.clasificar_contexto_empresa();

drop trigger if exists trg_clasificar_empresa_movimiento on public.movimientos;
create trigger trg_clasificar_empresa_movimiento
before insert on public.movimientos
for each row execute function public.clasificar_contexto_empresa();

-- ------------------------------------------------------------
-- 6. Vistas consolidadas y pendientes de clasificacion
-- ------------------------------------------------------------
create or replace view public.vista_resumen_multiempresa
with (security_invoker = true) as
select
  e.id as empresa_id,
  e.grupo_id,
  e.codigo,
  e.ruc,
  e.razon_social,
  e.nombre_comercial,
  e.tipo,
  e.obligado_contabilidad,
  e.activo,
  (select count(*) from public.empresa_almacenes ea where ea.empresa_id = e.id) as almacenes_asignados,
  (select count(*) from public.empresa_almacenes ea where ea.empresa_id = e.id and ea.es_operadora_principal) as almacenes_principales,
  (select count(*) from public.perfil_empresas pe where pe.empresa_id = e.id) as usuarios_asignados,
  -- Cuenta documentos vinculados sin depender de la columna `anulado` de v14.
  -- Algunas instalaciones historicas aplicaron v13 y v17 sin completar v14;
  -- la conciliacion dedicada puede separar activas/anuladas cuando esa columna exista.
  (select count(*) from public.documentos_venta_xml dv where dv.empresa_id = e.id) as facturas_xml,
  (
    select coalesce(sum(i.cantidad), 0)
    from public.empresa_almacenes ea
    join public.inventario i on i.entidad_id = ea.almacen_id
    where ea.empresa_id = e.id and ea.es_operadora_principal
  ) as stock_fisico_operado
from public.empresas e;

create or replace view public.vista_pendientes_multiempresa
with (security_invoker = true) as
select 'emisores_sin_empresa'::text as tipo,
       count(*)::bigint as cantidad,
       'RUC emisores habilitados que aun no corresponden a una empresa'::text as detalle
from public.emisores_facturacion where empresa_id is null
union all
select 'almacenes_sin_operadora', count(*)::bigint,
       'Tiendas o bodegas activas sin una empresa operadora principal'
from public.almacenes a
where a.activo and not exists (
  select 1 from public.empresa_almacenes ea
  where ea.almacen_id = a.id and ea.es_operadora_principal
)
union all
select 'facturas_sin_empresa', count(*)::bigint,
       'Facturas XML historicas pendientes de atribucion legal'
from public.documentos_venta_xml where empresa_id is null
union all
select 'documentos_inventario_sin_empresa', count(*)::bigint,
       'Documentos operativos pendientes de empresa responsable'
from public.documentos_inventario where empresa_responsable_id is null
union all
select 'movimientos_sin_empresa', count(*)::bigint,
       'Movimientos historicos pendientes de clasificacion empresarial'
from public.movimientos where empresa_id is null;

-- ------------------------------------------------------------
-- 7. Propiedad, privilegios y recarga de PostgREST
-- ------------------------------------------------------------
alter function public.usuario_puede_empresa(uuid, boolean) owner to postgres;
alter function public.admin_guardar_empresa(uuid, uuid, text, text, text, text, text, boolean, boolean) owner to postgres;
alter function public.admin_configurar_empresa_almacenes(uuid, jsonb) owner to postgres;
alter function public.admin_asignar_empresas_perfil(uuid, jsonb) owner to postgres;
alter function public.admin_guardar_empresa_completa(uuid, uuid, text, text, text, text, text, boolean, boolean, jsonb) owner to postgres;
alter function public.clasificar_contexto_empresa() owner to postgres;

revoke all on public.grupos_economicos from public, anon;
revoke all on public.empresas from public, anon;
revoke all on public.empresa_almacenes from public, anon;
revoke all on public.perfil_empresas from public, anon;
revoke all on public.configuracion_multiempresa_eventos from public, anon;
revoke insert, update, delete on public.grupos_economicos from authenticated;
revoke insert, update, delete on public.empresas from authenticated;
revoke insert, update, delete on public.empresa_almacenes from authenticated;
revoke insert, update, delete on public.perfil_empresas from authenticated;
revoke insert, update, delete on public.configuracion_multiempresa_eventos from authenticated;
grant select on public.grupos_economicos to authenticated;
grant select on public.empresas to authenticated;
grant select on public.empresa_almacenes to authenticated;
grant select on public.perfil_empresas to authenticated;
grant select on public.configuracion_multiempresa_eventos to authenticated;
grant select on public.vista_resumen_multiempresa to authenticated;
grant select on public.vista_pendientes_multiempresa to authenticated;

revoke execute on function public.usuario_puede_empresa(uuid, boolean) from public, anon;
grant execute on function public.usuario_puede_empresa(uuid, boolean) to authenticated;
revoke execute on function public.admin_guardar_empresa(uuid, uuid, text, text, text, text, text, boolean, boolean) from public, anon;
revoke execute on function public.admin_configurar_empresa_almacenes(uuid, jsonb) from public, anon;
revoke execute on function public.admin_asignar_empresas_perfil(uuid, jsonb) from public, anon;
revoke execute on function public.admin_guardar_empresa_completa(uuid, uuid, text, text, text, text, text, boolean, boolean, jsonb) from public, anon;
grant execute on function public.admin_guardar_empresa(uuid, uuid, text, text, text, text, text, boolean, boolean) to authenticated;
grant execute on function public.admin_configurar_empresa_almacenes(uuid, jsonb) to authenticated;
grant execute on function public.admin_asignar_empresas_perfil(uuid, jsonb) to authenticated;
grant execute on function public.admin_guardar_empresa_completa(uuid, uuid, text, text, text, text, text, boolean, boolean, jsonb) to authenticated;
revoke execute on function public.clasificar_contexto_empresa() from public, anon, authenticated;

notify pgrst, 'reload schema';
