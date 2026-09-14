-- ============================================================
-- Verificacion v139 - Adicionales historicos recuperados
-- Solo lectura. Ejecutar despues de v139.
-- ============================================================

select count(*) as registro_migracion_debe_ser_uno
from public.schema_migrations_boman
where id = 'v139' and archivo = 'v139_recuperar_adicionales_contratos.sql';

select count(*) as contratos_con_adicionales_recuperados
from public.contratos
where adicionales <> '{}'::jsonb;

-- Debe ser cero: contratos que siguen vacios aunque la fuente conserva un
-- objeto JSON de adicionales. Solo cuenta fuentes almacenadas ya como objeto;
-- el script principal de v139 también recupera las guardadas como texto JSON.
select count(*) as objetos_directos_pendientes_de_recuperar_debe_ser_cero
from public.contratos c
join public.bomansport_contratos b on b.numero = c.numero
where coalesce(c.adicionales, '{}'::jsonb) = '{}'::jsonb
  and jsonb_typeof(b.datos -> 'adicionales') = 'object'
  and (b.datos -> 'adicionales') <> '{}'::jsonb;
