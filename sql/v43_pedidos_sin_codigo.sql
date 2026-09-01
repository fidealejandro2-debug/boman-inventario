-- ============================================================
-- BOMAN INVENTARIO - v43: pedidos sin codigo en la reposicion
--
-- La tienda o la franquicia a veces necesita algo que todavia no existe en el
-- catalogo. Antes tenia que llamar para que alguien creara el producto y recien
-- ahi solicitarlo. Ahora la linea se pide por descripcion libre y bodega la
-- convierte a producto real antes de aprobar.
--
-- Ejecutar despues de v42.
-- ============================================================

-- 1. La linea puede nacer sin producto ------------------------------------
alter table public.documento_inventario_lineas
  alter column producto_id drop not null;

alter table public.documento_inventario_lineas
  add column if not exists descripcion_libre text;

alter table public.documento_inventario_lineas
  drop constraint if exists linea_producto_o_descripcion;
alter table public.documento_inventario_lineas
  add constraint linea_producto_o_descripcion
  check (producto_id is not null or nullif(btrim(descripcion_libre), '') is not null);

-- 2. Una linea sin producto no puede salir de la solicitud -----------------
-- El aprobador copia las lineas a la transferencia. Si alguna sigue sin
-- producto, la copia falla aqui y toda la aprobacion se revierte. Es un
-- trigger y no una validacion dentro de la funcion para que ningun camino
-- futuro (otra RPC, un insert manual) pueda saltarselo.
create or replace function public.exigir_producto_fuera_de_solicitud_v43()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if new.producto_id is null
     and (select tipo from public.documentos_inventario where id = new.documento_id)
         is distinct from 'solicitud_reposicion' then
    raise exception 'La solicitud tiene pedidos sin codigo. Crea el producto y asignalo a esa linea antes de aprobar.';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_exigir_producto_fuera_de_solicitud on public.documento_inventario_lineas;
create trigger trg_exigir_producto_fuera_de_solicitud
  before insert on public.documento_inventario_lineas
  for each row execute function public.exigir_producto_fuera_de_solicitud_v43();

-- 3. Crear solicitud aceptando lineas por descripcion ----------------------
-- Misma firma que v12: el wrapper de franquicia (crear_solicitud_reposicion_v42)
-- y la interfaz existente siguen funcionando sin cambios. Un item sin
-- producto_id ahora exige 'descripcion'.
create or replace function public.crear_solicitud_reposicion(
  p_destino_id uuid,
  p_items jsonb,
  p_prioridad text default 'normal',
  p_nota text default null,
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
  v_rol text := public.rol_usuario_actual();
begin
  if p_idempotency_key is not null then
    select id into v_id from public.documentos_inventario
    where idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;

  -- 'franquiciado' venia de un parche textual de v42 sobre esta misma funcion.
  -- Al reescribirla aqui hay que dejarlo explicito o el local pierde el acceso.
  if v_rol not in ('admin', 'control', 'bodega', 'tienda', 'franquiciado') then
    raise exception 'No tienes permiso para solicitar reposición';
  end if;
  if not public.usuario_puede_almacen(p_destino_id, true) then
    raise exception 'No tienes permiso para solicitar para ese almacén';
  end if;
  if p_prioridad not in ('normal', 'urgente') then
    raise exception 'Prioridad no válida';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La solicitud debe tener al menos un producto';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(cantidad integer)
    where coalesce(x.cantidad, 0) <= 0
  ) then
    raise exception 'La solicitud contiene cantidades inválidas';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(producto_id uuid)
    left join public.productos p on p.id = x.producto_id and p.activo
    where x.producto_id is not null and p.id is null
  ) then
    raise exception 'La solicitud contiene productos inválidos o inactivos';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(producto_id uuid, descripcion text)
    where x.producto_id is null and length(btrim(coalesce(x.descripcion, ''))) < 5
  ) then
    raise exception 'Describe el producto sin código con al menos 5 caracteres';
  end if;

  insert into public.documentos_inventario
    (numero, tipo, estado, destino_id, prioridad, nota, idempotency_key, creado_por)
  values
    (public.numero_documento_inventario('solicitud_reposicion'),
     'solicitud_reposicion', 'solicitado', p_destino_id, p_prioridad,
     nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid())
  returning id into v_id;

  -- Con codigo: se agrupan por producto, porque el documento no admite dos
  -- lineas del mismo producto.
  insert into public.documento_inventario_lineas
    (documento_id, producto_id, cantidad_solicitada, observacion)
  select v_id, x.producto_id, sum(x.cantidad)::integer, max(nullif(btrim(x.observacion), ''))
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer, observacion text)
  where x.producto_id is not null
  group by x.producto_id;

  -- Sin codigo: una linea por descripcion, sin agrupar.
  insert into public.documento_inventario_lineas
    (documento_id, producto_id, cantidad_solicitada, descripcion_libre, observacion)
  select v_id, null, x.cantidad, btrim(x.descripcion), nullif(btrim(x.observacion), '')
  from jsonb_to_recordset(p_items)
       x(producto_id uuid, cantidad integer, descripcion text, observacion text)
  where x.producto_id is null;

  perform public.registrar_evento_documento(v_id, null, 'solicitado', p_nota);
  return v_id;
end;
$fn$;

-- 4. Convertir el pedido sin codigo en producto real ----------------------
create or replace function public.asignar_producto_linea_v43(
  p_linea_id uuid,
  p_producto_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  l public.documento_inventario_lineas%rowtype;
  d public.documentos_inventario%rowtype;
  v_existente uuid;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'bodega') then
    raise exception 'No tienes permiso para asignar productos a la solicitud';
  end if;

  select * into l from public.documento_inventario_lineas where id = p_linea_id for update;
  if not found then raise exception 'La línea no existe'; end if;
  if l.producto_id is not null then
    raise exception 'Esa línea ya tiene un producto asignado';
  end if;

  select * into d from public.documentos_inventario where id = l.documento_id for update;
  if d.tipo <> 'solicitud_reposicion' or d.estado <> 'solicitado' then
    raise exception 'Solo se puede asignar el producto mientras la solicitud está pendiente';
  end if;
  if not exists (select 1 from public.productos where id = p_producto_id and activo) then
    raise exception 'El producto no existe o está inactivo';
  end if;

  select id into v_existente from public.documento_inventario_lineas
  where documento_id = l.documento_id and producto_id = p_producto_id;

  if v_existente is not null then
    update public.documento_inventario_lineas
    set cantidad_solicitada = coalesce(cantidad_solicitada, 0) + coalesce(l.cantidad_solicitada, 0),
        observacion = concat_ws(' · ', observacion, 'Incluye pedido sin código: ' || l.descripcion_libre)
    where id = v_existente;
    delete from public.documento_inventario_lineas where id = l.id;
  else
    update public.documento_inventario_lineas
    set producto_id = p_producto_id,
        observacion = concat_ws(' · ', observacion, 'Pedido sin código: ' || l.descripcion_libre)
    where id = l.id;
  end if;

  perform public.registrar_evento_documento(
    d.id, d.estado, d.estado,
    'Pedido sin código resuelto: ' || l.descripcion_libre
  );
end;
$fn$;

alter function public.exigir_producto_fuera_de_solicitud_v43() owner to postgres;
alter function public.asignar_producto_linea_v43(uuid, uuid) owner to postgres;
revoke execute on function public.asignar_producto_linea_v43(uuid, uuid) from public, anon;
grant execute on function public.asignar_producto_linea_v43(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
