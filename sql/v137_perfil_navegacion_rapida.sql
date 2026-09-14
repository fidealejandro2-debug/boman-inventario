-- ============================================================
-- v137 - Perfil de navegacion en una sola consulta
-- Reduce los viajes de red necesarios para abrir cada menu.
-- Ejecutar despues de v136.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v137', 0));

do $v137$
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta v134: no existe el registro formal de migraciones';
  end if;
  if to_regprocedure('public.permisos_usuario_actual_v35()') is null
     or to_regprocedure('public.modo_boman_especifico_activo()') is null
     or to_regprocedure('public.estaciones_usuario_actual_v117()') is null then
    raise exception 'Faltan dependencias del perfil de navegacion';
  end if;
  if not exists (
    select 1 from pg_attribute
     where attrelid = 'public.perfiles'::regclass
       and attname = 'clave_temporal_desde' and not attisdropped
  ) then
    raise exception 'Falta v44: perfiles.clave_temporal_desde no existe';
  end if;
end;
$v137$;

create or replace function public.perfil_navegacion_v137()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $v137$
  select jsonb_build_object(
    'id', p.id,
    'nombre_completo', p.nombre_completo,
    'rol', p.rol::text,
    'entidad_id', p.entidad_id,
    'activo', p.activo,
    'clave_temporal_desde', p.clave_temporal_desde,
    'permisos', public.permisos_usuario_actual_v35(),
    'modo_boman_especifico', public.modo_boman_especifico_activo(),
    'estaciones', public.estaciones_usuario_actual_v117()
  )
  from public.perfiles p
  where p.id = auth.uid();
$v137$;

alter function public.perfil_navegacion_v137() owner to postgres;
revoke all on function public.perfil_navegacion_v137()
  from public, anon, authenticated;
grant execute on function public.perfil_navegacion_v137() to authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v137', 137, 'v137_perfil_navegacion_rapida.sql',
  'Consolida perfil, permisos, modo y estaciones en una sola llamada para acelerar la navegacion.'
)
on conflict (id) do nothing;

notify pgrst, 'reload schema';
commit;
