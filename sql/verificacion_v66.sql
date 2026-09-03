-- ============================================================
-- Verificacion v66 - Alertas de precios en XML de compras
-- Solo lectura: ejecutar despues de instalar v66.
-- ============================================================

select
  to_regprocedure('public.preparar_alerta_precio_compra_xml_v66()') is not null
    as comparador_precios_ok,
  to_regprocedure('public.actualizar_precio_homologado_v66()') is not null
    as actualizador_referencia_ok,
  to_regprocedure('public.limpiar_precio_al_cambiar_homologacion_v66()') is not null
    as limpieza_cambio_producto_ok;

select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and (table_name, column_name) in (
    ('proveedor_producto_homologaciones', 'ultimo_precio_unitario'),
    ('proveedor_producto_homologaciones', 'ultimo_precio_neto'),
    ('proveedor_producto_homologaciones', 'ultimo_precio_fecha'),
    ('proveedor_producto_homologaciones', 'ultimo_precio_documento'),
    ('compras_xml_importacion_lineas', 'precio_neto'),
    ('compras_xml_importacion_lineas', 'precio_referencia_unitario'),
    ('compras_xml_importacion_lineas', 'precio_referencia_neto'),
    ('compras_xml_importacion_lineas', 'variacion_precio_pct'),
    ('compras_xml_importacion_lineas', 'alerta_precio')
  )
order by table_name, column_name;

select trigger_name, event_object_table
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name in (
    'trg_preparar_alerta_precio_compra_xml_v66',
    'trg_actualizar_precio_homologado_v66',
    'trg_limpiar_precio_homologacion_v66'
  )
order by trigger_name;

select
  not has_function_privilege(
    'authenticated', 'public.preparar_alerta_precio_compra_xml_v66()', 'execute'
  ) as comparador_directo_revocado,
  not has_function_privilege(
    'authenticated', 'public.actualizar_precio_homologado_v66()', 'execute'
  ) as actualizador_directo_revocado,
  not has_function_privilege(
    'authenticated', 'public.limpiar_precio_al_cambiar_homologacion_v66()', 'execute'
  ) as limpieza_directa_revocada;

-- Todos los siguientes resultados deben ser cero.
select count(*) as precios_netos_incorrectos_debe_ser_cero
from public.compras_xml_importacion_lineas
where precio_neto <> round(subtotal / cantidad, 4);

select count(*) as alertas_sin_referencia_debe_ser_cero
from public.compras_xml_importacion_lineas
where alerta_precio
  and precio_referencia_unitario is null
  and precio_referencia_neto is null;

select count(*) as alertas_sin_cambio_debe_ser_cero
from public.compras_xml_importacion_lineas
where alerta_precio
  and coalesce(abs(precio_unitario - precio_referencia_unitario), 0) < 0.0001
  and coalesce(abs(precio_neto - precio_referencia_neto), 0) < 0.0001;

select count(*) as referencias_negativas_debe_ser_cero
from public.proveedor_producto_homologaciones
where ultimo_precio_unitario < 0 or ultimo_precio_neto < 0;

-- Panorama informativo de variaciones pendientes de revision.
select i.establecimiento || '-' || i.punto_emision || '-' || i.secuencial as numero_documento,
       i.proveedor_razon_social,
       l.codigo_proveedor, l.descripcion,
       l.precio_referencia_neto, l.precio_neto, l.variacion_precio_pct
from public.compras_xml_importacion_lineas l
join public.compras_xml_importaciones i on i.id = l.importacion_id
where l.alerta_precio and i.estado in ('pendiente_homologacion', 'listo')
order by abs(l.variacion_precio_pct) desc nulls last, i.fecha_emision desc;
