select
 to_regclass('public.servicios_franquicia_v143') is not null as catalogo_ok,
 to_regprocedure('public.guardar_servicio_franquicia_v143(uuid,text,numeric)') is not null as crear_ok,
 to_regprocedure('public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid)') is not null as venta_mixta_ok,
 exists(select 1 from information_schema.columns where table_schema='public'and table_name='venta_franquicia_lineas'and column_name='servicio_id') as linea_servicio_ok,
 exists(select 1 from public.schema_migrations_boman where id='v143') as registrada_ok;

select count(*) as lineas_con_tipo_inconsistente_debe_ser_cero
from public.venta_franquicia_lineas
where (tipo_item='producto')<>(producto_id is not null)
   or (tipo_item='servicio')<>(servicio_id is not null);
