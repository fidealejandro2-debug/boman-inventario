-- BOMAN INVENTARIO - v152 paso 1
-- PostgreSQL exige confirmar el nuevo valor del enum antes de usarlo.
-- Ejecutar este archivo y luego v152_paso2_panel_supervision.sql.

alter type public.rol_usuario add value if not exists 'supervisor';

notify pgrst,'reload schema';
