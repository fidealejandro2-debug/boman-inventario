-- ============================================================
-- Verificacion v47 - Control diario de franquicia
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v47 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.venta_franquicia_pagos') is not null as pagos_ok,
  to_regclass('public.franquicia_caja_cierres') is not null as cierres_ok,
  to_regclass('public.franquicia_caja_cierre_eventos') is not null as eventos_ok,
  to_regclass('public.vista_ventas_franquicia_v47') is not null as vista_ventas_ok,
  to_regclass('public.vista_resumen_caja_diaria_franquicia_v47') is not null
    as resumen_caja_ok,
  to_regclass('public.vista_alertas_franquicia_v47') is not null as alertas_ok;

select
  to_regprocedure(
    'public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid)'
  ) is not null as registrar_venta_ok,
  to_regprocedure('public.anular_venta_franquicia_v47(uuid,text,uuid)') is not null
    as anular_venta_ok,
  to_regprocedure(
    'public.aplicar_factura_venta_franquicia_v47(jsonb,jsonb,jsonb,text)'
  ) is not null as factura_xml_desglosada_ok,
  to_regprocedure(
    'public.cerrar_caja_franquicia_v47(date,numeric,numeric,text,uuid)'
  ) is not null as cerrar_caja_ok,
  to_regprocedure('public.reabrir_caja_franquicia_v47(uuid,text)') is not null
    as reabrir_caja_ok,
  to_regprocedure('public.guardar_minimos_franquicia_v47(jsonb)') is not null
    as guardar_minimos_ok,
  to_regprocedure(
    'public.crear_reposicion_sugerida_franquicia_v47(text,uuid)'
  ) is not null as reposicion_automatica_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'venta_franquicia_pagos', 'franquicia_caja_cierres',
    'franquicia_caja_cierre_eventos'
  )
order by tablename;

select c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'vista_ventas_franquicia_v47',
    'vista_resumen_caja_diaria_franquicia_v47',
    'vista_alertas_franquicia_v47'
  )
order by c.relname;

select
  has_function_privilege(
    'authenticated',
    'public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid)',
    'execute'
  ) as registrar_v47_authenticated_ok,
  not has_function_privilege(
    'authenticated',
    'public.registrar_venta_franquicia_v42(date,jsonb,text,numeric,text,text,uuid)',
    'execute'
  ) as registrar_v42_directo_bloqueado,
  not has_function_privilege(
    'authenticated',
    'public.aplicar_factura_venta_franquicia_v44(jsonb,jsonb,text)',
    'execute'
  ) as factura_v44_directa_bloqueada,
  has_function_privilege(
    'authenticated',
    'public.cerrar_caja_franquicia_v47(date,numeric,numeric,text,uuid)',
    'execute'
  ) as cerrar_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.cerrar_caja_franquicia_v47(date,numeric,numeric,text,uuid)',
    'execute'
  ) as cerrar_anon_bloqueado,
  not has_table_privilege(
    'authenticated', 'public.venta_franquicia_pagos', 'insert'
  ) as pagos_insert_directo_bloqueado,
  not has_table_privilege(
    'authenticated', 'public.franquicia_caja_cierres', 'update'
  ) as cierres_update_directo_bloqueado;

select
  position('old.franquicia_id' in pg_get_functiondef(p.oid)) > 0
    as protege_franquicia_original,
  position('old.fecha' in pg_get_functiondef(p.oid)) > 0
    as protege_fecha_original,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'bloquear_caja_cerrada_v47';

-- Todos los siguientes resultados deben ser cero.

select count(*) as ventas_registradas_con_pagos_incompletos_debe_ser_cero
from public.ventas_franquicia v
left join lateral (
  select coalesce(sum(p.monto), 0)::numeric(14,2) pagado
  from public.venta_franquicia_pagos p where p.venta_id = v.id
) x on true
where v.estado = 'registrada' and x.pagado <> v.total;

select count(*) as pagos_sin_movimiento_vigente_debe_ser_cero
from public.venta_franquicia_pagos p
join public.ventas_franquicia v on v.id = p.venta_id and v.estado = 'registrada'
where not exists (
  select 1 from public.franquicia_caja_movimientos m
  where m.venta_pago_id = p.id and m.estado = 'vigente'
    and m.reversa_de_id is null and m.tipo = 'ingreso'
    and m.monto = p.monto and m.medio_pago = p.medio_pago
);

select count(*) as movimientos_pago_duplicados_debe_ser_cero
from (
  select venta_pago_id
  from public.franquicia_caja_movimientos
  where venta_pago_id is not null
  group by venta_pago_id having count(*) > 1
) duplicados;

select count(*) as facturas_vigentes_con_pagos_incompletos_debe_ser_cero
from public.documentos_venta_xml d
join public.franquicias f on f.almacen_id = d.almacen_id
left join lateral (
  select coalesce(sum(m.monto), 0)::numeric(14,2) pagado
  from public.franquicia_caja_movimientos m
  where m.documento_xml_id = d.id and m.estado = 'vigente'
    and m.reversa_de_id is null and m.tipo = 'ingreso'
) x on true
where not d.anulado
  and d.anulacion_stock_estado not in ('reversion_tecnica', 'reversion_tecnica_legacy')
  and exists (
    select 1 from public.franquicia_caja_movimientos m
    where m.documento_xml_id = d.id
  )
  and x.pagado <> d.importe_total;

select count(*) as pagos_xml_duplicados_debe_ser_cero
from (
  select documento_xml_id, documento_pago_numero
  from public.franquicia_caja_movimientos
  where documento_xml_id is not null and documento_pago_numero is not null
  group by documento_xml_id, documento_pago_numero having count(*) > 1
) duplicados;

select count(*) as cierres_con_calculo_inconsistente_debe_ser_cero
from public.franquicia_caja_cierres
where saldo_esperado_efectivo <>
        round(saldo_inicial_efectivo + ingresos_efectivo - egresos_efectivo, 2)
   or diferencia <> round(efectivo_contado - saldo_esperado_efectivo, 2)
   or (estado = 'cerrado' and reabierto_at is not null)
   or (estado = 'reabierto' and reabierto_at is null);

select count(*) as cierres_sin_evento_debe_ser_cero
from public.franquicia_caja_cierres c
where not exists (
  select 1 from public.franquicia_caja_cierre_eventos e
  where e.cierre_id = c.id and e.tipo = c.estado
);

select count(*) as minimos_franquicia_invalidos_debe_ser_cero
from public.producto_almacen_config c
join public.franquicias f on f.almacen_id = c.almacen_id
where c.stock_minimo < 0 or c.punto_reposicion < 0
   or (c.stock_maximo is not null and c.stock_maximo < c.stock_minimo);

select count(*) as alertas_duplicadas_debe_ser_cero
from (
  select franquicia_id, documento_id, count(*) total
  from public.vista_alertas_franquicia_v47
  group by franquicia_id, documento_id having count(*) > 1
) duplicadas;

-- Panorama informativo.
select medio_pago, count(*) pagos, coalesce(sum(monto), 0) monto
from public.venta_franquicia_pagos
group by medio_pago order by medio_pago;

select estado, count(*) cierres, coalesce(sum(abs(diferencia)), 0) diferencia_absoluta
from public.franquicia_caja_cierres
group by estado order by estado;

select tipo_alerta, count(*) alertas
from public.vista_alertas_franquicia_v47
group by tipo_alerta order by tipo_alerta;
