-- ============================================================
-- Verificacion v81 - Operacion comercial de franquicia
-- Solo lectura. Ejecutar despues de instalar v81.
-- ============================================================
select
 to_regclass('public.franquicia_caja_turnos') is not null as turnos_ok,
 to_regclass('public.clientes_franquicia') is not null as clientes_ok,
 to_regclass('public.cuentas_cobrar_franquicia') is not null as cartera_ok,
 to_regclass('public.cobros_franquicia') is not null as cobros_ok,
 to_regclass('public.devoluciones_franquicia') is not null as devoluciones_ok,
 to_regclass('public.devolucion_franquicia_lineas') is not null as devolucion_lineas_ok,
 to_regclass('public.vista_turnos_caja_franquicia_v81') is not null as vista_turnos_ok;

select
 to_regprocedure('public.abrir_turno_caja_v81(text,text,numeric,uuid)') is not null as abrir_turno_ok,
 to_regprocedure('public.cerrar_turno_caja_v81(uuid,numeric,text,uuid)') is not null as cerrar_turno_ok,
 to_regprocedure('public.registrar_venta_franquicia_v81(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid)') is not null as venta_credito_ok,
 to_regprocedure('public.aplicar_factura_venta_franquicia_v81(jsonb,jsonb,jsonb,text,uuid,date)') is not null as factura_credito_ok,
 to_regprocedure('public.registrar_cobro_franquicia_v81(uuid,date,numeric,text,text,uuid)') is not null as cobrar_ok,
 to_regprocedure('public.registrar_devolucion_franquicia_v81(uuid,date,jsonb,jsonb,text,uuid)') is not null as devolver_ok;

select tablename,rowsecurity from pg_tables where schemaname='public' and tablename in
 ('franquicia_caja_turnos','clientes_franquicia','cuentas_cobrar_franquicia','cobros_franquicia','devoluciones_franquicia','devolucion_franquicia_lineas') order by tablename;

select
 not has_function_privilege('anon','public.registrar_venta_franquicia_v81(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid)','execute') as venta_anon_bloqueada_ok,
 not has_function_privilege('authenticated','public.registrar_venta_franquicia_v50(date,jsonb,jsonb,numeric,text,text,uuid)','execute') as venta_anterior_bloqueada_ok,
 not has_function_privilege('authenticated','public.aplicar_factura_venta_franquicia_v47(jsonb,jsonb,jsonb,text)','execute') as factura_anterior_bloqueada_ok,
 not has_table_privilege('authenticated','public.cuentas_cobrar_franquicia','insert') as cxc_insert_directo_bloqueado_ok;

-- Todos deben ser cero.
select count(*) as pagos_sin_referencia_debe_ser_cero from public.venta_franquicia_pagos
where medio_pago in ('transferencia','tarjeta') and btrim(coalesce(referencia,''))='';

select count(*) as caja_sin_referencia_debe_ser_cero from public.franquicia_caja_movimientos
where medio_pago in ('transferencia','tarjeta') and btrim(coalesce(referencia,''))='';

select count(*) as cajas_activas_duplicadas_debe_ser_cero from (
 select almacen_id,caja_codigo from public.franquicia_caja_turnos where estado in ('abierto','reabierto')
 group by almacen_id,caja_codigo having count(*)>1) x;

select count(*) as operadores_con_dos_turnos_debe_ser_cero from (
 select abierto_por from public.franquicia_caja_turnos where estado in ('abierto','reabierto')
 group by abierto_por having count(*)>1) x;

select count(*) as creditos_sin_cartera_debe_ser_cero
from public.venta_franquicia_pagos p left join public.cuentas_cobrar_franquicia c on c.venta_id=p.venta_id
where p.medio_pago='credito' and c.id is null;

select count(*) as creditos_xml_sin_cartera_debe_ser_cero
from public.franquicia_caja_movimientos m
left join public.cuentas_cobrar_franquicia c on c.documento_xml_id=m.documento_xml_id
where m.medio_pago='credito' and m.documento_xml_id is not null and c.id is null;

select count(*) as saldos_cartera_inconsistentes_debe_ser_cero
from public.cuentas_cobrar_franquicia c left join lateral(
 select coalesce(sum(x.monto),0) cobrado from public.cobros_franquicia x where x.cuenta_id=c.id
) x on true where (c.estado<>'anulada' and c.saldo<>c.monto_original-x.cobrado-c.monto_ajustado)
  or (c.estado in ('pagada','anulada') and c.saldo<>0);

select count(*) as cantidades_devueltas_excedidas_debe_ser_cero
from public.venta_franquicia_lineas l left join lateral(
 select coalesce(sum(dl.cantidad),0) devuelta from public.devolucion_franquicia_lineas dl where dl.venta_linea_id=l.id
) x on true where x.devuelta>l.cantidad;

select estado,count(*) turnos,coalesce(sum(diferencia),0) diferencia
from public.franquicia_caja_turnos group by estado order by estado;
select estado,count(*) cuentas,coalesce(sum(saldo),0) saldo
from public.cuentas_cobrar_franquicia group by estado order by estado;
