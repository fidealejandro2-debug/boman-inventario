-- ============================================================
-- Verificacion v131 - Cola de sincronizacion BomanSport
-- Solo lectura. Ejecutar despues de v131.
-- ============================================================

select
  to_regclass('public.bomansport_sincronizaciones') is not null as cola_ok,
  to_regprocedure('public.reclamar_sincronizaciones_bomansport_v131(integer)') is not null
    as reclamar_ok,
  to_regprocedure('public.resolver_sincronizacion_bomansport_v131(uuid,boolean,text)') is not null
    as resolver_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'bomansport_sincronizaciones';

select
  not has_table_privilege('authenticated', 'public.bomansport_sincronizaciones', 'select')
    as lectura_authenticated_revocada_ok,
  not has_table_privilege('authenticated', 'public.bomansport_sincronizaciones', 'insert')
    as escritura_authenticated_revocada_ok,
  not has_function_privilege(
    'authenticated', 'public.reclamar_sincronizaciones_bomansport_v131(integer)', 'execute'
  ) as reclamar_authenticated_revocado_ok;

-- Todos deben ser cero.
select count(*) as filas_invalidas_debe_ser_cero
from public.bomansport_sincronizaciones
where intentos < 0
   or payload is null
   or idempotency_key is null
   or (estado = 'sincronizado' and sincronizado_at is null)
   or (estado in ('pendiente', 'intervencion') and ultimo_error is null and intentos > 0);

select estado, count(*) as total, min(proximo_intento_at) as siguiente
from public.bomansport_sincronizaciones
group by estado
order by estado;
