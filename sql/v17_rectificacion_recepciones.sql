-- ============================================================
-- BOMAN INVENTARIO - Rectificación auditada de recepciones v17
-- Revierte una recepción mal registrada sin borrar su historia.
-- Ejecutar una sola vez DESPUÉS de v16.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Registro permanente de la rectificación
-- ------------------------------------------------------------
alter table public.incidencias_transferencia
  add column if not exists cierre_tipo text not null default 'disposicion'
    check (cierre_tipo in ('disposicion', 'rectificacion'));

-- Una transferencia puede volver a recibirse después de una rectificación y
-- generar una nueva no conformidad. Se conserva cada ciclo por separado.
alter table public.incidencias_transferencia
  drop constraint if exists incidencias_transferencia_documento_id_key;
create unique index if not exists uq_incidencia_transferencia_activa_documento
  on public.incidencias_transferencia(documento_id)
  where estado in ('abierta', 'en_investigacion', 'pendiente_aprobacion');

alter table public.incidencia_transferencia_lineas
  drop constraint if exists incidencia_transferencia_lineas_documento_linea_id_key;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'incidencia_linea_ciclo_documento_key'
      and conrelid = 'public.incidencia_transferencia_lineas'::regclass
  ) then
    alter table public.incidencia_transferencia_lineas
      add constraint incidencia_linea_ciclo_documento_key
      unique (incidencia_id, documento_linea_id);
  end if;
end;
$$;

create table if not exists public.rectificaciones_recepcion (
  id uuid primary key default gen_random_uuid(),
  documento_id uuid not null references public.documentos_inventario(id),
  incidencia_id uuid references public.incidencias_transferencia(id),
  estado_anterior text not null,
  recibido_por_anterior uuid references public.perfiles(id),
  recibido_at_anterior timestamptz,
  clasificacion_anterior jsonb not null,
  motivo text not null,
  realizado_por uuid not null references public.perfiles(id),
  idempotency_key uuid unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_rectificaciones_recepcion_documento_fecha
  on public.rectificaciones_recepcion(documento_id, created_at desc);

alter table public.rectificaciones_recepcion enable row level security;

drop policy if exists "leer_rectificaciones_recepcion" on public.rectificaciones_recepcion;
create policy "leer_rectificaciones_recepcion"
on public.rectificaciones_recepcion for select to authenticated using (
  public.puede_ver_documento(documento_id)
);

-- ------------------------------------------------------------
-- 2. Rectificación: exclusiva de Admin, atómica y compensatoria
-- ------------------------------------------------------------
create or replace function public.admin_rectificar_recepcion_transferencia(
  p_documento_id uuid,
  p_motivo text,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  it public.documento_inventario_lineas%rowtype;
  v_rectificacion_id uuid;
  v_incidencia_id uuid;
  v_stock_actual integer;
  v_stock_nuevo integer;
  v_clasificacion jsonb;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administración puede rectificar una recepción';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo y la evidencia de la rectificación son obligatorios';
  end if;

  select * into d from public.documentos_inventario
  where id = p_documento_id for update;
  if not found or d.tipo <> 'transferencia' then
    raise exception 'La transferencia no existe';
  end if;

  -- El bloqueo del documento serializa también los reintentos simultáneos.
  if p_idempotency_key is not null then
    select id into v_rectificacion_id
    from public.rectificaciones_recepcion
    where idempotency_key = p_idempotency_key;
    if found then
      if not exists (
        select 1 from public.rectificaciones_recepcion
        where id = v_rectificacion_id and documento_id = p_documento_id
      ) then
        raise exception 'La clave de idempotencia pertenece a otra recepción';
      end if;
      return v_rectificacion_id;
    end if;
  end if;

  if d.estado not in ('recibido', 'recibido_con_diferencia', 'cerrado_con_diferencia')
     or d.recibido_at is null then
    raise exception 'El documento no tiene una recepción rectificable';
  end if;

  select id into v_incidencia_id
  from public.incidencias_transferencia
  where documento_id = d.id and estado <> 'resuelta'
  order by created_at desc
  limit 1;

  if exists (
    select 1
    from public.incidencias_transferencia inc
    join public.incidencia_transferencia_lineas l on l.incidencia_id = inc.id
    join public.incidencia_transferencia_acciones a on a.linea_incidencia_id = l.id
    where inc.documento_id = d.id
  ) then
    raise exception 'La incidencia ya tiene disposiciones aplicadas; corrige mediante conteo controlado';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'linea_id', l.id,
    'producto_id', l.producto_id,
    'cantidad_despachada', l.cantidad_despachada,
    'cantidad_recibida', l.cantidad_recibida,
    'cantidad_no_conforme', l.cantidad_no_conforme,
    'cantidad_no_recibida', l.cantidad_no_recibida,
    'observacion', l.observacion
  ) order by l.id), '[]'::jsonb)
  into v_clasificacion
  from public.documento_inventario_lineas l
  where l.documento_id = d.id;

  insert into public.rectificaciones_recepcion (
    documento_id, incidencia_id, estado_anterior,
    recibido_por_anterior, recibido_at_anterior,
    clasificacion_anterior, motivo, realizado_por, idempotency_key
  ) values (
    d.id, v_incidencia_id, d.estado,
    d.recibido_por, d.recibido_at,
    v_clasificacion, btrim(p_motivo), auth.uid(), p_idempotency_key
  ) returning id into v_rectificacion_id;

  for it in
    select * from public.documento_inventario_lineas
    where documento_id = d.id order by id
  loop
    if coalesce(it.cantidad_recibida, 0) > 0
       or coalesce(it.cantidad_no_conforme, 0) > 0 then
      if public.conteo_abierto_producto(d.destino_id, it.producto_id) then
        raise exception 'Hay un conteo abierto para uno de los productos en el destino';
      end if;

      -- Con trazabilidad por unidades no puede probarse qué lote salió primero.
      -- Por seguridad, cualquier movimiento posterior del SKU obliga a usar conteo.
      if exists (
        select 1 from public.movimientos m
        where m.producto_id = it.producto_id
          and m.entidad_id = d.destino_id
          and m.created_at > d.recibido_at
          and m.grupo_id is distinct from d.id
          and not coalesce(m.anulado, false)
      ) then
        raise exception 'El producto tuvo movimientos posteriores a la recepción; corrige mediante conteo controlado';
      end if;
    end if;

    if coalesce(it.cantidad_recibida, 0) > 0 then
      select cantidad into v_stock_actual from public.inventario
      where producto_id = it.producto_id and entidad_id = d.destino_id
      for update;
      v_stock_actual := coalesce(v_stock_actual, 0);
      if v_stock_actual < it.cantidad_recibida then
        raise exception 'No existe stock suficiente en destino para revertir la recepción';
      end if;
      v_stock_nuevo := v_stock_actual - it.cantidad_recibida;

      update public.inventario
      set cantidad = v_stock_nuevo, updated_at = now()
      where producto_id = it.producto_id and entidad_id = d.destino_id;

      insert into public.movimientos (
        producto_id, entidad_id, entidad_destino_id, tipo,
        cantidad, cantidad_anterior, nota, usuario_id, grupo_id
      ) values (
        it.producto_id, d.destino_id, d.origen_id, 'ajuste',
        v_stock_nuevo, v_stock_actual,
        'Rectificación de recepción ' || d.numero || ' - ' || btrim(p_motivo)
        || ' [rectificación ' || v_rectificacion_id || ']',
        auth.uid(), d.id
      );
    end if;

    if coalesce(it.cantidad_no_conforme, 0) > 0 then
      update public.inventario_cuarentena
      set cantidad = cantidad - it.cantidad_no_conforme, updated_at = now()
      where producto_id = it.producto_id and almacen_id = d.destino_id
        and cantidad >= it.cantidad_no_conforme;
      if not found then
        raise exception 'El saldo de cuarentena no permite rectificar la recepción';
      end if;
    end if;
  end loop;

  if v_incidencia_id is not null then
    update public.incidencias_transferencia
    set estado = 'resuelta', cierre_tipo = 'rectificacion',
        causa_raiz = 'Error en el registro de la recepción',
        accion_correctiva = 'Recepción revertida para repetir la confirmación física: ' || btrim(p_motivo),
        resuelto_por = auth.uid(), resuelto_at = now(), updated_at = now()
    where id = v_incidencia_id;
  end if;

  update public.documento_inventario_lineas
  set cantidad_recibida = null,
      cantidad_rechazada = null,
      cantidad_no_conforme = 0,
      cantidad_no_recibida = 0,
      observacion = null
  where documento_id = d.id;

  update public.documentos_inventario
  set estado = 'en_transito', recibido_por = null, recibido_at = null,
      revisado_por = null,
      nota = concat_ws(E'\n', nota,
        'RECTIFICACIÓN DE RECEPCIÓN: ' || btrim(p_motivo)
        || ' [' || v_rectificacion_id || ']'),
      updated_at = now(), version = version + 1
  where id = d.id;

  perform public.registrar_evento_documento(
    d.id, d.estado, 'en_transito',
    'Recepción rectificada por Administración. Motivo: ' || btrim(p_motivo)
    || '. Registro: ' || v_rectificacion_id
  );

  return v_rectificacion_id;
end;
$$;

-- ------------------------------------------------------------
-- 3. Propiedad y privilegios
-- ------------------------------------------------------------
alter function public.admin_rectificar_recepcion_transferencia(uuid, text, uuid) owner to postgres;

revoke all on public.rectificaciones_recepcion from public, anon;
revoke insert, update, delete on public.rectificaciones_recepcion from authenticated;
grant select on public.rectificaciones_recepcion to authenticated;

revoke execute on function public.admin_rectificar_recepcion_transferencia(uuid, text, uuid)
  from public, anon;
grant execute on function public.admin_rectificar_recepcion_transferencia(uuid, text, uuid)
  to authenticated;

-- Sigue prohibido el cierre v12 que únicamente recibía una nota.
revoke execute on function public.cerrar_incidencia_transferencia(uuid, text)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
