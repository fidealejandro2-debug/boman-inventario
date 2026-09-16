-- Verificacion estructural de v160. No crea documentos ni consume secuenciales.

select
  to_regclass('public.configuracion_tributaria_empresas_v160') is not null as configuracion_ok,
  to_regclass('public.certificados_firma_v160') is not null as certificados_ok,
  to_regclass('public.series_comprobantes_v160') is not null as series_ok,
  to_regclass('public.facturas_electronicas_v160') is not null as facturas_ok,
  to_regclass('public.factura_lineas_v160') is not null as lineas_ok,
  to_regclass('public.factura_impuestos_v160') is not null as impuestos_ok,
  to_regclass('public.factura_pagos_v160') is not null as pagos_ok,
  to_regclass('public.comprobantes_retencion_v160') is not null as retenciones_ok,
  to_regclass('public.transmisiones_sri_v160') is not null as cola_ok,
  to_regclass('public.respuestas_sri_v160') is not null as respuestas_ok,
  to_regclass('public.facturacion_eventos_v160') is not null as auditoria_ok;

select codigo,modulo,nombre,activo
from public.permisos_sistema
where codigo in(
  'facturacion.preparar','facturacion.emitir','facturacion.reintentar',
  'facturacion.anular','facturacion.certificados','facturacion.retenciones_emitir'
)
order by orden;

select rol::text,permiso_codigo,permitido
from public.rol_permisos
where permiso_codigo like 'facturacion.%'
order by rol::text,permiso_codigo;

select
  to_regprocedure('public.guardar_configuracion_tributaria_v160(uuid,jsonb,uuid)') is not null as configurar_ok,
  to_regprocedure('public.registrar_certificado_firma_v160(uuid,jsonb,uuid)') is not null as certificado_ok,
  to_regprocedure('public.desactivar_certificado_firma_v160(uuid,text,uuid)') is not null as desactivar_certificado_ok,
  to_regprocedure('public.configurar_serie_comprobante_v160(uuid,smallint,text,bigint,uuid)') is not null as serie_ok,
  to_regprocedure('public.preparar_factura_electronica_v160(jsonb,jsonb,jsonb,jsonb,uuid)') is not null as preparar_factura_ok,
  to_regprocedure('public.emitir_factura_electronica_v160(uuid,uuid)') is not null as emitir_factura_ok,
  to_regprocedure('public.preparar_retencion_electronica_v160(jsonb,jsonb,uuid)') is not null as preparar_retencion_ok,
  to_regprocedure('public.emitir_retencion_electronica_v160(uuid,uuid)') is not null as emitir_retencion_ok,
  to_regprocedure('public.reintentar_transmision_sri_v160(uuid,text,uuid)') is not null as reintentar_ok,
  to_regprocedure('public.solicitar_anulacion_comprobante_v160(text,uuid,text,uuid)') is not null as anular_ok,
  to_regprocedure('public.listar_comprobantes_electronicos_v160(uuid,text,text,date,date)') is not null as listar_ok,
  to_regprocedure('public.obtener_comprobante_electronico_v160(text,uuid)') is not null as detalle_ok;

select
  public.digito_modulo11_sri_v160('150320260117900000000011001001000000001123456781') between 0 and 9 as modulo11_ok,
  length(public.clave_acceso_sri_v160(date '2026-03-15','01','1790000000001',1,'001001','000000001','12345678'))=49 as clave_49_ok;

select
  not has_table_privilege('authenticated','public.facturas_electronicas_v160','insert') as factura_insert_bloqueado,
  not has_table_privilege('authenticated','public.facturas_electronicas_v160','update') as factura_update_bloqueado,
  not has_table_privilege('authenticated','public.series_comprobantes_v160','update') as serie_update_bloqueado,
  not has_function_privilege('authenticated','public.reclamar_transmisiones_sri_v160(text,integer)','execute') as worker_restringido,
  not has_function_privilege('authenticated','public.registrar_resultado_transmision_sri_v160(uuid,text,text,jsonb,integer)','execute') as resultado_worker_restringido;

select id,version,archivo,aplicada_at
from public.schema_migrations_boman where id='v160';

-- Todos deben ser cero en operacion normal.
select
  (select count(*) from public.facturas_electronicas_v160 where clave_acceso is not null and length(clave_acceso)<>49) as claves_factura_invalidas,
  (select count(*) from public.comprobantes_retencion_v160 where clave_acceso is not null and length(clave_acceso)<>49) as claves_retencion_invalidas,
  (select count(*) from public.series_comprobantes_v160 where siguiente_secuencial<=ultimo_secuencial) as series_inconsistentes,
  (select count(*) from public.transmisiones_sri_v160 where (factura_id is null)=(retencion_id is null)) as colas_sin_documento_unico;
