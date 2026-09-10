-- ============================================================
-- Verificacion v115 - Consolidado comercial
-- Solo lectura. Ejecutar despues de instalar v115.
-- ============================================================

select
 to_regclass('public.comisiones_vendedores_v115')is not null as comisiones_ok,
 to_regclass('public.comisiones_eventos_v115')is not null as auditoria_ok;

select column_name,is_nullable
from information_schema.columns
where table_schema='public'and table_name='contratos'
 and column_name in(
  'nombre_contrato_v115','cliente_confirmado_v115','almacen_venta_id_v115'
 )
order by column_name;

select
 to_regprocedure('public.catalogo_ingreso_contrato_v115()')is not null
  as catalogo_ingreso_ok,
 to_regprocedure('public.crear_contrato_v115(jsonb,uuid)')is not null
  as ingreso_ok,
 to_regprocedure('public.consolidado_comercial_v115(date,date,text[],uuid[],text[])')is not null
  as consolidado_ok,
 to_regprocedure('public.guardar_comision_vendedor_v115(text,numeric,text,date,date,text,text,uuid)')is not null
  as comisiones_rpc_ok;

select
 has_function_privilege(
  'authenticated','public.crear_contrato_v115(jsonb,uuid)','execute'
 )as ingreso_v115_ok,
 not has_function_privilege(
  'authenticated','public.crear_contrato_v108(jsonb,uuid)','execute'
 )as ingreso_v108_revocado_ok,
 has_function_privilege(
  'authenticated',
  'public.consolidado_comercial_v115(date,date,text[],uuid[],text[])','execute'
 )as consolidado_authenticated_ok,
 not has_function_privilege(
  'anon','public.consolidado_comercial_v115(date,date,text[],uuid[],text[])',
  'execute'
 )as anon_bloqueado_ok;

select tablename,rowsecurity
from pg_tables
where schemaname='public'
 and tablename in('comisiones_vendedores_v115','comisiones_eventos_v115')
order by tablename;

-- Todos los siguientes resultados deben ser cero.
select count(*)as contratos_sin_nombre_debe_ser_cero
from public.contratos
where nullif(btrim(nombre_contrato_v115),'')is null;

select count(*)as tiendas_invalidas_debe_ser_cero
from public.contratos c
left join public.almacenes a on a.id=c.almacen_venta_id_v115
where c.almacen_venta_id_v115 is not null and a.id is null;

select count(*)as reglas_comision_invalidas_debe_ser_cero
from public.comisiones_vendedores_v115
where porcentaje<0 or porcentaje>100
 or base not in('facturado','cobrado')
 or vigente_hasta<vigente_desde;

select count(*)as eventos_comision_incompletos_debe_ser_cero
from public.comisiones_eventos_v115
where usuario_id is null or idempotency_key is null
 or length(btrim(motivo))<10;

-- Informativo: son contratos importados del Sheets histórico. Allí solo
-- existía el nombre del contrato, así que el cliente real debe confirmarse.
select count(*)as clientes_historicos_por_confirmar
from public.contratos
where not cliente_confirmado_v115;

select vendedor,porcentaje,base,vigente_desde,vigente_hasta
from public.comisiones_vendedores_v115
where activo
order by vendedor,vigente_desde desc;
