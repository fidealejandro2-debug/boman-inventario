-- Verificacion v155. Solo lectura; ejecutar despues de la migracion.

select to_regprocedure('public.revisar_operacion_diaria_v155()') is not null as rpc_ok;

-- Debe quedar SIN grant a authenticated/anon: solo la llama el cron con la
-- llave de servicio, nunca el navegador.
select
  not has_function_privilege('authenticated','public.revisar_operacion_diaria_v155()','execute') as bloqueada_authenticated,
  not has_function_privilege('anon','public.revisar_operacion_diaria_v155()','execute') as bloqueada_anon;

-- Ejecucion real de prueba (no requiere sesion: es security definer y no
-- valida permiso de usuario, solo la llama el service role). Revisa el
-- resultado a mano: recordatorios/cierres_pendientes/depositos_faltantes
-- segun el estado real de tus datos de prueba.
select public.revisar_operacion_diaria_v155() as resultado_prueba;
