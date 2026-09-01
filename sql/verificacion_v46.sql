-- ============================================================
-- Verificacion v46 - Cierre de accesos de franquicia
-- Solo lectura: ejecutar despues de instalar v46.
-- ============================================================

-- 1. La nueva puerta existe y solo authenticated puede ejecutarla.
select
  to_regprocedure(
    'public.aplicar_factura_venta_xml_operativa_v46(jsonb,uuid,jsonb,text,boolean,text)'
  ) is not null as puerta_operativa_ok,
  has_function_privilege(
    'authenticated',
    'public.aplicar_factura_venta_xml_operativa_v46(jsonb,uuid,jsonb,text,boolean,text)',
    'execute'
  ) as operativa_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.aplicar_factura_venta_xml_operativa_v46(jsonb,uuid,jsonb,text,boolean,text)',
    'execute'
  ) as operativa_anon_bloqueada;

-- 2. CRITICO: authenticated ya no puede saltarse las puertas controladas.
select
  not has_function_privilege(
    'authenticated',
    'public.aplicar_factura_venta_xml(jsonb,uuid,jsonb,text)', 'execute'
  ) as motor_v13_directo_bloqueado,
  not has_function_privilege(
    'authenticated',
    'public.aplicar_factura_venta_xml_v19(jsonb,uuid,jsonb,text,boolean,text)',
    'execute'
  ) as motor_v19_directo_bloqueado,
  not has_function_privilege(
    'authenticated',
    'public.aplicar_factura_venta_xml_v20(jsonb,uuid,jsonb,text,boolean,text)',
    'execute'
  ) as motor_v20_directo_bloqueado,
  has_function_privilege(
    'authenticated',
    'public.aplicar_factura_venta_franquicia_v44(jsonb,jsonb,text)', 'execute'
  ) as puerta_franquicia_ok;

-- 3. La puerta interna valida rol y permiso, y es SECURITY DEFINER.
select
  p.prosecdef as security_definer,
  p.proconfig,
  pg_get_functiondef(p.oid) like '%ventas.acceder%' as valida_permiso,
  pg_get_functiondef(p.oid) not like '%franquiciado%' as separa_franquicia
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'aplicar_factura_venta_xml_operativa_v46';

-- 4. Todos deben ser cero.
-- Una factura vigente cargada desde el panel de franquicia debe estar ligada a
-- su ingreso. Se identifica con la misma clave deterministica que uso v44.
select count(*) as facturas_franquicia_sin_caja_debe_ser_cero
from public.documentos_venta_xml d
join public.franquicias f on f.almacen_id = d.almacen_id
where not d.anulado
  and d.anulacion_stock_estado not in ('reversion_tecnica', 'reversion_tecnica_legacy')
  and exists (
    select 1 from public.franquicia_caja_movimientos x
    where x.franquicia_id = f.id
      and x.idempotency_key = md5(d.clave_acceso)::uuid
  )
  and not exists (
    select 1 from public.franquicia_caja_movimientos m
    where m.documento_xml_id = d.id and m.estado = 'vigente'
  );

select count(*) as facturas_anuladas_con_caja_vigente_debe_ser_cero
from public.documentos_venta_xml d
join public.franquicia_caja_movimientos m on m.documento_xml_id = d.id
where (d.anulado or d.anulacion_stock_estado = 'reversion_tecnica')
  and m.estado = 'vigente';

-- 5. Informativo: puertas publicas finales del flujo XML.
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'aplicar_factura_venta_xml', 'aplicar_factura_venta_xml_v19',
    'aplicar_factura_venta_xml_v20',
    'aplicar_factura_venta_xml_operativa_v46',
    'aplicar_factura_venta_franquicia_v44'
  )
order by p.proname;
