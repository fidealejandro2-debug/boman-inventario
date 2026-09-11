-- ============================================================
-- Verificacion v136 - Registro inequívoco de las dos v134
-- Solo lectura. Ejecutar despues de v136.
-- ============================================================

select
  to_regclass('public.schema_migrations_boman') is not null as libro_ok,
  to_regprocedure('public.cronograma_produccion_v96(date,date)') is not null
    as cronograma_ok,
  to_regprocedure('public.registrar_intento_respaldo_v135(uuid,boolean,text)') is not null
    as respaldo_ok;

select id, version, archivo, aplicada_at
from public.schema_migrations_boman
where id in ('v134_registro', 'v134_cronograma', 'v135', 'v136')
order by version, id;

-- Todos deben ser cero.
select count(*) as ids_v134_ambiguos_debe_ser_cero
from public.schema_migrations_boman
where id = 'v134';

select 4 - count(*) as registros_faltantes_debe_ser_cero
from public.schema_migrations_boman
where id in ('v134_registro', 'v134_cronograma', 'v135', 'v136');

select count(*) as archivos_duplicados_debe_ser_cero
from (
  select archivo
  from public.schema_migrations_boman
  where not es_baseline
  group by archivo
  having count(*) > 1
) duplicados;
