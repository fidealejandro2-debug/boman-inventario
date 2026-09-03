-- ============================================================
-- BOMAN INVENTARIO - v62
-- Panel consolidado de franquicias
-- Ejecutar despues de v57 y antes de verificacion_v62.sql.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.franquicias') is null
     or to_regclass('public.vista_stock_operativo') is null
     or to_regclass('public.vista_cierres_pendientes_v57') is null then
    raise exception 'Faltan dependencias de franquicias. Instala y valida hasta v57 antes de v62';
  end if;
  if to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta el motor de permisos v35';
  end if;
end $$;

-- El consolidado es un permiso distinto de operar el local. El administrador
-- siempre lo conserva; Control y Gerencia lo reciben inicialmente, pero la
-- matriz de permisos permite retirarlo si cambia la organizacion.
insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('franquicia.consolidado', 'Franquicias', 'Consolidado de franquicias',
   'Compara ventas, caja, inventario, reposiciones y alertas de todos los locales.', 129)
on conflict (codigo) do update set
  modulo = excluded.modulo,
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  orden = excluded.orden,
  activo = true,
  updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, 'franquicia.consolidado', false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
where r.rol::text <> 'admin'
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos
set permitido = true, updated_at = now()
where rol::text in ('control', 'gerencia')
  and permiso_codigo = 'franquicia.consolidado';

create or replace function public.resumen_consolidado_franquicias_v62(
  p_desde date default null,
  p_hasta date default null
) returns table (
  franquicia_id uuid,
  franquicia_codigo text,
  franquicia_nombre text,
  ciudad text,
  empresa_codigo text,
  empresa_nombre text,
  almacen_id uuid,
  almacen_nombre text,
  ventas_registradas bigint,
  ventas_anuladas bigint,
  unidades_vendidas bigint,
  total_vendido numeric,
  descuentos_otorgados numeric,
  ingresos_total numeric,
  egresos_total numeric,
  resultado_operativo numeric,
  ingresos_efectivo numeric,
  ingresos_transferencia numeric,
  ingresos_tarjeta numeric,
  ingresos_otros numeric,
  dias_cerrados bigint,
  dias_con_diferencia bigint,
  diferencia_acumulada numeric,
  cierres_pendientes bigint,
  cierre_pendiente_mas_antiguo date,
  stock_unidades bigint,
  stock_disponible bigint,
  valor_inventario numeric,
  productos_bajo_minimo bigint,
  productos_sin_stock bigint,
  unidades_sugeridas_reponer bigint,
  solicitudes_pendientes bigint,
  transferencias_pendientes_recepcion bigint,
  alertas_activas bigint,
  ultima_venta date,
  ultimo_cierre date
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_desde date;
  v_hasta date;
begin
  if not public.usuario_tiene_permiso_v35('franquicia.consolidado') then
    raise exception 'No tienes permiso para consultar el consolidado de franquicias';
  end if;

  v_desde := coalesce(p_desde, date_trunc('month', v_hoy)::date);
  v_hasta := coalesce(p_hasta, v_hoy);

  if v_desde > v_hasta then
    raise exception 'La fecha desde no puede ser posterior a la fecha hasta';
  end if;
  if v_hasta - v_desde > 366 then
    raise exception 'El consolidado admite un rango maximo de 367 dias';
  end if;

  return query
  select
    f.id,
    f.codigo,
    f.nombre,
    f.ciudad,
    e.codigo,
    coalesce(e.nombre_comercial, e.razon_social),
    f.almacen_id,
    a.nombre,
    coalesce(v.registradas, 0),
    coalesce(v.anuladas, 0),
    coalesce(v.unidades, 0),
    coalesce(v.total, 0::numeric),
    coalesce(v.descuentos, 0::numeric),
    coalesce(c.ingresos, 0::numeric),
    coalesce(c.egresos, 0::numeric),
    coalesce(c.ingresos, 0::numeric) - coalesce(c.egresos, 0::numeric),
    coalesce(c.efectivo, 0::numeric),
    coalesce(c.transferencia, 0::numeric),
    coalesce(c.tarjeta, 0::numeric),
    coalesce(c.otros, 0::numeric),
    coalesce(ci.dias_cerrados, 0),
    coalesce(ci.dias_diferencia, 0),
    coalesce(ci.diferencia, 0::numeric),
    coalesce(cp.pendientes, 0),
    cp.mas_antiguo,
    coalesce(s.unidades, 0),
    coalesce(s.disponible, 0),
    coalesce(s.valor, 0::numeric),
    coalesce(s.bajo_minimo, 0),
    coalesce(s.sin_stock, 0),
    coalesce(s.sugerido, 0),
    coalesce(d.solicitudes, 0),
    coalesce(d.por_recibir, 0),
    coalesce(al.alertas, 0),
    v.ultima,
    ci.ultimo
  from public.franquicias f
  join public.empresas e on e.id = f.empresa_id and e.activo
  join public.almacenes a on a.id = f.almacen_id and a.activo
  left join lateral (
    select
      count(*) filter (where vf.estado = 'registrada') as registradas,
      count(*) filter (where vf.estado = 'anulada') as anuladas,
      coalesce(sum(vl.unidades) filter (where vf.estado = 'registrada'), 0)::bigint as unidades,
      coalesce(sum(vf.total) filter (where vf.estado = 'registrada'), 0) as total,
      coalesce(sum(vf.descuento) filter (where vf.estado = 'registrada'), 0) as descuentos,
      max(vf.fecha) filter (where vf.estado = 'registrada') as ultima
    from public.ventas_franquicia vf
    left join lateral (
      select coalesce(sum(l.cantidad), 0)::bigint as unidades
      from public.venta_franquicia_lineas l
      where l.venta_id = vf.id
    ) vl on true
    where vf.franquicia_id = f.id
      and vf.fecha between v_desde and v_hasta
  ) v on true
  left join lateral (
    select
      coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0) as ingresos,
      coalesce(sum(m.monto) filter (where m.tipo = 'egreso'), 0) as egresos,
      coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'), 0) as efectivo,
      coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'transferencia'), 0) as transferencia,
      coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'tarjeta'), 0) as tarjeta,
      coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago not in ('efectivo', 'transferencia', 'tarjeta')), 0) as otros
    from public.franquicia_caja_movimientos m
    where m.franquicia_id = f.id
      and m.fecha between v_desde and v_hasta
      and m.estado = 'vigente' and m.reversa_de_id is null
  ) c on true
  left join lateral (
    select
      count(*) as dias_cerrados,
      count(*) filter (where abs(cc.diferencia) >= 0.01) as dias_diferencia,
      coalesce(sum(cc.diferencia), 0) as diferencia,
      max(cc.fecha) as ultimo
    from public.franquicia_caja_cierres cc
    where cc.franquicia_id = f.id
      and cc.fecha between v_desde and v_hasta
      and cc.estado = 'cerrado'
  ) ci on true
  left join lateral (
    select count(*) as pendientes, min(x.fecha) as mas_antiguo
    from public.vista_cierres_pendientes_v57 x
    where x.franquicia_id = f.id
  ) cp on true
  left join lateral (
    select
      coalesce(sum(st.stock_fisico), 0)::bigint as unidades,
      coalesce(sum(st.stock_disponible), 0)::bigint as disponible,
      coalesce(sum(st.stock_fisico * coalesce(st.precio, 0)), 0) as valor,
      count(*) filter (where st.bajo_minimo) as bajo_minimo,
      count(*) filter (where st.stock_fisico = 0) as sin_stock,
      coalesce(sum(st.sugerido_reponer), 0)::bigint as sugerido
    from public.vista_stock_operativo st
    where st.almacen_id = f.almacen_id
  ) s on true
  left join lateral (
    select
      count(*) filter (
        where di.tipo = 'solicitud_reposicion' and di.estado = 'solicitado'
      ) as solicitudes,
      count(*) filter (
        where di.tipo = 'transferencia' and di.estado in ('despachado', 'en_transito')
      ) as por_recibir
    from public.documentos_inventario di
    where di.destino_id = f.almacen_id
  ) d on true
  left join lateral (
    select count(*) as alertas
    from public.vista_alertas_franquicia_v47 af
    where af.franquicia_id = f.id
  ) al on true
  where f.activo
  order by coalesce(v.total, 0) desc, f.nombre;
end;
$fn$;

alter function public.resumen_consolidado_franquicias_v62(date,date)
  owner to postgres;

revoke execute on function public.resumen_consolidado_franquicias_v62(date,date)
  from public, anon;
grant execute on function public.resumen_consolidado_franquicias_v62(date,date)
  to authenticated;

comment on function public.resumen_consolidado_franquicias_v62(date,date) is
  'Comparativo operativo de todos los locales para un rango; inventario y pendientes reflejan el estado actual.';

commit;

notify pgrst, 'reload schema';
