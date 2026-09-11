-- ============================================================
-- Verificacion v135 - Intentos de respaldo a Sheets
-- Solo lectura. Ejecutar despues de v135.
-- ============================================================

select
  to_regprocedure('public.registrar_intento_respaldo_v135(uuid,boolean,text)') is not null
    as registrar_intento_ok,
  not has_function_privilege(
    'authenticated', 'public.registrar_intento_respaldo_v135(uuid,boolean,text)', 'execute'
  ) as authenticated_revocado_ok,
  has_function_privilege(
    'service_role', 'public.registrar_intento_respaldo_v135(uuid,boolean,text)', 'execute'
  ) as service_role_ok,
  exists (select 1 from public.schema_migrations_boman where id = 'v135')
    as migracion_registrada_ok;

select position(
  'respaldo_sheets_intentos = coalesce(respaldo_sheets_intentos, 0) + 1'
  in pg_get_functiondef(p.oid)
) > 0 as incremento_atomico_ok
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'registrar_intento_respaldo_v135';

-- Debe ser cero.
select count(*) as respaldos_inconsistentes_debe_ser_cero
from public.contrato_ingresos_v108
where respaldo_sheets_intentos < 0
   or (respaldo_sheets_estado = 'sincronizado' and respaldado_sheets_at is null)
   or (respaldo_sheets_estado = 'error' and btrim(coalesce(respaldo_sheets_error, '')) = '');
