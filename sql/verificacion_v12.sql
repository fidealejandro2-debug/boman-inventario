-- ============================================================
-- BOMAN INVENTARIO - Verificación posterior a v12 (solo lectura)
-- No modifica datos. Ejecutar después de v12 en Supabase SQL Editor.
-- Cada consulta debe devolver el resultado indicado en el comentario.
-- ============================================================

-- 1. Deben aparecer los seis roles, incluidos tienda y control.
select unnest(enum_range(null::public.rol_usuario))::text as rol order by 1;

-- 2. Los cinco objetos principales deben existir.
select to_regclass(objeto) as objeto_instalado
from unnest(array[
  'public.perfil_almacenes',
  'public.producto_almacen_config',
  'public.documentos_inventario',
  'public.documento_inventario_lineas',
  'public.productos_maestro_cambios'
]) objeto;

-- 3. Debe devolver cero: toda combinación activa producto/almacén tiene configuración.
select count(*) as configuraciones_faltantes
from public.productos p
cross join public.almacenes a
left join public.producto_almacen_config c
  on c.producto_id = p.id and c.almacen_id = a.id
where p.activo and a.activo and c.producto_id is null;

-- 4. Debe devolver cero antes de habilitar usuarios operativos.
select p.id, p.nombre_completo, p.rol
from public.perfiles p
where p.activo
  and p.rol::text in ('bodega', 'logistica', 'tienda')
  and not exists (
    select 1 from public.perfil_almacenes pa where pa.perfil_id = p.id
  );

-- 5. Debe devolver cero: no puede haber inventario negativo.
select count(*) as existencias_negativas
from public.inventario where cantidad < 0;

-- 6. Debe devolver cero: un documento no puede repetir el mismo SKU.
select documento_id, producto_id, count(*)
from public.documento_inventario_lineas
group by documento_id, producto_id
having count(*) > 1;

-- 7. Resumen operativo inicial. Después del despliegue permite ver pendientes.
select tipo, estado, count(*) as documentos
from public.documentos_inventario
group by tipo, estado
order by tipo, estado;

-- 8. La vista debe responder y mostrar las cuatro cantidades separadas.
select almacen, sku, stock_fisico, stock_reservado, stock_disponible,
       transito_entrada, transito_salida, sugerido_reponer
from public.vista_stock_operativo
order by almacen, sku
limit 20;

-- PRUEBA DE ACEPTACIÓN EN LA APP (usar tres usuarios distintos)
-- A. TIENDA: crear una solicitud de reposición con dos SKU.
-- B. BODEGA: aprobarla, confirmar picking e indicar despacho.
-- C. Verificar que origen bajó y destino sigue igual; destino muestra "en tránsito".
-- D. TIENDA: recibir un SKU completo y el segundo con una unidad faltante.
-- E. Verificar que destino subió solo lo recibido y Control muestra la incidencia.
-- F. TIENDA/BODEGA: abrir y completar un conteo ciego con una diferencia.
-- G. CONTROL (persona distinta): registrar segundo conteo, aprobar y comprobar el ajuste en kardex.
-- H. CONTROL: cerrar la incidencia de transferencia con número de acta/motivo.
-- I. ADMIN: modificar precio o categoría de un producto y comprobarlo en
--    Centro de Control -> Cambios recientes del catálogo.
