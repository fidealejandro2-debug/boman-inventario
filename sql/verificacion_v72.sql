-- ============================================================
-- Verificacion v72 - Factura de tienda propia -> caja
-- Solo lectura: ejecutar despues de instalar v72.
-- ============================================================

select to_regprocedure('public.sincronizar_ingreso_caja_tienda_v72()') is not null as trigger_fn_ok;

select tgname, tgenabled from pg_trigger
where tgrelid = 'public.documentos_venta_xml'::regclass
  and tgname = 'trg_ingreso_caja_tienda_v72';

-- Facturas ya aplicadas en tiendas propias ANTES de instalar v72 no generaron
-- ingreso retroactivo (el trigger es AFTER INSERT, no corre para filas viejas).
-- Esto es informativo, no un error: sirve para saber si hace falta un backfill
-- manual puntual.
select d.id, d.numero_documento, d.almacen_id, a.nombre, d.importe_total, d.fecha_emision
from public.documentos_venta_xml d
join public.almacenes a on a.id = d.almacen_id and a.tipo = 'tienda'
where not d.anulado
  and not exists (select 1 from public.franquicias f where f.almacen_id = a.id and f.activo)
  and not exists (
    select 1 from public.franquicia_caja_movimientos m
    where m.documento_xml_id = d.id and m.estado = 'vigente'
  )
order by d.fecha_emision desc
limit 50;

-- Los ingresos que genera el trigger se datan por fecha de REGISTRO, no por
-- fecha de emision: una factura emitida hace meses debe entrar a la caja del
-- dia en que se importo, con la emision guardada en la referencia. Si aqui
-- aparece alguno cuya fecha coincide con una emision vieja, el trigger no es
-- el que lo creo.
select m.fecha as fecha_en_caja, d.fecha_emision, m.referencia,
       a.nombre as tienda, m.monto
from public.franquicia_caja_movimientos m
join public.documentos_venta_xml d on d.id = m.documento_xml_id
join public.almacenes a on a.id = m.almacen_id
where m.franquicia_id is null and m.estado = 'vigente'
order by m.created_at desc
limit 20;
