-- ============================================================
-- BOMAN INVENTARIO - Incidencias de transferencia SGC v16
-- Clasificación completa, cuarentena, investigación y disposición final.
-- Ejecutar una sola vez DESPUÉS de v15.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Clasificación inequívoca de la recepción
-- ------------------------------------------------------------
alter table public.documento_inventario_lineas
  add column if not exists cantidad_no_conforme integer not null default 0
    check (cantidad_no_conforme >= 0),
  add column if not exists cantidad_no_recibida integer not null default 0
    check (cantidad_no_recibida >= 0);

-- Migra las recepciones históricas: "rechazado" se interpreta como recibido
-- físicamente pero no conforme; el saldo sin clasificar queda como no recibido.
update public.documento_inventario_lineas
set cantidad_no_conforme = coalesce(cantidad_rechazada, 0),
    cantidad_no_recibida = greatest(
      coalesce(cantidad_despachada, 0)
      - coalesce(cantidad_recibida, 0)
      - coalesce(cantidad_rechazada, 0), 0
    )
where cantidad_recibida is not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'documento_lineas_recepcion_clasificada_check'
      and conrelid = 'public.documento_inventario_lineas'::regclass
  ) then
    alter table public.documento_inventario_lineas
      add constraint documento_lineas_recepcion_clasificada_check check (
        cantidad_recibida is null
        or coalesce(cantidad_recibida, 0)
           + cantidad_no_conforme
           + cantidad_no_recibida
           = coalesce(cantidad_despachada, 0)
      );
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 2. Stock físicamente presente, pero bloqueado por no conformidad
-- ------------------------------------------------------------
create table if not exists public.inventario_cuarentena (
  producto_id uuid not null references public.productos(id),
  almacen_id uuid not null references public.almacenes(id),
  cantidad integer not null default 0 check (cantidad >= 0),
  updated_at timestamptz not null default now(),
  primary key (producto_id, almacen_id)
);

-- ------------------------------------------------------------
-- 3. No conformidad, líneas afectadas y acciones inmutables
-- ------------------------------------------------------------
create table if not exists public.incidencias_transferencia (
  id uuid primary key default gen_random_uuid(),
  documento_id uuid not null unique references public.documentos_inventario(id),
  estado text not null default 'abierta' check (
    estado in ('abierta', 'en_investigacion', 'pendiente_aprobacion', 'resuelta')
  ),
  descripcion_inicial text not null,
  causa_raiz text,
  accion_correctiva text,
  fecha_limite date not null default (current_date + 3),
  creado_por uuid not null references public.perfiles(id),
  resuelto_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resuelto_at timestamptz
);

create table if not exists public.incidencia_transferencia_lineas (
  id uuid primary key default gen_random_uuid(),
  incidencia_id uuid not null references public.incidencias_transferencia(id) on delete restrict,
  documento_linea_id uuid not null unique references public.documento_inventario_lineas(id),
  producto_id uuid not null references public.productos(id),
  cantidad_no_conforme_inicial integer not null default 0 check (cantidad_no_conforme_inicial >= 0),
  cantidad_no_recibida_inicial integer not null default 0 check (cantidad_no_recibida_inicial >= 0),
  observacion text,
  check (cantidad_no_conforme_inicial + cantidad_no_recibida_inicial > 0)
);

create table if not exists public.incidencia_transferencia_acciones (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null,
  linea_incidencia_id uuid not null references public.incidencia_transferencia_lineas(id) on delete restrict,
  origen_estado text not null check (origen_estado in ('no_recibida', 'cuarentena')),
  accion text not null check (
    accion in ('recibir_destino', 'liberar_destino', 'retornar_origen', 'perdida')
  ),
  cantidad integer not null check (cantidad > 0),
  detalle text not null,
  realizado_por uuid not null references public.perfiles(id),
  created_at timestamptz not null default now(),
  unique (grupo_id, linea_incidencia_id, origen_estado, accion),
  check (
    (origen_estado = 'no_recibida' and accion in ('recibir_destino', 'retornar_origen', 'perdida'))
    or
    (origen_estado = 'cuarentena' and accion in ('liberar_destino', 'retornar_origen', 'perdida'))
  )
);

create index if not exists idx_incidencias_transferencia_estado_limite
  on public.incidencias_transferencia(estado, fecha_limite, created_at);
create index if not exists idx_incidencia_lineas_incidencia
  on public.incidencia_transferencia_lineas(incidencia_id, producto_id);
create index if not exists idx_incidencia_acciones_linea
  on public.incidencia_transferencia_acciones(linea_incidencia_id, created_at);

alter table public.inventario_cuarentena enable row level security;
alter table public.incidencias_transferencia enable row level security;
alter table public.incidencia_transferencia_lineas enable row level security;
alter table public.incidencia_transferencia_acciones enable row level security;

create or replace function public.puede_ver_incidencia_transferencia(p_incidencia_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.incidencias_transferencia i
    where i.id = p_incidencia_id
      and public.puede_ver_documento(i.documento_id)
  );
$$;

drop policy if exists "leer_inventario_cuarentena" on public.inventario_cuarentena;
create policy "leer_inventario_cuarentena"
on public.inventario_cuarentena for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
);

drop policy if exists "leer_incidencias_transferencia" on public.incidencias_transferencia;
create policy "leer_incidencias_transferencia"
on public.incidencias_transferencia for select to authenticated using (
  public.puede_ver_documento(documento_id)
);

drop policy if exists "leer_incidencia_transferencia_lineas" on public.incidencia_transferencia_lineas;
create policy "leer_incidencia_transferencia_lineas"
on public.incidencia_transferencia_lineas for select to authenticated using (
  public.puede_ver_incidencia_transferencia(incidencia_id)
);

drop policy if exists "leer_incidencia_transferencia_acciones" on public.incidencia_transferencia_acciones;
create policy "leer_incidencia_transferencia_acciones"
on public.incidencia_transferencia_acciones for select to authenticated using (
  exists (
    select 1 from public.incidencia_transferencia_lineas l
    where l.id = linea_incidencia_id
      and public.puede_ver_incidencia_transferencia(l.incidencia_id)
  )
);

-- ------------------------------------------------------------
-- 4. Convierte diferencias abiertas de v12 en incidencias trazables
-- ------------------------------------------------------------
insert into public.incidencias_transferencia (
  documento_id, estado, descripcion_inicial, creado_por, created_at
)
select d.id, 'abierta',
       coalesce(nullif(btrim(d.nota), ''), 'Diferencia migrada desde recepción anterior a v16'),
       coalesce(d.recibido_por, d.creado_por), coalesce(d.recibido_at, d.updated_at)
from public.documentos_inventario d
where d.tipo = 'transferencia' and d.estado = 'recibido_con_diferencia'
on conflict (documento_id) do nothing;

insert into public.incidencia_transferencia_lineas (
  incidencia_id, documento_linea_id, producto_id,
  cantidad_no_conforme_inicial, cantidad_no_recibida_inicial, observacion
)
select i.id, l.id, l.producto_id, l.cantidad_no_conforme,
       l.cantidad_no_recibida, l.observacion
from public.incidencias_transferencia i
join public.documento_inventario_lineas l on l.documento_id = i.documento_id
where l.cantidad_no_conforme + l.cantidad_no_recibida > 0
on conflict (documento_linea_id) do nothing;

-- En datos históricos, "rechazado" significaba producto físicamente presente
-- pero no aceptado. Se inicia como cuarentena no disponible.
insert into public.inventario_cuarentena as q(producto_id, almacen_id, cantidad)
select il.producto_id, d.destino_id, sum(il.cantidad_no_conforme_inicial)::integer
from public.incidencia_transferencia_lineas il
join public.incidencias_transferencia i on i.id = il.incidencia_id
join public.documentos_inventario d on d.id = i.documento_id
where i.estado <> 'resuelta' and il.cantidad_no_conforme_inicial > 0
group by il.producto_id, d.destino_id
on conflict (producto_id, almacen_id) do update
set cantidad = excluded.cantidad, updated_at = now();

-- ------------------------------------------------------------
-- 5. Recepción v16: toda unidad queda clasificada
-- ------------------------------------------------------------
create or replace function public.recibir_transferencia(
  p_documento_id uuid,
  p_items jsonb,
  p_nota text default null
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  it record;
  v_recibida integer;
  v_no_conforme integer;
  v_no_recibida integer;
  v_diferencia boolean := false;
  v_estado text;
  v_incidencia_id uuid;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega', 'tienda') then
    raise exception 'No tienes permiso para recibir transferencias';
  end if;
  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'La recepción no contiene una clasificación válida';
  end if;

  select * into d from public.documentos_inventario
  where id = p_documento_id for update;
  if not found or d.tipo <> 'transferencia'
     or d.estado not in ('despachado', 'en_transito') then
    raise exception 'La transferencia no está pendiente de recepción';
  end if;
  if not public.usuario_puede_almacen(d.destino_id, true) then
    raise exception 'No tienes permiso sobre el destino';
  end if;

  for it in
    select l.*,
      (select x from jsonb_array_elements(p_items) x
       where (x->>'producto_id')::uuid = l.producto_id limit 1) as clasificacion
    from public.documento_inventario_lineas l
    where l.documento_id = d.id
    order by l.id
  loop
    if it.clasificacion is null then
      raise exception 'Debes clasificar todas las líneas de la recepción';
    end if;
    v_recibida := coalesce((it.clasificacion->>'cantidad_recibida')::integer, 0);
    v_no_conforme := coalesce(
      (it.clasificacion->>'cantidad_no_conforme')::integer,
      (it.clasificacion->>'cantidad_rechazada')::integer, 0
    );
    v_no_recibida := coalesce(
      (it.clasificacion->>'cantidad_no_recibida')::integer,
      coalesce(it.cantidad_despachada, 0) - v_recibida - v_no_conforme
    );

    if v_recibida < 0 or v_no_conforme < 0 or v_no_recibida < 0
       or v_recibida + v_no_conforme + v_no_recibida
          <> coalesce(it.cantidad_despachada, 0) then
      raise exception 'Cada línea debe clasificar exactamente todo lo despachado';
    end if;
    if public.conteo_abierto_producto(d.destino_id, it.producto_id) then
      raise exception 'Hay un conteo abierto para uno de los productos en el destino';
    end if;
    if v_no_conforme > 0 or v_no_recibida > 0 then v_diferencia := true; end if;

    if v_recibida > 0 then
      insert into public.inventario (producto_id, entidad_id, cantidad)
      values (it.producto_id, d.destino_id, v_recibida)
      on conflict (producto_id, entidad_id) do update
      set cantidad = public.inventario.cantidad + excluded.cantidad, updated_at = now();

      insert into public.movimientos
        (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota,
         usuario_id, grupo_id)
      values
        (it.producto_id, d.destino_id, d.origen_id, 'transferencia_recibo', v_recibida,
         concat('Documento ', d.numero, ' - recepción conforme',
                coalesce(' - ' || nullif(btrim(p_nota), ''), '')),
         auth.uid(), d.id);
    end if;

    if v_no_conforme > 0 then
      insert into public.inventario_cuarentena as q(producto_id, almacen_id, cantidad)
      values (it.producto_id, d.destino_id, v_no_conforme)
      on conflict (producto_id, almacen_id) do update
      set cantidad = q.cantidad + excluded.cantidad, updated_at = now();
    end if;

    update public.documento_inventario_lineas
    set cantidad_recibida = v_recibida,
        cantidad_no_conforme = v_no_conforme,
        cantidad_no_recibida = v_no_recibida,
        cantidad_rechazada = v_no_conforme + v_no_recibida,
        observacion = coalesce(
          nullif(btrim(it.clasificacion->>'observacion'), ''), observacion
        )
    where id = it.id;
  end loop;

  if v_diferencia and btrim(coalesce(p_nota, '')) = '' then
    raise exception 'La no conformidad requiere una descripción inicial';
  end if;
  v_estado := case when v_diferencia then 'recibido_con_diferencia' else 'recibido' end;

  update public.documentos_inventario
  set estado = v_estado, recibido_por = auth.uid(), recibido_at = now(),
      nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
      updated_at = now(), version = version + 1
  where id = d.id;

  if v_diferencia then
    insert into public.incidencias_transferencia (
      documento_id, estado, descripcion_inicial, creado_por
    ) values (d.id, 'abierta', btrim(p_nota), auth.uid())
    returning id into v_incidencia_id;

    insert into public.incidencia_transferencia_lineas (
      incidencia_id, documento_linea_id, producto_id,
      cantidad_no_conforme_inicial, cantidad_no_recibida_inicial, observacion
    )
    select v_incidencia_id, l.id, l.producto_id,
           l.cantidad_no_conforme, l.cantidad_no_recibida, l.observacion
    from public.documento_inventario_lineas l
    where l.documento_id = d.id
      and l.cantidad_no_conforme + l.cantidad_no_recibida > 0;
  end if;

  perform public.registrar_evento_documento(
    d.id, d.estado, v_estado,
    case when v_diferencia
      then 'No conformidad abierta: ' || btrim(p_nota)
      else coalesce(nullif(btrim(p_nota), ''), 'Recepción completa verificada')
    end
  );
  return v_estado;
end;
$$;

-- ------------------------------------------------------------
-- 6. Disposición documentada; pérdida requiere Admin
-- ------------------------------------------------------------
create or replace function public.resolver_incidencia_transferencia(
  p_incidencia_id uuid,
  p_acciones jsonb,
  p_nota text,
  p_causa_raiz text default null,
  p_accion_correctiva text default null,
  p_idempotency_key uuid default null
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.incidencias_transferencia%rowtype;
  d public.documentos_inventario%rowtype;
  li public.incidencia_transferencia_lineas%rowtype;
  it record;
  v_rol text := public.rol_usuario_actual();
  v_inicial integer;
  v_resuelto integer;
  v_disponible integer;
  v_pendiente integer;
  v_estado text;
  v_incidencia_idempotente uuid;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Control o Administración pueden resolver incidencias';
  end if;
  if btrim(coalesce(p_nota, '')) = '' then
    raise exception 'La acción debe incluir evidencia u observación';
  end if;
  if jsonb_typeof(p_acciones) <> 'array' or jsonb_array_length(p_acciones) = 0 then
    raise exception 'Selecciona al menos una disposición para las unidades pendientes';
  end if;

  select * into i from public.incidencias_transferencia
  where id = p_incidencia_id for update;
  if not found then raise exception 'La incidencia no existe'; end if;
  select * into d from public.documentos_inventario where id = i.documento_id for update;

  -- La fila de incidencia ya está bloqueada: dos reintentos simultáneos con la
  -- misma clave no pueden aplicar dos veces una disposición de inventario.
  if p_idempotency_key is not null then
    select l.incidencia_id into v_incidencia_idempotente
    from public.incidencia_transferencia_acciones a
    join public.incidencia_transferencia_lineas l on l.id = a.linea_incidencia_id
    where a.grupo_id = p_idempotency_key
    limit 1;
    if found then
      if v_incidencia_idempotente <> p_incidencia_id then
        raise exception 'La clave de idempotencia ya pertenece a otra incidencia';
      end if;
      return i.estado;
    end if;
  end if;
  if i.estado = 'resuelta' then raise exception 'La incidencia ya fue resuelta'; end if;

  for it in
    select * from jsonb_to_recordset(p_acciones) as a(
      linea_incidencia_id uuid, origen_estado text, accion text, cantidad integer
    )
  loop
    if it.linea_incidencia_id is null or coalesce(it.cantidad, 0) <= 0 then
      raise exception 'Existe una acción sin línea o cantidad válida';
    end if;
    select * into li from public.incidencia_transferencia_lineas
    where id = it.linea_incidencia_id and incidencia_id = i.id;
    if not found then raise exception 'Una acción no pertenece a esta incidencia'; end if;

    if it.origen_estado = 'no_recibida' then
      if it.accion not in ('recibir_destino', 'retornar_origen', 'perdida') then
        raise exception 'La disposición no corresponde a mercadería no recibida';
      end if;
      v_inicial := li.cantidad_no_recibida_inicial;
    elsif it.origen_estado = 'cuarentena' then
      if it.accion not in ('liberar_destino', 'retornar_origen', 'perdida') then
        raise exception 'La disposición no corresponde a mercadería en cuarentena';
      end if;
      v_inicial := li.cantidad_no_conforme_inicial;
    else
      raise exception 'El origen de la disposición no es válido';
    end if;

    select coalesce(sum(a.cantidad), 0)::integer into v_resuelto
    from public.incidencia_transferencia_acciones a
    where a.linea_incidencia_id = li.id and a.origen_estado = it.origen_estado;
    v_disponible := v_inicial - v_resuelto;
    if it.cantidad > v_disponible then
      raise exception 'La acción supera la cantidad pendiente de la línea';
    end if;
    if it.accion = 'perdida' and v_rol <> 'admin' then
      raise exception 'Las pérdidas de inventario requieren aprobación de Administración';
    end if;
    if public.conteo_abierto_producto(
      case when it.accion = 'retornar_origen' then d.origen_id else d.destino_id end,
      li.producto_id
    ) and it.accion <> 'perdida' then
      raise exception 'Hay un conteo abierto para el producto en el almacén de disposición';
    end if;

    if it.origen_estado = 'cuarentena' then
      update public.inventario_cuarentena
      set cantidad = cantidad - it.cantidad, updated_at = now()
      where producto_id = li.producto_id and almacen_id = d.destino_id
        and cantidad >= it.cantidad;
      if not found then raise exception 'El saldo de cuarentena no es suficiente'; end if;
    end if;

    if it.accion in ('recibir_destino', 'liberar_destino') then
      insert into public.inventario (producto_id, entidad_id, cantidad)
      values (li.producto_id, d.destino_id, it.cantidad)
      on conflict (producto_id, entidad_id) do update
      set cantidad = public.inventario.cantidad + excluded.cantidad, updated_at = now();

      insert into public.movimientos
        (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota,
         usuario_id, grupo_id)
      values
        (li.producto_id, d.destino_id, d.origen_id,
         case when it.accion = 'recibir_destino'
              then 'transferencia_recibo'::public.tipo_movimiento
              else 'entrada'::public.tipo_movimiento end,
         it.cantidad, 'Regularización incidencia ' || d.numero || ' - ' || btrim(p_nota),
         auth.uid(), d.id);
    elsif it.accion = 'retornar_origen' then
      insert into public.inventario (producto_id, entidad_id, cantidad)
      values (li.producto_id, d.origen_id, it.cantidad)
      on conflict (producto_id, entidad_id) do update
      set cantidad = public.inventario.cantidad + excluded.cantidad, updated_at = now();

      insert into public.movimientos
        (producto_id, entidad_id, entidad_destino_id, tipo, cantidad, nota,
         usuario_id, grupo_id)
      values
        (li.producto_id, d.origen_id, d.destino_id, 'transferencia_recibo',
         it.cantidad, 'Retorno confirmado de incidencia ' || d.numero || ' - ' || btrim(p_nota),
         auth.uid(), d.id);
    end if;

    insert into public.incidencia_transferencia_acciones (
      grupo_id, linea_incidencia_id, origen_estado, accion, cantidad,
      detalle, realizado_por
    ) values (
      coalesce(p_idempotency_key, gen_random_uuid()), li.id, it.origen_estado,
      it.accion, it.cantidad, btrim(p_nota), auth.uid()
    );
  end loop;

  select coalesce(sum(pendiente), 0)::integer into v_pendiente
  from (
    select
      greatest(l.cantidad_no_recibida_inicial - coalesce((
        select sum(a.cantidad) from public.incidencia_transferencia_acciones a
        where a.linea_incidencia_id = l.id and a.origen_estado = 'no_recibida'
      ), 0), 0)
      + greatest(l.cantidad_no_conforme_inicial - coalesce((
        select sum(a.cantidad) from public.incidencia_transferencia_acciones a
        where a.linea_incidencia_id = l.id and a.origen_estado = 'cuarentena'
      ), 0), 0) as pendiente
    from public.incidencia_transferencia_lineas l
    where l.incidencia_id = i.id
  ) saldos;

  if v_pendiente = 0 then
    if coalesce(nullif(btrim(p_causa_raiz), ''), nullif(btrim(i.causa_raiz), '')) is null then
      raise exception 'Para cerrar debes documentar la causa raíz';
    end if;
    if coalesce(nullif(btrim(p_accion_correctiva), ''), nullif(btrim(i.accion_correctiva), '')) is null then
      raise exception 'Para cerrar debes documentar la acción correctiva o preventiva';
    end if;
    update public.incidencias_transferencia
    set estado = 'resuelta',
        causa_raiz = coalesce(nullif(btrim(p_causa_raiz), ''), causa_raiz),
        accion_correctiva = coalesce(nullif(btrim(p_accion_correctiva), ''), accion_correctiva),
        resuelto_por = auth.uid(), resuelto_at = now(), updated_at = now()
    where id = i.id;
    update public.documentos_inventario
    set estado = 'cerrado_con_diferencia', revisado_por = auth.uid(),
        nota = concat_ws(E'\n', nota, btrim(p_nota)),
        updated_at = now(), version = version + 1
    where id = d.id;
    perform public.registrar_evento_documento(
      d.id, d.estado, 'cerrado_con_diferencia',
      'Incidencia resuelta. Causa: '
      || coalesce(nullif(btrim(p_causa_raiz), ''), btrim(i.causa_raiz))
      || '. Acción: '
      || coalesce(nullif(btrim(p_accion_correctiva), ''), btrim(i.accion_correctiva))
    );
    v_estado := 'resuelta';
  else
    update public.incidencias_transferencia
    set estado = 'en_investigacion',
        causa_raiz = coalesce(nullif(btrim(p_causa_raiz), ''), causa_raiz),
        accion_correctiva = coalesce(nullif(btrim(p_accion_correctiva), ''), accion_correctiva),
        updated_at = now()
    where id = i.id;
    perform public.registrar_evento_documento(
      d.id, d.estado, d.estado,
      'Avance de incidencia: ' || btrim(p_nota) || '. Pendientes: ' || v_pendiente
    );
    v_estado := 'en_investigacion';
  end if;
  return v_estado;
end;
$$;

-- El cierre legado por una simple nota queda retirado.
revoke execute on function public.cerrar_incidencia_transferencia(uuid, text)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- 7. Stock operativo: tránsito con incidencia y cuarentena visibles
-- ------------------------------------------------------------
create or replace view public.vista_stock_operativo
with (security_invoker = true) as
select
  c.producto_id, c.almacen_id, p.sku, p.nombre as producto,
  p.categoria_id, p.categoria, p.subcategoria_id, p.subcategoria,
  p.talla, p.color, p.precio, a.nombre as almacen, a.tipo as almacen_tipo,
  c.ubicacion, c.stock_minimo, c.stock_maximo, c.stock_seguridad,
  c.punto_reposicion,
  coalesce(inv.cantidad, 0) as stock_fisico,
  coalesce(res.reservado, 0) as stock_reservado,
  greatest(coalesce(inv.cantidad, 0) - coalesce(res.reservado, 0), 0) as stock_disponible,
  coalesce(te.entrada, 0) as transito_entrada,
  coalesce(ts.salida, 0) as transito_salida,
  (greatest(coalesce(inv.cantidad, 0) - coalesce(res.reservado, 0), 0) <= c.stock_minimo) as bajo_minimo,
  case
    when greatest(coalesce(inv.cantidad, 0) - coalesce(res.reservado, 0), 0)
         + coalesce(te.entrada, 0) <= c.punto_reposicion
    then greatest(
      coalesce(c.stock_maximo, c.punto_reposicion)
      - (greatest(coalesce(inv.cantidad, 0) - coalesce(res.reservado, 0), 0) + coalesce(te.entrada, 0)), 0
    ) else 0
  end as sugerido_reponer,
  inv.updated_at,
  coalesce(ti.pendiente, 0) as transito_incidencia,
  coalesce(q.cantidad, 0) as stock_cuarentena
from public.producto_almacen_config c
join public.productos p on p.id = c.producto_id and p.activo
join public.almacenes a on a.id = c.almacen_id and a.activo
left join public.inventario inv on inv.producto_id = c.producto_id and inv.entidad_id = c.almacen_id
left join lateral (
  select sum(coalesce(l.cantidad_preparada, l.cantidad_aprobada, 0))::integer reservado
  from public.documentos_inventario d
  join public.documento_inventario_lineas l on l.documento_id = d.id
  where d.tipo = 'transferencia' and d.origen_id = c.almacen_id
    and d.estado in ('aprobado', 'preparando') and l.producto_id = c.producto_id
) res on true
left join lateral (
  select sum(coalesce(l.cantidad_despachada, 0))::integer entrada
  from public.documentos_inventario d
  join public.documento_inventario_lineas l on l.documento_id = d.id
  where d.tipo = 'transferencia' and d.destino_id = c.almacen_id
    and d.estado in ('despachado', 'en_transito') and l.producto_id = c.producto_id
) te on true
left join lateral (
  select sum(coalesce(l.cantidad_despachada, 0))::integer salida
  from public.documentos_inventario d
  join public.documento_inventario_lineas l on l.documento_id = d.id
  where d.tipo = 'transferencia' and d.origen_id = c.almacen_id
    and d.estado in ('despachado', 'en_transito') and l.producto_id = c.producto_id
) ts on true
left join lateral (
  select sum(greatest(il.cantidad_no_recibida_inicial - coalesce((
    select sum(ia.cantidad) from public.incidencia_transferencia_acciones ia
    where ia.linea_incidencia_id = il.id and ia.origen_estado = 'no_recibida'
  ), 0), 0))::integer pendiente
  from public.incidencias_transferencia inc
  join public.documentos_inventario d on d.id = inc.documento_id
  join public.incidencia_transferencia_lineas il on il.incidencia_id = inc.id
  where inc.estado <> 'resuelta' and d.destino_id = c.almacen_id
    and il.producto_id = c.producto_id
) ti on true
left join public.inventario_cuarentena q
  on q.producto_id = c.producto_id and q.almacen_id = c.almacen_id
where c.activo;

-- ------------------------------------------------------------
-- 8. Propiedad y privilegios
-- ------------------------------------------------------------
alter function public.puede_ver_incidencia_transferencia(uuid) owner to postgres;
alter function public.recibir_transferencia(uuid, jsonb, text) owner to postgres;
alter function public.resolver_incidencia_transferencia(uuid, jsonb, text, text, text, uuid) owner to postgres;

revoke all on public.inventario_cuarentena from public, anon;
revoke all on public.incidencias_transferencia from public, anon;
revoke all on public.incidencia_transferencia_lineas from public, anon;
revoke all on public.incidencia_transferencia_acciones from public, anon;
revoke insert, update, delete on public.inventario_cuarentena from authenticated;
revoke insert, update, delete on public.incidencias_transferencia from authenticated;
revoke insert, update, delete on public.incidencia_transferencia_lineas from authenticated;
revoke insert, update, delete on public.incidencia_transferencia_acciones from authenticated;
grant select on public.inventario_cuarentena to authenticated;
grant select on public.incidencias_transferencia to authenticated;
grant select on public.incidencia_transferencia_lineas to authenticated;
grant select on public.incidencia_transferencia_acciones to authenticated;
grant select on public.vista_stock_operativo to authenticated;

revoke execute on function public.puede_ver_incidencia_transferencia(uuid) from public, anon;
grant execute on function public.puede_ver_incidencia_transferencia(uuid) to authenticated;
revoke execute on function public.recibir_transferencia(uuid, jsonb, text) from public, anon;
grant execute on function public.recibir_transferencia(uuid, jsonb, text) to authenticated;
revoke execute on function public.resolver_incidencia_transferencia(uuid, jsonb, text, text, text, uuid)
  from public, anon;
grant execute on function public.resolver_incidencia_transferencia(uuid, jsonb, text, text, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';
