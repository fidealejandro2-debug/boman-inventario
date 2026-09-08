-- Verificacion v103 - Cierre de migracion BomanSport. Solo lectura.
select to_regclass('public.bomansport_cierre_migracion_v103') is not null as configuracion_ok,
       to_regclass('public.bomansport_cierre_eventos_v103') is not null as auditoria_ok;
select to_regprocedure('public.diagnostico_cierre_bomansport_v103()') is not null as diagnostico_ok,
       to_regprocedure('public.admin_cambiar_cierre_bomansport_v103(text,jsonb,text,uuid)') is not null as cambio_ok;
select id,modo,checklist,supabase_principal_desde,cerrado_at,updated_at
from public.bomansport_cierre_migracion_v103;
select tablename,rowsecurity from pg_tables where schemaname='public'
and tablename in('bomansport_cierre_migracion_v103','bomansport_cierre_eventos_v103') order by tablename;
select has_function_privilege('authenticated','public.diagnostico_cierre_bomansport_v103()','execute') as diagnostico_authenticated_ok,
not has_function_privilege('anon','public.admin_cambiar_cierre_bomansport_v103(text,jsonb,text,uuid)','execute') as cambio_anon_debe_ser_true,
not has_table_privilege('authenticated','public.bomansport_cierre_migracion_v103','update') as update_directo_debe_ser_true;
select count(*) as configuraciones_duplicadas_debe_ser_cero from (
  select id from public.bomansport_cierre_migracion_v103 group by id having count(*)>1
) x;
select count(*) as eventos_incompletos_debe_ser_cero from public.bomansport_cierre_eventos_v103
where usuario_id is null or idempotency_key is null or length(btrim(motivo))<10 or resultado is null;
-- Ejecutar esta consulta con sesion admin para ver el diagnostico completo:
-- select public.diagnostico_cierre_bomansport_v103();
