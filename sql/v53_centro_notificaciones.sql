-- ============================================================
-- BOMAN INVENTARIO - v53: centro general de notificaciones
--
-- Centraliza avisos operativos derivados del panel y comunicados internos.
-- Cada usuario conserva su propio estado de lectura y archivo. El alcance
-- siempre se deriva de la sesion, los permisos, empresas y almacenes.
-- Ejecutar una sola vez DESPUES de v52.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Permisos configurables
-- ------------------------------------------------------------
insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('notificaciones.acceder', 'Notificaciones', 'Centro de notificaciones',
   'Consulta avisos y pendientes visibles para el usuario.', 140),
  ('notificaciones.publicar', 'Notificaciones', 'Publicar comunicados',
   'Publica comunicados internos por rol, usuario, empresa o almacen.', 141)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.activo
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos
set permitido = true, updated_at = now()
where permiso_codigo = 'notificaciones.acceder';

update public.rol_permisos
set permitido = true, updated_at = now()
where permiso_codigo = 'notificaciones.publicar'
  and rol::text in ('control', 'gerencia');

create or replace view public.vista_matriz_permisos_v35
with (security_invoker = true) as
select
  r.rol::text as rol,
  ps.codigo as permiso_codigo,
  ps.modulo,
  ps.nombre,
  ps.descripcion,
  ps.orden,
  case when r.rol::text = 'admin' then true else coalesce(rp.permitido, false) end
    as permitido,
  r.rol::text <> 'admin' as configurable,
  rp.updated_at
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema ps
left join public.rol_permisos rp
  on rp.rol = r.rol and rp.permiso_codigo = ps.codigo
where ps.activo;

-- ------------------------------------------------------------
-- 2. Comunicados y estado personal
-- ------------------------------------------------------------
create table if not exists public.notificaciones_comunicados (
  id uuid primary key default gen_random_uuid(),
  origen_clave text unique check (origen_clave is null or length(origen_clave) <= 240),
  origen_tipo text,
  grupo_id uuid references public.grupos_economicos(id) on delete restrict,
  empresa_id uuid references public.empresas(id) on delete restrict,
  almacen_id uuid references public.almacenes(id) on delete restrict,
  usuario_destino_id uuid references public.perfiles(id) on delete cascade,
  rol_destino public.rol_usuario,
  permiso_requerido text references public.permisos_sistema(codigo) on delete restrict,
  modulo text not null check (btrim(modulo) <> '' and length(modulo) <= 80),
  nivel text not null default 'informativa'
    check (nivel in ('informativa', 'accion', 'alerta', 'critica')),
  titulo text not null check (btrim(titulo) <> '' and length(titulo) <= 160),
  mensaje text not null check (btrim(mensaje) <> '' and length(mensaje) <= 1200),
  href text not null default '/dashboard' check (href like '/%' and length(href) <= 300),
  vigente_desde timestamptz not null default now(),
  vigente_hasta timestamptz,
  activo boolean not null default true,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (vigente_hasta is null or vigente_hasta > vigente_desde)
);

create table if not exists public.notificacion_usuario_estados (
  usuario_id uuid not null references public.perfiles(id) on delete cascade,
  notificacion_clave text not null check (btrim(notificacion_clave) <> ''),
  leida_at timestamptz,
  archivada_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (usuario_id, notificacion_clave)
);

create index if not exists idx_notificaciones_vigentes_v53
  on public.notificaciones_comunicados(activo, vigente_desde desc);
create index if not exists idx_notificaciones_destino_v53
  on public.notificaciones_comunicados(usuario_destino_id, rol_destino, created_at desc);
create index if not exists idx_notificacion_estado_usuario_v53
  on public.notificacion_usuario_estados(usuario_id, archivada_at, leida_at);

-- ------------------------------------------------------------
-- 3. Lectura unificada: comunicados + pendientes operativos
-- ------------------------------------------------------------
create or replace function public.listar_notificaciones_v53(
  p_incluir_leidas boolean default true,
  p_incluir_archivadas boolean default false
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_rol text;
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_resumen jsonb;
  v_resultado jsonb;
begin
  if v_uid is null or not public.usuario_tiene_permiso_v35('notificaciones.acceder') then
    raise exception 'No tienes permiso para consultar notificaciones';
  end if;

  select p.rol::text into v_rol
  from public.perfiles p
  where p.id = v_uid and p.activo;
  if not found then raise exception 'El perfil no existe o esta inactivo'; end if;

  v_resumen := public.resumen_panel_principal_v51();

  with alertas as (
    select 'comunicado:' || n.id::text as clave, n.modulo, n.nivel,
           n.titulo, n.mensaje, n.href, n.vigente_desde as fecha,
           'comunicado'::text as origen
    from public.notificaciones_comunicados n
    where n.activo and n.vigente_desde <= now()
      and (n.vigente_hasta is null or n.vigente_hasta > now())
      and (n.usuario_destino_id is null or n.usuario_destino_id = v_uid)
      and (n.rol_destino is null or n.rol_destino::text = v_rol)
      and (n.permiso_requerido is null
        or public.usuario_tiene_permiso_v35(n.permiso_requerido))
      and (n.empresa_id is null or public.usuario_puede_empresa(n.empresa_id, false))
      and (n.almacen_id is null or public.usuario_puede_almacen(n.almacen_id, false))
      and (n.grupo_id is null or exists (
        select 1 from public.empresas e
        where e.grupo_id = n.grupo_id and e.activo
          and public.usuario_puede_empresa(e.id, false)
      ))

    union all
    select 'inventario:bajo_minimo:' || v_hoy::text || ':' ||
             (v_resumen #>> '{inventario,productos_bajo_minimo}'),
           'Inventario', 'critica', 'Productos bajo minimo',
           (v_resumen #>> '{inventario,productos_bajo_minimo}') ||
             ' productos requieren reposicion; sugerido ' ||
             (v_resumen #>> '{inventario,unidades_sugeridas}') || ' unidades.',
           '/inventario', v_hoy::timestamp at time zone 'America/Guayaquil', 'sistema'
    where public.usuario_tiene_permiso_v35('inventario.acceder')
      and coalesce((v_resumen #>> '{inventario,productos_bajo_minimo}')::integer, 0) > 0

    union all
    select 'operaciones:recibir:' || v_hoy::text || ':' ||
             (v_resumen #>> '{operaciones,transferencias_recibir}'),
           'Operaciones', 'accion', 'Transferencias por recibir',
           (v_resumen #>> '{operaciones,transferencias_recibir}') ||
             ' transferencias estan despachadas o en transito.',
           case when v_rol in ('franquiciado', 'vendedor_franquicia')
             then '/franquicia' else '/operaciones' end,
           v_hoy::timestamp at time zone 'America/Guayaquil', 'sistema'
    where public.usuario_tiene_permiso_v35('operaciones.acceder')
      and coalesce((v_resumen #>> '{operaciones,transferencias_recibir}')::integer, 0) > 0

    union all
    select 'control:solicitudes:' || v_hoy::text || ':' ||
             (v_resumen #>> '{operaciones,solicitudes_pendientes}'),
           'Control', 'accion', 'Solicitudes por aprobar',
           (v_resumen #>> '{operaciones,solicitudes_pendientes}') ||
             ' solicitudes de reposicion esperan resolucion.',
           '/control', v_hoy::timestamp at time zone 'America/Guayaquil', 'sistema'
    where public.usuario_tiene_permiso_v35('control.acceder')
      and coalesce((v_resumen #>> '{operaciones,solicitudes_pendientes}')::integer, 0) > 0

    union all
    select 'compras:pendientes:' || v_hoy::text || ':' ||
             ((coalesce((v_resumen #>> '{compras,pendientes_aprobacion}')::integer, 0)
              + coalesce((v_resumen #>> '{compras,pendientes_recepcion}')::integer, 0))::text),
           'Compras', 'accion', 'Compras pendientes',
           (v_resumen #>> '{compras,pendientes_aprobacion}') || ' por aprobar y ' ||
             (v_resumen #>> '{compras,pendientes_recepcion}') || ' por recibir.',
           '/compras', v_hoy::timestamp at time zone 'America/Guayaquil', 'sistema'
    where public.usuario_tiene_permiso_v35('compras.acceder')
      and coalesce((v_resumen #>> '{compras,pendientes_aprobacion}')::integer, 0)
        + coalesce((v_resumen #>> '{compras,pendientes_recepcion}')::integer, 0) > 0

    union all
    select 'produccion:atrasadas:' || v_hoy::text || ':' ||
             (v_resumen #>> '{produccion,ordenes_atrasadas}'),
           'Produccion', 'critica', 'Ordenes de produccion atrasadas',
           (v_resumen #>> '{produccion,ordenes_atrasadas}') ||
             ' ordenes activas superaron su fecha planificada.',
           '/produccion', v_hoy::timestamp at time zone 'America/Guayaquil', 'sistema'
    where public.usuario_tiene_permiso_v35('produccion.acceder')
      and coalesce((v_resumen #>> '{produccion,ordenes_atrasadas}')::integer, 0) > 0

    union all
    select 'nomina:documentos:' || v_hoy::text || ':' ||
             (v_resumen #>> '{nomina,documentos_vencidos}'),
           'Nomina', 'critica', 'Documentos de personal vencidos',
           (v_resumen #>> '{nomina,documentos_vencidos}') ||
             ' documentos requieren actualizacion.',
           '/nomina', v_hoy::timestamp at time zone 'America/Guayaquil', 'sistema'
    where public.usuario_tiene_permiso_v35('nomina.acceder')
      and coalesce((v_resumen #>> '{nomina,documentos_vencidos}')::integer, 0) > 0

    union all
    select 'franquicia:alertas:' || v_hoy::text || ':' ||
             (v_resumen #>> '{franquicia,alertas}'),
           'Franquicia', 'accion', 'Reposiciones del local',
           (v_resumen #>> '{franquicia,alertas}') ||
             ' solicitudes cambiaron de estado o esperan recepcion.',
           '/franquicia', v_hoy::timestamp at time zone 'America/Guayaquil', 'sistema'
    where public.usuario_tiene_permiso_v35('franquicia.acceder')
      and coalesce((v_resumen #>> '{franquicia,alertas}')::integer, 0) > 0
  ), visibles as (
    select a.*, e.leida_at, e.archivada_at
    from alertas a
    left join public.notificacion_usuario_estados e
      on e.usuario_id = v_uid and e.notificacion_clave = a.clave
    where (p_incluir_leidas or e.leida_at is null)
      and (p_incluir_archivadas or e.archivada_at is null)
  )
  select jsonb_build_object(
    'no_leidas', count(*) filter (where leida_at is null),
    'criticas', count(*) filter (where leida_at is null and nivel = 'critica'),
    'total', count(*),
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'clave', clave, 'modulo', modulo, 'nivel', nivel,
      'titulo', titulo, 'mensaje', mensaje, 'href', href,
      'fecha', fecha, 'origen', origen,
      'leida', leida_at is not null, 'archivada', archivada_at is not null
    ) order by
      case nivel when 'critica' then 1 when 'alerta' then 2
        when 'accion' then 3 else 4 end,
      fecha desc), '[]'::jsonb)
  ) into v_resultado
  from visibles;

  return coalesce(v_resultado, jsonb_build_object(
    'no_leidas', 0, 'criticas', 0, 'total', 0, 'items', '[]'::jsonb
  ));
end;
$fn$;

create or replace function public.resumen_notificaciones_v53()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.listar_notificaciones_v53(false, false) - 'items';
$$;

create or replace function public.marcar_notificaciones_v53(
  p_claves text[],
  p_accion text
) returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_total integer;
begin
  if v_uid is null or not public.usuario_tiene_permiso_v35('notificaciones.acceder') then
    raise exception 'No tienes permiso para gestionar notificaciones';
  end if;
  if p_accion not in ('leer', 'no_leida', 'archivar', 'restaurar') then
    raise exception 'Accion de notificacion no valida';
  end if;
  if coalesce(cardinality(p_claves), 0) = 0 then return 0; end if;
  if cardinality(p_claves) > 200 then
    raise exception 'Solo puedes gestionar 200 notificaciones por operacion';
  end if;
  if exists (select 1 from unnest(p_claves) c where btrim(c) = '' or length(c) > 300) then
    raise exception 'Una clave de notificacion no es valida';
  end if;

  insert into public.notificacion_usuario_estados as e (
    usuario_id, notificacion_clave, leida_at, archivada_at, updated_at
  )
  select v_uid, c,
    case when p_accion in ('leer', 'archivar') then now() else null end,
    case when p_accion = 'archivar' then now() else null end,
    now()
  from (select distinct unnest(p_claves) as c) x
  on conflict (usuario_id, notificacion_clave) do update set
    leida_at = case
      when p_accion = 'leer' then now()
      when p_accion = 'no_leida' then null
      when p_accion = 'archivar' then coalesce(e.leida_at, now())
      else e.leida_at end,
    archivada_at = case
      when p_accion = 'archivar' then now()
      when p_accion = 'restaurar' then null
      else e.archivada_at end,
    updated_at = now();
  get diagnostics v_total = row_count;
  return v_total;
end;
$fn$;

create or replace function public.publicar_notificacion_v53(
  p_datos jsonb,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_rol public.rol_usuario;
  v_usuario uuid;
  v_empresa uuid;
  v_almacen uuid;
  v_grupo uuid;
  v_hasta timestamptz;
begin
  if v_uid is null or not public.usuario_tiene_permiso_v35('notificaciones.publicar') then
    raise exception 'No tienes permiso para publicar comunicados';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;

  select n.id into v_id
  from public.notificaciones_comunicados n
  where n.origen_clave = 'manual:' || p_idempotency_key::text;
  if found then return v_id; end if;

  if nullif(p_datos->>'rol_destino', '') is not null then
    v_rol := (p_datos->>'rol_destino')::public.rol_usuario;
  end if;
  v_usuario := nullif(p_datos->>'usuario_destino_id', '')::uuid;
  v_empresa := nullif(p_datos->>'empresa_id', '')::uuid;
  v_almacen := nullif(p_datos->>'almacen_id', '')::uuid;
  v_grupo := nullif(p_datos->>'grupo_id', '')::uuid;
  v_hasta := nullif(p_datos->>'vigente_hasta', '')::timestamptz;

  if btrim(coalesce(p_datos->>'titulo', '')) = ''
     or btrim(coalesce(p_datos->>'mensaje', '')) = '' then
    raise exception 'El titulo y el mensaje son obligatorios';
  end if;
  if coalesce(p_datos->>'nivel', 'informativa') not in
     ('informativa', 'accion', 'alerta', 'critica') then
    raise exception 'Nivel de notificacion no valido';
  end if;
  if coalesce(p_datos->>'href', '/dashboard') not like '/%' then
    raise exception 'El enlace debe ser una ruta interna';
  end if;
  if v_usuario is not null and not exists (
    select 1 from public.perfiles p where p.id = v_usuario and p.activo
  ) then raise exception 'El usuario destinatario no existe o esta inactivo'; end if;
  if v_empresa is not null and not public.usuario_puede_empresa(v_empresa, false) then
    raise exception 'No tienes acceso a la empresa destinataria';
  end if;
  if v_almacen is not null and not public.usuario_puede_almacen(v_almacen, false) then
    raise exception 'No tienes acceso al almacen destinatario';
  end if;
  if v_grupo is not null and not exists (
    select 1 from public.empresas e
    where e.grupo_id = v_grupo and e.activo
      and public.usuario_puede_empresa(e.id, false)
  ) then raise exception 'No tienes acceso al grupo destinatario'; end if;

  insert into public.notificaciones_comunicados (
    origen_clave, origen_tipo, grupo_id, empresa_id, almacen_id,
    usuario_destino_id, rol_destino, permiso_requerido, modulo, nivel,
    titulo, mensaje, href, vigente_hasta, creado_por
  ) values (
    'manual:' || p_idempotency_key::text, 'manual', v_grupo, v_empresa, v_almacen,
    v_usuario, v_rol, nullif(p_datos->>'permiso_requerido', ''),
    coalesce(nullif(btrim(p_datos->>'modulo'), ''), 'General'),
    coalesce(p_datos->>'nivel', 'informativa'), btrim(p_datos->>'titulo'),
    btrim(p_datos->>'mensaje'), coalesce(nullif(p_datos->>'href', ''), '/dashboard'),
    v_hasta, v_uid
  ) returning id into v_id;
  return v_id;
end;
$fn$;

-- ------------------------------------------------------------
-- 4. Seguridad
-- ------------------------------------------------------------
alter table public.notificaciones_comunicados enable row level security;
alter table public.notificacion_usuario_estados enable row level security;

drop policy if exists "leer_comunicados_visibles_v53" on public.notificaciones_comunicados;
create policy "leer_comunicados_visibles_v53"
on public.notificaciones_comunicados for select to authenticated using (
  public.usuario_tiene_permiso_v35('notificaciones.acceder')
  and activo and vigente_desde <= now()
  and (vigente_hasta is null or vigente_hasta > now())
  and (usuario_destino_id is null or usuario_destino_id = auth.uid())
  and (rol_destino is null or rol_destino::text = public.rol_usuario_actual())
  and (permiso_requerido is null or public.usuario_tiene_permiso_v35(permiso_requerido))
  and (empresa_id is null or public.usuario_puede_empresa(empresa_id, false))
  and (almacen_id is null or public.usuario_puede_almacen(almacen_id, false))
  and (grupo_id is null or exists (
    select 1 from public.empresas e
    where e.grupo_id = public.notificaciones_comunicados.grupo_id and e.activo
      and public.usuario_puede_empresa(e.id, false)
  ))
);

drop policy if exists "leer_estado_notificaciones_propio_v53" on public.notificacion_usuario_estados;
create policy "leer_estado_notificaciones_propio_v53"
on public.notificacion_usuario_estados for select to authenticated
using (usuario_id = auth.uid());

alter function public.listar_notificaciones_v53(boolean, boolean) owner to postgres;
alter function public.resumen_notificaciones_v53() owner to postgres;
alter function public.marcar_notificaciones_v53(text[], text) owner to postgres;
alter function public.publicar_notificacion_v53(jsonb, uuid) owner to postgres;

revoke all on public.notificaciones_comunicados from public, anon;
revoke all on public.notificacion_usuario_estados from public, anon;
revoke insert, update, delete on public.notificaciones_comunicados from authenticated;
revoke insert, update, delete on public.notificacion_usuario_estados from authenticated;
grant select on public.notificaciones_comunicados to authenticated;
grant select on public.notificacion_usuario_estados to authenticated;

revoke execute on function public.listar_notificaciones_v53(boolean, boolean) from public, anon;
revoke execute on function public.resumen_notificaciones_v53() from public, anon;
revoke execute on function public.marcar_notificaciones_v53(text[], text) from public, anon;
revoke execute on function public.publicar_notificacion_v53(jsonb, uuid) from public, anon;
grant execute on function public.listar_notificaciones_v53(boolean, boolean) to authenticated;
grant execute on function public.resumen_notificaciones_v53() to authenticated;
grant execute on function public.marcar_notificaciones_v53(text[], text) to authenticated;
grant execute on function public.publicar_notificacion_v53(jsonb, uuid) to authenticated;

notify pgrst, 'reload schema';
