-- ============================================================
-- BOMAN INVENTARIO - Actualizacion v7
-- Administracion auditada de usuarios desde el panel.
-- Ejecutar DESPUES de v6. No modifica migraciones anteriores.
-- ============================================================

create table if not exists perfiles_cambios (
  id uuid primary key default gen_random_uuid(),
  perfil_id uuid not null references perfiles(id),
  realizado_por uuid not null references perfiles(id),
  valores_anteriores jsonb not null,
  valores_nuevos jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_perfiles_cambios_perfil_fecha
  on perfiles_cambios(perfil_id, created_at desc);

alter table perfiles_cambios enable row level security;

drop policy if exists "admin_lee_perfiles_cambios" on perfiles_cambios;
create policy "admin_lee_perfiles_cambios"
on perfiles_cambios for select to authenticated using (
  exists (
    select 1 from perfiles p
    where p.id = auth.uid() and p.activo and p.rol = 'admin'
  )
);

create or replace function admin_actualizar_perfil(
  p_perfil_id uuid,
  p_nombre_completo text,
  p_rol rol_usuario,
  p_entidad_id uuid,
  p_activo boolean
) returns void as $$
declare
  v_uid uuid := auth.uid();
  v_anterior perfiles%rowtype;
  v_entidad_final uuid := p_entidad_id;
  v_otros_admins integer;
begin
  if not exists (
    select 1 from perfiles
    where id = v_uid and activo and rol = 'admin'
  ) then
    raise exception 'Solo un administrador activo puede modificar usuarios';
  end if;

  if p_perfil_id is null then
    raise exception 'Debes indicar el usuario';
  end if;
  if p_nombre_completo is null or btrim(p_nombre_completo) = '' then
    raise exception 'El nombre completo es obligatorio';
  end if;
  if p_rol is null then
    raise exception 'Debes indicar el rol';
  end if;
  if p_activo is null then
    raise exception 'Debes indicar si el usuario esta activo';
  end if;

  select * into v_anterior
  from perfiles
  where id = p_perfil_id
  for update;

  if not found then
    raise exception 'El perfil indicado no existe';
  end if;

  if p_perfil_id = v_uid and (p_rol <> 'admin' or not p_activo) then
    raise exception 'No puedes quitarte tu propio acceso de administrador';
  end if;

  if p_rol in ('admin', 'gerencia') then
    v_entidad_final := null;
  elsif v_entidad_final is not null and not exists (
    select 1 from almacenes where id = v_entidad_final and activo
  ) then
    raise exception 'El almacen asignado no existe o esta inactivo';
  end if;

  if v_anterior.rol = 'admin' and v_anterior.activo
     and (p_rol <> 'admin' or not p_activo) then
    select count(*) into v_otros_admins
    from perfiles
    where id <> p_perfil_id and rol = 'admin' and activo;

    if v_otros_admins = 0 then
      raise exception 'Debe quedar al menos un administrador activo';
    end if;
  end if;

  update perfiles
  set nombre_completo = btrim(p_nombre_completo),
      rol = p_rol,
      entidad_id = v_entidad_final,
      activo = p_activo
  where id = p_perfil_id;

  if row(
    v_anterior.nombre_completo,
    v_anterior.rol,
    v_anterior.entidad_id,
    v_anterior.activo
  ) is distinct from row(
    btrim(p_nombre_completo),
    p_rol,
    v_entidad_final,
    p_activo
  ) then
    insert into perfiles_cambios (
      perfil_id,
      realizado_por,
      valores_anteriores,
      valores_nuevos
    ) values (
      p_perfil_id,
      v_uid,
      jsonb_build_object(
        'nombre_completo', v_anterior.nombre_completo,
        'rol', v_anterior.rol,
        'entidad_id', v_anterior.entidad_id,
        'activo', v_anterior.activo
      ),
      jsonb_build_object(
        'nombre_completo', btrim(p_nombre_completo),
        'rol', p_rol,
        'entidad_id', v_entidad_final,
        'activo', p_activo
      )
    );
  end if;
end;
$$ language plpgsql security definer set search_path = public;

revoke update on perfiles from public, anon, authenticated;
revoke insert, update, delete on perfiles_cambios from public, anon, authenticated;
grant select on perfiles_cambios to authenticated;

revoke execute on function admin_actualizar_perfil(uuid, text, rol_usuario, uuid, boolean)
  from public, anon;
grant execute on function admin_actualizar_perfil(uuid, text, rol_usuario, uuid, boolean)
  to authenticated;

