-- ============================================================
-- BOMAN INVENTARIO - v42 PASO 1: roles de franquicia
--
-- EJECUTAR ESTE ARCHIVO SOLO, Y CONFIRMAR, ANTES DE v42.
--
-- PostgreSQL no permite usar un valor de enum en la misma transaccion en que
-- se agrega: falla con "unsafe use of new value ... of enum type". Por eso
-- los dos roles nuevos van en su propia ejecucion, separados del resto de
-- v42, que si los usa. Es el mismo caso que ya ocurrio con tipo_movimiento
-- en v21 y con el rol nomina en v26.
--
-- Despues de correr esto, ejecutar sql/v42_operacion_franquicias.sql.
-- ============================================================

alter type public.rol_usuario add value if not exists 'franquiciado';
alter type public.rol_usuario add value if not exists 'vendedor_franquicia';
