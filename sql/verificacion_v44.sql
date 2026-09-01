-- ============================================================
-- Verificacion v44 - Correcciones de la operacion de franquicia
-- Solo lectura: ejecutar despues de instalar v44.
-- ============================================================

-- 1. RPC nuevas instaladas y cerradas a anonimos.
select
  to_regprocedure('public.anular_venta_franquicia_v44(uuid,text,uuid)') is not null as anular_venta_ok,
  to_regprocedure('public.aplicar_factura_venta_franquicia_v44(jsonb,jsonb,text)') is not null as factura_local_ok,
  to_regprocedure('public.confirmar_cambio_clave_v44()') is not null as cambio_clave_ok,
  not has_function_privilege('anon','public.anular_venta_franquicia_v44(uuid,text,uuid)','execute') as anular_anon_bloqueada,
  not has_function_privilege('anon','public.aplicar_factura_venta_franquicia_v44(jsonb,jsonb,text)','execute') as factura_anon_bloqueada,
  not has_function_privilege('anon','public.confirmar_cambio_clave_v44()','execute') as clave_anon_bloqueada;

-- 2. Las tres son definer con search_path fijo.
select p.proname, p.prosecdef as security_definer, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('anular_venta_franquicia_v44',
                    'aplicar_factura_venta_franquicia_v44',
                    'confirmar_cambio_clave_v44')
order by p.proname;

-- 3. La vista de caja no cuenta las contrapartidas de reversa y sigue
-- respetando el RLS de las tablas base.
select
  (select c.reloptions::text like '%security_invoker=true%'
   from pg_class c where c.oid = 'public.vista_caja_franquicia_v42'::regclass) as security_invoker_ok,
  (select pg_get_viewdef('public.vista_caja_franquicia_v42'::regclass) like '%reversa_de_id IS NULL%')
    as saldo_excluye_contrapartidas;

-- 4. El motor de facturas XML admite los roles de franquicia.
select coalesce(bool_or(pg_get_functiondef(p.oid) like '%vendedor_franquicia%'), false)
       as xml_admite_franquicia
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'aplicar_factura_venta_xml';

-- 5. La marca de clave temporal existe y no la puede limpiar el propio usuario
-- por update directo (solo la RPC, que comprueba el cambio real).
select
  (select count(*) = 1 from pg_attribute
   where attrelid = 'public.perfiles'::regclass
     and attname = 'clave_temporal_desde' and not attisdropped) as columna_ok,
  not has_column_privilege('authenticated','public.perfiles','clave_temporal_desde','update')
    as update_directo_bloqueado;

-- 6. CRITICO - saldo de caja. Todos deben ser cero.
-- Cada reversa debe ser el espejo exacto del movimiento que anula: mismo monto
-- y signo contrario. Si no, el saldo del local queda descuadrado.
select count(*) as reversas_descuadradas_debe_ser_cero
from public.franquicia_caja_movimientos r
join public.franquicia_caja_movimientos o on o.id = r.reversa_de_id
where r.monto <> o.monto or r.tipo = o.tipo or o.estado <> 'revertido';

-- Un original revertido sin su contrapartida, o al reves, es un descuadre.
select count(*) as reversas_huerfanas_debe_ser_cero
from public.franquicia_caja_movimientos m
where m.estado = 'revertido'
  and not exists (
    select 1 from public.franquicia_caja_movimientos r where r.reversa_de_id = m.id
  );

-- 7. CRITICO - anulaciones. Todos deben ser cero.
-- Una venta anulada tiene que tener su ingreso de caja fuera de circulacion.
select count(*) as ventas_anuladas_con_caja_vigente_debe_ser_cero
from public.ventas_franquicia v
join public.franquicia_caja_movimientos m on m.venta_id = v.id
where v.estado = 'anulada' and m.estado = 'vigente';

-- Y su motivo y autor registrados.
select count(*) as anulaciones_sin_trazabilidad_debe_ser_cero
from public.ventas_franquicia
where estado = 'anulada'
  and (anulada_por is null or anulada_at is null
       or char_length(btrim(coalesce(motivo_anulacion, ''))) < 10);

-- Una venta anulada debe tener devuelto el stock de todas sus lineas.
select count(*) as lineas_anuladas_sin_devolucion_debe_ser_cero
from public.ventas_franquicia v
join public.venta_franquicia_lineas l on l.venta_id = v.id
where v.estado = 'anulada'
  and not exists (
    -- aplicar_movimiento_stock_v20 guarda el documento de origen en grupo_id.
    select 1 from public.movimientos mi
    where mi.grupo_id = v.id
      and mi.documento_tipo = 'anulacion_venta_franquicia'
      and mi.producto_id = l.producto_id
  );

-- 8. Informativo: saldo actual de cada local segun la vista corregida.
select franquicia, max(fecha) as ultimo_movimiento,
       (array_agg(saldo_acumulado order by fecha desc, created_at desc, id desc))[1] as saldo
from public.vista_caja_franquicia_v42
group by franquicia
order by franquicia;

-- 9. Informativo: usuarios que todavia deben cambiar su clave temporal.
select p.nombre_completo, p.rol, p.clave_temporal_desde
from public.perfiles p
where p.clave_temporal_desde is not null
order by p.clave_temporal_desde;
