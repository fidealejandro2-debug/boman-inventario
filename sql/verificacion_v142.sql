select
  to_regprocedure('public.configurar_beneficios_empleado_v142(uuid,boolean,boolean,date,date,boolean,text,uuid)') is not null as rpc_ok,
  to_regprocedure('public.aplicar_inicio_decimos_rol_v142()') is not null as snapshot_ok,
  exists(select 1 from information_schema.columns where table_schema='public' and table_name='empleado_compensacion' and column_name='inicio_mensualiza_decimo_tercero') as inicio_d13_ok,
  exists(select 1 from information_schema.columns where table_schema='public' and table_name='empleado_compensacion' and column_name='inicio_mensualiza_decimo_cuarto') as inicio_d14_ok,
  exists(select 1 from public.schema_migrations_boman where id='v142') as registrada_ok;

select count(*) as preferencias_activas_sin_inicio_debe_ser_cero
from public.empleado_compensacion
where (mensualiza_decimo_tercero and inicio_mensualiza_decimo_tercero is null)
   or (mensualiza_decimo_cuarto and inicio_mensualiza_decimo_cuarto is null);
