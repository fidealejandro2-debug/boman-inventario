-- ============================================================
-- BOMAN INVENTARIO - v82: conteo fisico desde el panel de franquicia
--
-- Hoy el sistema de conteos (v12/v15/v22) ya funciona por almacen -
-- documentos_inventario.origen_id referencia almacenes(id) en general, no
-- solo bodegas propias - y usuario_puede_almacen() ya reconoce a un
-- franquiciado en SU almacen via perfil_almacenes (el mismo mecanismo que
-- usa franquicia_usuario_actual_v42). Verificado antes de escribir esto:
-- no hace falta tocar RLS ni el resolver de permisos, ya alcanza a
-- franquicias.
--
-- El unico bloqueo real son los cuatro guards de rol embebidos en las RPC
-- de creacion/guardado, que enumeran ('admin','control','bodega','tienda')
-- sin incluir los roles de franquicia. Se amplian esos cuatro, uno por uno,
-- reproduciendo el cuerpo completo tal como quedo en v12/v22 (no un parche
-- textual: son funciones chicas y ya se tiene el texto verificado entero).
--
-- Las RPC de resolucion (guardar_reconteo_inventario, resolver_conteo_inventario,
-- v15) NO se tocan a proposito: siguen exclusivas de admin/control. Es
-- exactamente el flujo pedido - el vendedor cuenta, el admin aprueba - y
-- coincide con la separacion de funciones que v15 ya dejo documentada.
--
-- Ejecutar despues de v81.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.crear_conteo_inventario(uuid,uuid[],text,uuid)') is null then
    raise exception 'Falta v12 (crear_conteo_inventario). Instalalo antes de v82';
  end if;
  if to_regprocedure('public.guardar_conteo_inventario_v22(uuid,jsonb,boolean,text,integer)') is null then
    raise exception 'Falta v22 (guardar_conteo_inventario_v22). Instalalo antes de v82';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. crear_conteo_inventario (v12) - abre el conteo
-- ------------------------------------------------------------
create or replace function public.crear_conteo_inventario(
  p_almacen_id uuid,
  p_producto_ids uuid[] default null,
  p_nota text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_rol text := public.rol_usuario_actual();
begin
  if p_idempotency_key is not null then
    select id into v_id from public.documentos_inventario where idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;
  if v_rol not in ('admin', 'control', 'bodega', 'tienda', 'franquiciado', 'vendedor_franquicia') then
    raise exception 'No tienes permiso para iniciar conteos';
  end if;
  if not public.usuario_puede_almacen(p_almacen_id, true) then
    raise exception 'No tienes permiso sobre ese almacén';
  end if;

  insert into public.documentos_inventario
    (numero, tipo, estado, origen_id, nota, idempotency_key, creado_por)
  values
    (public.numero_documento_inventario('conteo'), 'conteo', 'en_conteo',
     p_almacen_id, nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid())
  returning id into v_id;

  insert into public.documento_inventario_lineas
    (documento_id, producto_id, stock_sistema)
  select v_id, p.id, coalesce(i.cantidad, 0)
  from public.productos p
  join public.producto_almacen_config c
    on c.producto_id = p.id and c.almacen_id = p_almacen_id and c.activo
  left join public.inventario i
    on i.producto_id = p.id and i.entidad_id = p_almacen_id
  where p.activo and (p_producto_ids is null or p.id = any(p_producto_ids));

  if not exists (select 1 from public.documento_inventario_lineas where documento_id = v_id) then
    raise exception 'El conteo no contiene productos habilitados';
  end if;
  if exists (
    select 1 from public.documento_inventario_lineas nueva
    join public.documento_inventario_lineas abierta on abierta.producto_id = nueva.producto_id
    join public.documentos_inventario d on d.id = abierta.documento_id
    where nueva.documento_id = v_id and abierta.documento_id <> v_id
      and d.tipo = 'conteo' and d.origen_id = p_almacen_id
      and d.estado in ('en_conteo', 'pendiente_revision')
  ) then raise exception 'Ya existe un conteo abierto para uno de los productos'; end if;

  perform public.registrar_evento_documento(v_id, null, 'en_conteo', p_nota);
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 2. guardar_conteo_inventario (v12) - lo sigue invocando
-- guardar_conteo_inventario_v22 por dentro (perform), asi que su propio
-- guard de rol se evalua igual aunque el cliente ya no la llame directo.
-- ------------------------------------------------------------
create or replace function public.guardar_conteo_inventario(
  p_documento_id uuid,
  p_items jsonb,
  p_enviar_revision boolean default false,
  p_nota text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare d public.documentos_inventario%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'tienda', 'franquiciado', 'vendedor_franquicia') then
    raise exception 'No tienes permiso para registrar conteos';
  end if;
  select * into d from public.documentos_inventario where id = p_documento_id for update;
  if not found or d.tipo <> 'conteo' or d.estado <> 'en_conteo' then
    raise exception 'El conteo no está abierto';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacén';
  end if;

  update public.documento_inventario_lineas l
  set cantidad_contada = x.cantidad,
      observacion = coalesce(nullif(btrim(x.observacion), ''), l.observacion)
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  where l.documento_id = d.id and l.producto_id = x.producto_id and x.cantidad >= 0;

  if p_enviar_revision then
    if exists (
      select 1 from public.documento_inventario_lineas
      where documento_id = d.id and cantidad_contada is null
    ) then raise exception 'Faltan productos por contar'; end if;
    update public.documentos_inventario
    set estado = 'pendiente_revision', nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
        updated_at = now(), version = version + 1
    where id = d.id;
    perform public.registrar_evento_documento(d.id, 'en_conteo', 'pendiente_revision', p_nota);
  else
    update public.documentos_inventario set updated_at = now(), version = version + 1 where id = d.id;
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 3. abrir_edicion_conteo_v22 - tomar/continuar el conteo propio
-- ------------------------------------------------------------
create or replace function public.abrir_edicion_conteo_v22(
  p_documento_id uuid,
  p_forzar boolean default false,
  p_motivo text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_responsable_id uuid;
  v_responsable_nombre text;
  v_version integer;
  v_forzado boolean := false;
begin
  if v_rol not in ('admin', 'control', 'bodega', 'tienda', 'franquiciado', 'vendedor_franquicia') then
    raise exception 'No tienes permiso para editar conteos';
  end if;

  select * into d
  from public.documentos_inventario
  where id = p_documento_id
  for update;

  if not found or d.tipo <> 'conteo' or d.estado <> 'en_conteo' then
    raise exception 'El conteo no esta abierto';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacen';
  end if;

  v_responsable_id := coalesce(d.conteo_responsable_id, d.creado_por);
  select nombre_completo into v_responsable_nombre
  from public.perfiles where id = v_responsable_id;

  if v_responsable_id is distinct from auth.uid() then
    if v_rol <> 'admin' or not coalesce(p_forzar, false) then
      raise exception 'Conteo asignado a %. Solicita al administrador que tome el control.',
        coalesce(v_responsable_nombre, 'otro usuario');
    end if;
    if btrim(coalesce(p_motivo, '')) = '' then
      raise exception 'La toma de control requiere un motivo';
    end if;

    update public.documentos_inventario
    set conteo_responsable_id = auth.uid(),
        conteo_actividad_at = now(),
        updated_at = now(),
        version = version + 1
    where id = d.id
    returning version into v_version;

    insert into public.conteo_responsable_eventos (
      documento_id, responsable_anterior_id, responsable_nuevo_id,
      motivo, realizado_por
    ) values (
      d.id, v_responsable_id, auth.uid(), btrim(p_motivo), auth.uid()
    );

    perform public.registrar_evento_documento(
      d.id, 'en_conteo', 'en_conteo',
      'Toma de control administrativa. Responsable anterior: '
        || coalesce(v_responsable_nombre, v_responsable_id::text)
        || '. Motivo: ' || btrim(p_motivo)
    );
    v_forzado := true;
  else
    update public.documentos_inventario
    set conteo_responsable_id = auth.uid(), conteo_actividad_at = now()
    where id = d.id
    returning version into v_version;
  end if;

  select nombre_completo into v_responsable_nombre
  from public.perfiles where id = auth.uid();

  return jsonb_build_object(
    'documento_id', d.id,
    'version', v_version,
    'responsable_id', auth.uid(),
    'responsable_nombre', v_responsable_nombre,
    'actividad_at', now(),
    'toma_control', v_forzado
  );
end;
$$;

-- ------------------------------------------------------------
-- 4. guardar_conteo_inventario_v22 - guardado con bloqueo optimista
-- ------------------------------------------------------------
create or replace function public.guardar_conteo_inventario_v22(
  p_documento_id uuid,
  p_items jsonb,
  p_enviar_revision boolean,
  p_nota text,
  p_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  v_version integer;
  v_estado text;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'tienda', 'franquiciado', 'vendedor_franquicia') then
    raise exception 'No tienes permiso para registrar conteos';
  end if;

  select * into d
  from public.documentos_inventario
  where id = p_documento_id
  for update;

  if not found or d.tipo <> 'conteo' or d.estado <> 'en_conteo' then
    raise exception 'El conteo no esta abierto';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacen';
  end if;
  if coalesce(d.conteo_responsable_id, d.creado_por) is distinct from auth.uid() then
    raise exception 'El conteo pertenece a otro responsable. Abrelo o usa la toma de control administrativa.';
  end if;
  if p_version is null or p_version <> d.version then
    raise exception 'El conteo cambio en otra sesion. Recarga antes de guardar para no sobrescribir informacion.';
  end if;

  -- Reutiliza la validacion historica dentro de la misma transaccion. El
  -- bloqueo FOR UPDATE y la version ya impiden doble guardado o last-write-wins.
  perform public.guardar_conteo_inventario(
    p_documento_id, p_items, coalesce(p_enviar_revision, false), p_nota
  );

  update public.documentos_inventario
  set conteo_actividad_at = case when estado = 'en_conteo' then now() end
  where id = p_documento_id
  returning version, estado into v_version, v_estado;

  return jsonb_build_object(
    'documento_id', p_documento_id,
    'version', v_version,
    'estado', v_estado,
    'enviado_revision', v_estado = 'pendiente_revision'
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Propiedad y privilegios (sin cambios de superficie: los mismos
-- objetos, los mismos grants que ya tenian v12/v22)
-- ------------------------------------------------------------
alter function public.crear_conteo_inventario(uuid, uuid[], text, uuid) owner to postgres;
alter function public.guardar_conteo_inventario(uuid, jsonb, boolean, text) owner to postgres;
alter function public.abrir_edicion_conteo_v22(uuid, boolean, text) owner to postgres;
alter function public.guardar_conteo_inventario_v22(uuid, jsonb, boolean, text, integer) owner to postgres;

revoke execute on function public.crear_conteo_inventario(uuid, uuid[], text, uuid) from public, anon;
revoke execute on function public.guardar_conteo_inventario(uuid, jsonb, boolean, text) from public, anon, authenticated;
revoke execute on function public.abrir_edicion_conteo_v22(uuid, boolean, text) from public, anon;
revoke execute on function public.guardar_conteo_inventario_v22(uuid, jsonb, boolean, text, integer) from public, anon;
grant execute on function public.crear_conteo_inventario(uuid, uuid[], text, uuid) to authenticated;
grant execute on function public.abrir_edicion_conteo_v22(uuid, boolean, text) to authenticated;
grant execute on function public.guardar_conteo_inventario_v22(uuid, jsonb, boolean, text, integer) to authenticated;

commit;

notify pgrst, 'reload schema';
