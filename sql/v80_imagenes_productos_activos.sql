-- ============================================================
-- BOMAN INVENTARIO - v80: imagenes de productos y activos
--
-- Galeria comun para productos y maquinaria. Los archivos viven en un
-- bucket privado; la base autoriza la ruta antes de cada carga y conserva
-- el rastro aunque una imagen se archive.
-- Ejecutar una sola vez DESPUES de v79.
-- ============================================================

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'imagenes-entidades', 'imagenes-entidades', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.imagenes_entidades (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  entidad_tipo text not null check (entidad_tipo in ('producto', 'activo')),
  entidad_id uuid not null,
  storage_path text not null unique check (btrim(storage_path) <> ''),
  nombre_archivo text not null check (btrim(nombre_archivo) <> ''),
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp')),
  tamano_bytes bigint not null check (tamano_bytes between 1 and 5242880),
  descripcion text,
  es_portada boolean not null default false,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'activa', 'archivada')),
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  archivado_por uuid references public.perfiles(id) on delete restrict,
  archivado_at timestamptz,
  motivo_archivo text,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_imagenes_entidades_v80
  on public.imagenes_entidades(entidad_tipo, entidad_id, estado, es_portada desc, created_at);
create unique index if not exists uq_imagen_portada_v80
  on public.imagenes_entidades(entidad_tipo, entidad_id)
  where es_portada and estado = 'activa';

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
          then p.rol::text = 'admin'
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
    if not exists (select 1 from public.productos pr where pr.id = p_entidad_id)
       or not exists (select 1 from public.perfiles p where p.id = v_uid and p.rol::text = 'admin') then
      raise exception 'No tienes permiso para agregar imagenes a productos';
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

-- La politica de Storage no consulta la tabla directamente: las filas
-- pendientes todavia no son visibles por RLS. Esta funcion valida que la
-- autorizacion previa pertenezca a la misma sesion.
create or replace function public.puede_subir_archivo_imagen_v80(
  p_storage_path text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.imagenes_entidades i
    where i.storage_path = p_storage_path
      and i.estado = 'pendiente' and i.creado_por = auth.uid()
  );
$$;

create or replace function public.confirmar_imagen_entidad_v80(
  p_imagen_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_imagen public.imagenes_entidades%rowtype;
begin
  select * into v_imagen from public.imagenes_entidades
  where id = p_imagen_id for update;
  if not found or v_imagen.creado_por <> auth.uid() then
    raise exception 'Imagen no encontrada o sin permiso';
  end if;
  if v_imagen.estado = 'activa' then return; end if;
  if v_imagen.estado <> 'pendiente' then raise exception 'La imagen ya fue archivada'; end if;
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'imagenes-entidades' and o.name = v_imagen.storage_path
  ) then
    raise exception 'El archivo no termino de subir';
  end if;

  if v_imagen.es_portada or not exists (
    select 1 from public.imagenes_entidades i
    where i.entidad_tipo = v_imagen.entidad_tipo and i.entidad_id = v_imagen.entidad_id
      and i.estado = 'activa'
  ) then
    update public.imagenes_entidades set es_portada = false, updated_at = now()
    where entidad_tipo = v_imagen.entidad_tipo and entidad_id = v_imagen.entidad_id
      and estado = 'activa';
    v_imagen.es_portada := true;
  end if;

  update public.imagenes_entidades
  set estado = 'activa', es_portada = v_imagen.es_portada, updated_at = now()
  where id = v_imagen.id;
end;
$fn$;

create or replace function public.establecer_portada_imagen_v80(
  p_imagen_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_imagen public.imagenes_entidades%rowtype;
begin
  select * into v_imagen from public.imagenes_entidades where id = p_imagen_id;
  if not found or v_imagen.estado <> 'activa'
     or not public.puede_ver_imagen_entidad_v80(p_imagen_id, true) then
    raise exception 'Imagen no encontrada o sin permiso';
  end if;
  update public.imagenes_entidades set es_portada = false, updated_at = now()
  where entidad_tipo = v_imagen.entidad_tipo and entidad_id = v_imagen.entidad_id
    and estado = 'activa' and es_portada;
  update public.imagenes_entidades set es_portada = true, updated_at = now()
  where id = p_imagen_id;
end;
$fn$;

create or replace function public.archivar_imagen_entidad_v80(
  p_imagen_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_imagen public.imagenes_entidades%rowtype;
begin
  if length(btrim(coalesce(p_motivo, ''))) < 5 then
    raise exception 'Indica un motivo de al menos 5 caracteres';
  end if;
  select * into v_imagen from public.imagenes_entidades where id = p_imagen_id for update;
  if not found or v_imagen.estado <> 'activa'
     or not public.puede_ver_imagen_entidad_v80(p_imagen_id, true) then
    raise exception 'Imagen no encontrada o sin permiso';
  end if;
  update public.imagenes_entidades set
    estado = 'archivada', es_portada = false, archivado_por = auth.uid(),
    archivado_at = now(), motivo_archivo = btrim(p_motivo), updated_at = now()
  where id = p_imagen_id;

  if v_imagen.es_portada then
    update public.imagenes_entidades set es_portada = true, updated_at = now()
    where id = (
      select i.id from public.imagenes_entidades i
      where i.entidad_tipo = v_imagen.entidad_tipo and i.entidad_id = v_imagen.entidad_id
        and i.estado = 'activa'
      order by i.created_at, i.id limit 1
    );
  end if;
end;
$fn$;

alter table public.imagenes_entidades enable row level security;

drop policy if exists "leer_imagenes_entidades_v80" on public.imagenes_entidades;
create policy "leer_imagenes_entidades_v80" on public.imagenes_entidades
for select to authenticated using (
  estado = 'activa' and public.puede_ver_imagen_entidad_v80(id, false)
);

drop policy if exists "subir_archivo_imagen_v80" on storage.objects;
create policy "subir_archivo_imagen_v80" on storage.objects
for insert to authenticated with check (
  bucket_id = 'imagenes-entidades'
  and public.puede_subir_archivo_imagen_v80(name)
);

drop policy if exists "leer_archivo_imagen_v80" on storage.objects;
create policy "leer_archivo_imagen_v80" on storage.objects
for select to authenticated using (
  bucket_id = 'imagenes-entidades' and exists (
    select 1 from public.imagenes_entidades i
    where i.storage_path = name and i.estado = 'activa'
      and public.puede_ver_imagen_entidad_v80(i.id, false)
  )
);

revoke all on public.imagenes_entidades from public, anon;
revoke insert, update, delete on public.imagenes_entidades from authenticated;
grant select on public.imagenes_entidades to authenticated;

revoke all on function public.puede_ver_imagen_entidad_v80(uuid, boolean) from public, anon;
revoke all on function public.preparar_imagen_entidad_v80(text, uuid, text, text, bigint, text, boolean, uuid) from public, anon;
revoke all on function public.puede_subir_archivo_imagen_v80(text) from public, anon;
revoke all on function public.confirmar_imagen_entidad_v80(uuid) from public, anon;
revoke all on function public.establecer_portada_imagen_v80(uuid) from public, anon;
revoke all on function public.archivar_imagen_entidad_v80(uuid, text) from public, anon;
grant execute on function public.puede_ver_imagen_entidad_v80(uuid, boolean) to authenticated;
grant execute on function public.preparar_imagen_entidad_v80(text, uuid, text, text, bigint, text, boolean, uuid) to authenticated;
grant execute on function public.puede_subir_archivo_imagen_v80(text) to authenticated;
grant execute on function public.confirmar_imagen_entidad_v80(uuid) to authenticated;
grant execute on function public.establecer_portada_imagen_v80(uuid) to authenticated;
grant execute on function public.archivar_imagen_entidad_v80(uuid, text) to authenticated;

commit;
