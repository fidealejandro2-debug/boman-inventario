-- ============================================================
-- BOMAN INVENTARIO - Bloqueo y concurrencia de conteos v22
-- Responsable exclusivo, toma de control auditada y control optimista
-- de version para impedir que una sesion antigua sobrescriba otra.
-- Ejecutar una sola vez DESPUES de v21.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Responsable y actividad de edicion
-- ------------------------------------------------------------
alter table public.documentos_inventario
  add column if not exists conteo_responsable_id uuid
    references public.perfiles(id) on delete restrict,
  add column if not exists conteo_actividad_at timestamptz;

create index if not exists idx_documentos_conteo_responsable
  on public.documentos_inventario(conteo_responsable_id, estado)
  where tipo = 'conteo';

-- Los conteos historicos quedan atribuidos a quien los creo. La actividad
-- solo permanece visible para los que siguen abiertos.
update public.documentos_inventario
set conteo_responsable_id = creado_por,
    conteo_actividad_at = case when estado = 'en_conteo' then updated_at end
where tipo = 'conteo' and conteo_responsable_id is null;

create table if not exists public.conteo_responsable_eventos (
  id uuid primary key default gen_random_uuid(),
  documento_id uuid not null references public.documentos_inventario(id) on delete restrict,
  responsable_anterior_id uuid references public.perfiles(id) on delete restrict,
  responsable_nuevo_id uuid not null references public.perfiles(id) on delete restrict,
  motivo text not null check (btrim(motivo) <> ''),
  realizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_conteo_responsable_eventos_documento
  on public.conteo_responsable_eventos(documento_id, created_at desc);

alter table public.conteo_responsable_eventos enable row level security;
drop policy if exists "leer_conteo_responsable_eventos_v22"
  on public.conteo_responsable_eventos;
create policy "leer_conteo_responsable_eventos_v22"
on public.conteo_responsable_eventos for select to authenticated using (
  public.puede_ver_documento(documento_id)
);

create or replace function public.inicializar_responsable_conteo_v22()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.tipo = 'conteo' then
    new.conteo_responsable_id := coalesce(new.conteo_responsable_id, new.creado_por, auth.uid());
    new.conteo_actividad_at := coalesce(new.conteo_actividad_at, now());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_inicializar_responsable_conteo_v22
  on public.documentos_inventario;
create trigger trg_inicializar_responsable_conteo_v22
before insert on public.documentos_inventario
for each row execute function public.inicializar_responsable_conteo_v22();

-- ------------------------------------------------------------
-- 2. Apertura y toma de control
-- ------------------------------------------------------------
create or replace function public.abrir_edicion_conteo_v22(
  p_documento_id uuid,
  p_forzar boolean default false,
  p_motivo text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_responsable_id uuid;
  v_responsable_nombre text;
  v_version integer;
  v_forzado boolean := false;
begin
  if v_rol not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para editar conteos';
  end if;

  select * into d
  from public.documentos_inventario
  where id = p_documento_id
  for update;

  if not found or d.tipo <> 'conteo' or d.estado <> 'en_conteo' then
    raise exception 'El conteo no esta abierto';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacen';
  end if;

  v_responsable_id := coalesce(d.conteo_responsable_id, d.creado_por);
  select nombre_completo into v_responsable_nombre
  from public.perfiles where id = v_responsable_id;

  if v_responsable_id is distinct from auth.uid() then
    if v_rol <> 'admin' or not coalesce(p_forzar, false) then
      raise exception 'Conteo asignado a %. Solicita al administrador que tome el control.',
        coalesce(v_responsable_nombre, 'otro usuario');
    end if;
    if btrim(coalesce(p_motivo, '')) = '' then
      raise exception 'La toma de control requiere un motivo';
    end if;

    update public.documentos_inventario
    set conteo_responsable_id = auth.uid(),
        conteo_actividad_at = now(),
        updated_at = now(),
        version = version + 1
    where id = d.id
    returning version into v_version;

    insert into public.conteo_responsable_eventos (
      documento_id, responsable_anterior_id, responsable_nuevo_id,
      motivo, realizado_por
    ) values (
      d.id, v_responsable_id, auth.uid(), btrim(p_motivo), auth.uid()
    );

    perform public.registrar_evento_documento(
      d.id, 'en_conteo', 'en_conteo',
      'Toma de control administrativa. Responsable anterior: '
        || coalesce(v_responsable_nombre, v_responsable_id::text)
        || '. Motivo: ' || btrim(p_motivo)
    );
    v_forzado := true;
  else
    update public.documentos_inventario
    set conteo_responsable_id = auth.uid(), conteo_actividad_at = now()
    where id = d.id
    returning version into v_version;
  end if;

  select nombre_completo into v_responsable_nombre
  from public.perfiles where id = auth.uid();

  return jsonb_build_object(
    'documento_id', d.id,
    'version', v_version,
    'responsable_id', auth.uid(),
    'responsable_nombre', v_responsable_nombre,
    'actividad_at', now(),
    'toma_control', v_forzado
  );
end;
$$;

-- ------------------------------------------------------------
-- 3. Guardado protegido por responsable y version
-- ------------------------------------------------------------
create or replace function public.guardar_conteo_inventario_v22(
  p_documento_id uuid,
  p_items jsonb,
  p_enviar_revision boolean,
  p_nota text,
  p_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  v_version integer;
  v_estado text;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para registrar conteos';
  end if;

  select * into d
  from public.documentos_inventario
  where id = p_documento_id
  for update;

  if not found or d.tipo <> 'conteo' or d.estado <> 'en_conteo' then
    raise exception 'El conteo no esta abierto';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacen';
  end if;
  if coalesce(d.conteo_responsable_id, d.creado_por) is distinct from auth.uid() then
    raise exception 'El conteo pertenece a otro responsable. Abrelo o usa la toma de control administrativa.';
  end if;
  if p_version is null or p_version <> d.version then
    raise exception 'El conteo cambio en otra sesion. Recarga antes de guardar para no sobrescribir informacion.';
  end if;

  -- Reutiliza la validacion historica dentro de la misma transaccion. El
  -- bloqueo FOR UPDATE y la version ya impiden doble guardado o last-write-wins.
  perform public.guardar_conteo_inventario(
    p_documento_id, p_items, coalesce(p_enviar_revision, false), p_nota
  );

  update public.documentos_inventario
  set conteo_actividad_at = case when estado = 'en_conteo' then now() end
  where id = p_documento_id
  returning version, estado into v_version, v_estado;

  return jsonb_build_object(
    'documento_id', p_documento_id,
    'version', v_version,
    'estado', v_estado,
    'enviado_revision', v_estado = 'pendiente_revision'
  );
end;
$$;

-- ------------------------------------------------------------
-- 4. Propiedad y privilegios
-- ------------------------------------------------------------
alter function public.inicializar_responsable_conteo_v22() owner to postgres;
alter function public.abrir_edicion_conteo_v22(uuid, boolean, text) owner to postgres;
alter function public.guardar_conteo_inventario_v22(uuid, jsonb, boolean, text, integer)
  owner to postgres;

revoke all on public.conteo_responsable_eventos from public, anon;
revoke insert, update, delete on public.conteo_responsable_eventos from authenticated;
grant select on public.conteo_responsable_eventos to authenticated;

revoke execute on function public.inicializar_responsable_conteo_v22()
  from public, anon, authenticated;
revoke execute on function public.abrir_edicion_conteo_v22(uuid, boolean, text)
  from public, anon;
revoke execute on function public.guardar_conteo_inventario_v22(uuid, jsonb, boolean, text, integer)
  from public, anon;
grant execute on function public.abrir_edicion_conteo_v22(uuid, boolean, text)
  to authenticated;
grant execute on function public.guardar_conteo_inventario_v22(uuid, jsonb, boolean, text, integer)
  to authenticated;

-- Impide que el cliente omita las validaciones de responsable y version.
revoke execute on function public.guardar_conteo_inventario(uuid, jsonb, boolean, text)
  from authenticated;

notify pgrst, 'reload schema';
