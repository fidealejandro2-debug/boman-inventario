-- ============================================================
-- Verificacion v45 - Caja de la factura XML de franquicia
-- Solo lectura: ejecutar despues de instalar v45.
-- ============================================================

-- 1. Vinculo del movimiento con el documento, unico por factura.
select
  (select count(*) = 1 from pg_attribute
   where attrelid = 'public.franquicia_caja_movimientos'::regclass
     and attname = 'documento_xml_id' and not attisdropped) as columna_ok,
  to_regclass('public.uq_caja_franquicia_documento_xml') is not null as unicidad_ok;

-- 2. Funcion de reversa y trigger que la dispara.
select
  to_regprocedure('public.revertir_caja_factura_franquicia_v45(uuid,text)') is not null as reversa_ok,
  to_regprocedure('public.sincronizar_caja_factura_franquicia_v45()') is not null as sincronizador_ok,
  (select count(*) = 1 from pg_trigger
   where tgrelid = 'public.documentos_venta_xml'::regclass
     and tgname = 'trg_sincronizar_caja_factura_franquicia'
     and not tgisinternal) as trigger_ok;

-- 3. La reversa no se puede llamar desde el navegador: solo la usa el trigger.
select
  not has_function_privilege('authenticated','public.revertir_caja_factura_franquicia_v45(uuid,text)','execute')
    as reversa_cerrada_a_usuarios,
  has_function_privilege('authenticated','public.aplicar_factura_venta_franquicia_v44(jsonb,jsonb,text)','execute')
    as envoltorio_disponible;

-- 4. El envoltorio ya guarda el vinculo (version de v45, no la de v44).
select pg_get_functiondef(p.oid) like '%documento_xml_id%' as envoltorio_actualizado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'aplicar_factura_venta_franquicia_v44';

-- 5. CRITICO. Todos deben ser cero.
-- Ninguna factura anulada puede conservar su ingreso sumando en caja.
select count(*) as facturas_anuladas_con_caja_vigente_debe_ser_cero
from public.documentos_venta_xml d
join public.franquicia_caja_movimientos m on m.documento_xml_id = d.id
where (d.anulado or d.anulacion_stock_estado = 'reversion_tecnica')
  and m.estado = 'vigente';

-- Ni un movimiento de factura sin su documento correspondiente.
select count(*) as movimientos_de_factura_huerfanos_debe_ser_cero
from public.franquicia_caja_movimientos m
where m.documento_xml_id is not null
  and not exists (select 1 from public.documentos_venta_xml d where d.id = m.documento_xml_id);

-- 6. Informativo: facturas del local con su efecto en caja.
select d.numero_documento, d.fecha_emision, d.importe_total,
       d.anulado, m.estado as estado_caja, m.monto
from public.documentos_venta_xml d
left join public.franquicia_caja_movimientos m on m.documento_xml_id = d.id
where m.id is not null
order by d.fecha_emision desc
limit 50;
