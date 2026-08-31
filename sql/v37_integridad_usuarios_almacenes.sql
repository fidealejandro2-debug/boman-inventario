-- ============================================================
-- v37 - Integridad al guardar usuarios y asignar almacenes
--
-- Corrige la diferencia entre la aplicación y v12: el rol nomina no es
-- operativo de inventario y, por tanto, no requiere almacén.
-- También reúne perfil + almacenes en una sola transacción SQL para que un
-- fallo no deje el usuario configurado a medias.
-- ============================================================

begin;

create or replace function public.admin_asignar_almacenes(
  p_perfil_id uuid,
  p_almacen_ids uuid[]
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol text;
  v_ids uuid[];
  v_requiere_almacen boolean;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo un administrador puede asignar almacenes';
  end if;

  select coalesce(array_agg(x order by primera_posicion), array[]::uuid[])
  into v_ids
  from (
    select x, min(posicion) as primera_posicion
    from unnest(coalesce(p_almacen_ids, array[]::uuid[]))
      with ordinality as entrada(x, posicion)
    where x is not null
    group by x
  ) unicos;

  select rol::text into v_rol
  from public.perfiles
  where id = p_perfil_id and activo
  for update;
  if not found then
    raise exception 'El usuario no existe o está inactivo';
  end if;

  v_requiere_almacen := v_rol not in ('admin', 'control', 'gerencia', 'nomina');

  if exists (
    select 1
    from unnest(v_ids) x
    left join public.almacenes a on a.id = x and a.activo
    where a.id is null
  ) then
    raise exception 'Uno de los almacenes asignados no existe o está inactivo';
  end if;

  if v_requiere_almacen and cardinality(v_ids) = 0 then
    raise exception 'Los usuarios operativos deben tener al menos un almacén asignado';
  end if;

  delete from public.perfil_almacenes where perfil_id = p_perfil_id;

  if v_requiere_almacen then
    insert into public.perfil_almacenes(perfil_id, almacen_id)
    select p_perfil_id, x from unnest(v_ids) x
    on conflict do nothing;

    update public.perfiles
    set entidad_id = v_ids[1]
    where id = p_perfil_id;
  else
    update public.perfiles
    set entidad_id = null
    where id = p_perfil_id;
  end if;
end;
$$;

create or replace function public.admin_guardar_usuario_v37(
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
declare
  v_ids uuid[];
  v_requiere_almacen boolean;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo un administrador activo puede modificar usuarios';
  end if;

  select coalesce(array_agg(x order by primera_posicion), array[]::uuid[])
  into v_ids
  from (
    select x, min(posicion) as primera_posicion
    from unnest(coalesce(p_almacen_ids, array[]::uuid[]))
      with ordinality as entrada(x, posicion)
    where x is not null
    group by x
  ) unicos;

  v_requiere_almacen := p_rol::text not in (
    'admin', 'control', 'gerencia', 'nomina'
  );

  if v_requiere_almacen and p_activo and cardinality(v_ids) = 0 then
    raise exception 'Los usuarios operativos deben tener al menos un almacén asignado';
  end if;

  if exists (
    select 1
    from unnest(v_ids) x
    left join public.almacenes a on a.id = x and a.activo
    where a.id is null
  ) then
    raise exception 'Uno de los almacenes asignados no existe o está inactivo';
  end if;

  -- Ambas llamadas forman parte de esta misma transacción. Si la asignación
  -- falla, también se revierte el cambio realizado sobre el perfil.
  perform public.admin_actualizar_perfil(
    p_perfil_id,
    p_nombre_completo,
    p_rol,
    case when v_requiere_almacen then v_ids[1] else null end,
    p_activo
  );

  if p_activo then
    perform public.admin_asignar_almacenes(p_perfil_id, v_ids);
  elsif not v_requiere_almacen then
    delete from public.perfil_almacenes where perfil_id = p_perfil_id;
  end if;
end;
$$;

alter function public.admin_asignar_almacenes(uuid, uuid[]) owner to postgres;
alter function public.admin_guardar_usuario_v37(
  uuid, text, public.rol_usuario, uuid[], boolean
) owner to postgres;

revoke all on function public.admin_asignar_almacenes(uuid, uuid[])
  from public, anon;
revoke all on function public.admin_guardar_usuario_v37(
  uuid, text, public.rol_usuario, uuid[], boolean
) from public, anon;

grant execute on function public.admin_asignar_almacenes(uuid, uuid[])
  to authenticated;
grant execute on function public.admin_guardar_usuario_v37(
  uuid, text, public.rol_usuario, uuid[], boolean
) to authenticated;

comment on function public.admin_guardar_usuario_v37(
  uuid, text, public.rol_usuario, uuid[], boolean
) is 'Guarda perfil y almacenes en una sola transacción; v37.';

-- Repara residuos de la lógica anterior. Estos roles son globales y sus
-- permisos dependen del rol/matriz, no de perfil_almacenes.
delete from public.perfil_almacenes pa
using public.perfiles p
where p.id = pa.perfil_id
  and p.rol::text in ('admin', 'control', 'gerencia', 'nomina');

update public.perfiles
set entidad_id = null
where rol::text in ('admin', 'control', 'gerencia', 'nomina')
  and entidad_id is not null;

commit;
