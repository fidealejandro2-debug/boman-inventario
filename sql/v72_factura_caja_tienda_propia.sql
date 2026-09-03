-- ============================================================
-- BOMAN INVENTARIO - v72: la factura de una tienda propia entra a su caja
--
-- Una franquicia registra el ingreso de su factura a mano, dentro de su propio
-- RPC (aplicar_factura_venta_franquicia_v47), porque necesita pedirle al
-- franquiciado el desglose por medio de pago. Una tienda propia no tiene ese
-- paso: importa su factura por la pantalla general de Ventas
-- (app/ventas/VentasXmlCliente.tsx -> aplicar_factura_venta_xml_v20), sin
-- pasar por ningun envoltorio de caja. Sin este trigger, esa venta nunca
-- aparece en su diario de caja (v71) y su cierre diario siempre daria en cero.
--
-- La reversa ya funciona sola: sincronizar_caja_factura_franquicia_v45 (v45)
-- corre para CUALQUIER documento al anularse, y revertir_caja_factura_
-- franquicia_v45 (v71) busca por documento_xml_id sin importar si es de
-- franquicia o de tienda propia.
--
-- Dos simplificaciones conscientes, ambas por lo mismo: la factura XML no
-- sabe COMO ni CUANDO se cobro.
--
--   1. Medio de pago: entra como 'otro' (igual que la franquicia ANTES de que
--      v47 le agregara el desglose). Alcanza para el total de caja, pero el
--      efectivo_esperado del cierre no arrastra automaticamente lo facturado
--      en efectivo. Si hiciera falta, se agrega con el patron de v47 (pedir
--      el desglose al aplicar la factura en VentasXmlCliente.tsx).
--
--   2. Fecha: se usa la fecha de REGISTRO, no la de emision. La fecha de
--      emision del SRI no es necesariamente el dia en que entro el dinero
--      (ventas a credito, facturas emitidas antes o despues del cobro), asi
--      que datar por emision distorsionaria el efectivo esperado de ese dia
--      y ademas impediria importar una factura vieja sin reabrir un cierre.
--      La fecha de emision queda en la referencia del movimiento.
--
-- Ejecutar despues de v71.
-- ============================================================

do $$
begin
  if to_regprocedure('public.almacen_caja_operativo_v71()') is null then
    raise exception 'Falta v71. Instalalo y validalo antes de v72';
  end if;
end $$;

create or replace function public.sincronizar_ingreso_caja_tienda_v72()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_es_tienda_propia boolean;
begin
  select a.tipo = 'tienda' and not exists (
    select 1 from public.franquicias f where f.almacen_id = a.id and f.activo
  )
  into v_es_tienda_propia
  from public.almacenes a where a.id = new.almacen_id;

  if not coalesce(v_es_tienda_propia, false) or coalesce(new.importe_total, 0) <= 0 then
    return new;
  end if;

  -- La fecha del movimiento es la de REGISTRO, no la de emision del documento:
  -- la fecha de emision del SRI no es necesariamente el dia en que el dinero
  -- entro a la gaveta (hay ventas a credito, facturas emitidas antes o despues
  -- del cobro). Datar por emision meteria efectivo en un dia en que no entro y
  -- distorsionaria el efectivo esperado de ese cierre; ademas haria imposible
  -- importar una factura vieja sin reabrir un dia ya cerrado. La fecha de
  -- emision no se pierde: queda en la referencia y en documento_xml_id.
  insert into public.franquicia_caja_movimientos (
    almacen_id, fecha, tipo, categoria, concepto, monto, medio_pago,
    referencia, documento_xml_id, idempotency_key, creado_por
  ) values (
    new.almacen_id, (now() at time zone 'America/Guayaquil')::date,
    'ingreso', 'venta',
    'Factura ' || new.numero_documento, new.importe_total, 'otro',
    'Factura ' || new.numero_documento
      || ' emitida ' || to_char(new.fecha_emision, 'DD/MM/YYYY'),
    new.id,
    -- La clave de acceso del SRI es unica por factura: si este trigger
    -- llegara a correr dos veces para el mismo documento, el segundo ingreso
    -- se descarta solo.
    md5(new.clave_acceso)::uuid, new.creado_por
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$fn$;

drop trigger if exists trg_ingreso_caja_tienda_v72 on public.documentos_venta_xml;
create trigger trg_ingreso_caja_tienda_v72
after insert on public.documentos_venta_xml
for each row execute function public.sincronizar_ingreso_caja_tienda_v72();

alter function public.sincronizar_ingreso_caja_tienda_v72() owner to postgres;

comment on function public.sincronizar_ingreso_caja_tienda_v72() is
  'Ingreso automatico a la caja de una tienda propia cuando se aplica su factura de venta. No aplica a franquicias (esas insertan su ingreso dentro de aplicar_factura_venta_franquicia_v47, con desglose de medios de pago).';

notify pgrst, 'reload schema';
