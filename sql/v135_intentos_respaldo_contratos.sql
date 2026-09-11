-- ============================================================
-- v135 - Contador atomico de intentos de respaldo a Sheets
-- Ejecutar despues de v134 y antes de verificacion_v135.sql.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v135', 0));

do $v135$
begin
  if to_regclass('public.contrato_ingresos_v108') is null then
    raise exception 'Falta v108: no existe contrato_ingresos_v108';
  end if;
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta v134: no existe el registro formal de migraciones';
  end if;
end;
$v135$;

create or replace function public.registrar_intento_respaldo_v135(
  p_ingreso_id uuid,
  p_exitoso boolean,
  p_error text default null
)
returns integer
language plpgsql security definer set search_path = '' as $v135$
declare
  v_intentos integer;
begin
  update public.contrato_ingresos_v108
     set respaldo_sheets_estado = case when coalesce(p_exitoso, false) then 'sincronizado' else 'error' end,
         respaldo_sheets_intentos = coalesce(respaldo_sheets_intentos, 0) + 1,
         respaldo_sheets_error = case
           when coalesce(p_exitoso, false) then null
           else left(coalesce(nullif(btrim(p_error), ''), 'Error de respaldo no especificado'), 2000)
         end,
         respaldado_sheets_at = case when coalesce(p_exitoso, false) then now() else respaldado_sheets_at end
   where id = p_ingreso_id
  returning respaldo_sheets_intentos into v_intentos;

  if v_intentos is null then raise exception 'No existe el ingreso de contrato'; end if;
  return v_intentos;
end;
$v135$;

revoke all on function public.registrar_intento_respaldo_v135(uuid,boolean,text)
  from public, anon, authenticated;
grant execute on function public.registrar_intento_respaldo_v135(uuid,boolean,text)
  to service_role;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values ('v135', 135, 'v135_intentos_respaldo_contratos.sql',
        'Incrementa de forma atomica cada intento real de respaldo a Sheets.')
on conflict (id) do nothing;

commit;
