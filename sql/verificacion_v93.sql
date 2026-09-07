-- ============================================================
-- Verificacion v93 - Compras XML integradas con Cuentas por pagar
-- Solo lectura. Ejecutar despues de instalar v93.
-- ============================================================

select
  to_regclass('public.compras_xml_cuentas_pagar_v93') is not null as vinculos_ok,
  to_regclass('public.vista_compras_xml_cxp_v93') is not null as vista_ok,
  to_regprocedure(
    'public.procesar_compra_xml_cxp_v93(uuid,text,uuid,date,text,uuid)'
  ) is not null as procesar_integrado_ok;

select
  has_function_privilege(
    'authenticated',
    'public.procesar_compra_xml_cxp_v93(uuid,text,uuid,date,text,uuid)',
    'execute'
  ) as rpc_v93_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.procesar_compra_xml_cxp_v93(uuid,text,uuid,date,text,uuid)',
    'execute'
  ) as rpc_v93_anon_bloqueada_ok,
  not has_function_privilege(
    'authenticated',
    'public.procesar_compra_xml_v65(uuid,text,text,uuid)',
    'execute'
  ) as rpc_v65_directa_revocada_ok,
  not has_table_privilege(
    'authenticated', 'public.compras_xml_cuentas_pagar_v93', 'insert'
  ) as insercion_directa_bloqueada_ok,
  not has_table_privilege(
    'authenticated', 'public.compras_xml_cuentas_pagar_v93', 'update'
  ) as edicion_directa_bloqueada_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename = 'compras_xml_cuentas_pagar_v93';

select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_compras_xml_cxp_v93';

-- Todos los siguientes resultados deben ser cero.
select count(*) as xml_procesados_sin_cuenta_debe_ser_cero
from public.compras_xml_importaciones i
where i.estado = 'procesado'
  and not exists (
    select 1 from public.compras_xml_cuentas_pagar_v93 x
    where x.importacion_id = i.id
  );

select count(*) as vinculos_inconsistentes_debe_ser_cero
from public.compras_xml_cuentas_pagar_v93 x
join public.compras_xml_importaciones i on i.id = x.importacion_id
join public.cuentas_por_pagar c on c.id = x.cuenta_id
where i.comprobante_id <> x.comprobante_id
   or c.comprobante_id <> x.comprobante_id
   or i.grupo_id <> x.grupo_id;

select count(*) as pagadoras_de_otro_grupo_debe_ser_cero
from public.compras_xml_cuentas_pagar_v93 x
join public.empresas e on e.id = x.empresa_pagadora_id_inicial
where e.grupo_id <> x.grupo_id;

select count(*) as vencimientos_anteriores_debe_ser_cero
from public.compras_xml_cuentas_pagar_v93 x
join public.compras_xml_importaciones i on i.id = x.importacion_id
where x.fecha_vencimiento_inicial < i.fecha_emision;

select count(*) as vinculaciones_v93_sin_evento_debe_ser_cero
from public.compras_xml_cuentas_pagar_v93 x
where x.origen = 'v93' and not exists (
  select 1 from public.cuentas_por_pagar_eventos e
  where e.cuenta_id = x.cuenta_id
    and e.tipo = 'creada_desde_xml'
    and e.idempotency_key = x.idempotency_key
);

select
  count(*) as facturas_xml_vinculadas,
  count(*) filter (where origen = 'v93') as registradas_desde_v93,
  count(*) filter (where origen = 'historico') as historicas_enlazadas,
  coalesce(sum(total), 0) as total_documentado
from public.vista_compras_xml_cxp_v93;
