-- ============================================================
-- BOMAN INVENTARIO - v51: panel principal por rol
--
-- Reune en una sola lectura los indicadores que necesita el inicio del ERP.
-- La funcion no recibe IDs elegidos por el navegador: deriva el usuario,
-- permisos, empresas, almacenes y franquicia desde la sesion autenticada.
-- Ejecutar una sola vez DESPUES de v50.
-- ============================================================

create or replace function public.resumen_panel_principal_v51()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_rol text;
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_inicio_hoy timestamptz;
  v_fin_hoy timestamptz;
  v_almacenes jsonb := '[]'::jsonb;
  v_empresas jsonb := '[]'::jsonb;
  v_almacenes_total bigint := 0;
  v_empresas_total bigint := 0;
  v_inventario jsonb := jsonb_build_object(
    'stock_fisico', 0, 'stock_disponible', 0, 'transito_entrada', 0,
    'productos_bajo_minimo', 0, 'unidades_sugeridas', 0,
    'movimientos_hoy', 0
  );
  v_operaciones jsonb := jsonb_build_object(
    'solicitudes_pendientes', 0, 'transferencias_preparar', 0,
    'transferencias_recibir', 0, 'conteos_revision', 0
  );
  v_ventas jsonb := jsonb_build_object(
    'documentos_hoy', 0, 'importe_hoy', 0
  );
  v_compras jsonb := jsonb_build_object(
    'pendientes_aprobacion', 0, 'pendientes_recepcion', 0
  );
  v_produccion jsonb := jsonb_build_object(
    'pendientes_aprobacion', 0, 'ordenes_activas', 0,
    'ordenes_atrasadas', 0
  );
  v_nomina jsonb := jsonb_build_object(
    'empleados_activos', 0, 'ausencias_solicitadas', 0,
    'documentos_por_vencer', 0, 'documentos_vencidos', 0,
    'periodos_pendientes', 0
  );
  v_franquicia jsonb := jsonb_build_object(
    'locales', 0, 'ventas_hoy', 0, 'total_ventas_hoy', 0,
    'alertas', 0, 'cierres_pendientes_hoy', 0
  );
  v_administracion jsonb := jsonb_build_object(
    'usuarios_activos', 0, 'usuarios_inactivos', 0
  );
  v_actividad jsonb := '[]'::jsonb;
begin
  if v_uid is null then
    raise exception 'Debes iniciar sesion para consultar el panel';
  end if;

  select p.rol::text into v_rol
  from public.perfiles p
  where p.id = v_uid and p.activo;
  if not found then
    raise exception 'El perfil no existe o esta inactivo';
  end if;

  v_inicio_hoy := v_hoy::timestamp at time zone 'America/Guayaquil';
  v_fin_hoy := (v_hoy + 1)::timestamp at time zone 'America/Guayaquil';

  select count(*), coalesce(jsonb_agg(x.nombre order by x.nombre), '[]'::jsonb)
  into v_almacenes_total, v_almacenes
  from (
    select a.nombre
    from public.almacenes a
    where a.activo and public.usuario_puede_almacen(a.id, false)
  ) x;

  select count(*), coalesce(jsonb_agg(x.nombre order by x.nombre), '[]'::jsonb)
  into v_empresas_total, v_empresas
  from (
    select e.razon_social as nombre
    from public.empresas e
    where e.activo and public.usuario_puede_empresa(e.id, false)
  ) x;

  if public.usuario_tiene_permiso_v35('inventario.acceder') then
    select jsonb_build_object(
      'stock_fisico', coalesce(sum(s.stock_fisico), 0),
      'stock_disponible', coalesce(sum(s.stock_disponible), 0),
      'transito_entrada', coalesce(sum(s.transito_entrada), 0),
      'productos_bajo_minimo', count(*) filter (
        where s.stock_minimo > 0 and s.stock_disponible <= s.stock_minimo
      ),
      'unidades_sugeridas', coalesce(sum(s.sugerido_reponer) filter (
        where s.sugerido_reponer > 0
      ), 0),
      'movimientos_hoy', (
        select count(*)
        from public.movimientos m
        where not coalesce(m.anulado, false)
          and m.created_at >= v_inicio_hoy and m.created_at < v_fin_hoy
          and (
            public.usuario_puede_almacen(m.entidad_id, false)
            or public.usuario_puede_almacen(m.entidad_destino_id, false)
          )
      )
    ) into v_inventario
    from public.vista_stock_operativo s
    where public.usuario_puede_almacen(s.almacen_id, false);
  end if;

  if public.usuario_tiene_permiso_v35('operaciones.acceder')
     or public.usuario_tiene_permiso_v35('conteos.acceder') then
    select jsonb_build_object(
      'solicitudes_pendientes', count(*) filter (
        where d.tipo = 'solicitud_reposicion' and d.estado = 'solicitado'
      ),
      'transferencias_preparar', count(*) filter (
        where d.tipo = 'transferencia' and d.estado in ('aprobado', 'preparando')
          and public.usuario_puede_almacen(d.origen_id, false)
      ),
      'transferencias_recibir', count(*) filter (
        where d.tipo = 'transferencia' and d.estado in ('despachado', 'en_transito')
          and public.usuario_puede_almacen(d.destino_id, false)
      ),
      'conteos_revision', count(*) filter (
        where d.tipo = 'conteo' and d.estado = 'pendiente_revision'
      )
    ) into v_operaciones
    from public.documentos_inventario d
    where public.puede_ver_documento(d.id);
  end if;

  if public.usuario_tiene_permiso_v35('ventas.acceder') then
    select jsonb_build_object(
      'documentos_hoy', count(*),
      'importe_hoy', coalesce(sum(d.importe_total), 0)
    ) into v_ventas
    from public.documentos_venta_xml d
    where d.fecha_emision = v_hoy
      and public.usuario_puede_almacen(d.almacen_id, false);
  end if;

  if public.usuario_tiene_permiso_v35('compras.acceder') then
    select jsonb_build_object(
      'pendientes_aprobacion', count(*) filter (
        where o.estado = 'pendiente_aprobacion'
      ),
      'pendientes_recepcion', count(*) filter (
        where o.estado in ('aprobada', 'parcial')
      )
    ) into v_compras
    from public.ordenes_compra o
    where public.usuario_puede_empresa(o.empresa_id, false);
  end if;

  if public.usuario_tiene_permiso_v35('produccion.acceder') then
    select jsonb_build_object(
      'pendientes_aprobacion', count(*) filter (
        where o.estado = 'pendiente_aprobacion'
      ),
      'ordenes_activas', count(*) filter (
        where o.estado in ('aprobada', 'en_proceso')
      ),
      'ordenes_atrasadas', count(*) filter (
        where o.estado in ('aprobada', 'en_proceso')
          and o.fecha_planificada is not null and o.fecha_planificada < v_hoy
      )
    ) into v_produccion
    from public.ordenes_produccion o
    where public.usuario_puede_empresa(o.empresa_id, false);
  end if;

  if public.usuario_tiene_permiso_v35('nomina.acceder') then
    select jsonb_build_object(
      'empleados_activos', (select count(*) from public.empleados e where e.estado = 'activo'),
      'ausencias_solicitadas', (
        select count(*) from public.ausencias a where a.estado = 'solicitada'
      ),
      'documentos_por_vencer', (
        select count(*) from public.vista_documentos_por_vencer d
        where d.dias_restantes between 0 and 60
      ),
      'documentos_vencidos', (
        select count(*) from public.vista_documentos_por_vencer d
        where d.dias_restantes < 0
      ),
      'periodos_pendientes', (
        select count(*) from public.nomina_periodos n where n.estado in ('abierto', 'calculado')
      )
    ) into v_nomina;
  end if;

  if public.usuario_tiene_permiso_v35('franquicia.acceder') then
    with accesibles as (
      select f.id
      from public.franquicias f
      where f.activo
        and public.usuario_puede_franquicia_v42(f.id, false, false)
    )
    select jsonb_build_object(
      'locales', (select count(*) from accesibles),
      'ventas_hoy', (
        select count(*)
        from public.ventas_franquicia v
        join accesibles f on f.id = v.franquicia_id
        where v.fecha = v_hoy and v.estado = 'registrada'
      ),
      'total_ventas_hoy', (
        select coalesce(sum(v.total), 0)
        from public.ventas_franquicia v
        join accesibles f on f.id = v.franquicia_id
        where v.fecha = v_hoy and v.estado = 'registrada'
      ),
      'alertas', (
        select count(*)
        from public.vista_alertas_franquicia_v47 a
        join accesibles f on f.id = a.franquicia_id
      ),
      'cierres_pendientes_hoy', case
        when public.usuario_tiene_permiso_v35('franquicia.caja') then (
          select count(*)
          from accesibles f
          where not exists (
            select 1 from public.franquicia_caja_cierres c
            where c.franquicia_id = f.id and c.fecha = v_hoy and c.estado = 'cerrado'
          )
        ) else 0 end
    ) into v_franquicia;
  end if;

  if v_rol = 'admin' then
    select jsonb_build_object(
      'usuarios_activos', count(*) filter (where p.activo),
      'usuarios_inactivos', count(*) filter (where not p.activo)
    ) into v_administracion
    from public.perfiles p;
  end if;

  if v_rol in ('franquiciado', 'vendedor_franquicia') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'fecha', x.created_at,
      'tipo', 'venta',
      'titulo', 'Venta #' || x.numero::text,
      'detalle', x.total::text || ' USD · ' || x.medio_pago,
      'href', '/franquicia'
    ) order by x.created_at desc), '[]'::jsonb)
    into v_actividad
    from (
      select v.created_at, v.numero, v.total, v.medio_pago
      from public.ventas_franquicia v
      where v.estado = 'registrada'
        and public.usuario_puede_franquicia_v42(v.franquicia_id, false, false)
      order by v.created_at desc
      limit 8
    ) x;
  elsif public.usuario_tiene_permiso_v35('movimientos.acceder') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'fecha', x.created_at,
      'tipo', x.tipo,
      'titulo', x.sku || ' · ' || x.producto,
      'detalle', x.cantidad::text || ' un. · ' || x.almacen,
      'href', '/movimientos'
    ) order by x.created_at desc), '[]'::jsonb)
    into v_actividad
    from (
      select m.created_at, m.tipo::text as tipo, m.cantidad,
             p.sku, p.nombre as producto, a.nombre as almacen
      from public.movimientos m
      join public.productos p on p.id = m.producto_id
      join public.almacenes a on a.id = m.entidad_id
      where not coalesce(m.anulado, false)
        and (
          public.usuario_puede_almacen(m.entidad_id, false)
          or public.usuario_puede_almacen(m.entidad_destino_id, false)
        )
      order by m.created_at desc
      limit 8
    ) x;
  end if;

  return jsonb_build_object(
    'generado_at', now(),
    'hoy', v_hoy,
    'rol', v_rol,
    'ambito', jsonb_build_object(
      'almacenes_total', v_almacenes_total,
      'almacenes', v_almacenes,
      'empresas_total', v_empresas_total,
      'empresas', v_empresas
    ),
    'inventario', v_inventario,
    'operaciones', v_operaciones,
    'ventas', v_ventas,
    'compras', v_compras,
    'produccion', v_produccion,
    'nomina', v_nomina,
    'franquicia', v_franquicia,
    'administracion', v_administracion,
    'actividad', v_actividad
  );
end;
$fn$;

alter function public.resumen_panel_principal_v51() owner to postgres;
revoke execute on function public.resumen_panel_principal_v51()
  from public, anon;
grant execute on function public.resumen_panel_principal_v51()
  to authenticated;

comment on function public.resumen_panel_principal_v51() is
  'Resumen de inicio derivado de la sesion. Aplica permisos y alcance por almacen, empresa y franquicia.';

notify pgrst, 'reload schema';
