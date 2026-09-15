-- ============================================================
-- v153 - Configuracion operativa por almacen: hora limite de cierre diario
-- y area en m2 (para el ranking de locales de v156 y las alertas de v155).
-- Ejecutar despues de v152 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v153', 0));

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta el registro formal de migraciones (v134)';
  end if;
  if to_regclass('public.almacenes') is null
     or to_regprocedure('public.usuario_puede_almacen(uuid,boolean)') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null
     or to_regprocedure('public.rol_usuario_actual()') is null then
    raise exception 'Falta el modelo base de almacenes/permisos';
  end if;
end;
$requisitos$;

create table if not exists public.almacen_configuracion_operativa_v153 (
  almacen_id uuid primary key references public.almacenes(id) on delete cascade,
  hora_limite_cierre time not null default '20:00',
  area_m2 numeric check (area_m2 is null or area_m2 > 0),
  actualizado_por uuid references public.perfiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Deja lista una fila por cada almacen activo existente: sin esto, el cron de
-- v155 no tendria hora limite de la que partir el primer dia.
insert into public.almacen_configuracion_operativa_v153(almacen_id)
select a.id from public.almacenes a where a.activo
on conflict (almacen_id) do nothing;

insert into public.permisos_sistema as p(
  codigo, modulo, nombre, descripcion, orden, es_boman_especifico
) values (
  'operativas.cierres.configurar', 'Franquicias', 'Configurar cierres y tamano de local',
  'Define la hora limite de cierre diario y el area en m2 de cada local, usados en el ranking y en las alertas de cierre pendiente.',
  61, false
)
on conflict(codigo) do update set
  modulo=excluded.modulo, nombre=excluded.nombre,
  descripcion=excluded.descripcion, orden=excluded.orden,
  activo=true, es_boman_especifico=false, updated_at=now();

-- Delegable por admin via Administracion -> Permisos por persona (v107); nadie
-- lo tiene por rol por defecto, ni siquiera control/gerencia.
insert into public.rol_permisos(rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.codigo = 'operativas.cierres.configurar'
on conflict (rol, permiso_codigo) do nothing;

create or replace function public.guardar_configuracion_operativa_v153(
  p_almacen_id uuid,
  p_hora_limite_cierre time,
  p_area_m2 numeric
) returns void
language plpgsql
security definer
set search_path = ''
as $v153$
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesion'; end if;
  -- usuario_tiene_permiso_v35 ya deja pasar a admin siempre (v35/v107): no
  -- hace falta un OR aparte para el rol admin.
  if not public.usuario_tiene_permiso_v35('operativas.cierres.configurar') then
    raise exception 'No tienes permiso para configurar este local';
  end if;
  if not exists (select 1 from public.almacenes a where a.id = p_almacen_id and a.activo) then
    raise exception 'El almacen no existe o esta inactivo';
  end if;
  if p_hora_limite_cierre is null then raise exception 'La hora limite es obligatoria'; end if;
  if p_area_m2 is not null and p_area_m2 <= 0 then
    raise exception 'El area debe ser mayor que cero';
  end if;

  insert into public.almacen_configuracion_operativa_v153(
    almacen_id, hora_limite_cierre, area_m2, actualizado_por
  ) values (
    p_almacen_id, p_hora_limite_cierre, p_area_m2, auth.uid()
  )
  on conflict (almacen_id) do update set
    hora_limite_cierre = excluded.hora_limite_cierre,
    area_m2 = excluded.area_m2,
    actualizado_por = excluded.actualizado_por,
    updated_at = now();
end;
$v153$;

alter table public.almacen_configuracion_operativa_v153 enable row level security;
drop policy if exists "leer_configuracion_operativa_v153" on public.almacen_configuracion_operativa_v153;
create policy "leer_configuracion_operativa_v153" on public.almacen_configuracion_operativa_v153
for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
  or public.usuario_tiene_permiso_v35('operativas.cierres.configurar')
);

revoke all on public.almacen_configuracion_operativa_v153 from public, anon;
revoke insert, update, delete on public.almacen_configuracion_operativa_v153 from authenticated;
grant select on public.almacen_configuracion_operativa_v153 to authenticated;

alter table public.almacen_configuracion_operativa_v153 owner to postgres;
alter function public.guardar_configuracion_operativa_v153(uuid,time,numeric) owner to postgres;
revoke all on function public.guardar_configuracion_operativa_v153(uuid,time,numeric) from public, anon;
grant execute on function public.guardar_configuracion_operativa_v153(uuid,time,numeric) to authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v153', 153, 'v153_configuracion_operativa_almacenes.sql',
  'Hora limite de cierre diario y area en m2 por almacen, para alertas de cierre y ranking de locales.'
)
on conflict (id) do update set version=excluded.version, archivo=excluded.archivo,
  notas=excluded.notas, aplicada_at=now();

notify pgrst, 'reload schema';
commit;
