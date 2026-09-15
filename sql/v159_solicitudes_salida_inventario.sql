-- ============================================================
-- v159 - Solicitudes de salida de inventario con aprobacion.
--
-- Hoy 'tienda' no puede sacar inventario del sistema de ninguna forma (solo
-- puede pedir reposicion/entrada, via crear_solicitud_reposicion). Este
-- archivo agrega un tipo de documento nuevo 'salida' al mismo modelo de
-- documentos_inventario que ya usan las solicitudes de reposicion y las
-- transferencias (sql/v12_fase_erp_operativa.sql) -mismo patron de
-- crear_X/resolver_X + documento_inventario_eventos como historial-, en vez
-- de inventar una tabla paralela.
--
-- Quien pide: tienda (y admin). Quien aprueba: bodega, supervisor y admin.
-- A diferencia de una transferencia, una salida no tiene destino: al
-- aprobarla se descuenta el stock de inmediato (tipo_movimiento 'salida'),
-- no queda en transito hacia otro almacen.
--
-- Ejecutar despues de v152 (rol supervisor) y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v159', 0));

do $requisitos$
begin
  if to_regclass('public.documentos_inventario') is null
     or to_regprocedure('public.numero_documento_inventario(text)') is null
     or to_regprocedure('public.registrar_evento_documento(uuid,text,text,text)') is null then
    raise exception 'Falta v12: instala primero los documentos operativos de inventario';
  end if;
  if to_regprocedure('public.aplicar_movimiento_stock_v20(uuid,uuid,uuid,public.tipo_movimiento,integer,uuid,text,text,uuid,uuid,uuid)') is null then
    raise exception 'Falta v20: instala primero aplicar_movimiento_stock_v20';
  end if;
  if not exists (
    select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'rol_usuario' and e.enumlabel = 'supervisor'
  ) then
    raise exception 'Falta v152 (rol supervisor): instalalo antes de v159';
  end if;
end;
$requisitos$;

-- ------------------------------------------------------------
-- 1. Nuevo tipo de documento 'salida' (mismo check, se amplia)
-- ------------------------------------------------------------
alter table public.documentos_inventario
  drop constraint if exists documentos_inventario_tipo_check;
alter table public.documentos_inventario
  add constraint documentos_inventario_tipo_check
  check (tipo in ('solicitud_reposicion', 'transferencia', 'conteo', 'salida'));

create sequence if not exists public.seq_salida_inventario;

-- 'supervisor' (v152) nunca recibio 'operaciones.acceder': sin esto podria
-- resolver la salida via RPC pero jamas veria la pantalla /operaciones para
-- hacerlo. Ya esta sembrado en false por v35 (todos los roles); solo falta
-- encenderlo para este rol.
update public.rol_permisos set permitido = true, updated_at = now()
where rol::text = 'supervisor' and permiso_codigo = 'operaciones.acceder';

create or replace function public.numero_documento_inventario(p_tipo text)
returns text
language plpgsql
security definer
set search_path = ''
as $v159$
declare
  v_num bigint;
  v_prefijo text;
begin
  if p_tipo = 'solicitud_reposicion' then
    v_num := nextval('public.seq_solicitud_reposicion'); v_prefijo := 'SR';
  elsif p_tipo = 'transferencia' then
    v_num := nextval('public.seq_transferencia_inventario'); v_prefijo := 'TR';
  elsif p_tipo = 'conteo' then
    v_num := nextval('public.seq_conteo_inventario'); v_prefijo := 'CT';
  elsif p_tipo = 'salida' then
    v_num := nextval('public.seq_salida_inventario'); v_prefijo := 'SA';
  else
    raise exception 'Tipo de documento no válido';
  end if;
  return v_prefijo || '-' || to_char(now() at time zone 'America/Guayaquil', 'YYYY')
         || '-' || lpad(v_num::text, 6, '0');
end;
$v159$;

-- ------------------------------------------------------------
-- 2. Crear la solicitud (tienda / admin)
-- ------------------------------------------------------------
create or replace function public.crear_solicitud_salida_v159(
  p_almacen_id uuid,
  p_items jsonb,
  p_motivo text,
  p_prioridad text default 'normal',
  p_idempotency_key uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $v159$
declare
  v_id uuid;
  v_rol text := public.rol_usuario_actual();
begin
  if p_idempotency_key is not null then
    select id into v_id from public.documentos_inventario
    where idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;

  if v_rol not in ('admin', 'tienda') then
    raise exception 'No tienes permiso para solicitar una salida de inventario';
  end if;
  if not public.usuario_puede_almacen(p_almacen_id, true) then
    raise exception 'No tienes permiso sobre ese almacen';
  end if;
  if p_prioridad not in ('normal', 'urgente') then
    raise exception 'Prioridad no válida';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 5 then
    raise exception 'Explica el motivo de la salida (minimo 5 caracteres)';
  end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La salida debe tener al menos un producto';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer)
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or coalesce(x.cantidad, 0) <= 0
  ) then
    raise exception 'La salida contiene productos o cantidades invalidas';
  end if;
  if exists (
    select producto_id from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer)
    group by producto_id having count(*) > 1
  ) then
    raise exception 'La salida contiene productos repetidos';
  end if;

  insert into public.documentos_inventario
    (numero, tipo, estado, origen_id, prioridad, nota, idempotency_key, creado_por)
  values
    (public.numero_documento_inventario('salida'), 'salida', 'solicitado',
     p_almacen_id, p_prioridad, btrim(p_motivo), p_idempotency_key, auth.uid())
  returning id into v_id;

  insert into public.documento_inventario_lineas
    (documento_id, producto_id, cantidad_solicitada)
  select v_id, x.producto_id, sum(x.cantidad)::integer
  from jsonb_to_recordset(p_items) x(producto_id uuid, cantidad integer)
  group by x.producto_id;

  perform public.registrar_evento_documento(v_id, null, 'solicitado', p_motivo);

  insert into public.notificaciones_comunicados(
    origen_clave, origen_tipo, almacen_id, rol_destino,
    modulo, nivel, titulo, mensaje, href, creado_por
  )
  select 'salida_inventario:' || v_id::text || ':' || r.rol::text,
    'salida_inventario', p_almacen_id, r.rol, 'Inventario', 'accion',
    'Salida de inventario por aprobar',
    'Se solicito una salida de inventario. Motivo: ' || btrim(p_motivo),
    '/operaciones', auth.uid()
  from unnest(array['bodega', 'supervisor']::public.rol_usuario[]) r(rol)
  on conflict (origen_clave) do nothing;

  return v_id;
end;
$v159$;

-- ------------------------------------------------------------
-- 3. Resolver (bodega / supervisor / admin): aprobar aplica el descuento de
--    stock de inmediato (no hay destino ni transito); rechazar solo cierra
--    el documento con motivo.
-- ------------------------------------------------------------
create or replace function public.resolver_solicitud_salida_v159(
  p_solicitud_id uuid,
  p_aprobar boolean,
  p_nota text default null,
  p_idempotency_key uuid default null
) returns void
language plpgsql
security definer
set search_path = ''
as $v159$
declare
  s public.documentos_inventario%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_empresa_id uuid;
  it record;
begin
  if v_rol not in ('admin', 'bodega', 'supervisor') then
    raise exception 'No tienes permiso para resolver salidas de inventario';
  end if;

  select * into s from public.documentos_inventario
  where id = p_solicitud_id for update;
  if not found or s.tipo <> 'salida' then
    raise exception 'La solicitud de salida no existe';
  end if;
  if s.estado <> 'solicitado' then
    raise exception 'La solicitud ya fue procesada';
  end if;
  if not public.usuario_puede_almacen(s.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacen de esta solicitud';
  end if;

  if not p_aprobar then
    if btrim(coalesce(p_nota, '')) = '' then
      raise exception 'Debes indicar el motivo del rechazo';
    end if;
    update public.documentos_inventario
    set estado = 'rechazado', revisado_por = auth.uid(),
        nota = concat_ws(E'\n', nota, btrim(p_nota)),
        updated_at = now(), version = version + 1
    where id = s.id;
    perform public.registrar_evento_documento(s.id, 'solicitado', 'rechazado', p_nota);
  else
    if p_idempotency_key is null then
      raise exception 'La clave de idempotencia es obligatoria para aprobar';
    end if;

    select e.id into v_empresa_id
    from public.empresa_almacenes ea
    join public.empresas e on e.id = ea.empresa_id and e.activo
    where ea.almacen_id = s.origen_id and ea.es_operadora_principal;
    if v_empresa_id is null then
      raise exception 'El almacen no tiene una empresa operadora principal configurada';
    end if;

    for it in
      select * from public.documento_inventario_lineas where documento_id = s.id
    loop
      perform public.aplicar_movimiento_stock_v20(
        it.producto_id, s.origen_id, v_empresa_id, 'salida'::public.tipo_movimiento,
        -it.cantidad_solicitada, s.id, 'solicitud_salida', s.nota,
        null, null, md5(p_idempotency_key::text || ':' || it.producto_id::text)::uuid
      );
      update public.documento_inventario_lineas
      set cantidad_aprobada = it.cantidad_solicitada
      where id = it.id;
    end loop;

    update public.documentos_inventario
    set estado = 'aplicado', aprobado_por = auth.uid(), aprobado_at = now(),
        nota = concat_ws(E'\n', nota, nullif(btrim(p_nota), '')),
        updated_at = now(), version = version + 1
    where id = s.id;
    perform public.registrar_evento_documento(s.id, 'solicitado', 'aplicado', p_nota);
  end if;

  insert into public.notificaciones_comunicados(
    origen_clave, origen_tipo, almacen_id, usuario_destino_id,
    modulo, nivel, titulo, mensaje, href, creado_por
  ) values (
    'salida_inventario:' || s.id::text || ':resuelta:' || s.creado_por::text,
    'salida_inventario', s.origen_id, s.creado_por, 'Inventario', 'informativa',
    case when p_aprobar then 'Salida de inventario aprobada' else 'Salida de inventario rechazada' end,
    s.numero || (case when p_aprobar then ' fue aprobada y se aplico al stock.' else ' fue rechazada: ' || coalesce(btrim(p_nota), '') end),
    '/operaciones', auth.uid()
  ) on conflict (origen_clave) do nothing;
end;
$v159$;

-- ------------------------------------------------------------
-- 4. Grants (RLS de documentos_inventario/lineas/eventos ya es generica por
--    origen_id/destino_id -sql/v12_fase_erp_operativa.sql:410-448- y cubre
--    el tipo 'salida' sin cambios).
-- ------------------------------------------------------------
alter function public.numero_documento_inventario(text) owner to postgres;
alter function public.crear_solicitud_salida_v159(uuid,jsonb,text,text,uuid) owner to postgres;
alter function public.resolver_solicitud_salida_v159(uuid,boolean,text,uuid) owner to postgres;

revoke all on function public.crear_solicitud_salida_v159(uuid,jsonb,text,text,uuid) from public, anon;
revoke all on function public.resolver_solicitud_salida_v159(uuid,boolean,text,uuid) from public, anon;
grant execute on function public.crear_solicitud_salida_v159(uuid,jsonb,text,text,uuid),
  public.resolver_solicitud_salida_v159(uuid,boolean,text,uuid)
  to authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v159', 159, 'v159_solicitudes_salida_inventario.sql',
  'Solicitudes de salida de inventario para tienda, con aprobacion de bodega/supervisor/admin (nuevo tipo salida en documentos_inventario).'
)
on conflict (id) do update set version=excluded.version, archivo=excluded.archivo,
  notas=excluded.notas, aplicada_at=now();

notify pgrst, 'reload schema';
commit;
