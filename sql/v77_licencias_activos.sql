-- ============================================================
-- BOMAN INVENTARIO - v77: licencias y permisos con vencimiento por activo
--
-- Hay maquinas cuya licencia (software, permiso de operacion, calibracion,
-- poliza) vence a plazo fijo y hay que renovar. v54 solo tenia
-- garantia_hasta, un campo suelto en el activo: no admite mas de una, no
-- guarda historial de renovaciones ni avisa antes del vencimiento.
--
-- Tabla propia y no columnas en el activo porque una maquina puede tener
-- varias licencias a la vez y cada renovacion debe quedar registrada: la
-- renovacion crea una fila nueva encadenada a la anterior, en vez de pisar
-- la fecha y perder el historial.
--
-- Ejecutar despues de v76.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.activos_mantenimiento') is null
     or to_regclass('public.mantenimiento_eventos') is null
     or to_regclass('public.notificaciones_comunicados') is null
     or to_regprocedure('public.puede_ver_activo_mantenimiento_v54(uuid,boolean)') is null then
    raise exception 'Faltan v53 o v54. Instalalos antes de v77';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Los eventos de mantenimiento admiten la licencia como entidad
-- ------------------------------------------------------------
-- v54 limitaba entidad_tipo a activo y orden. Sin esto, registrar la
-- auditoria de una licencia viola el check.
alter table public.mantenimiento_eventos
  drop constraint if exists mantenimiento_eventos_entidad_tipo_check;
alter table public.mantenimiento_eventos
  add constraint mantenimiento_eventos_entidad_tipo_check
  check (entidad_tipo in ('activo', 'orden', 'licencia'));

-- ------------------------------------------------------------
-- 2. Licencias
-- ------------------------------------------------------------
create table if not exists public.activo_licencias (
  id uuid primary key default gen_random_uuid(),
  activo_id uuid not null references public.activos_mantenimiento(id) on delete restrict,
  tipo text not null default 'software' check (tipo in (
    'software', 'permiso_operacion', 'calibracion', 'certificacion',
    'poliza_seguro', 'suscripcion', 'otro'
  )),
  nombre text not null check (btrim(nombre) <> ''),
  proveedor text,
  numero text,
  fecha_inicio date,
  fecha_vencimiento date not null,
  -- Cuantos dias antes empieza a avisar. Se guarda por licencia porque
  -- renovar un permiso municipal no toma lo mismo que renovar un antivirus.
  dias_aviso integer not null default 30 check (dias_aviso between 1 and 365),
  costo_renovacion numeric(14,2) check (costo_renovacion is null or costo_renovacion >= 0),
  responsable_id uuid references public.perfiles(id) on delete set null,
  estado text not null default 'vigente'
    check (estado in ('vigente', 'renovada', 'cancelada')),
  -- Cadena de renovaciones: la fila nueva apunta a la que reemplaza.
  renovacion_de_id uuid unique references public.activo_licencias(id) on delete restrict,
  motivo_cancelacion text,
  notas text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fecha_inicio is null or fecha_vencimiento >= fecha_inicio),
  check (estado <> 'cancelada' or btrim(coalesce(motivo_cancelacion, '')) <> '')
);

create index if not exists idx_licencias_activo_v77
  on public.activo_licencias(activo_id, fecha_vencimiento);
create index if not exists idx_licencias_vencimiento_v77
  on public.activo_licencias(fecha_vencimiento)
  where estado = 'vigente';

comment on table public.activo_licencias is
  'Licencias, permisos y certificaciones con vencimiento de cada activo. Renovar crea una fila nueva encadenada por renovacion_de_id; no se pisa la anterior.';

-- ------------------------------------------------------------
-- 3. Vista con el estado calculado
-- ------------------------------------------------------------
create or replace view public.vista_licencias_activos_v77
with (security_invoker = true) as
select
  l.*,
  a.codigo as activo_codigo,
  a.nombre as activo_nombre,
  a.grupo_id,
  a.empresa_id,
  a.almacen_id,
  e.codigo as empresa_codigo,
  e.razon_social as empresa,
  p.nombre_completo as responsable,
  (l.fecha_vencimiento - (now() at time zone 'America/Guayaquil')::date) as dias_restantes,
  case
    when l.estado = 'cancelada' then 'cancelada'
    when l.estado = 'renovada' then 'renovada'
    when l.fecha_vencimiento < (now() at time zone 'America/Guayaquil')::date then 'vencida'
    when l.fecha_vencimiento
      <= (now() at time zone 'America/Guayaquil')::date + l.dias_aviso then 'por_vencer'
    else 'vigente'
  end as estado_vencimiento
from public.activo_licencias l
join public.activos_mantenimiento a on a.id = l.activo_id
left join public.empresas e on e.id = a.empresa_id
left join public.perfiles p on p.id = l.responsable_id;

-- ------------------------------------------------------------
-- 4. Alta y edicion
-- ------------------------------------------------------------
create or replace function public.guardar_licencia_activo_v77(
  p_id uuid,
  p_activo_id uuid,
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
  v_activo uuid;
  v_anterior public.activo_licencias%rowtype;
  v_venc date := nullif(p_datos->>'fecha_vencimiento', '')::date;
begin
  if v_uid is null then raise exception 'Sesion no valida'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'El motivo es obligatorio'; end if;

  -- Reejecucion: si el evento ya existe, devolver la licencia que creo.
  select me.entidad_id into v_id
  from public.mantenimiento_eventos me
  where me.idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  if p_id is not null then
    select * into v_anterior from public.activo_licencias where id = p_id for update;
    if not found then raise exception 'La licencia no existe'; end if;
    v_activo := v_anterior.activo_id;
  else
    v_activo := p_activo_id;
  end if;
  if v_activo is null then raise exception 'Indica el activo de la licencia'; end if;
  if not public.puede_ver_activo_mantenimiento_v54(v_activo, true) then
    raise exception 'No tienes permiso para gestionar las licencias de ese activo';
  end if;
  if btrim(coalesce(p_datos->>'nombre', '')) = '' then
    raise exception 'El nombre de la licencia es obligatorio';
  end if;
  if v_venc is null then raise exception 'La fecha de vencimiento es obligatoria'; end if;

  if p_id is null then
    insert into public.activo_licencias (
      activo_id, tipo, nombre, proveedor, numero, fecha_inicio, fecha_vencimiento,
      dias_aviso, costo_renovacion, responsable_id, notas, creado_por, actualizado_por
    ) values (
      v_activo,
      coalesce(nullif(p_datos->>'tipo', ''), 'software'),
      btrim(p_datos->>'nombre'),
      nullif(btrim(coalesce(p_datos->>'proveedor', '')), ''),
      nullif(btrim(coalesce(p_datos->>'numero', '')), ''),
      nullif(p_datos->>'fecha_inicio', '')::date,
      v_venc,
      coalesce(nullif(p_datos->>'dias_aviso', '')::integer, 30),
      nullif(p_datos->>'costo_renovacion', '')::numeric,
      nullif(p_datos->>'responsable_id', '')::uuid,
      nullif(btrim(coalesce(p_datos->>'notas', '')), ''),
      v_uid, v_uid
    ) returning id into v_id;
  else
    update public.activo_licencias set
      tipo = coalesce(nullif(p_datos->>'tipo', ''), tipo),
      nombre = btrim(p_datos->>'nombre'),
      proveedor = nullif(btrim(coalesce(p_datos->>'proveedor', '')), ''),
      numero = nullif(btrim(coalesce(p_datos->>'numero', '')), ''),
      fecha_inicio = nullif(p_datos->>'fecha_inicio', '')::date,
      fecha_vencimiento = v_venc,
      dias_aviso = coalesce(nullif(p_datos->>'dias_aviso', '')::integer, dias_aviso),
      costo_renovacion = nullif(p_datos->>'costo_renovacion', '')::numeric,
      responsable_id = nullif(p_datos->>'responsable_id', '')::uuid,
      notas = nullif(btrim(coalesce(p_datos->>'notas', '')), ''),
      actualizado_por = v_uid,
      updated_at = now()
    where id = p_id returning id into v_id;
  end if;

  insert into public.mantenimiento_eventos (
    entidad_tipo, entidad_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    'licencia', v_id,
    case when p_id is null then 'licencia_creada' else 'licencia_editada' end,
    case when p_id is null then null else v_anterior.fecha_vencimiento::text end,
    v_venc::text, btrim(p_motivo), coalesce(p_datos, '{}'::jsonb), v_uid, p_idempotency_key
  );
  return v_id;
end;
$fn$;

-- ------------------------------------------------------------
-- 5. Renovacion: fila nueva encadenada, la anterior queda como historial
-- ------------------------------------------------------------
create or replace function public.renovar_licencia_activo_v77(
  p_licencia_id uuid,
  p_fecha_vencimiento date,
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
  v_ant public.activo_licencias%rowtype;
  v_inicio date := nullif(p_datos->>'fecha_inicio', '')::date;
begin
  if v_uid is null then raise exception 'Sesion no valida'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'El motivo es obligatorio'; end if;

  select me.entidad_id into v_id
  from public.mantenimiento_eventos me
  where me.idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  select * into v_ant from public.activo_licencias where id = p_licencia_id for update;
  if not found then raise exception 'La licencia no existe'; end if;
  if not public.puede_ver_activo_mantenimiento_v54(v_ant.activo_id, true) then
    raise exception 'No tienes permiso para renovar las licencias de ese activo';
  end if;
  if v_ant.estado <> 'vigente' then
    raise exception 'Solo se renueva una licencia vigente; esta esta %', v_ant.estado;
  end if;
  if exists (select 1 from public.activo_licencias r where r.renovacion_de_id = p_licencia_id) then
    raise exception 'Esa licencia ya fue renovada';
  end if;
  if p_fecha_vencimiento is null then
    raise exception 'Indica hasta cuando queda vigente la renovacion';
  end if;
  if p_fecha_vencimiento <= v_ant.fecha_vencimiento then
    raise exception 'La renovacion debe vencer despues del % ',
      to_char(v_ant.fecha_vencimiento, 'DD/MM/YYYY');
  end if;

  -- El periodo nuevo hereda los datos del anterior salvo lo que se cambie.
  insert into public.activo_licencias (
    activo_id, tipo, nombre, proveedor, numero, fecha_inicio, fecha_vencimiento,
    dias_aviso, costo_renovacion, responsable_id, notas,
    renovacion_de_id, creado_por, actualizado_por
  ) values (
    v_ant.activo_id, v_ant.tipo, v_ant.nombre,
    coalesce(nullif(btrim(coalesce(p_datos->>'proveedor', '')), ''), v_ant.proveedor),
    coalesce(nullif(btrim(coalesce(p_datos->>'numero', '')), ''), v_ant.numero),
    -- Por defecto arranca el dia siguiente al vencimiento anterior, que es
    -- como se encadenan los periodos sin dejar huecos.
    coalesce(v_inicio, v_ant.fecha_vencimiento + 1),
    p_fecha_vencimiento,
    coalesce(nullif(p_datos->>'dias_aviso', '')::integer, v_ant.dias_aviso),
    coalesce(nullif(p_datos->>'costo_renovacion', '')::numeric, v_ant.costo_renovacion),
    coalesce(nullif(p_datos->>'responsable_id', '')::uuid, v_ant.responsable_id),
    nullif(btrim(coalesce(p_datos->>'notas', '')), ''),
    p_licencia_id, v_uid, v_uid
  ) returning id into v_id;

  update public.activo_licencias
  set estado = 'renovada', actualizado_por = v_uid, updated_at = now()
  where id = p_licencia_id;

  insert into public.mantenimiento_eventos (
    entidad_tipo, entidad_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    'licencia', v_id, 'licencia_renovada',
    v_ant.fecha_vencimiento::text, p_fecha_vencimiento::text,
    btrim(p_motivo),
    coalesce(p_datos, '{}'::jsonb) || jsonb_build_object('renovacion_de', p_licencia_id),
    v_uid, p_idempotency_key
  );
  return v_id;
end;
$fn$;

-- ------------------------------------------------------------
-- 6. Cancelar una licencia que ya no aplica
-- ------------------------------------------------------------
create or replace function public.cancelar_licencia_activo_v77(
  p_licencia_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_ant public.activo_licencias%rowtype;
begin
  if v_uid is null then raise exception 'Sesion no valida'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica la cancelacion con al menos 10 caracteres';
  end if;
  if exists (
    select 1 from public.mantenimiento_eventos me where me.idempotency_key = p_idempotency_key
  ) then return; end if;

  select * into v_ant from public.activo_licencias where id = p_licencia_id for update;
  if not found then raise exception 'La licencia no existe'; end if;
  if not public.puede_ver_activo_mantenimiento_v54(v_ant.activo_id, true) then
    raise exception 'No tienes permiso para cancelar las licencias de ese activo';
  end if;
  if v_ant.estado <> 'vigente' then
    raise exception 'Solo se cancela una licencia vigente; esta esta %', v_ant.estado;
  end if;

  update public.activo_licencias
  set estado = 'cancelada', motivo_cancelacion = btrim(p_motivo),
      actualizado_por = v_uid, updated_at = now()
  where id = p_licencia_id;

  insert into public.mantenimiento_eventos (
    entidad_tipo, entidad_id, tipo, estado_anterior, estado_nuevo,
    detalle, datos, usuario_id, idempotency_key
  ) values (
    'licencia', p_licencia_id, 'licencia_cancelada', 'vigente', 'cancelada',
    btrim(p_motivo), '{}'::jsonb, v_uid, p_idempotency_key
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 7. Avisos en el centro de notificaciones
-- ------------------------------------------------------------
-- Mismo mecanismo que sincronizar_alertas_mantenimiento_v54: upsert por
-- origen_clave y se apaga lo que deja de aplicar.
create or replace function public.sincronizar_alertas_licencias_v77()
returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
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
    'mantenimiento:licencia:' || l.id::text || ':vencimiento', 'mantenimiento_licencia',
    a.grupo_id, a.empresa_id, a.almacen_id, 'mantenimiento.acceder', 'Mantenimiento',
    case when l.fecha_vencimiento < v_hoy then 'critica' else 'alerta' end,
    left(
      case when l.fecha_vencimiento < v_hoy
        then 'Licencia vencida · ' else 'Licencia por vencer · ' end
      || a.codigo || ' · ' || l.nombre, 160),
    left(
      l.nombre || ' de ' || a.nombre
      || case when l.fecha_vencimiento < v_hoy
           then ' vencio el ' else ' vence el ' end
      || to_char(l.fecha_vencimiento, 'DD/MM/YYYY')
      || coalesce(' · proveedor ' || l.proveedor, '')
      || coalesce(' · renovacion USD ' || l.costo_renovacion::text, ''), 1200),
    '/mantenimiento', v_uid
  from public.activo_licencias l
  join public.activos_mantenimiento a on a.id = l.activo_id
  where l.estado = 'vigente'
    and a.activo and a.estado <> 'baja'
    and public.puede_ver_activo_mantenimiento_v54(a.id, false)
    and l.fecha_vencimiento <= v_hoy + l.dias_aviso
  on conflict (origen_clave) do update set
    activo = true, nivel = excluded.nivel, titulo = excluded.titulo,
    mensaje = excluded.mensaje, updated_at = now();
  get diagnostics v_total = row_count;

  -- Se apaga el aviso de lo renovado, cancelado, dado de baja o que ya no
  -- entra en su ventana de aviso.
  update public.notificaciones_comunicados n
  set activo = false, updated_at = now()
  where n.origen_tipo = 'mantenimiento_licencia' and n.activo
    and exists (
      select 1
      from public.activo_licencias l
      join public.activos_mantenimiento a on a.id = l.activo_id
      where n.origen_clave = 'mantenimiento:licencia:' || l.id::text || ':vencimiento'
        and public.puede_ver_activo_mantenimiento_v54(a.id, false)
        and (
          l.estado <> 'vigente'
          or not a.activo or a.estado = 'baja'
          or l.fecha_vencimiento > v_hoy + l.dias_aviso
        )
    );
  return v_total;
end;
$fn$;

-- ------------------------------------------------------------
-- 8. RLS y privilegios
-- ------------------------------------------------------------
alter table public.activo_licencias enable row level security;

drop policy if exists "leer_licencias_activos_v77" on public.activo_licencias;
create policy "leer_licencias_activos_v77"
on public.activo_licencias for select to authenticated using (
  public.puede_ver_activo_mantenimiento_v54(activo_id, false)
);

alter table public.activo_licencias owner to postgres;
alter view public.vista_licencias_activos_v77 owner to postgres;
alter function public.guardar_licencia_activo_v77(uuid,uuid,jsonb,text,uuid) owner to postgres;
alter function public.renovar_licencia_activo_v77(uuid,date,jsonb,text,uuid) owner to postgres;
alter function public.cancelar_licencia_activo_v77(uuid,text,uuid) owner to postgres;
alter function public.sincronizar_alertas_licencias_v77() owner to postgres;

revoke all on public.activo_licencias from public, anon;
revoke insert, update, delete on public.activo_licencias from authenticated;
grant select on public.activo_licencias to authenticated;
revoke all on public.vista_licencias_activos_v77 from public, anon;
grant select on public.vista_licencias_activos_v77 to authenticated;

revoke execute on function public.guardar_licencia_activo_v77(uuid,uuid,jsonb,text,uuid) from public, anon;
revoke execute on function public.renovar_licencia_activo_v77(uuid,date,jsonb,text,uuid) from public, anon;
revoke execute on function public.cancelar_licencia_activo_v77(uuid,text,uuid) from public, anon;
revoke execute on function public.sincronizar_alertas_licencias_v77() from public, anon;
grant execute on function public.guardar_licencia_activo_v77(uuid,uuid,jsonb,text,uuid) to authenticated;
grant execute on function public.renovar_licencia_activo_v77(uuid,date,jsonb,text,uuid) to authenticated;
grant execute on function public.cancelar_licencia_activo_v77(uuid,text,uuid) to authenticated;
grant execute on function public.sincronizar_alertas_licencias_v77() to authenticated;

commit;

notify pgrst, 'reload schema';
