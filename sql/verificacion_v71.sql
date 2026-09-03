-- ============================================================
-- Verificacion v71 - Caja diaria tambien para tiendas propias
-- Solo lectura: ejecutar despues de instalar v71.
-- ============================================================

-- 1. Todas las filas de caja tienen almacen_id; ninguna franquicia perdio su
-- franquicia_id en el backfill.
select count(*) as movimientos_sin_almacen_debe_ser_cero
from public.franquicia_caja_movimientos where almacen_id is null;

select count(*) as cierres_sin_almacen_debe_ser_cero
from public.franquicia_caja_cierres where almacen_id is null;

select count(*) as movimientos_de_franquicia_sin_franquicia_id_debe_ser_cero
from public.franquicia_caja_movimientos m
join public.franquicias f on f.almacen_id = m.almacen_id and f.activo
where m.franquicia_id is null;

-- 2. El nuevo unique protege tambien a tienda propia (antes unique(franquicia_id,
-- fecha) no chocaba nunca entre dos filas con franquicia_id null).
select conname from pg_constraint
where conrelid = 'public.franquicia_caja_cierres'::regclass
  and conname = 'franquicia_caja_cierres_almacen_id_fecha_key';

-- 3. El rol tienda ya tiene el permiso de caja encendido.
select rol, permiso_codigo, permitido from public.rol_permisos
where rol::text = 'tienda' and permiso_codigo = 'franquicia.caja';

-- 4. Objetos instalados.
select
  to_regprocedure('public.almacen_caja_operativo_v71()') is not null as resolver_ok,
  to_regprocedure('public.saldo_inicial_caja_franquicia_v49(uuid,date)') is not null as saldo_inicial_ok,
  to_regprocedure('public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid)') is not null as cerrar_ok,
  to_regprocedure('public.reabrir_caja_franquicia_v47(uuid,text)') is not null as reabrir_ok,
  to_regclass('public.vista_caja_franquicia_v42') is not null as vista_saldo_ok;

-- 5. Informativo: tiendas propias candidatas (almacen tipo tienda, sin
-- franquicia activa) y si ya tienen algun empleado de rol tienda asignado.
select a.id, a.nombre,
  exists (
    select 1 from public.perfil_almacenes pa
    join public.perfiles p on p.id = pa.perfil_id and p.activo and p.rol::text = 'tienda'
    where pa.almacen_id = a.id
  ) as tiene_empleado_tienda_asignado
from public.almacenes a
where a.activo and a.tipo = 'tienda'
  and not exists (select 1 from public.franquicias f where f.almacen_id = a.id and f.activo)
order by a.nombre;

-- 6. Nada de esto debio tocar el mini-POS de franquicia.
select to_regprocedure('public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid)') is not null
  as venta_franquicia_intacta;
