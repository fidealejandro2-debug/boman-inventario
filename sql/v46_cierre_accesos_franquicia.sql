-- ============================================================
-- BOMAN INVENTARIO - v46: cierre de accesos de franquicia
--
-- La v44 habilito los roles de franquicia dentro del motor XML historico para
-- que el envoltorio del local pudiera reutilizarlo. Como esas RPC historicas
-- conservaban EXECUTE para authenticated, el local tambien podia llamarlas de
-- forma directa: el stock salia, pero no se generaba el ingreso en su caja.
--
-- v46 deja los motores historicos como funciones internas y publica dos
-- puertas separadas:
--   - operacion general: roles internos con permiso de Ventas XML;
--   - franquicia: aplicar_factura_venta_franquicia_v44, que siempre crea caja.
--
-- Tambien enlaza de forma deterministica los ingresos que pudieran haberse
-- creado entre la instalacion de v44 y v45.
-- Ejecutar despues de v45.
-- ============================================================

-- 1. Puerta para la operacion interna -------------------------------------
create or replace function public.aplicar_factura_venta_xml_operativa_v46(
  p_documento jsonb,
  p_almacen_id uuid,
  p_asignaciones jsonb,
  p_nota text default null,
  p_confirmar_codigo_no_estandar boolean default false,
  p_codigo_nota text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_rol text := public.rol_usuario_actual();
begin
  if v_rol not in ('admin', 'control', 'tienda', 'bodega')
     or not public.usuario_tiene_permiso_v35('ventas.acceder') then
    raise exception 'No tienes permiso para importar ventas XML';
  end if;

  return public.aplicar_factura_venta_xml_v20(
    p_documento, p_almacen_id, p_asignaciones, p_nota,
    p_confirmar_codigo_no_estandar, p_codigo_nota
  );
end;
$fn$;

alter function public.aplicar_factura_venta_xml_operativa_v46(
  jsonb, uuid, jsonb, text, boolean, text
) owner to postgres;

-- Los tres niveles historicos solo se invocan desde funciones SECURITY
-- DEFINER controladas. Revocar authenticated es lo que cierra el bypass; no
-- basta con ocultar el boton en React.
revoke execute on function public.aplicar_factura_venta_xml(
  jsonb, uuid, jsonb, text
) from public, anon, authenticated;
revoke execute on function public.aplicar_factura_venta_xml_v19(
  jsonb, uuid, jsonb, text, boolean, text
) from public, anon, authenticated;
revoke execute on function public.aplicar_factura_venta_xml_v20(
  jsonb, uuid, jsonb, text, boolean, text
) from public, anon, authenticated;

revoke execute on function public.aplicar_factura_venta_xml_operativa_v46(
  jsonb, uuid, jsonb, text, boolean, text
) from public, anon;
grant execute on function public.aplicar_factura_venta_xml_operativa_v46(
  jsonb, uuid, jsonb, text, boolean, text
) to authenticated;

-- La puerta de franquicia sigue disponible. Internamente se ejecuta como
-- postgres y por eso puede llamar v20 aunque authenticated ya no pueda.
revoke execute on function public.aplicar_factura_venta_franquicia_v44(
  jsonb, jsonb, text
) from public, anon;
grant execute on function public.aplicar_factura_venta_franquicia_v44(
  jsonb, jsonb, text
) to authenticated;

-- 2. Enlace retroactivo v44 -> v45 ---------------------------------------
-- La idempotencia de v44 se derivo de la clave SRI, de modo que esta union es
-- exacta incluso si dos emisores usan la misma numeracion visible.
update public.franquicia_caja_movimientos m
set documento_xml_id = d.id
from public.documentos_venta_xml d
join public.franquicias f on f.almacen_id = d.almacen_id
where m.franquicia_id = f.id
  and m.documento_xml_id is null
  and m.venta_id is null
  and m.categoria = 'venta'
  and m.idempotency_key = md5(d.clave_acceso)::uuid;

-- Si una factura se anulo antes de que existiera el vinculo de v45, el
-- trigger no pudo verla. Se compensa ahora; la funcion retorna sin hacer nada
-- cuando el movimiento ya estaba revertido.
do $migra$
declare it record;
begin
  for it in
    select d.id,
           case
             when d.anulado then 'Factura anulada antes de instalar v46'
             else 'Importacion revertida antes de instalar v46'
           end as motivo
    from public.documentos_venta_xml d
    join public.franquicia_caja_movimientos m on m.documento_xml_id = d.id
    where (d.anulado or d.anulacion_stock_estado = 'reversion_tecnica')
      and m.estado = 'vigente'
  loop
    perform public.revertir_caja_factura_franquicia_v45(it.id, it.motivo);
  end loop;
end;
$migra$;

notify pgrst, 'reload schema';
