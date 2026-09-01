-- ============================================================
-- Verificacion v43 - Pedidos sin codigo en la reposicion
-- Solo lectura: ejecutar despues de instalar v43.
-- ============================================================

-- 1. La linea admite nacer sin producto, pero nunca vacia.
select
  (select not attnotnull from pg_attribute
   where attrelid = 'public.documento_inventario_lineas'::regclass
     and attname = 'producto_id') as producto_id_admite_null,
  (select count(*) = 1 from pg_attribute
   where attrelid = 'public.documento_inventario_lineas'::regclass
     and attname = 'descripcion_libre' and not attisdropped) as columna_descripcion_ok,
  (select count(*) = 1 from pg_constraint
   where conrelid = 'public.documento_inventario_lineas'::regclass
     and conname = 'linea_producto_o_descripcion') as check_producto_o_descripcion_ok;

-- 2. El trigger que impide que una linea sin producto salga de la solicitud.
select
  to_regprocedure('public.exigir_producto_fuera_de_solicitud_v43()') is not null as funcion_ok,
  (select count(*) = 1 from pg_trigger
   where tgrelid = 'public.documento_inventario_lineas'::regclass
     and tgname = 'trg_exigir_producto_fuera_de_solicitud'
     and not tgisinternal) as trigger_ok;

-- 3. RPC de asignacion instalada y cerrada a anonimos.
select
  to_regprocedure('public.asignar_producto_linea_v43(uuid,uuid)') is not null as asignar_ok,
  has_function_privilege('authenticated','public.asignar_producto_linea_v43(uuid,uuid)','execute') as asignar_authenticated_ok,
  not has_function_privilege('anon','public.asignar_producto_linea_v43(uuid,uuid)','execute') as asignar_anon_bloqueada;

-- 4. CRITICO: v43 reescribe crear_solicitud_reposicion, que v42 habia parcheado
-- para admitir al franquiciado. Si esto sale false, el local perdio la
-- reposicion y hay que reejecutar v43.
select pg_get_functiondef(p.oid) like '%franquiciado%' as franquiciado_conserva_reposicion
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'crear_solicitud_reposicion';

-- 5. La funcion sigue siendo definer con search_path fijo.
select p.proname, p.prosecdef as security_definer, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('crear_solicitud_reposicion','asignar_producto_linea_v43',
                    'exigir_producto_fuera_de_solicitud_v43')
order by p.proname;

-- 6. Todos deben ser cero: ninguna linea sin producto puede vivir fuera de una
-- solicitud pendiente, ni quedar sin descripcion.
select count(*) as lineas_sin_producto_fuera_de_solicitud_debe_ser_cero
from public.documento_inventario_lineas l
join public.documentos_inventario d on d.id = l.documento_id
where l.producto_id is null and d.tipo <> 'solicitud_reposicion';

select count(*) as lineas_sin_producto_ni_descripcion_debe_ser_cero
from public.documento_inventario_lineas
where producto_id is null and nullif(btrim(descripcion_libre), '') is null;

-- 7. Informativo: pedidos sin codigo esperando que bodega los convierta.
select d.numero, d.created_at::date as fecha, a.nombre as destino,
       l.descripcion_libre, l.cantidad_solicitada
from public.documento_inventario_lineas l
join public.documentos_inventario d on d.id = l.documento_id
left join public.almacenes a on a.id = d.destino_id
where l.producto_id is null and d.estado = 'solicitado'
order by d.created_at desc
limit 50;
