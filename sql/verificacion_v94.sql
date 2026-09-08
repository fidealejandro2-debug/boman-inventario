-- ============================================================
-- Verificacion v94 - Poblar contratos (v79) desde BomanSport
-- Solo lectura. Ejecutar despues de instalar v94 y de sincronizar al menos
-- una vez desde /administracion/contratos-bomansport.
-- ============================================================

-- 1. La tabla de log existe, con RLS y privilegios correctos.
select
  to_regclass('public.bomansport_produccion_importaciones') is not null as tabla_ok,
  (select rowsecurity from pg_tables where schemaname = 'public'
    and tablename = 'bomansport_produccion_importaciones') as rls_ok,
  has_table_privilege('authenticated', 'public.bomansport_produccion_importaciones', 'select') as select_ok,
  not has_table_privilege('authenticated', 'public.bomansport_produccion_importaciones', 'insert') as sin_insert_ok,
  not has_table_privilege('anon', 'public.bomansport_produccion_importaciones', 'select') as anon_bloqueado_ok;

-- 2. Ninguna corrida colgada "en_curso" por mas de una hora.
select count(*) as importaciones_colgadas_debe_ser_cero
from public.bomansport_produccion_importaciones
where estado = 'en_curso' and iniciado_en < now() - interval '1 hour';

-- 3. Conteos poblados en el esquema v79 (deben ser > 0 tras la primera
-- sincronizacion, y coherentes con el numero real de contratos/lineas).
select
  (select count(*) from public.contratos) as contratos,
  (select count(*) from public.contrato_prendas) as prendas,
  (select count(*) from public.contrato_jugadores) as jugadores,
  (select count(*) from public.contrato_archivos where tipo = 'mockup') as mockups,
  (select count(*) from public.contrato_archivos where tipo = 'logo') as logos,
  (select count(*) from public.contrato_specs) as specs,
  (select count(*) from public.contrato_facturacion) as facturacion,
  (select count(*) from public.contrato_etapas) as etapas,
  (select count(*) from public.contrato_eventos) as eventos;

-- 4. contrato_prendas sin cantidad valida (debe ser cero, ya lo exige el
-- check de v79; doble verificacion legible).
select count(*) as prendas_invalidas_debe_ser_cero
from public.contrato_prendas where cantidad <= 0;

-- 5. Todo contrato_etapas/contrato_eventos apunta a un contrato que existe
-- (deberia ser automatico por la FK on delete cascade; confirma que nada
-- quedo huerfano de una corrida parcial).
select count(*) as etapas_huerfanas_debe_ser_cero
from public.contrato_etapas ce
left join public.contratos c on c.id = ce.contrato_id
where c.id is null;

-- 6. Ultima fila de Trazabilidad ya incorporada (crece con cada corrida;
-- confirma que el alto-de-agua avanza y no se relee la hoja entera).
select origen, estado, contratos_procesados, etapas_nuevas, eventos_nuevos,
       con_error, ultima_fila_trazabilidad, iniciado_en
from public.bomansport_produccion_importaciones
order by iniciado_en desc
limit 10;

-- 7. Muestra de contratos ya migrados, con su etapa vigente y ultima etapa
-- registrada en la bitacora (deben ser coherentes).
select c.numero, c.cliente, c.estado, c.disenador, c.total_prendas,
  (select ce.etapa from public.contrato_etapas ce
    where ce.contrato_id = c.id order by ce.marcado_en desc limit 1) as ultima_etapa_bitacora
from public.contratos c
order by c.updated_at desc
limit 20;
