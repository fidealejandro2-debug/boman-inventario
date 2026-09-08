-- ============================================================
-- Verificacion v101 - Costos y rentabilidad por contrato
-- Solo lectura. Ejecutar despues de instalar v101.
-- ============================================================

select
  to_regclass('public.contrato_costos_lineas_v101') is not null as lineas_ok,
  to_regclass('public.contrato_ordenes_produccion_v101') is not null as vinculos_ok,
  to_regclass('public.contrato_costos_eventos_v101') is not null as eventos_ok;

select
  to_regprocedure('public.guardar_costo_contrato_v101(uuid,uuid,text,text,text,numeric,numeric,text,uuid)') is not null as guardar_ok,
  to_regprocedure('public.anular_costo_contrato_v101(uuid,text,uuid)') is not null as anular_ok,
  to_regprocedure('public.vincular_orden_costo_v101(uuid,uuid,boolean,text,uuid)') is not null as vincular_ok,
  to_regprocedure('public.obtener_hoja_costo_v101(uuid)') is not null as hoja_ok,
  to_regprocedure('public.dashboard_rentabilidad_v101(date,date,text,text,integer,integer)') is not null as dashboard_ok;

select codigo, activo from public.permisos_sistema
where codigo in ('produccion.costos.ver','produccion.costos.editar')
order by codigo;

select tablename, rowsecurity from pg_tables
where schemaname='public' and tablename in (
  'contrato_costos_lineas_v101','contrato_ordenes_produccion_v101',
  'contrato_costos_eventos_v101'
) order by tablename;

select
  has_function_privilege('authenticated','public.obtener_hoja_costo_v101(uuid)','execute') as hoja_authenticated_ok,
  has_function_privilege('authenticated','public.dashboard_rentabilidad_v101(date,date,text,text,integer,integer)','execute') as dashboard_authenticated_ok,
  not has_function_privilege('anon','public.guardar_costo_contrato_v101(uuid,uuid,text,text,text,numeric,numeric,text,uuid)','execute') as guardar_anon_debe_ser_true,
  not has_table_privilege('authenticated','public.contrato_costos_lineas_v101','insert') as insert_directo_debe_ser_true,
  not has_table_privilege('authenticated','public.contrato_costos_lineas_v101','update') as update_directo_debe_ser_true;

-- Todos los siguientes resultados deben ser cero.
select count(*) as lineas_con_total_incorrecto_debe_ser_cero
from public.contrato_costos_lineas_v101
where total <> round(cantidad*costo_unitario,2);

select count(*) as ordenes_vinculadas_mas_de_una_vez_debe_ser_cero
from (select orden_id from public.contrato_ordenes_produccion_v101 group by orden_id having count(*)>1)x;

select count(*) as eventos_incompletos_debe_ser_cero
from public.contrato_costos_eventos_v101
where usuario_id is null or idempotency_key is null
   or length(btrim(motivo))<10 or resultado is null;

select count(*) as ediciones_sin_evento_debe_ser_cero
from public.contrato_costos_lineas_v101 l
where not exists (
  select 1 from public.contrato_costos_eventos_v101 e where e.linea_id=l.id
);

-- Panorama informativo: no debe fallar aunque aun no existan costos.
select
  count(*) filter(where activo) as lineas_activas,
  coalesce(sum(total) filter(where activo and naturaleza='estimado'),0) as manual_estimado,
  coalesce(sum(total) filter(where activo and naturaleza='real'),0) as manual_real
from public.contrato_costos_lineas_v101;

select count(*) as ordenes_vinculadas,
       coalesce(sum(o.costo_total_estimado),0) as costo_ordenes_estimado,
       coalesce(sum(o.costo_total_real),0) as costo_ordenes_real
from public.contrato_ordenes_produccion_v101 co
join public.ordenes_produccion o on o.id=co.orden_id;
