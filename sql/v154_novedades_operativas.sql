-- ============================================================
-- v154 - Novedades operativas: descuadres de caja, cierres pendientes y
-- depositos faltantes, con responsable, fecha limite, evidencia (archivo
-- real) y estado, con historial hasta su resolucion.
--
-- Las novedades se crean de DOS formas:
--   1. Automatica: el sistema las detecta (descuadre al cerrar caja aqui
--      mismo; cierre pendiente y deposito faltante desde el cron de v155)
--      y las inserta via la funcion interna _crear_novedad_operativa_v154
--      (sin grant a authenticated: solo la llaman otras funciones
--      security definer de este mismo archivo o el cron de v155).
--   2. Manual: un admin o alguien con el permiso nuevo
--      operativas.novedades.gestionar las registra a mano via
--      crear_novedad_operativa_v154 (esta si tiene grant a authenticated).
--
-- Ejecutar despues de v153 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v154', 0));

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta el registro formal de migraciones (v134)';
  end if;
  if to_regclass('public.caja_depositos_v87') is null then
    raise exception 'Falta v87: instala primero la conciliacion de depositos de caja';
  end if;
  if to_regprocedure('public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid)') is null then
    raise exception 'Falta v71: instala primero el cierre de caja generalizado';
  end if;
  if to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null
     or to_regprocedure('public.usuario_puede_almacen(uuid,boolean)') is null then
    raise exception 'Falta el motor de permisos (v35/v107)';
  end if;
  if to_regclass('public.notificaciones_comunicados') is null then
    raise exception 'Falta v53: instala primero el centro de notificaciones';
  end if;
end;
$requisitos$;

-- ------------------------------------------------------------
-- 1. Permiso configurable
-- ------------------------------------------------------------
insert into public.permisos_sistema as p(
  codigo, modulo, nombre, descripcion, orden, es_boman_especifico
) values (
  'operativas.novedades.gestionar', 'Franquicias', 'Gestionar novedades operativas',
  'Ver, asignar, comentar, resolver y anular novedades de descuadres de caja, cierres pendientes y depositos faltantes de cualquier local.',
  62, false
)
on conflict(codigo) do update set
  modulo=excluded.modulo, nombre=excluded.nombre,
  descripcion=excluded.descripcion, orden=excluded.orden,
  activo=true, es_boman_especifico=false, updated_at=now();

insert into public.rol_permisos(rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.codigo = 'operativas.novedades.gestionar'
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos set permitido = true, updated_at = now()
where permiso_codigo = 'operativas.novedades.gestionar'
  and rol::text in ('control', 'gerencia', 'supervisor');

-- ------------------------------------------------------------
-- 2. Tablas: novedad, historial, evidencia (archivo real)
-- ------------------------------------------------------------
create table if not exists public.novedades_operativas_v154 (
  id uuid primary key default gen_random_uuid(),
  numero bigint generated always as identity,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  tipo text not null check (tipo in (
    'descuadre_caja', 'cierre_pendiente', 'deposito_faltante', 'otro'
  )),
  origen_cierre_id uuid references public.franquicia_caja_cierres(id) on delete restrict,
  origen_deposito_id uuid references public.caja_depositos_v87(id) on delete restrict,
  fecha_hecho date not null,
  descripcion text not null check (length(btrim(descripcion)) >= 5),
  monto_afectado numeric,
  asignado_a uuid references public.perfiles(id) on delete restrict,
  fecha_limite date,
  prioridad text not null default 'normal' check (prioridad in ('normal', 'urgente')),
  estado text not null default 'abierta' check (estado in ('abierta', 'resuelta', 'anulada')),
  comentario_resolucion text,
  resuelta_por uuid references public.perfiles(id) on delete restrict,
  resuelta_at timestamptz,
  anulada_por uuid references public.perfiles(id) on delete restrict,
  anulada_at timestamptz,
  motivo_anulacion text,
  creado_por uuid references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (estado <> 'resuelta' or (
    asignado_a is not null and resuelta_por is not null and resuelta_at is not null
    and length(btrim(coalesce(comentario_resolucion, ''))) >= 3
  )),
  check (estado <> 'anulada' or (
    anulada_por is not null and anulada_at is not null
    and length(btrim(coalesce(motivo_anulacion, ''))) >= 10
  ))
);

-- Evita que el cron (v155) duplique la misma novedad automatica del mismo
-- almacen/tipo/dia si corre dos veces; no restringe las manuales.
create unique index if not exists uq_novedad_operativa_auto_v154
  on public.novedades_operativas_v154(almacen_id, tipo, fecha_hecho)
  where creado_por is null;

create index if not exists idx_novedades_operativas_estado_v154
  on public.novedades_operativas_v154(almacen_id, estado, fecha_hecho desc);

create table if not exists public.novedad_operativa_eventos_v154 (
  id uuid primary key default gen_random_uuid(),
  novedad_id uuid not null references public.novedades_operativas_v154(id) on delete restrict,
  tipo text not null check (btrim(tipo) <> ''),
  estado_anterior text,
  estado_nuevo text,
  detalle text not null check (length(btrim(detalle)) >= 3),
  usuario_id uuid references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);
create index if not exists idx_novedad_eventos_novedad_v154
  on public.novedad_operativa_eventos_v154(novedad_id, created_at);

create table if not exists public.novedad_operativa_evidencias_v154 (
  id uuid primary key default gen_random_uuid(),
  novedad_id uuid not null references public.novedades_operativas_v154(id) on delete restrict,
  storage_path text not null unique check (btrim(storage_path) <> ''),
  nombre_archivo text not null check (btrim(nombre_archivo) <> ''),
  mime_type text not null check (mime_type in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  )),
  tamano_bytes bigint not null check (tamano_bytes between 1 and 8388608),
  descripcion text,
  adjuntado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index if not exists idx_novedad_evidencias_novedad_v154
  on public.novedad_operativa_evidencias_v154(novedad_id, created_at);

-- Mismo patron de v138 (bucket privado + tabla de pendientes con vencimiento):
-- prepare -> el navegador sube el archivo -> registrar consume la fila.
create table if not exists public.novedad_evidencia_pendientes_v154 (
  id uuid primary key,
  novedad_id uuid not null references public.novedades_operativas_v154(id) on delete restrict,
  creado_por uuid not null references public.perfiles(id) on delete cascade,
  storage_path text not null unique check (btrim(storage_path) <> ''),
  nombre_archivo text not null check (btrim(nombre_archivo) <> ''),
  mime_type text not null check (mime_type in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  )),
  tamano_bytes bigint not null check (tamano_bytes between 1 and 8388608),
  usado_en uuid references public.novedad_operativa_evidencias_v154(id) on delete set null,
  vence_en timestamptz not null default now() + interval '24 hours',
  created_at timestamptz not null default now()
);
create index if not exists idx_novedad_evidencia_pendientes_usuario_v154
  on public.novedad_evidencia_pendientes_v154(creado_por, vence_en desc)
  where usado_en is null;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'novedades-evidencia', 'novedades-evidencia', false, 8388608,
  array['image/jpeg','image/png','image/webp','application/pdf']::text[]
)
on conflict(id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------
-- 3. Creacion interna (sin permiso; la usan solo otras funciones
--    security definer de este archivo, o el cron de v155)
-- ------------------------------------------------------------
-- Las novedades automaticas no tienen sesion de usuario detras (las dispara
-- un cron con la llave de servicio, o quedan marcadas creado_por=null aunque
-- las dispare de rebote un franquiciado cerrando su caja). Pero
-- notificaciones_comunicados.creado_por es NOT NULL: se usa un admin activo
-- cualquiera como "autor tecnico" de esos avisos, nunca se le atribuyen a
-- la persona que sin saberlo disparo la deteccion.
create or replace function public._perfil_sistema_v154()
returns uuid
language sql stable security definer set search_path = ''
as $v154$
  select id from public.perfiles where rol = 'admin' and activo
  order by created_at limit 1;
$v154$;

create or replace function public._crear_novedad_operativa_v154(
  p_almacen_id uuid,
  p_tipo text,
  p_origen_cierre_id uuid,
  p_origen_deposito_id uuid,
  p_fecha_hecho date,
  p_descripcion text,
  p_monto_afectado numeric,
  p_prioridad text,
  p_creado_por uuid,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $v154$
declare
  v_id uuid;
  v_autor_aviso uuid;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.novedades_operativas_v154 where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  if coalesce(p_tipo, '') not in (
    'descuadre_caja', 'cierre_pendiente', 'deposito_faltante', 'otro'
  ) then raise exception 'El tipo de novedad no es valido'; end if;
  if p_fecha_hecho is null then raise exception 'La fecha del hecho es obligatoria'; end if;
  if length(btrim(coalesce(p_descripcion, ''))) < 5 then
    raise exception 'Describe la novedad con al menos 5 caracteres';
  end if;
  if coalesce(p_prioridad, 'normal') not in ('normal', 'urgente') then
    raise exception 'La prioridad no es valida';
  end if;
  if not exists (select 1 from public.almacenes a where a.id = p_almacen_id and a.activo) then
    raise exception 'El almacen no existe o esta inactivo';
  end if;

  insert into public.novedades_operativas_v154(
    almacen_id, tipo, origen_cierre_id, origen_deposito_id, fecha_hecho,
    descripcion, monto_afectado, prioridad, creado_por, idempotency_key
  ) values (
    p_almacen_id, p_tipo, p_origen_cierre_id, p_origen_deposito_id, p_fecha_hecho,
    btrim(p_descripcion), p_monto_afectado, coalesce(p_prioridad, 'normal'),
    p_creado_por, p_idempotency_key
  )
  on conflict (almacen_id, tipo, fecha_hecho) where creado_por is null do nothing
  returning id into v_id;

  if v_id is null then
    -- Choco con el indice unico de automaticas del dia: ya existia, se reusa.
    select id into v_id from public.novedades_operativas_v154
    where almacen_id = p_almacen_id and tipo = p_tipo and fecha_hecho = p_fecha_hecho
      and creado_por is null;
    return v_id;
  end if;

  insert into public.novedad_operativa_eventos_v154(
    novedad_id, tipo, estado_nuevo, detalle, usuario_id, idempotency_key
  ) values (
    v_id, 'registrada', 'abierta',
    case when p_creado_por is null then 'Novedad detectada automaticamente'
      else 'Novedad registrada' end,
    p_creado_por, p_idempotency_key
  );

  v_autor_aviso := coalesce(p_creado_por, public._perfil_sistema_v154());
  if v_autor_aviso is not null then
    insert into public.notificaciones_comunicados(
      origen_clave, origen_tipo, almacen_id, rol_destino,
      modulo, nivel, titulo, mensaje, href, creado_por
    )
    select 'novedad:' || v_id::text || ':' || r.rol::text,
      'novedad_operativa', p_almacen_id, r.rol, 'Franquicias',
      case when coalesce(p_prioridad, 'normal') = 'urgente' then 'critica' else 'accion' end,
      case p_tipo
        when 'descuadre_caja' then 'Descuadre de caja'
        when 'cierre_pendiente' then 'Cierre diario pendiente'
        when 'deposito_faltante' then 'Deposito de caja faltante'
        else 'Novedad operativa'
      end,
      btrim(p_descripcion), '/franquicias/novedades', v_autor_aviso
    from unnest(array['control', 'gerencia', 'supervisor']::public.rol_usuario[]) r(rol)
    on conflict (origen_clave) do nothing;
  end if;

  return v_id;
end;
$v154$;

-- ------------------------------------------------------------
-- 4. Creacion manual (con permiso, para authenticated)
-- ------------------------------------------------------------
create or replace function public.crear_novedad_operativa_v154(
  p_datos jsonb,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $v154$
declare v_almacen_id uuid := nullif(p_datos->>'almacen_id', '')::uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('operativas.novedades.gestionar') then
    raise exception 'No tienes permiso para registrar novedades operativas';
  end if;
  if v_almacen_id is null then raise exception 'Selecciona el local de la novedad'; end if;
  return public._crear_novedad_operativa_v154(
    v_almacen_id, p_datos->>'tipo',
    nullif(p_datos->>'origen_cierre_id', '')::uuid,
    nullif(p_datos->>'origen_deposito_id', '')::uuid,
    nullif(p_datos->>'fecha_hecho', '')::date,
    p_datos->>'descripcion',
    nullif(p_datos->>'monto_afectado', '')::numeric,
    coalesce(p_datos->>'prioridad', 'normal'),
    auth.uid(), p_idempotency_key
  );
end;
$v154$;

-- ------------------------------------------------------------
-- 5. Asignar, comentar, resolver, anular
-- ------------------------------------------------------------
create or replace function public.asignar_novedad_operativa_v154(
  p_novedad_id uuid,
  p_asignado_a uuid,
  p_fecha_limite date,
  p_comentario text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $v154$
declare n public.novedades_operativas_v154%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if exists (select 1 from public.novedad_operativa_eventos_v154 where idempotency_key = p_idempotency_key) then return; end if;
  if not public.usuario_tiene_permiso_v35('operativas.novedades.gestionar') then
    raise exception 'No tienes permiso para asignar novedades operativas';
  end if;
  select * into n from public.novedades_operativas_v154 where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado <> 'abierta' then raise exception 'La novedad ya esta cerrada'; end if;
  if p_asignado_a is null then raise exception 'Selecciona un responsable'; end if;
  if not exists (select 1 from public.perfiles p where p.id = p_asignado_a and p.activo) then
    raise exception 'El responsable no existe o esta inactivo';
  end if;
  if p_fecha_limite is not null and p_fecha_limite < current_date then
    raise exception 'La fecha limite no puede ser en el pasado';
  end if;

  update public.novedades_operativas_v154 set
    asignado_a = p_asignado_a, fecha_limite = p_fecha_limite, updated_at = now()
  where id = n.id;

  insert into public.novedad_operativa_eventos_v154(
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id, idempotency_key
  ) values (
    n.id, 'asignada', n.estado, n.estado,
    coalesce(nullif(btrim(p_comentario), ''), 'Asignada como responsable'),
    auth.uid(), p_idempotency_key
  );
end;
$v154$;

create or replace function public.agregar_comentario_novedad_v154(
  p_novedad_id uuid,
  p_comentario text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $v154$
declare n public.novedades_operativas_v154%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if exists (select 1 from public.novedad_operativa_eventos_v154 where idempotency_key = p_idempotency_key) then return; end if;
  if not public.usuario_tiene_permiso_v35('operativas.novedades.gestionar') then
    raise exception 'No tienes permiso para comentar esta novedad';
  end if;
  select * into n from public.novedades_operativas_v154 where id = p_novedad_id;
  if not found then raise exception 'La novedad no existe'; end if;
  if length(btrim(coalesce(p_comentario, ''))) < 3 then
    raise exception 'Escribe un comentario de al menos 3 caracteres';
  end if;
  insert into public.novedad_operativa_eventos_v154(
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id, idempotency_key
  ) values (n.id, 'comentario', n.estado, n.estado, btrim(p_comentario), auth.uid(), p_idempotency_key);
end;
$v154$;

create or replace function public.resolver_novedad_operativa_v154(
  p_novedad_id uuid,
  p_comentario text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $v154$
declare n public.novedades_operativas_v154%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if exists (select 1 from public.novedad_operativa_eventos_v154 where idempotency_key = p_idempotency_key) then return; end if;
  if not public.usuario_tiene_permiso_v35('operativas.novedades.gestionar') then
    raise exception 'No tienes permiso para resolver esta novedad';
  end if;
  select * into n from public.novedades_operativas_v154 where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado <> 'abierta' then raise exception 'La novedad ya esta cerrada'; end if;
  if n.asignado_a is null then
    raise exception 'Asigna un responsable antes de resolver la novedad';
  end if;
  if length(btrim(coalesce(p_comentario, ''))) < 3 then
    raise exception 'Escribe un comentario de resolucion de al menos 3 caracteres';
  end if;

  update public.novedades_operativas_v154 set
    estado = 'resuelta', comentario_resolucion = btrim(p_comentario),
    resuelta_por = auth.uid(), resuelta_at = now(), updated_at = now()
  where id = n.id;

  update public.notificaciones_comunicados set activo = false, updated_at = now()
  where origen_clave like 'novedad:' || n.id::text || ':%';

  insert into public.novedad_operativa_eventos_v154(
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id, idempotency_key
  ) values (n.id, 'resuelta', n.estado, 'resuelta', btrim(p_comentario), auth.uid(), p_idempotency_key);
end;
$v154$;

create or replace function public.anular_novedad_operativa_v154(
  p_novedad_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $v154$
declare n public.novedades_operativas_v154%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if exists (select 1 from public.novedad_operativa_eventos_v154 where idempotency_key = p_idempotency_key) then return; end if;
  if not public.usuario_tiene_permiso_v35('operativas.novedades.gestionar') then
    raise exception 'No tienes permiso para anular esta novedad';
  end if;
  select * into n from public.novedades_operativas_v154 where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado = 'anulada' then return; end if;
  if n.estado = 'resuelta' then raise exception 'La novedad ya fue resuelta, no se puede anular'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Indica un motivo de anulacion de al menos 10 caracteres';
  end if;

  update public.novedades_operativas_v154 set
    estado = 'anulada', motivo_anulacion = btrim(p_motivo),
    anulada_por = auth.uid(), anulada_at = now(), updated_at = now()
  where id = n.id;

  update public.notificaciones_comunicados set activo = false, updated_at = now()
  where origen_clave like 'novedad:' || n.id::text || ':%';

  insert into public.novedad_operativa_eventos_v154(
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id, idempotency_key
  ) values (n.id, 'anulada', n.estado, 'anulada', btrim(p_motivo), auth.uid(), p_idempotency_key);
end;
$v154$;

-- ------------------------------------------------------------
-- 6. Evidencia (archivo real): prepare -> upload -> registrar
-- ------------------------------------------------------------
create or replace function public.preparar_evidencia_novedad_v154(
  p_novedad_id uuid,
  p_nombre_archivo text,
  p_mime_type text,
  p_tamano_bytes bigint,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $v154$
declare
  v_uid uuid := auth.uid();
  n public.novedades_operativas_v154%rowtype;
  v_ext text;
  v_path text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if not public.usuario_tiene_permiso_v35('operativas.novedades.gestionar') then
    raise exception 'No tienes permiso para adjuntar evidencia';
  end if;
  select * into n from public.novedades_operativas_v154 where id = p_novedad_id;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado = 'anulada' then raise exception 'No se adjunta evidencia a una novedad anulada'; end if;
  if lower(coalesce(p_mime_type, '')) not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) then
    raise exception 'Usa una foto JPG, PNG o WebP, o un PDF';
  end if;
  if p_tamano_bytes is null or p_tamano_bytes not between 1 and 8388608 then
    raise exception 'El archivo debe pesar entre 1 byte y 8 MB';
  end if;

  v_ext := case lower(p_mime_type)
    when 'image/png' then 'png'
    when 'image/webp' then 'webp'
    when 'application/pdf' then 'pdf'
    else 'jpg'
  end;
  v_path := n.almacen_id::text || '/' || v_uid::text || '/' || p_idempotency_key::text || '.' || v_ext;

  insert into public.novedad_evidencia_pendientes_v154(
    id, novedad_id, creado_por, storage_path, nombre_archivo, mime_type, tamano_bytes
  ) values (
    p_idempotency_key, n.id, v_uid, v_path,
    left(btrim(coalesce(nullif(p_nombre_archivo, ''), 'evidencia')), 255),
    lower(p_mime_type), p_tamano_bytes
  ) on conflict(id) do nothing;

  select storage_path into v_path
  from public.novedad_evidencia_pendientes_v154
  where id = p_idempotency_key and creado_por = v_uid and novedad_id = n.id
    and usado_en is null and vence_en > now();
  if v_path is null then raise exception 'La clave de la evidencia ya fue utilizada'; end if;
  return jsonb_build_object('id', p_idempotency_key, 'path', v_path);
end;
$v154$;

create or replace function public.puede_subir_evidencia_novedad_v154(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $v154$
  select exists (
    select 1 from public.novedad_evidencia_pendientes_v154 p
    where p.storage_path = p_path and p.creado_por = auth.uid()
      and p.usado_en is null and p.vence_en > now()
  );
$v154$;

create or replace function public.puede_leer_evidencia_novedad_v154(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $v154$
  select exists (
    select 1 from public.novedad_evidencia_pendientes_v154 p
    where p.storage_path = p_path and p.creado_por = auth.uid()
      and p.usado_en is null and p.vence_en > now()
  ) or exists (
    select 1 from public.novedad_operativa_evidencias_v154 e
    join public.novedades_operativas_v154 n on n.id = e.novedad_id
    where e.storage_path = p_path
      and (public.usuario_puede_almacen(n.almacen_id, false)
        or public.usuario_tiene_permiso_v35('operativas.novedades.gestionar'))
  );
$v154$;

drop policy if exists "subir_evidencia_novedad_v154" on storage.objects;
create policy "subir_evidencia_novedad_v154"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'novedades-evidencia'
  and public.puede_subir_evidencia_novedad_v154(name)
);

drop policy if exists "leer_evidencia_novedad_v154" on storage.objects;
create policy "leer_evidencia_novedad_v154"
on storage.objects for select to authenticated
using (
  bucket_id = 'novedades-evidencia'
  and public.puede_leer_evidencia_novedad_v154(name)
);

create or replace function public.agregar_evidencia_novedad_v154(
  p_novedad_id uuid,
  p_evidencia_id uuid,
  p_descripcion text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $v154$
declare
  n public.novedades_operativas_v154%rowtype;
  pend public.novedad_evidencia_pendientes_v154%rowtype;
  v_id uuid;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select * into n from public.novedades_operativas_v154 where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if not public.usuario_tiene_permiso_v35('operativas.novedades.gestionar') then
    raise exception 'No tienes permiso para adjuntar evidencia';
  end if;
  if n.estado = 'anulada' then raise exception 'No se adjunta evidencia a una novedad anulada'; end if;

  select * into pend from public.novedad_evidencia_pendientes_v154
  where id = p_evidencia_id and novedad_id = n.id and creado_por = auth.uid()
    and usado_en is null and vence_en > now()
  for update;
  if not found then raise exception 'La evidencia no fue preparada o ya fue utilizada'; end if;
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'novedades-evidencia' and o.name = pend.storage_path
  ) then
    raise exception 'El archivo no termino de cargarse';
  end if;

  insert into public.novedad_operativa_evidencias_v154(
    novedad_id, storage_path, nombre_archivo, mime_type, tamano_bytes, descripcion, adjuntado_por
  ) values (
    n.id, pend.storage_path, pend.nombre_archivo, pend.mime_type, pend.tamano_bytes,
    nullif(btrim(p_descripcion), ''), auth.uid()
  ) returning id into v_id;

  update public.novedad_evidencia_pendientes_v154 set usado_en = v_id where id = pend.id;

  insert into public.novedad_operativa_eventos_v154(
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id, idempotency_key
  ) values (
    n.id, 'evidencia_adjuntada', n.estado, n.estado,
    'Evidencia adjuntada: ' || pend.nombre_archivo, auth.uid(), p_idempotency_key
  );

  return v_id;
end;
$v154$;

-- ------------------------------------------------------------
-- 7. Descuadre automatico al cerrar caja: create or replace de
--    cerrar_caja_franquicia_v49 conservando el cuerpo vigente de v71
--    (sql/v71_caja_tienda_propia.sql:307) y agregando solo la deteccion,
--    antes del "return to_jsonb(c)".
-- ------------------------------------------------------------
create or replace function public.cerrar_caja_franquicia_v49(
  p_fecha date,
  p_saldo_inicial_efectivo numeric,
  p_efectivo_contado numeric,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $v154$
declare
  v_op record;
  c public.franquicia_caja_cierres%rowtype;
  v_ing_ef numeric(14,2);
  v_egr_ef numeric(14,2);
  v_ing numeric(14,2);
  v_egr numeric(14,2);
  v_esperado numeric(14,2);
  v_inicial numeric(14,2);
  v_derivado numeric(14,2);
  v_origen text;
begin
  if public.rol_usuario_actual() not in ('franquiciado', 'tienda')
     or not public.usuario_tiene_permiso_v35('franquicia.caja') then
    raise exception 'No tienes permiso para cerrar esta caja';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into v_op from public.almacen_caja_operativo_v71();
  if v_op.almacen_id is null then raise exception 'No tienes un local activo asignado para caja'; end if;

  select cc.* into c
  from public.franquicia_caja_cierres cc
  left join public.franquicia_caja_cierre_eventos e on e.cierre_id = cc.id
  where cc.almacen_id = v_op.almacen_id
    and (cc.idempotency_key = p_idempotency_key or e.idempotency_key = p_idempotency_key)
  limit 1;
  if found then return to_jsonb(c); end if;

  if p_fecha is null or p_fecha > (now() at time zone 'America/Guayaquil')::date then
    raise exception 'La fecha de cierre no es valida';
  end if;
  if coalesce(p_efectivo_contado, -1) < 0 then
    raise exception 'El efectivo contado no puede ser negativo';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_op.almacen_id::text || p_fecha::text, 47));
  select * into c from public.franquicia_caja_cierres
  where almacen_id = v_op.almacen_id and fecha = p_fecha for update;
  if found and c.estado = 'cerrado' then raise exception 'La caja de ese dia ya esta cerrada'; end if;

  v_derivado := public.saldo_inicial_caja_franquicia_v49(v_op.almacen_id, p_fecha);
  if v_derivado is null then
    if coalesce(p_saldo_inicial_efectivo, -1) < 0 then
      raise exception 'Es el primer cierre del local: indica con cuanto efectivo arranca la caja';
    end if;
    v_inicial := round(p_saldo_inicial_efectivo, 2);
    v_origen := 'declarado';
  else
    v_inicial := greatest(v_derivado, 0);
    v_origen := 'derivado';
  end if;

  select
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'egreso' and m.medio_pago = 'efectivo'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'egreso'), 0)
  into v_ing_ef, v_egr_ef, v_ing, v_egr
  from public.franquicia_caja_movimientos m
  where m.almacen_id = v_op.almacen_id and m.fecha = p_fecha
    and m.estado = 'vigente' and m.reversa_de_id is null;

  v_esperado := round(v_inicial + v_ing_ef - v_egr_ef, 2);

  if c.id is null then
    insert into public.franquicia_caja_cierres (
      franquicia_id, almacen_id, fecha, saldo_inicial_efectivo, saldo_inicial_origen,
      ingresos_efectivo, egresos_efectivo, saldo_esperado_efectivo,
      efectivo_contado, diferencia, ingresos_total, egresos_total,
      nota, idempotency_key, cerrado_por
    ) values (
      v_op.franquicia_id, v_op.almacen_id, p_fecha, v_inicial, v_origen, v_ing_ef, v_egr_ef, v_esperado,
      round(p_efectivo_contado, 2), round(p_efectivo_contado - v_esperado, 2),
      v_ing, v_egr, nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid()
    ) returning * into c;
  else
    update public.franquicia_caja_cierres set
      estado = 'cerrado', saldo_inicial_efectivo = v_inicial,
      saldo_inicial_origen = v_origen,
      ingresos_efectivo = v_ing_ef, egresos_efectivo = v_egr_ef,
      saldo_esperado_efectivo = v_esperado,
      efectivo_contado = round(p_efectivo_contado, 2),
      diferencia = round(p_efectivo_contado - v_esperado, 2),
      ingresos_total = v_ing, egresos_total = v_egr,
      nota = nullif(btrim(p_nota), ''), idempotency_key = p_idempotency_key,
      cerrado_por = auth.uid(), cerrado_at = now(),
      motivo_reapertura = null, reabierto_por = null, reabierto_at = null
    where id = c.id returning * into c;
  end if;

  insert into public.franquicia_caja_cierre_eventos(
    cierre_id, tipo, detalle, usuario_id, idempotency_key
  ) values (
    c.id, 'cerrado',
    'Cierre diario confirmado. Saldo inicial ' || v_origen ||
    ' de ' || c.saldo_inicial_efectivo || '. Diferencia: ' || c.diferencia,
    auth.uid(), p_idempotency_key
  );

  -- NUEVO en v154: descuadre -> novedad operativa automatica (deterministica
  -- por cierre, para que reintentar el cierre no duplique la novedad).
  if abs(coalesce(c.diferencia, 0)) >= 0.01 then
    perform public._crear_novedad_operativa_v154(
      c.almacen_id, 'descuadre_caja', c.id, null, c.fecha,
      'Descuadre de caja: diferencia de ' || c.diferencia::text ||
        ' en el cierre del ' || c.fecha::text,
      c.diferencia,
      case when abs(c.diferencia) > 5 then 'urgente' else 'normal' end,
      null,
      md5('descuadre_caja:' || c.id::text)::uuid
    );
  end if;

  return to_jsonb(c);
end;
$v154$;

-- ------------------------------------------------------------
-- 8. Vista operativa
-- ------------------------------------------------------------
create or replace view public.vista_novedades_operativas_v154
with (security_invoker = true) as
select
  n.id, n.numero, n.almacen_id, a.nombre as almacen_nombre,
  n.tipo, n.origen_cierre_id, n.origen_deposito_id, n.fecha_hecho,
  n.descripcion, n.monto_afectado, n.asignado_a,
  ap.nombre_completo as asignado_a_nombre,
  n.fecha_limite, n.prioridad, n.estado, n.comentario_resolucion,
  n.resuelta_por, rp.nombre_completo as resuelta_por_nombre, n.resuelta_at,
  n.anulada_por, np.nombre_completo as anulada_por_nombre, n.anulada_at, n.motivo_anulacion,
  n.creado_por, cp.nombre_completo as creado_por_nombre,
  (select count(*)::integer from public.novedad_operativa_evidencias_v154 e
    where e.novedad_id = n.id) as evidencias,
  n.created_at, n.updated_at
from public.novedades_operativas_v154 n
join public.almacenes a on a.id = n.almacen_id
left join public.perfiles ap on ap.id = n.asignado_a
left join public.perfiles rp on rp.id = n.resuelta_por
left join public.perfiles np on np.id = n.anulada_por
left join public.perfiles cp on cp.id = n.creado_por;

-- ------------------------------------------------------------
-- 9. RLS y privilegios
-- ------------------------------------------------------------
alter table public.novedades_operativas_v154 enable row level security;
alter table public.novedad_operativa_eventos_v154 enable row level security;
alter table public.novedad_operativa_evidencias_v154 enable row level security;
alter table public.novedad_evidencia_pendientes_v154 enable row level security;

drop policy if exists "leer_novedades_operativas_v154" on public.novedades_operativas_v154;
create policy "leer_novedades_operativas_v154" on public.novedades_operativas_v154
for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
  or public.usuario_tiene_permiso_v35('operativas.novedades.gestionar')
);

drop policy if exists "leer_novedad_eventos_v154" on public.novedad_operativa_eventos_v154;
create policy "leer_novedad_eventos_v154" on public.novedad_operativa_eventos_v154
for select to authenticated using (
  exists (
    select 1 from public.novedades_operativas_v154 n
    where n.id = novedad_id
      and (public.usuario_puede_almacen(n.almacen_id, false)
        or public.usuario_tiene_permiso_v35('operativas.novedades.gestionar'))
  )
);

drop policy if exists "leer_novedad_evidencias_v154" on public.novedad_operativa_evidencias_v154;
create policy "leer_novedad_evidencias_v154" on public.novedad_operativa_evidencias_v154
for select to authenticated using (
  exists (
    select 1 from public.novedades_operativas_v154 n
    where n.id = novedad_id
      and (public.usuario_puede_almacen(n.almacen_id, false)
        or public.usuario_tiene_permiso_v35('operativas.novedades.gestionar'))
  )
);

revoke all on public.novedades_operativas_v154 from public, anon;
revoke all on public.novedad_operativa_eventos_v154 from public, anon;
revoke all on public.novedad_operativa_evidencias_v154 from public, anon;
revoke all on public.novedad_evidencia_pendientes_v154 from public, anon, authenticated;
revoke insert, update, delete on public.novedades_operativas_v154 from authenticated;
revoke insert, update, delete on public.novedad_operativa_eventos_v154 from authenticated;
revoke insert, update, delete on public.novedad_operativa_evidencias_v154 from authenticated;
grant select on public.novedades_operativas_v154 to authenticated;
grant select on public.novedad_operativa_eventos_v154 to authenticated;
grant select on public.novedad_operativa_evidencias_v154 to authenticated;

revoke all on public.vista_novedades_operativas_v154 from public, anon;
grant select on public.vista_novedades_operativas_v154 to authenticated;

alter table public.novedades_operativas_v154 owner to postgres;
alter table public.novedad_operativa_eventos_v154 owner to postgres;
alter table public.novedad_operativa_evidencias_v154 owner to postgres;
alter table public.novedad_evidencia_pendientes_v154 owner to postgres;
alter view public.vista_novedades_operativas_v154 owner to postgres;

alter function public._perfil_sistema_v154() owner to postgres;
alter function public._crear_novedad_operativa_v154(uuid,text,uuid,uuid,date,text,numeric,text,uuid,uuid) owner to postgres;
alter function public.crear_novedad_operativa_v154(jsonb,uuid) owner to postgres;
alter function public.asignar_novedad_operativa_v154(uuid,uuid,date,text,uuid) owner to postgres;
alter function public.agregar_comentario_novedad_v154(uuid,text,uuid) owner to postgres;
alter function public.resolver_novedad_operativa_v154(uuid,text,uuid) owner to postgres;
alter function public.anular_novedad_operativa_v154(uuid,text,uuid) owner to postgres;
alter function public.preparar_evidencia_novedad_v154(uuid,text,text,bigint,uuid) owner to postgres;
alter function public.puede_subir_evidencia_novedad_v154(text) owner to postgres;
alter function public.puede_leer_evidencia_novedad_v154(text) owner to postgres;
alter function public.agregar_evidencia_novedad_v154(uuid,uuid,text,uuid) owner to postgres;
alter function public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid) owner to postgres;

revoke all on function public._perfil_sistema_v154() from public, anon, authenticated;
revoke all on function public._crear_novedad_operativa_v154(uuid,text,uuid,uuid,date,text,numeric,text,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.crear_novedad_operativa_v154(jsonb,uuid) from public, anon;
revoke all on function public.asignar_novedad_operativa_v154(uuid,uuid,date,text,uuid) from public, anon;
revoke all on function public.agregar_comentario_novedad_v154(uuid,text,uuid) from public, anon;
revoke all on function public.resolver_novedad_operativa_v154(uuid,text,uuid) from public, anon;
revoke all on function public.anular_novedad_operativa_v154(uuid,text,uuid) from public, anon;
revoke all on function public.preparar_evidencia_novedad_v154(uuid,text,text,bigint,uuid) from public, anon;
revoke all on function public.puede_subir_evidencia_novedad_v154(text) from public, anon;
revoke all on function public.puede_leer_evidencia_novedad_v154(text) from public, anon;
revoke all on function public.agregar_evidencia_novedad_v154(uuid,uuid,text,uuid) from public, anon;

grant execute on function public.crear_novedad_operativa_v154(jsonb,uuid),
  public.asignar_novedad_operativa_v154(uuid,uuid,date,text,uuid),
  public.agregar_comentario_novedad_v154(uuid,text,uuid),
  public.resolver_novedad_operativa_v154(uuid,text,uuid),
  public.anular_novedad_operativa_v154(uuid,text,uuid),
  public.preparar_evidencia_novedad_v154(uuid,text,text,bigint,uuid),
  public.puede_subir_evidencia_novedad_v154(text),
  public.puede_leer_evidencia_novedad_v154(text),
  public.agregar_evidencia_novedad_v154(uuid,uuid,text,uuid)
  to authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v154', 154, 'v154_novedades_operativas.sql',
  'Novedades operativas (descuadre, cierre pendiente, deposito faltante) con asignacion, evidencia y historial; deteccion automatica de descuadre al cerrar caja.'
)
on conflict (id) do update set version=excluded.version, archivo=excluded.archivo,
  notas=excluded.notas, aplicada_at=now();

notify pgrst, 'reload schema';
commit;
