-- ============================================================
-- Verificacion v50 - Control mensual del local
-- Solo lectura: ejecutar despues de instalar v50.
-- ============================================================

-- 1. Permisos nuevos registrados y repartidos a todos los roles.
select codigo, modulo, nombre, activo
from public.permisos_sistema
where codigo in ('franquicia.precio_libre', 'franquicia.descuento')
order by codigo;

select count(*) = 2 as permisos_creados
from public.permisos_sistema
where codigo in ('franquicia.precio_libre', 'franquicia.descuento') and activo;

-- Quien los tiene hoy. El vendedor NO deberia tener ninguno de los dos.
select rol, permiso_codigo, permitido
from public.rol_permisos
where permiso_codigo in ('franquicia.precio_libre', 'franquicia.descuento',
                         'conteos.acceder')
  and rol::text in ('franquiciado', 'vendedor_franquicia')
order by rol, permiso_codigo;

-- 2. La venta pasa por la version que valida esos permisos.
select
  to_regprocedure('public.registrar_venta_franquicia_v50(date,jsonb,jsonb,numeric,text,text,uuid)') is not null
    as venta_v50_ok,
  has_function_privilege('authenticated','public.registrar_venta_franquicia_v50(date,jsonb,jsonb,numeric,text,text,uuid)','execute')
    as venta_v50_disponible,
  -- La de v47 no valida precio ni descuento: debe quedar cerrada.
  not has_function_privilege('authenticated','public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid)','execute')
    as venta_v47_cerrada;

-- 3. El conteo del local: cuenta el franquiciado, resuelve Control.
select coalesce(bool_or(pg_get_functiondef(p.oid) like '%franquiciado%'), false) as admite_franquiciado,
       p.proname
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('crear_conteo_inventario', 'guardar_conteo_inventario',
                    'guardar_reconteo_inventario')
group by p.proname
order by p.proname;

-- CRITICO: resolver_conteo_inventario NO debe admitir al franquiciado. Si esto
-- sale false, el local podria aprobar su propio ajuste de inventario.
select pg_get_functiondef(p.oid) not like '%franquiciado%' as resolucion_sigue_en_control
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resolver_conteo_inventario';

-- Y debe seguir bloqueando la aprobacion propia.
select pg_get_functiondef(p.oid) like '%No puedes aprobar tu propio conteo%'
       as autoaprobacion_bloqueada
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resolver_conteo_inventario';

-- 4. Vistas del resumen mensual, respetando el RLS de las tablas base.
select
  (select c.reloptions::text like '%security_invoker=true%'
   from pg_class c where c.oid = 'public.vista_resumen_mensual_franquicia_v50'::regclass)
     as mensual_security_invoker_ok,
  (select c.reloptions::text like '%security_invoker=true%'
   from pg_class c where c.oid = 'public.vista_inventario_valorizado_franquicia_v50'::regclass)
     as inventario_security_invoker_ok,
  not has_table_privilege('anon','public.vista_resumen_mensual_franquicia_v50','select')
     as mensual_anon_bloqueada;

-- El resumen debe excluir las contrapartidas de reversa, igual que el saldo.
select pg_get_viewdef('public.vista_resumen_mensual_franquicia_v50'::regclass)
       like '%reversa_de_id IS NULL%' as excluye_contrapartidas;

-- 5. CRITICO. Todos deben ser cero.
-- El resultado del mes tiene que ser exactamente ingresos menos egresos.
select count(*) as resultados_descuadrados_debe_ser_cero
from public.vista_resumen_mensual_franquicia_v50
where round(resultado_operativo, 2) <> round(ingresos - egresos, 2);

-- Los medios de pago no pueden sumar mas que el total de ingresos.
select count(*) as medios_de_pago_inconsistentes_debe_ser_cero
from public.vista_resumen_mensual_franquicia_v50
where round(ingresos_efectivo + ingresos_transferencia + ingresos_tarjeta, 2)
      > round(ingresos, 2) + 0.01;

-- 6. Informativo: el resumen de los ultimos meses de cada local.
select franquicia, anio, numero_mes, ingresos, egresos, resultado_operativo,
       ventas_registradas, unidades_vendidas, dias_cerrados, dias_con_diferencia
from public.vista_resumen_mensual_franquicia_v50
order by franquicia, mes desc
limit 24;

-- 7. Informativo: inventario valorizado de cada local, hoy.
select * from public.vista_inventario_valorizado_franquicia_v50 order by franquicia;
