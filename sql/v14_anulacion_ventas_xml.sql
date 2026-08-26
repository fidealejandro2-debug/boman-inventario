-- ============================================================
-- BOMAN INVENTARIO - Anulación administrativa de Ventas XML v14
-- Revierte el inventario y conserva íntegra la evidencia importada.
-- Ejecutar una sola vez DESPUÉS de v13.
-- ============================================================

alter table public.documentos_venta_xml
  add column if not exists anulado boolean not null default false,
  add column if not exists motivo_anulacion text,
  add column if not exists anulado_por uuid references public.perfiles(id),
  add column if not exists anulado_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'documentos_venta_xml_anulacion_completa_check'
      and conrelid = 'public.documentos_venta_xml'::regclass
  ) then
    alter table public.documentos_venta_xml
      add constraint documentos_venta_xml_anulacion_completa_check check (
        (not anulado and motivo_anulacion is null and anulado_por is null and anulado_at is null)
        or
        (anulado and btrim(coalesce(motivo_anulacion, '')) <> ''
          and anulado_por is not null and anulado_at is not null)
      );
  end if;
end;
$$;

create index if not exists idx_documentos_venta_xml_anulado_fecha
  on public.documentos_venta_xml(anulado, created_at desc);

create or replace function public.admin_anular_factura_venta_xml(
  p_documento_id uuid,
  p_motivo text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_venta_xml%rowtype;
  it record;
  v_unidades integer := 0;
  v_movimientos integer := 0;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administración puede anular una factura XML aplicada';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'Debes indicar el motivo de la anulación';
  end if;

  select * into d
  from public.documentos_venta_xml
  where id = p_documento_id
  for update;

  if not found then raise exception 'La factura XML no existe'; end if;
  if d.anulado then raise exception 'La factura XML ya fue anulada'; end if;

  if exists (
    select 1
    from public.documento_venta_xml_lineas l
    join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
    where l.documento_id = d.id
      and public.conteo_abierto_producto(d.almacen_id, a.producto_id)
  ) then
    raise exception 'No se puede anular porque existe un conteo abierto para uno de sus productos';
  end if;

  -- Devuelve exactamente las unidades descontadas por las asignaciones originales.
  for it in
    select a.producto_id, sum(a.cantidad)::integer cantidad
    from public.documento_venta_xml_lineas l
    join public.documento_venta_xml_asignaciones a on a.linea_id = l.id
    where l.documento_id = d.id and l.afecta_inventario
    group by a.producto_id
    order by a.producto_id
  loop
    insert into public.inventario (producto_id, entidad_id, cantidad)
    values (it.producto_id, d.almacen_id, it.cantidad)
    on conflict (producto_id, entidad_id) do update
    set cantidad = public.inventario.cantidad + excluded.cantidad,
        updated_at = now();

    v_unidades := v_unidades + it.cantidad;
  end loop;

  -- Los movimientos no se eliminan: quedan marcados como anulados con responsable y motivo.
  update public.movimientos
  set anulado = true,
      anulado_por = auth.uid(),
      anulado_at = now(),
      motivo_anulacion = btrim(p_motivo)
  where grupo_id = d.id
    and tipo::text = 'venta_xml'
    and not anulado;
  get diagnostics v_movimientos = row_count;

  update public.documentos_venta_xml
  set anulado = true,
      motivo_anulacion = btrim(p_motivo),
      anulado_por = auth.uid(),
      anulado_at = now()
  where id = d.id;

  return jsonb_build_object(
    'id', d.id,
    'numero_documento', d.numero_documento,
    'unidades_reintegradas', v_unidades,
    'movimientos_anulados', v_movimientos,
    'mensaje', 'Factura anulada y stock reintegrado correctamente'
  );
end;
$$;

alter function public.admin_anular_factura_venta_xml(uuid, text) owner to postgres;

revoke execute on function public.admin_anular_factura_venta_xml(uuid, text)
  from public, anon;
grant execute on function public.admin_anular_factura_venta_xml(uuid, text)
  to authenticated;

notify pgrst, 'reload schema';

