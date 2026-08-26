-- ============================================================
-- BOMAN INVENTARIO - Excepción admin para conteos propios v15
-- Admin puede recontar y resolver su propio conteo. Control conserva
-- la separación de funciones. La excepción queda explícita en eventos.
-- Ejecutar una sola vez DESPUÉS de v14.
-- ============================================================

create or replace function public.guardar_reconteo_inventario(
  p_documento_id uuid,
  p_items jsonb,
  p_nota text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_detalle text;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Control puede registrar el segundo conteo';
  end if;
  select * into d from public.documentos_inventario
  where id = p_documento_id for update;
  if not found or d.tipo <> 'conteo' or d.estado <> 'pendiente_revision' then
    raise exception 'El conteo no está pendiente de revisión';
  end if;
  if d.creado_por = auth.uid() and v_rol <> 'admin' then
    raise exception 'Quien realizó el primer conteo no puede registrar el segundo';
  end if;

  update public.documento_inventario_lineas l
  set cantidad_reconteo = x.cantidad,
      observacion = coalesce(nullif(btrim(x.observacion), ''), l.observacion)
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  where l.documento_id = d.id and l.producto_id = x.producto_id
    and x.cantidad >= 0 and l.cantidad_contada is distinct from l.stock_sistema;

  update public.documentos_inventario
  set revisado_por = auth.uid(),
      nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = d.id;

  v_detalle := case
    when d.creado_por = auth.uid() then
      'Excepción Admin: segundo conteo propio. ' || coalesce(nullif(btrim(p_nota), ''), 'Registrado')
    else
      'Segundo conteo: ' || coalesce(nullif(btrim(p_nota), ''), 'Registrado')
  end;
  perform public.registrar_evento_documento(
    d.id, 'pendiente_revision', 'pendiente_revision', v_detalle
  );
end;
$$;

create or replace function public.resolver_conteo_inventario(
  p_documento_id uuid,
  p_aprobar boolean,
  p_nota text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  it record;
  v_rol text := public.rol_usuario_actual();
  v_actual integer;
  v_final integer;
  v_detalle text;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Control puede resolver conteos';
  end if;
  if btrim(coalesce(p_nota, '')) = '' then
    raise exception 'La resolución debe tener una observación';
  end if;
  select * into d from public.documentos_inventario
  where id = p_documento_id for update;
  if not found or d.tipo <> 'conteo' or d.estado <> 'pendiente_revision' then
    raise exception 'El conteo no está pendiente de revisión';
  end if;
  if d.creado_por = auth.uid() and v_rol <> 'admin' then
    raise exception 'No puedes aprobar tu propio conteo';
  end if;

  v_detalle := case
    when d.creado_por = auth.uid() then
      'Excepción Admin: resolución de conteo propio. ' || btrim(p_nota)
    else btrim(p_nota)
  end;

  if not p_aprobar then
    update public.documentos_inventario
    set estado = 'en_conteo', revisado_por = auth.uid(),
        nota = concat_ws(E'\n', nota, btrim(p_nota)),
        updated_at = now(), version = version + 1
    where id = d.id;
    update public.documento_inventario_lineas
    set cantidad_reconteo = null where documento_id = d.id;
    perform public.registrar_evento_documento(
      d.id, 'pendiente_revision', 'en_conteo', v_detalle
    );
    return;
  end if;

  if exists (
    select 1 from public.documento_inventario_lineas
    where documento_id = d.id
      and cantidad_contada is distinct from stock_sistema
      and cantidad_reconteo is null
  ) then
    raise exception 'Las diferencias requieren un segundo conteo antes de aprobar';
  end if;

  for it in
    select * from public.documento_inventario_lineas
    where documento_id = d.id order by id
  loop
    select cantidad into v_actual from public.inventario
    where producto_id = it.producto_id and entidad_id = d.origen_id for update;
    v_actual := coalesce(v_actual, 0);
    if v_actual <> it.stock_sistema then
      raise exception 'El stock cambió durante el conteo. Reabre el conteo para actualizar la base.';
    end if;
    v_final := coalesce(it.cantidad_reconteo, it.cantidad_contada);
    if v_final is null then raise exception 'Existe una línea sin conteo'; end if;

    if v_final <> v_actual then
      insert into public.inventario (producto_id, entidad_id, cantidad)
      values (it.producto_id, d.origen_id, v_final)
      on conflict (producto_id, entidad_id) do update
      set cantidad = excluded.cantidad, updated_at = now();

      insert into public.movimientos
        (producto_id, entidad_id, tipo, cantidad, cantidad_anterior,
         nota, usuario_id, grupo_id)
      values
        (it.producto_id, d.origen_id, 'ajuste', v_final, v_actual,
         'Conteo aprobado ' || d.numero || ' - ' || v_detalle, auth.uid(), d.id);
    end if;
  end loop;

  update public.documentos_inventario
  set estado = 'aplicado', aprobado_por = auth.uid(), aprobado_at = now(),
      aplicado_at = now(), nota = concat_ws(E'\n', nota, btrim(p_nota)),
      updated_at = now(), version = version + 1
  where id = d.id;
  perform public.registrar_evento_documento(
    d.id, 'pendiente_revision', 'aplicado', v_detalle
  );
end;
$$;

alter function public.guardar_reconteo_inventario(uuid, jsonb, text) owner to postgres;
alter function public.resolver_conteo_inventario(uuid, boolean, text) owner to postgres;

revoke execute on function public.guardar_reconteo_inventario(uuid, jsonb, text)
  from public, anon;
revoke execute on function public.resolver_conteo_inventario(uuid, boolean, text)
  from public, anon;
grant execute on function public.guardar_reconteo_inventario(uuid, jsonb, text)
  to authenticated;
grant execute on function public.resolver_conteo_inventario(uuid, boolean, text)
  to authenticated;

notify pgrst, 'reload schema';

