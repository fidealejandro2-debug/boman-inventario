-- ============================================================
-- Diagnostico: como valida el rol la funcion aplicar_factura_venta_xml
-- Solo lectura. Ejecutar si v44 aborta al habilitar los roles de franquicia.
-- ============================================================

-- Cuantas versiones hay instaladas y con que firma.
select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as firma
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'aplicar_factura_venta_xml'
order by p.oid desc;

-- La linea exacta donde valida el rol. Esto es lo que v44 necesita reconocer.
select linea
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace,
lateral regexp_split_to_table(pg_get_functiondef(p.oid), E'\n') as linea
where n.nspname = 'public' and p.proname = 'aplicar_factura_venta_xml'
  and linea ~ 'not\s+in\s*\(';

-- Si ya quedo habilitada, esto devuelve true.
select coalesce(bool_or(pg_get_functiondef(p.oid) like '%vendedor_franquicia%'), false)
       as franquicia_habilitada
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'aplicar_factura_venta_xml';
