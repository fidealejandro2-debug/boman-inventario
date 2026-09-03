-- ============================================================
-- Verificacion v58 - Comprobantes de compra y retenciones
-- Solo lectura: ejecutar despues de instalar v58.
-- ============================================================

-- 1. Tablas y funciones instaladas.
select
  to_regclass('public.comprobantes_compra') is not null as comprobantes_ok,
  to_regclass('public.comprobante_compra_lineas') is not null as lineas_ok,
  to_regclass('public.retenciones_compra') is not null as retenciones_ok,
  to_regclass('public.retencion_conceptos') is not null as catalogo_ok,
  to_regprocedure('public.registrar_comprobante_compra_v58(jsonb,jsonb,jsonb,uuid)') is not null as registrar_ok,
  to_regprocedure('public.anular_comprobante_compra_v58(uuid,text)') is not null as anular_ok;

-- 2. Toda escritura pasa por las RPC: la tabla esta cerrada.
select
  not has_table_privilege('authenticated','public.comprobantes_compra','insert') as insert_bloqueado,
  not has_table_privilege('authenticated','public.comprobantes_compra','update') as update_bloqueado,
  not has_table_privilege('authenticated','public.retenciones_compra','insert') as retencion_insert_bloqueado,
  not has_table_privilege('anon','public.comprobantes_compra','select') as anon_bloqueado,
  has_table_privilege('authenticated','public.comprobantes_compra','select') as lectura_ok;

-- 3. Las vistas respetan el RLS de las tablas base.
select
  (select c.reloptions::text like '%security_invoker=true%'
   from pg_class c where c.oid = 'public.vista_libro_compras_v58'::regclass) as libro_invoker_ok,
  (select c.reloptions::text like '%security_invoker=true%'
   from pg_class c where c.oid = 'public.vista_resumen_compras_mes_v58'::regclass) as resumen_invoker_ok;

-- 4. Definer con search_path fijo.
select p.proname, p.prosecdef as security_definer, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('registrar_comprobante_compra_v58', 'anular_comprobante_compra_v58')
order by p.proname;

-- 5. CRITICO. Todos deben ser cero.
-- El total tiene que ser la suma de su desglose: si no, el libro de compras
-- nace descuadrado y se descubre recien en la declaracion.
select count(*) as comprobantes_descuadrados_debe_ser_cero
from public.comprobantes_compra
where round(total, 2) <> round(
  base_cero + base_gravada + base_no_objeto + base_exenta
  + monto_iva + monto_ice + propina, 2);

-- Cada retencion tiene que ser su base por su porcentaje.
select count(*) as retenciones_mal_calculadas_debe_ser_cero
from public.retenciones_compra
where round(valor, 2) <> round(base_imponible * porcentaje / 100, 2);

-- La retencion no puede superar el impuesto ni la base del comprobante.
select count(*) as retenciones_imposibles_debe_ser_cero
from public.retenciones_compra r
join public.retencion_conceptos rc on rc.codigo = r.concepto_codigo
join public.comprobantes_compra c on c.id = r.comprobante_id
where (rc.clase = 'iva' and r.valor > c.monto_iva + 0.01)
   or (rc.clase = 'renta' and r.base_imponible > c.total + 0.01);

-- Las lineas deben sumar las bases declaradas.
select count(*) as lineas_que_no_cuadran_debe_ser_cero
from public.comprobantes_compra c
join lateral (
  select round(coalesce(sum(subtotal), 0), 2) as suma
  from public.comprobante_compra_lineas where comprobante_id = c.id
) l on true
where l.suma <> round(c.base_cero + c.base_gravada + c.base_no_objeto + c.base_exenta, 2);

-- 6. Informativo: catalogo de retenciones vigente en el sistema.
-- VERIFICAR contra la resolucion del SRI: los porcentajes se siembran con los
-- habituales, pero los cambia el SRI y aqui se editan sin migracion.
select codigo, clase, nombre, porcentaje, activo
from public.retencion_conceptos order by clase, codigo;

-- 7. Informativo: libro de compras de los ultimos meses.
select empresa, anio, numero_mes, comprobantes, base_gravada, iva_credito,
       retencion_iva, retencion_renta, total_compras
from public.vista_resumen_compras_mes_v58
order by empresa, mes desc
limit 24;
