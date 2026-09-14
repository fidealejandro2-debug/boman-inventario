-- ============================================================
-- v138 - Comprobantes privados para depositos de caja
-- Ejecutar despues de v137 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v138', 0));

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta v134: no existe el registro formal de migraciones';
  end if;
  if to_regclass('public.caja_depositos_v87') is null
     or to_regprocedure('public.registrar_deposito_caja_v87(uuid,date,numeric,text,text,text,text,uuid)') is null then
    raise exception 'Falta v87: instala primero la conciliacion de depositos de caja';
  end if;
end;
$requisitos$;

alter table public.caja_depositos_v87
  add column if not exists comprobante_storage_path text,
  add column if not exists comprobante_nombre text,
  add column if not exists comprobante_mime_type text,
  add column if not exists comprobante_tamano_bytes bigint;

create unique index if not exists uq_caja_deposito_comprobante_path_v138
  on public.caja_depositos_v87(comprobante_storage_path)
  where comprobante_storage_path is not null;

create table if not exists public.caja_comprobantes_pendientes_v138 (
  id uuid primary key,
  cierre_id uuid not null references public.franquicia_caja_cierres(id) on delete restrict,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  creado_por uuid not null references public.perfiles(id) on delete cascade,
  storage_path text not null unique check (btrim(storage_path) <> ''),
  nombre_archivo text not null check (btrim(nombre_archivo) <> ''),
  mime_type text not null check (mime_type in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  )),
  tamano_bytes bigint not null check (tamano_bytes between 1 and 8388608),
  usado_en uuid references public.caja_depositos_v87(id) on delete set null,
  vence_en timestamptz not null default now() + interval '24 hours',
  created_at timestamptz not null default now()
);

create index if not exists idx_caja_comprobantes_pendientes_usuario_v138
  on public.caja_comprobantes_pendientes_v138(creado_por, vence_en desc)
  where usado_en is null;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'caja-comprobantes', 'caja-comprobantes', false, 8388608,
  array['image/jpeg','image/png','image/webp','application/pdf']::text[]
)
on conflict(id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.preparar_comprobante_deposito_v138(
  p_cierre_id uuid,
  p_nombre_archivo text,
  p_mime_type text,
  p_tamano_bytes bigint,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $v138$
declare
  v_uid uuid := auth.uid();
  v_cierre public.franquicia_caja_cierres%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_ext text;
  v_path text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;

  select * into v_cierre
  from public.franquicia_caja_cierres
  where id = p_cierre_id and estado = 'cerrado';
  if not found then raise exception 'Selecciona un cierre diario confirmado'; end if;
  if v_rol not in ('admin', 'franquiciado', 'tienda')
     or (v_rol <> 'admin' and (
       not public.usuario_tiene_permiso_v35('franquicia.caja')
       or not public.usuario_puede_almacen(v_cierre.almacen_id, true)
     )) then
    raise exception 'No tienes permiso para adjuntar comprobantes de este local';
  end if;
  if lower(coalesce(p_mime_type, '')) not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) then
    raise exception 'Usa una foto JPG, PNG o WebP, o un comprobante PDF';
  end if;
  if p_tamano_bytes is null or p_tamano_bytes not between 1 and 8388608 then
    raise exception 'El comprobante debe pesar entre 1 byte y 8 MB';
  end if;

  v_ext := case lower(p_mime_type)
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'application/pdf' then 'pdf'
    else 'jpg'
  end;
  v_path := v_cierre.almacen_id::text || '/' || v_uid::text || '/'
    || p_idempotency_key::text || '.' || v_ext;

  insert into public.caja_comprobantes_pendientes_v138(
    id, cierre_id, almacen_id, creado_por, storage_path,
    nombre_archivo, mime_type, tamano_bytes
  ) values (
    p_idempotency_key, v_cierre.id, v_cierre.almacen_id, v_uid, v_path,
    left(btrim(coalesce(nullif(p_nombre_archivo, ''), 'comprobante')), 255),
    lower(p_mime_type), p_tamano_bytes
  ) on conflict(id) do nothing;

  select storage_path into v_path
  from public.caja_comprobantes_pendientes_v138
  where id = p_idempotency_key and creado_por = v_uid
    and cierre_id = v_cierre.id and usado_en is null and vence_en > now();
  if v_path is null then raise exception 'La clave del comprobante ya fue utilizada'; end if;
  return jsonb_build_object('id', p_idempotency_key, 'path', v_path);
end;
$v138$;

create or replace function public.puede_subir_comprobante_deposito_v138(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $v138$
  select exists (
    select 1 from public.caja_comprobantes_pendientes_v138 p
    where p.storage_path = p_path and p.creado_por = auth.uid()
      and p.usado_en is null and p.vence_en > now()
  );
$v138$;

create or replace function public.puede_leer_comprobante_deposito_v138(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $v138$
  select exists (
    select 1 from public.caja_comprobantes_pendientes_v138 p
    where p.storage_path = p_path and p.creado_por = auth.uid()
      and p.usado_en is null and p.vence_en > now()
  ) or exists (
    select 1 from public.caja_depositos_v87 d
    where d.comprobante_storage_path = p_path
      and public.usuario_puede_almacen(d.almacen_id, false)
  );
$v138$;

drop policy if exists "subir_comprobante_deposito_v138" on storage.objects;
create policy "subir_comprobante_deposito_v138"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'caja-comprobantes'
  and public.puede_subir_comprobante_deposito_v138(name)
);

drop policy if exists "leer_comprobante_deposito_v138" on storage.objects;
create policy "leer_comprobante_deposito_v138"
on storage.objects for select to authenticated
using (
  bucket_id = 'caja-comprobantes'
  and public.puede_leer_comprobante_deposito_v138(name)
);

create or replace function public.registrar_deposito_caja_v138(
  p_cierre_id uuid,
  p_fecha date,
  p_monto numeric,
  p_banco text,
  p_referencia text,
  p_comprobante_id uuid,
  p_nota text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $v138$
declare
  c public.franquicia_caja_cierres%rowtype;
  v_id uuid;
  v_movimiento uuid;
  v_depositado numeric(14,2);
  v_rol text := public.rol_usuario_actual();
  v_comprobante public.caja_comprobantes_pendientes_v138%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.caja_depositos_v87
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  select * into c from public.franquicia_caja_cierres
  where id = p_cierre_id for update;
  if not found or c.estado <> 'cerrado' then
    raise exception 'Selecciona un cierre diario confirmado';
  end if;
  if v_rol not in ('admin', 'franquiciado', 'tienda')
     or (v_rol <> 'admin' and (
       not public.usuario_tiene_permiso_v35('franquicia.caja')
       or not public.usuario_puede_almacen(c.almacen_id, true)
     )) then
    raise exception 'No tienes permiso para registrar el deposito de este local';
  end if;
  if p_fecha is null
     or p_fecha <= c.fecha
     or p_fecha > (now() at time zone 'America/Guayaquil')::date then
    raise exception 'El deposito debe registrarse en un dia posterior al cierre y no puede ser futuro';
  end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if btrim(coalesce(p_banco, '')) = '' or btrim(coalesce(p_referencia, '')) = '' then
    raise exception 'Banco y referencia del deposito son obligatorios';
  end if;
  if exists (
    select 1 from public.caja_depositos_v87 d
    where d.almacen_id = c.almacen_id and d.estado <> 'anulado'
      and lower(btrim(d.banco)) = lower(btrim(p_banco))
      and lower(btrim(d.referencia)) = lower(btrim(p_referencia))
  ) then
    raise exception 'Ya existe un deposito vigente con ese banco y referencia';
  end if;

  select coalesce(sum(d.monto), 0) into v_depositado
  from public.caja_depositos_v87 d
  where d.cierre_id = c.id and d.estado <> 'anulado';
  if round(v_depositado + p_monto, 2) > c.efectivo_contado then
    raise exception 'El total depositado no puede superar el efectivo contado en el cierre';
  end if;

  if p_comprobante_id is not null then
    select * into v_comprobante
    from public.caja_comprobantes_pendientes_v138
    where id = p_comprobante_id and cierre_id = c.id
      and almacen_id = c.almacen_id and creado_por = auth.uid()
      and usado_en is null and vence_en > now()
    for update;
    if not found then raise exception 'El comprobante no fue preparado o ya fue utilizado'; end if;
    if not exists (
      select 1 from storage.objects o
      where o.bucket_id = 'caja-comprobantes' and o.name = v_comprobante.storage_path
    ) then
      raise exception 'El comprobante no termino de cargarse';
    end if;
  end if;

  select public.registrar_caja_franquicia_v42(
    p_fecha, 'egreso', 'deposito_bancario',
    'Deposito de efectivo del cierre ' || c.fecha::text,
    round(p_monto, 2), 'efectivo', btrim(p_referencia),
    p_idempotency_key, c.almacen_id
  ) into v_movimiento;

  insert into public.caja_depositos_v87 (
    cierre_id, almacen_id, movimiento_id, fecha_deposito, monto,
    banco, referencia, comprobante_url, comprobante_storage_path,
    comprobante_nombre, comprobante_mime_type, comprobante_tamano_bytes,
    nota, registrado_por, idempotency_key
  ) values (
    c.id, c.almacen_id, v_movimiento, p_fecha, round(p_monto, 2),
    btrim(p_banco), btrim(p_referencia), null,
    case when p_comprobante_id is null then null else v_comprobante.storage_path end,
    case when p_comprobante_id is null then null else v_comprobante.nombre_archivo end,
    case when p_comprobante_id is null then null else v_comprobante.mime_type end,
    case when p_comprobante_id is null then null else v_comprobante.tamano_bytes end,
    nullif(btrim(coalesce(p_nota, '')), ''), auth.uid(), p_idempotency_key
  ) returning id into v_id;

  if p_comprobante_id is not null then
    update public.caja_comprobantes_pendientes_v138
    set usado_en = v_id where id = p_comprobante_id;
  end if;

  insert into public.notificaciones_comunicados (
    origen_clave, origen_tipo, almacen_id, rol_destino,
    modulo, nivel, titulo, mensaje, href, creado_por
  )
  select 'caja:deposito:' || v_id::text || ':' || r.rol::text,
    'deposito_caja', c.almacen_id, r.rol,
    'Caja', 'accion', 'Deposito de caja por confirmar',
    'Se registro un deposito de ' || round(p_monto, 2)::text ||
      ' en ' || btrim(p_banco) || case when p_comprobante_id is null
        then '. No tiene comprobante adjunto.' else '. Tiene comprobante adjunto.' end,
    case when c.franquicia_id is null then '/tienda' else '/franquicia' end,
    auth.uid()
  from unnest(array['admin', 'control']::public.rol_usuario[]) r(rol)
  on conflict (origen_clave) do nothing;

  return v_id;
end;
$v138$;

create or replace view public.vista_depositos_caja_v87
with (security_invoker = true)
as
select d.id, d.cierre_id, d.almacen_id, a.nombre as almacen,
  c.fecha as fecha_cierre, c.efectivo_contado,
  d.fecha_deposito, d.monto, d.banco, d.referencia,
  d.comprobante_url, d.nota, d.estado, d.movimiento_id,
  d.registrado_por, rp.nombre_completo as registrado_por_nombre,
  d.confirmado_por, cp.nombre_completo as confirmado_por_nombre,
  d.confirmado_at, d.created_at,
  d.comprobante_storage_path, d.comprobante_nombre,
  d.comprobante_mime_type, d.comprobante_tamano_bytes
from public.caja_depositos_v87 d
join public.franquicia_caja_cierres c on c.id = d.cierre_id
join public.almacenes a on a.id = d.almacen_id
join public.perfiles rp on rp.id = d.registrado_por
left join public.perfiles cp on cp.id = d.confirmado_por;

alter table public.caja_comprobantes_pendientes_v138 enable row level security;
revoke all on public.caja_comprobantes_pendientes_v138 from public, anon, authenticated;

alter table public.caja_comprobantes_pendientes_v138 owner to postgres;
alter function public.preparar_comprobante_deposito_v138(uuid,text,text,bigint,uuid) owner to postgres;
alter function public.puede_subir_comprobante_deposito_v138(text) owner to postgres;
alter function public.puede_leer_comprobante_deposito_v138(text) owner to postgres;
alter function public.registrar_deposito_caja_v138(uuid,date,numeric,text,text,uuid,text,uuid) owner to postgres;
alter view public.vista_depositos_caja_v87 owner to postgres;

revoke all on function public.preparar_comprobante_deposito_v138(uuid,text,text,bigint,uuid)
  from public, anon;
revoke all on function public.puede_subir_comprobante_deposito_v138(text)
  from public, anon;
revoke all on function public.puede_leer_comprobante_deposito_v138(text)
  from public, anon;
revoke all on function public.registrar_deposito_caja_v138(uuid,date,numeric,text,text,uuid,text,uuid)
  from public, anon;
grant execute on function public.preparar_comprobante_deposito_v138(uuid,text,text,bigint,uuid),
  public.puede_subir_comprobante_deposito_v138(text),
  public.puede_leer_comprobante_deposito_v138(text),
  public.registrar_deposito_caja_v138(uuid,date,numeric,text,text,uuid,text,uuid)
  to authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v138', 138, 'v138_comprobantes_depositos_caja.sql',
  'Agrega comprobantes privados, captura desde camara, validacion y trazabilidad para depositos de caja.'
)
on conflict (id) do nothing;

notify pgrst, 'reload schema';
commit;
