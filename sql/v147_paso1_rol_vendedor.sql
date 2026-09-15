-- BOMAN INVENTARIO - v147 paso 1
-- PostgreSQL no permite usar un valor nuevo de enum dentro de la misma
-- transaccion que lo crea. Ejecutar este archivo y luego el paso 2.

alter type public.rol_usuario add value if not exists 'vendedor';

notify pgrst,'reload schema';
