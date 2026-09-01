-- ============================================================
-- Verificacion v42 - Operacion de franquicias
-- Solo lectura: ejecutar despues de instalar v42.
-- ============================================================

select e.enumlabel, true instalado
from pg_enum e join pg_type t on t.oid=e.enumtypid
join pg_namespace n on n.oid=t.typnamespace
where n.nspname='public' and t.typname='rol_usuario'
  and e.enumlabel in ('franquiciado','vendedor_franquicia')
order by e.enumlabel;

select
  to_regclass('public.franquicias') is not null as franquicias_ok,
  to_regclass('public.ventas_franquicia') is not null as ventas_ok,
  to_regclass('public.venta_franquicia_lineas') is not null as lineas_ok,
  to_regclass('public.franquicia_caja_movimientos') is not null as caja_ok,
  to_regclass('public.ajustes_inventario_franquicia') is not null as ajustes_ok;

select
  to_regprocedure('public.admin_guardar_franquicia_v42(uuid,uuid,uuid,uuid,text,text,text,boolean)') is not null as configurar_ok,
  to_regprocedure('public.registrar_venta_franquicia_v42(date,jsonb,text,numeric,text,text,uuid)') is not null as venta_ok,
  to_regprocedure('public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid)') is not null as caja_rpc_ok,
  to_regprocedure('public.registrar_ajuste_franquicia_v42(date,text,jsonb,text,uuid)') is not null as ajuste_rpc_ok,
  to_regprocedure('public.crear_solicitud_reposicion_v42(uuid,jsonb,text,text,uuid)') is not null as reposicion_ok,
  to_regprocedure('public.recibir_transferencia_franquicia_v42(uuid,jsonb,text)') is not null as recepcion_ok;

select tablename, rowsecurity
from pg_tables
where schemaname='public' and tablename in (
  'franquicias','ventas_franquicia','venta_franquicia_lineas',
  'franquicia_caja_movimientos','ajustes_inventario_franquicia',
  'ajuste_inventario_franquicia_lineas'
) order by tablename;

select
  not has_table_privilege('authenticated','public.ventas_franquicia','insert') as venta_directa_bloqueada,
  not has_table_privilege('authenticated','public.franquicia_caja_movimientos','update') as caja_edicion_bloqueada,
  not has_function_privilege('anon','public.registrar_venta_franquicia_v42(date,jsonb,text,numeric,text,text,uuid)','execute') as venta_anon_bloqueada;

-- Todos deben ser cero.
select count(*) as franquicias_sin_operadora_valida_debe_ser_cero
from public.franquicias f
left join public.empresa_almacenes ea
  on ea.empresa_id=f.empresa_id and ea.almacen_id=f.almacen_id
where f.activo and (
  ea.empresa_id is null or not ea.es_operadora_principal
  or not ea.permite_ventas or not ea.custodia_inventario
);

select count(*) as usuarios_franquicia_con_asignacion_invalida_debe_ser_cero
from public.perfiles p
left join lateral (
  select count(*) total, count(*) filter (where f.activo) validos
  from public.perfil_almacenes pa
  left join public.franquicias f on f.almacen_id=pa.almacen_id
  where pa.perfil_id=p.id
) x on true
where p.activo and p.rol::text in ('franquiciado','vendedor_franquicia')
  and (x.total <> 1 or x.validos <> 1);

select count(*) as ventas_totales_inconsistentes_debe_ser_cero
from public.ventas_franquicia v
left join lateral (
  select coalesce(sum(l.total),0)::numeric(14,2) subtotal
  from public.venta_franquicia_lineas l where l.venta_id=v.id
) x on true
where v.subtotal <> x.subtotal or v.total <> v.subtotal-v.descuento;

select count(*) as ventas_sin_movimientos_debe_ser_cero
from public.venta_franquicia_lineas l
join public.ventas_franquicia v on v.id=l.venta_id and v.estado='registrada'
where not exists (
  select 1 from public.movimientos m
  where m.grupo_id=v.id and m.documento_tipo='venta_franquicia'
    and m.producto_id=l.producto_id and not coalesce(m.anulado,false)
);

select count(*) as ventas_sin_ingreso_caja_debe_ser_cero
from public.ventas_franquicia v
where v.estado='registrada' and v.total>0 and not exists (
  select 1 from public.franquicia_caja_movimientos m
  where m.venta_id=v.id and m.tipo='ingreso'
);

select count(*) as vendedores_con_permiso_caja_debe_ser_cero
from public.rol_permisos
where rol::text='vendedor_franquicia'
  and permiso_codigo in ('franquicia.caja','franquicia.inventario','franquicia.reposicion')
  and permitido;

select f.codigo, f.nombre, f.ciudad, a.nombre almacen,
       e.razon_social, e.obligado_contabilidad, f.activo
from public.franquicias f
join public.almacenes a on a.id=f.almacen_id
join public.empresas e on e.id=f.empresa_id
order by f.nombre;

