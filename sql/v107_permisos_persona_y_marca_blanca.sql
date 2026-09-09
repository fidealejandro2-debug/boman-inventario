-- ============================================================
-- BOMAN INVENTARIO - v107: permisos por persona + interruptor de marca blanca
--
-- Hoy los permisos son 100% por rol (rol_permisos). Este archivo agrega dos
-- cosas independientes, ambas compuestas sobre las MISMAS funciones que ya
-- usa todo el sistema (usuario_tiene_permiso_v35/permisos_usuario_actual_v35
-- via create or replace, no se reemplazan por otras de nombre distinto):
--
-- 1. Excepciones de permiso por persona (perfil_permisos): un override gana
--    sobre el valor del rol cuando existe. Pensado para casos puntuales
--    ("esta persona sí puede ver X aunque su rol no", o al revés).
-- 2. Un interruptor de "marca blanca" (configuracion_sistema): permite
--    apagar de un tiro lo que es especifico de Boman Sport (contratos/
--    BomanSport, franquicias) si el ERP se vendiera como producto generico.
--
-- Ejecutar despues de v35, v81 y v100.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regprocedure('public.permisos_usuario_actual_v35()') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null
     or to_regprocedure('public.admin_guardar_permisos_rol_v35(text,jsonb,text,uuid)') is null
     or to_regprocedure('public.rol_usuario_actual()') is null then
    raise exception 'Falta v35. Instalala antes de v107';
  end if;
  if not exists (select 1 from public.permisos_sistema where codigo = 'franquicia.turnos') then
    raise exception 'Falta v81. Instalala antes de v107';
  end if;
  if not exists (select 1 from public.permisos_sistema where codigo = 'contratos.finanzas.ver') then
    raise exception 'Falta v100. Instalala antes de v107';
  end if;
end;
$requisitos$;

-- ------------------------------------------------------------
-- 1. Marca blanca: configuracion global + etiqueta por permiso
-- ------------------------------------------------------------

-- Fila unica (id boolean primary key default true check(id) fuerza a que
-- exista como maximo una fila) en vez de una tabla de configuracion generica
-- que hoy no hace falta.
create table if not exists public.configuracion_sistema (
  id boolean primary key default true check (id),
  es_boman_especifico_activo boolean not null default true,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  updated_at timestamptz not null default now()
);
insert into public.configuracion_sistema (id, es_boman_especifico_activo)
values (true, true)
on conflict (id) do nothing;

alter table public.permisos_sistema
  add column if not exists es_boman_especifico boolean not null default false;

comment on column public.permisos_sistema.es_boman_especifico is
  'Marca permisos atados al modelo de negocio propio de Boman Sport (sincronizacion de contratos '
  'BomanSport/Google Sheets, operacion de franquicias). Sirve para ocultarlos de un tiro si el ERP '
  'se vende como producto generico (ver configuracion_sistema.es_boman_especifico_activo).';

-- contratos.* es integro especifico de Boman (la sincronizacion con
-- BomanSport/Google Sheets no existe fuera de este cliente). franquicia.*
-- igual, EXCEPTO franquicia.caja: esa la reutiliza la caja de tienda propia
-- (puedeVerCajaTienda en Navbar.tsx), que no es especifica de franquicias.
update public.permisos_sistema set es_boman_especifico = true
where codigo in (
  'contratos.acceder', 'contratos.editar', 'contratos.marcar_etapa',
  'contratos.finanzas.ver', 'contratos.finanzas.editar',
  'franquicia.acceder', 'franquicia.ventas', 'franquicia.inventario',
  'franquicia.reposicion', 'franquicia.precio_libre', 'franquicia.descuento',
  'franquicia.consolidado', 'franquicia.turnos', 'franquicia.cobros',
  'franquicia.devoluciones'
);

create or replace function public.modo_boman_especifico_activo()
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
    (select es_boman_especifico_activo from public.configuracion_sistema where id),
    true
  );
$fn$;

create or replace function public.admin_actualizar_configuracion_sistema_v107(
  p_es_boman_especifico_activo boolean,
  p_motivo text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede cambiar la configuracion del sistema';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El motivo debe tener al menos 10 caracteres';
  end if;

  update public.configuracion_sistema
  set es_boman_especifico_activo = p_es_boman_especifico_activo,
      actualizado_por = auth.uid(),
      updated_at = now()
  where id;

  return jsonb_build_object(
    'mensaje',
    case when p_es_boman_especifico_activo
      then 'Funciones especificas de Boman Sport activadas.'
      else 'Funciones especificas de Boman Sport ocultas (modo marca blanca).'
    end
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 2. Permisos por persona: override sobre el valor del rol
-- ------------------------------------------------------------

create table if not exists public.perfil_permisos (
  perfil_id uuid not null references public.perfiles(id) on delete restrict,
  permiso_codigo text not null references public.permisos_sistema(codigo) on delete restrict,
  permitido boolean not null,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (perfil_id, permiso_codigo)
);

comment on table public.perfil_permisos is
  'Excepciones de permiso por persona. Si existe una fila aqui, gana sobre el valor del rol '
  '(rol_permisos) para ese permiso puntual; si no existe, se usa el valor del rol como siempre.';

create table if not exists public.permisos_usuario_eventos (
  id uuid primary key default gen_random_uuid(),
  perfil_id uuid not null references public.perfiles(id) on delete restrict,
  permisos_anteriores jsonb not null,
  permisos_nuevos jsonb not null,
  motivo text not null check (length(btrim(motivo)) >= 10),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_perfil_permisos_permiso_v107
  on public.perfil_permisos(permiso_codigo, perfil_id);
create index if not exists idx_permisos_usuario_eventos_v107
  on public.permisos_usuario_eventos(perfil_id, created_at desc);

create or replace function public.admin_guardar_permisos_usuario_v107(
  p_perfil_id uuid,
  p_items jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_perfil public.perfiles%rowtype;
  v_antes jsonb;
  v_despues jsonb;
  v_evento_id uuid;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede cambiar permisos individuales';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El motivo debe tener al menos 10 caracteres';
  end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Selecciona al menos un permiso para modificar';
  end if;

  select * into v_perfil from public.perfiles where id = p_perfil_id;
  if not found then raise exception 'La persona no existe'; end if;
  -- Admin ya tiene todo por el bypass de rol: un override aqui no haria nada
  -- util y podria confundirse con una forma de bloquear al ultimo admin.
  if v_perfil.rol::text = 'admin' then
    raise exception 'No se pueden asignar permisos individuales a una cuenta de Administrador';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 107));
  select id into v_evento_id
  from public.permisos_usuario_eventos
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_evento_id, 'duplicado', true,
      'mensaje', 'Los permisos ya habian sido guardados');
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(permiso_codigo text, permitido boolean)
    left join public.permisos_sistema ps on ps.codigo = x.permiso_codigo and ps.activo
    where x.permiso_codigo is null or ps.codigo is null
  ) then
    raise exception 'La lista contiene un permiso inexistente o inactivo';
  end if;
  if exists (
    select permiso_codigo
    from jsonb_to_recordset(p_items) as x(permiso_codigo text, permitido boolean)
    group by permiso_codigo having count(*) > 1
  ) then
    raise exception 'La lista contiene permisos repetidos';
  end if;

  select coalesce(jsonb_object_agg(permiso_codigo, permitido), '{}'::jsonb) into v_antes
  from public.perfil_permisos where perfil_id = p_perfil_id;

  -- permitido = null en el item borra el override (vuelve al valor del rol).
  delete from public.perfil_permisos pp
  using jsonb_to_recordset(p_items) as x(permiso_codigo text, permitido boolean)
  where pp.perfil_id = p_perfil_id
    and pp.permiso_codigo = x.permiso_codigo
    and x.permitido is null;

  insert into public.perfil_permisos as pp (perfil_id, permiso_codigo, permitido, actualizado_por)
  select p_perfil_id, x.permiso_codigo, x.permitido, auth.uid()
  from jsonb_to_recordset(p_items) as x(permiso_codigo text, permitido boolean)
  where x.permitido is not null
  on conflict (perfil_id, permiso_codigo) do update
  set permitido = excluded.permitido, actualizado_por = auth.uid(), updated_at = now();

  select coalesce(jsonb_object_agg(permiso_codigo, permitido), '{}'::jsonb) into v_despues
  from public.perfil_permisos where perfil_id = p_perfil_id;

  insert into public.permisos_usuario_eventos (
    perfil_id, permisos_anteriores, permisos_nuevos, motivo, usuario_id, idempotency_key
  ) values (
    p_perfil_id, v_antes, v_despues, btrim(p_motivo), auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;

  return jsonb_build_object('id', v_evento_id, 'duplicado', false,
    'mensaje', 'Permisos individuales actualizados correctamente');
end;
$fn$;

create or replace view public.vista_matriz_permisos_usuario_v107
with (security_invoker = true) as
select
  pf.id as perfil_id,
  pf.nombre_completo,
  pf.rol::text as rol,
  ps.codigo as permiso_codigo,
  ps.modulo,
  ps.nombre,
  ps.descripcion,
  ps.orden,
  ps.es_boman_especifico,
  case when pf.rol::text = 'admin' then true else coalesce(rp.permitido, false) end
    as permitido_por_rol,
  pp.permitido as permitido_override,
  coalesce(
    pp.permitido,
    case when pf.rol::text = 'admin' then true else coalesce(rp.permitido, false) end
  ) as permitido_efectivo,
  (pf.rol::text <> 'admin') as configurable,
  pp.updated_at
from public.perfiles pf
cross join public.permisos_sistema ps
left join public.rol_permisos rp on rp.rol = pf.rol and rp.permiso_codigo = ps.codigo
left join public.perfil_permisos pp on pp.perfil_id = pf.id and pp.permiso_codigo = ps.codigo
where ps.activo and pf.activo;

-- ------------------------------------------------------------
-- 3. Componer overrides + marca blanca en las funciones YA existentes
--    (create or replace sobre el mismo nombre: toda RPC protegida del
--    sistema sigue llamando a estas dos funciones sin cambiar una linea).
-- ------------------------------------------------------------

create or replace function public.usuario_tiene_permiso_v35(p_permiso_codigo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select exists (
    select 1
    from public.perfiles p
    join public.permisos_sistema ps
      on ps.codigo = p_permiso_codigo and ps.activo
    left join public.rol_permisos rp
      on rp.rol = p.rol and rp.permiso_codigo = p_permiso_codigo
    left join public.perfil_permisos pp
      on pp.perfil_id = p.id and pp.permiso_codigo = p_permiso_codigo
    where p.id = auth.uid() and p.activo
      and (not ps.es_boman_especifico or public.modo_boman_especifico_activo())
      and coalesce(
        pp.permitido,
        p.rol::text = 'admin' or coalesce(rp.permitido, false)
      )
  );
$fn$;

create or replace function public.permisos_usuario_actual_v35()
returns text[]
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(array_agg(x.codigo order by x.orden), array[]::text[])
  from (
    select ps.codigo, ps.orden
    from public.perfiles p
    join public.permisos_sistema ps on ps.activo
    left join public.rol_permisos rp
      on rp.rol = p.rol and rp.permiso_codigo = ps.codigo
    left join public.perfil_permisos pp
      on pp.perfil_id = p.id and pp.permiso_codigo = ps.codigo
    where p.id = auth.uid() and p.activo
      and (not ps.es_boman_especifico or public.modo_boman_especifico_activo())
      and coalesce(
        pp.permitido,
        p.rol::text = 'admin' or coalesce(rp.permitido, false)
      )
  ) x;
$fn$;

-- ------------------------------------------------------------
-- 4. RLS y permisos
-- ------------------------------------------------------------

alter table public.configuracion_sistema enable row level security;
alter table public.perfil_permisos enable row level security;
alter table public.permisos_usuario_eventos enable row level security;

drop policy if exists "admin_leer_configuracion_sistema_v107" on public.configuracion_sistema;
create policy "admin_leer_configuracion_sistema_v107" on public.configuracion_sistema
for select to authenticated using (public.rol_usuario_actual() = 'admin');

drop policy if exists "admin_leer_perfil_permisos_v107" on public.perfil_permisos;
create policy "admin_leer_perfil_permisos_v107" on public.perfil_permisos
for select to authenticated using (public.rol_usuario_actual() = 'admin');

drop policy if exists "admin_leer_permisos_usuario_eventos_v107" on public.permisos_usuario_eventos;
create policy "admin_leer_permisos_usuario_eventos_v107" on public.permisos_usuario_eventos
for select to authenticated using (public.rol_usuario_actual() = 'admin');

alter table public.configuracion_sistema owner to postgres;
alter table public.perfil_permisos owner to postgres;
alter table public.permisos_usuario_eventos owner to postgres;
alter function public.modo_boman_especifico_activo() owner to postgres;
alter function public.admin_actualizar_configuracion_sistema_v107(boolean, text) owner to postgres;
alter function public.admin_guardar_permisos_usuario_v107(uuid, jsonb, text, uuid) owner to postgres;
alter function public.usuario_tiene_permiso_v35(text) owner to postgres;
alter function public.permisos_usuario_actual_v35() owner to postgres;

revoke all on public.configuracion_sistema from public, anon;
revoke all on public.perfil_permisos from public, anon;
revoke all on public.permisos_usuario_eventos from public, anon;
revoke insert, update, delete on public.configuracion_sistema from authenticated;
revoke insert, update, delete on public.perfil_permisos from authenticated;
revoke insert, update, delete on public.permisos_usuario_eventos from authenticated;
grant select on public.configuracion_sistema to authenticated;
grant select on public.perfil_permisos to authenticated;
grant select on public.permisos_usuario_eventos to authenticated;
grant select on public.vista_matriz_permisos_usuario_v107 to authenticated;

revoke execute on function public.modo_boman_especifico_activo() from public, anon;
revoke execute on function public.admin_actualizar_configuracion_sistema_v107(boolean, text) from public, anon;
revoke execute on function public.admin_guardar_permisos_usuario_v107(uuid, jsonb, text, uuid) from public, anon;
grant execute on function public.modo_boman_especifico_activo() to authenticated;
grant execute on function public.admin_actualizar_configuracion_sistema_v107(boolean, text) to authenticated;
grant execute on function public.admin_guardar_permisos_usuario_v107(uuid, jsonb, text, uuid) to authenticated;

comment on table public.configuracion_sistema is
  'Configuracion global de una sola fila. Hoy solo controla el interruptor de marca blanca.';
comment on table public.permisos_usuario_eventos is
  'Auditoria de cada cambio de permisos por persona: motivo, quien, antes/despues, idempotencia.';

commit;

notify pgrst, 'reload schema';
