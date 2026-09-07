-- ============================================================
-- BOMAN INVENTARIO - v89: fotos de productos para franquiciados
--
-- Todos los usuarios con acceso a Existencias conservan lectura y vista
-- previa. El administrador de cada franquicia puede agregar, cambiar la
-- portada y retirar fotos, pero solo de productos configurados en su almacen.
-- El vendedor de franquicia permanece en modo de solo lectura.
-- Ejecutar una sola vez DESPUES de v88.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.vista_portadas_productos_v88') is null
     or to_regprocedure('public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)') is null then
    raise exception 'Falta v88. Instalalo y validalo antes de v89';
  end if;
end $$;

create or replace function public.puede_editar_fotos_producto_v89(
  p_producto_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and exists (
        select 1 from public.productos pr where pr.id = p_producto_id
      )
      and (
        p.rol::text = 'admin'
        or (
          p.rol::text = 'franquiciado'
          and exists (
            select 1
            from public.perfil_almacenes pa
            join public.franquicias f
              on f.almacen_id = pa.almacen_id and f.activo
            join public.producto_almacen_config pac
              on pac.almacen_id = pa.almacen_id
             and pac.producto_id = p_producto_id
            where pa.perfil_id = p.id
          )
        )
      )
  );
$$;

create or replace function public.puede_ver_imagen_entidad_v80(
  p_imagen_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.imagenes_entidades i
    join public.perfiles p on p.id = auth.uid()
    where i.id = p_imagen_id and p.activo and p.grupo_id = i.grupo_id
      and (
        (i.entidad_tipo = 'producto' and exists (
          select 1 from public.productos pr where pr.id = i.entidad_id
        ) and case when p_escritura
          then public.puede_editar_fotos_producto_v89(i.entidad_id)
          else public.usuario_tiene_permiso_v35('inventario.acceder')
        end)
        or
        (i.entidad_tipo = 'activo'
          and public.puede_ver_activo_mantenimiento_v54(i.entidad_id, p_escritura))
      )
  );
$$;

create or replace function public.preparar_imagen_entidad_v80(
  p_entidad_tipo text,
  p_entidad_id uuid,
  p_nombre_archivo text,
  p_mime_type text,
  p_tamano_bytes bigint,
  p_descripcion text,
  p_es_portada boolean,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_grupo uuid;
  v_id uuid;
  v_path text;
  v_extension text;
  v_existente public.imagenes_entidades%rowtype;
begin
  if v_uid is null then raise exception 'Sesion requerida'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if p_entidad_tipo not in ('producto', 'activo') or p_entidad_id is null then
    raise exception 'Entidad de imagen invalida';
  end if;
  if lower(coalesce(p_mime_type, '')) not in ('image/jpeg', 'image/png', 'image/webp') then
    raise exception 'Formato no permitido. Usa JPG, PNG o WebP';
  end if;
  if p_tamano_bytes is null or p_tamano_bytes not between 1 and 5242880 then
    raise exception 'La imagen debe pesar como maximo 5 MB';
  end if;

  select * into v_existente from public.imagenes_entidades
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_existente.id, 'path', v_existente.storage_path);
  end if;

  select p.grupo_id into v_grupo from public.perfiles p
  where p.id = v_uid and p.activo;
  if v_grupo is null then raise exception 'El usuario no tiene grupo economico'; end if;

  if p_entidad_tipo = 'producto' then
    if not public.puede_editar_fotos_producto_v89(p_entidad_id) then
      raise exception 'No tienes permiso para agregar imagenes a este producto';
    end if;
  elsif not exists (
    select 1 from public.activos_mantenimiento a
    where a.id = p_entidad_id and a.grupo_id = v_grupo
      and public.puede_ver_activo_mantenimiento_v54(a.id, true)
  ) then
    raise exception 'No tienes permiso para agregar imagenes a este activo';
  end if;

  v_id := gen_random_uuid();
  v_extension := case lower(p_mime_type)
    when 'image/png' then 'png' when 'image/webp' then 'webp' else 'jpg' end;
  v_path := v_grupo::text || '/' || p_entidad_tipo || '/' ||
    p_entidad_id::text || '/' || v_id::text || '.' || v_extension;

  insert into public.imagenes_entidades (
    id, grupo_id, entidad_tipo, entidad_id, storage_path, nombre_archivo,
    mime_type, tamano_bytes, descripcion, es_portada, creado_por, idempotency_key
  ) values (
    v_id, v_grupo, p_entidad_tipo, p_entidad_id, v_path,
    left(btrim(coalesce(p_nombre_archivo, 'foto')), 255), lower(p_mime_type),
    p_tamano_bytes, nullif(btrim(coalesce(p_descripcion, '')), ''),
    coalesce(p_es_portada, false), v_uid, p_idempotency_key
  );

  return jsonb_build_object('id', v_id, 'path', v_path);
end;
$fn$;

alter function public.puede_editar_fotos_producto_v89(uuid) owner to postgres;
alter function public.puede_ver_imagen_entidad_v80(uuid, boolean) owner to postgres;
alter function public.preparar_imagen_entidad_v80(text, uuid, text, text, bigint, text, boolean, uuid) owner to postgres;

revoke all on function public.puede_editar_fotos_producto_v89(uuid) from public, anon, authenticated;
revoke all on function public.puede_ver_imagen_entidad_v80(uuid, boolean) from public, anon;
revoke all on function public.preparar_imagen_entidad_v80(text, uuid, text, text, bigint, text, boolean, uuid) from public, anon;
grant execute on function public.puede_ver_imagen_entidad_v80(uuid, boolean) to authenticated;
grant execute on function public.preparar_imagen_entidad_v80(text, uuid, text, text, bigint, text, boolean, uuid) to authenticated;

comment on function public.puede_editar_fotos_producto_v89(uuid) is
  'Autoriza fotos a admin global o franquiciado sobre productos configurados en su propio almacen.';

commit;

notify pgrst, 'reload schema';
