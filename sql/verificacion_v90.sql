-- ============================================================
-- Verificacion v90 - Importacion de contratos BomanSport
-- Solo lectura. Ejecutar despues de instalar v90.
-- ============================================================

-- 1. Las 3 tablas existen.
select
  to_regclass('public.bomansport_contratos') is not null as tabla_contratos_ok,
  to_regclass('public.bomansport_importaciones') is not null as tabla_importaciones_ok,
  to_regclass('public.bomansport_contratos_historial') is not null as tabla_historial_ok;

-- 2. RLS habilitado en las 3.
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('bomansport_contratos', 'bomansport_importaciones', 'bomansport_contratos_historial');

-- 3. Privilegios: authenticated solo lee, anon no tiene nada.
select
  has_table_privilege('authenticated', 'public.bomansport_contratos', 'select') as contratos_select_ok,
  not has_table_privilege('authenticated', 'public.bomansport_contratos', 'insert') as contratos_sin_insert_ok,
  not has_table_privilege('authenticated', 'public.bomansport_contratos', 'update') as contratos_sin_update_ok,
  not has_table_privilege('anon', 'public.bomansport_contratos', 'select') as contratos_anon_bloqueado_ok,
  has_table_privilege('authenticated', 'public.bomansport_importaciones', 'select') as importaciones_select_ok,
  not has_table_privilege('anon', 'public.bomansport_importaciones', 'select') as importaciones_anon_bloqueado_ok,
  has_table_privilege('authenticated', 'public.bomansport_contratos_historial', 'select') as historial_select_ok,
  not has_table_privilege('anon', 'public.bomansport_contratos_historial', 'select') as historial_anon_bloqueado_ok;

-- 4. La FK de ultima_importacion_id existe.
select count(*) as fk_ultima_importacion_ok
from information_schema.table_constraints
where constraint_name = 'bomansport_contratos_ultima_importacion_fkey'
  and table_name = 'bomansport_contratos';

-- 5. Sin duplicados por numero (debe ser cero; ademas numero ya es unique,
-- esto es una doble verificacion legible).
select count(*) as numeros_duplicados_debe_ser_cero
from (
  select numero from public.bomansport_contratos
  group by numero having count(*) > 1
) dup;

-- 6. Ninguna importacion queda "en_curso" colgada por mas de una hora
-- (indicaria una corrida que fallo sin cerrar su propio log).
select count(*) as importaciones_colgadas_debe_ser_cero
from public.bomansport_importaciones
where estado = 'en_curso' and iniciado_en < now() - interval '1 hour';

-- 7. Resumen (vacio hasta la primera sincronizacion, es normal).
select numero, cliente, estado, total_prendas, ultima_sincronizacion_en, ultimo_cambio_en
from public.bomansport_contratos
order by ultima_sincronizacion_en desc
limit 20;

select origen, estado, total_filas_origen, creados, actualizados, sin_cambio, con_error, iniciado_en
from public.bomansport_importaciones
order by iniciado_en desc
limit 10;
