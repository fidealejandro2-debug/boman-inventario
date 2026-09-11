-- ============================================================
-- BOMAN INVENTARIO - v130 / PASO 1
-- Nuevo rol operativo de Produccion.
--
-- IMPORTANTE: ejecuta este archivo solo y espera a que termine. Despues
-- ejecuta v130_paso2_rol_produccion.sql como una consulta nueva. PostgreSQL
-- no permite usar un valor de enum dentro de la transaccion que lo agrega.
-- ============================================================

alter type public.rol_usuario add value if not exists 'produccion';

