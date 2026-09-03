-- ============================================================
-- BOMAN INVENTARIO - v71: caja diaria tambien para tiendas propias
--
-- Hasta ahora el diario de caja (ingresos/egresos + cierre con efectivo
-- esperado vs contado) era exclusivo de franquicias, todo anclado a
-- franquicia_id. Una tienda propia (almacen tipo='tienda' SIN fila en
-- franquicias, ver v64) no tenia ningun control de efectivo.
--
-- Generaliza la clave de las tablas de caja a almacen_id (franquicia_id
-- se vuelve opcional: se llena solo para filas de franquicia). El flujo
-- de franquicia queda intacto -mismo camino de codigo, misma funcion
-- franquicia_usuario_actual_v42()-; se agrega un camino nuevo para el rol
-- 'tienda', resuelto via perfil_almacenes (el mismo mecanismo generico que
-- ya usan bodega/control/tienda para todo lo demas).
--
-- Ejecutar despues de v64 y v49.
-- ============================================================

do $$
begin
  if to_regprocedure('public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid)') is null
     or to_regprocedure('public.resumen_consolidado_tiendas_v64(date,date)') is null
     or to_regprocedure('public.usuario_puede_almacen(uuid,boolean)') is null then
    raise exception 'Faltan dependencias. Instala y valida hasta v64 y v49 antes de v71';
  end if;
  -- Mas abajo se apaga este trigger para poder hacer el backfill; si no
  -- existiera, el alter table fallaria con un error mucho menos claro.
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.franquicia_caja_movimientos'::regclass
      and tgname = 'trg_bloquear_caja_cerrada_v47'
      and not tgisinternal
  ) then
    raise exception 'Falta el trigger trg_bloquear_caja_cerrada_v47 (v47). Instala y valida v47 antes de v71';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. almacen_id en las dos tablas de caja
-- ------------------------------------------------------------
alter table public.franquicia_caja_movimientos
  add column if not exists almacen_id uuid references public.almacenes(id) on delete restrict;
alter table public.franquicia_caja_cierres
  add column if not exists almacen_id uuid references public.almacenes(id) on delete restrict;

-- El backfill es una UPDATE sobre franquicia_caja_movimientos, y esa tabla
-- tiene el trigger de dia cerrado (bloquear_caja_cerrada_v47): sin esto, la
-- migracion se cae contra cualquier franquicia con un dia real ya cerrado.
-- Es solo para llenar la columna nueva -no cambia fecha, monto ni estado de
-- ninguna fila- asi que apagarlo aqui es seguro.
alter table public.franquicia_caja_movimientos disable trigger trg_bloquear_caja_cerrada_v47;

update public.franquicia_caja_movimientos m
set almacen_id = f.almacen_id
from public.franquicias f
where m.franquicia_id = f.id and m.almacen_id is null;

alter table public.franquicia_caja_movimientos enable trigger trg_bloquear_caja_cerrada_v47;

update public.franquicia_caja_cierres c
set almacen_id = f.almacen_id
from public.franquicias f
where c.franquicia_id = f.id and c.almacen_id is null;

do $$
begin
  if exists (select 1 from public.franquicia_caja_movimientos where almacen_id is null)
     or exists (select 1 from public.franquicia_caja_cierres where almacen_id is null) then
    raise exception 'Quedaron filas de caja sin almacen_id tras el backfill; revisa antes de continuar';
  end if;
end $$;

alter table public.franquicia_caja_movimientos alter column almacen_id set not null;
alter table public.franquicia_caja_cierres alter column almacen_id set not null;
alter table public.franquicia_caja_movimientos alter column franquicia_id drop not null;
alter table public.franquicia_caja_cierres alter column franquicia_id drop not null;

-- El unique(franquicia_id, fecha) no protegia nada para filas de tienda propia
-- (franquicia_id null no choca nunca con otro null). almacen_id es unico por
-- franquicia (franquicias.almacen_id ya es unique), asi que lo reemplaza sin
-- cambiar el comportamiento para franquicias.
alter table public.franquicia_caja_cierres
  drop constraint if exists franquicia_caja_cierres_franquicia_id_fecha_key;
-- add constraint no admite "if not exists": sin el guard, re-ejecutar el
-- archivo tras un fallo parcial se cae con "constraint already exists".
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.franquicia_caja_cierres'::regclass
      and conname = 'franquicia_caja_cierres_almacen_id_fecha_key'
  ) then
    alter table public.franquicia_caja_cierres
      add constraint franquicia_caja_cierres_almacen_id_fecha_key unique (almacen_id, fecha);
  end if;
end $$;

create index if not exists idx_caja_almacen_fecha_v71
  on public.franquicia_caja_movimientos(almacen_id, fecha desc, created_at desc);
create index if not exists idx_caja_cierres_almacen_v71
  on public.franquicia_caja_cierres(almacen_id, fecha desc);

comment on column public.franquicia_caja_movimientos.almacen_id is
  'Local operativo de este movimiento. Para franquicias, coincide con franquicias.almacen_id; para tiendas propias, franquicia_id queda null.';
comment on column public.franquicia_caja_cierres.almacen_id is
  'Igual criterio que franquicia_caja_movimientos.almacen_id.';

-- ------------------------------------------------------------
-- 2. Permiso: el rol tienda puede operar caja (admin lo ajusta despues
--    desde Administracion -> Permisos si alguna vez quiere restringirlo)
-- ------------------------------------------------------------
-- Upsert y no update a secas: si por lo que sea la fila (tienda x
-- franquicia.caja) no estuviera en la matriz, un update seria un no-op
-- silencioso y el permiso nunca se encenderia.
insert into public.rol_permisos (rol, permiso_codigo, permitido)
values ('tienda', 'franquicia.caja', true)
on conflict (rol, permiso_codigo) do update
  set permitido = true, updated_at = now();

-- ------------------------------------------------------------
-- 3. Resolver: el almacen (y franquicia, si aplica) que opera el usuario
--    actual para efectos de caja. Prueba primero el camino de franquicia
--    -identico al que ya existia-; solo si no aplica, prueba tienda propia.
-- ------------------------------------------------------------
create or replace function public.almacen_caja_operativo_v71()
returns table(almacen_id uuid, franquicia_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_franquicia_id uuid;
  v_almacen_id uuid;
  v_count integer;
begin
  v_franquicia_id := public.franquicia_usuario_actual_v42();
  if v_franquicia_id is not null then
    select f.almacen_id into v_almacen_id from public.franquicias f where f.id = v_franquicia_id;
    return query select v_almacen_id, v_franquicia_id;
    return;
  end if;

  if public.rol_usuario_actual() = 'tienda'
     and public.usuario_tiene_permiso_v35('franquicia.caja') then
    -- (array_agg(...))[1] y no min(a.id): min() sobre uuid recien existe desde
    -- PostgreSQL 14, y array_agg funciona en cualquier version.
    select count(*), (array_agg(a.id))[1] into v_count, v_almacen_id
    from public.perfiles p
    join public.perfil_almacenes pa on pa.perfil_id = p.id
    join public.almacenes a on a.id = pa.almacen_id and a.activo and a.tipo = 'tienda'
    where p.id = auth.uid() and p.activo
      and not exists (
        select 1 from public.franquicias ff where ff.almacen_id = a.id and ff.activo
      );
    if v_count = 1 then
      return query select v_almacen_id, null::uuid;
    elsif v_count > 1 then
      raise exception 'Tienes mas de una tienda asignada; pide a Administracion que deje solo una para operar su caja';
    end if;
  end if;
  return;
end;
$fn$;

alter function public.almacen_caja_operativo_v71() owner to postgres;
revoke execute on function public.almacen_caja_operativo_v71() from public, anon;
grant execute on function public.almacen_caja_operativo_v71() to authenticated;

-- ------------------------------------------------------------
-- 4. RPCs de caja: mismo camino de franquicia intacto, mas el camino tienda
-- ------------------------------------------------------------
create or replace function public.registrar_caja_franquicia_v42(
  p_fecha date,
  p_tipo text,
  p_categoria text,
  p_concepto text,
  p_monto numeric,
  p_medio_pago text,
  p_referencia text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_op record; v_id uuid;
begin
  if public.rol_usuario_actual() not in ('franquiciado', 'tienda')
     or not public.usuario_tiene_permiso_v35('franquicia.caja') then
    raise exception 'No tienes permiso para registrar movimientos de caja';
  end if;
  select * into v_op from public.almacen_caja_operativo_v71();
  if v_op.almacen_id is null then raise exception 'No tienes un local activo asignado para caja'; end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.franquicia_caja_movimientos where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  if p_fecha is null or p_fecha > current_date then raise exception 'La fecha no es valida'; end if;
  if p_tipo not in ('ingreso', 'egreso') then raise exception 'El tipo no es valido'; end if;
  if btrim(coalesce(p_categoria, '')) = '' or btrim(coalesce(p_concepto, '')) = '' then
    raise exception 'La categoria y el concepto son obligatorios';
  end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_medio_pago not in ('efectivo', 'transferencia', 'tarjeta', 'mixto', 'otro') then
    raise exception 'El medio de pago no es valido';
  end if;
  insert into public.franquicia_caja_movimientos (
    franquicia_id, almacen_id, fecha, tipo, categoria, concepto, monto, medio_pago,
    referencia, idempotency_key, creado_por
  ) values (
    v_op.franquicia_id, v_op.almacen_id, p_fecha, p_tipo, btrim(p_categoria), btrim(p_concepto),
    round(p_monto, 2), p_medio_pago, nullif(btrim(p_referencia), ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;
  return v_id;
end;
$fn$;

create or replace function public.revertir_caja_franquicia_v42(
  p_movimiento_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare m public.franquicia_caja_movimientos%rowtype; v_id uuid;
begin
  if public.rol_usuario_actual() not in ('admin', 'franquiciado', 'tienda') then
    raise exception 'No tienes permiso para revertir caja';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Explica el motivo de la reversa'; end if;
  select id into v_id from public.franquicia_caja_movimientos where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  select * into m from public.franquicia_caja_movimientos where id = p_movimiento_id for update;
  if not found then raise exception 'El movimiento no existe'; end if;
  if public.rol_usuario_actual() <> 'admin' and not (
    (m.franquicia_id is not null and public.usuario_puede_franquicia_v42(m.franquicia_id, true, true))
    or (
      m.franquicia_id is null and public.rol_usuario_actual() = 'tienda'
      and public.usuario_puede_almacen(m.almacen_id, true)
      and public.usuario_tiene_permiso_v35('franquicia.caja')
    )
  ) then
    raise exception 'No tienes acceso a esta caja';
  end if;
  if m.estado <> 'vigente' or m.reversa_de_id is not null then raise exception 'El movimiento ya fue revertido'; end if;
  update public.franquicia_caja_movimientos
  set estado = 'revertido', motivo_reversa = btrim(p_motivo)
  where id = m.id;
  insert into public.franquicia_caja_movimientos (
    franquicia_id, almacen_id, fecha, tipo, categoria, concepto, monto, medio_pago,
    referencia, reversa_de_id, motivo_reversa, idempotency_key, creado_por
  ) values (
    m.franquicia_id, m.almacen_id, current_date,
    case when m.tipo = 'ingreso' then 'egreso' else 'ingreso' end,
    'reversa', 'Reversa: ' || m.concepto, m.monto, m.medio_pago,
    m.referencia, m.id, btrim(p_motivo), p_idempotency_key, auth.uid()
  ) returning id into v_id;
  return v_id;
end;
$fn$;

-- El parametro pasa de p_franquicia_id a p_almacen_id, y Postgres no permite
-- renombrar un parametro con create or replace: hay que soltarla primero.
-- Nadie mas depende de ella (cerrar_caja_franquicia_v49 la resuelve en tiempo
-- de ejecucion, no por dependencia dura), y mas abajo se le devuelven el
-- owner y los grants.
drop function if exists public.saldo_inicial_caja_franquicia_v49(uuid, date);

create or replace function public.saldo_inicial_caja_franquicia_v49(
  p_almacen_id uuid,
  p_fecha date
) returns numeric
language sql
stable
security definer
set search_path = ''
as $fn$
  with anterior as (
    select fecha, efectivo_contado
    from public.franquicia_caja_cierres
    where almacen_id = p_almacen_id
      and fecha < p_fecha
      and estado = 'cerrado'
    order by fecha desc
    limit 1
  ),
  intermedios as (
    select coalesce(sum(
      case when m.tipo = 'ingreso' then m.monto else -m.monto end
    ), 0) as neto
    from public.franquicia_caja_movimientos m, anterior a
    where m.almacen_id = p_almacen_id
      and m.medio_pago = 'efectivo'
      and m.estado = 'vigente'
      and m.reversa_de_id is null
      and m.fecha > a.fecha
      and m.fecha < p_fecha
  )
  select round(a.efectivo_contado + i.neto, 2)
  from anterior a, intermedios i;
$fn$;

create or replace function public.cerrar_caja_franquicia_v49(
  p_fecha date,
  p_saldo_inicial_efectivo numeric,
  p_efectivo_contado numeric,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_op record;
  c public.franquicia_caja_cierres%rowtype;
  v_ing_ef numeric(14,2);
  v_egr_ef numeric(14,2);
  v_ing numeric(14,2);
  v_egr numeric(14,2);
  v_esperado numeric(14,2);
  v_inicial numeric(14,2);
  v_derivado numeric(14,2);
  v_origen text;
begin
  if public.rol_usuario_actual() not in ('franquiciado', 'tienda')
     or not public.usuario_tiene_permiso_v35('franquicia.caja') then
    raise exception 'No tienes permiso para cerrar esta caja';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into v_op from public.almacen_caja_operativo_v71();
  if v_op.almacen_id is null then raise exception 'No tienes un local activo asignado para caja'; end if;

  select cc.* into c
  from public.franquicia_caja_cierres cc
  left join public.franquicia_caja_cierre_eventos e on e.cierre_id = cc.id
  where cc.almacen_id = v_op.almacen_id
    and (cc.idempotency_key = p_idempotency_key or e.idempotency_key = p_idempotency_key)
  limit 1;
  if found then return to_jsonb(c); end if;

  if p_fecha is null or p_fecha > (now() at time zone 'America/Guayaquil')::date then
    raise exception 'La fecha de cierre no es valida';
  end if;
  if coalesce(p_efectivo_contado, -1) < 0 then
    raise exception 'El efectivo contado no puede ser negativo';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_op.almacen_id::text || p_fecha::text, 47));
  select * into c from public.franquicia_caja_cierres
  where almacen_id = v_op.almacen_id and fecha = p_fecha for update;
  if found and c.estado = 'cerrado' then raise exception 'La caja de ese dia ya esta cerrada'; end if;

  v_derivado := public.saldo_inicial_caja_franquicia_v49(v_op.almacen_id, p_fecha);
  if v_derivado is null then
    if coalesce(p_saldo_inicial_efectivo, -1) < 0 then
      raise exception 'Es el primer cierre del local: indica con cuanto efectivo arranca la caja';
    end if;
    v_inicial := round(p_saldo_inicial_efectivo, 2);
    v_origen := 'declarado';
  else
    v_inicial := greatest(v_derivado, 0);
    v_origen := 'derivado';
  end if;

  select
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'egreso' and m.medio_pago = 'efectivo'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'egreso'), 0)
  into v_ing_ef, v_egr_ef, v_ing, v_egr
  from public.franquicia_caja_movimientos m
  where m.almacen_id = v_op.almacen_id and m.fecha = p_fecha
    and m.estado = 'vigente' and m.reversa_de_id is null;

  v_esperado := round(v_inicial + v_ing_ef - v_egr_ef, 2);

  if c.id is null then
    insert into public.franquicia_caja_cierres (
      franquicia_id, almacen_id, fecha, saldo_inicial_efectivo, saldo_inicial_origen,
      ingresos_efectivo, egresos_efectivo, saldo_esperado_efectivo,
      efectivo_contado, diferencia, ingresos_total, egresos_total,
      nota, idempotency_key, cerrado_por
    ) values (
      v_op.franquicia_id, v_op.almacen_id, p_fecha, v_inicial, v_origen, v_ing_ef, v_egr_ef, v_esperado,
      round(p_efectivo_contado, 2), round(p_efectivo_contado - v_esperado, 2),
      v_ing, v_egr, nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid()
    ) returning * into c;
  else
    update public.franquicia_caja_cierres set
      estado = 'cerrado', saldo_inicial_efectivo = v_inicial,
      saldo_inicial_origen = v_origen,
      ingresos_efectivo = v_ing_ef, egresos_efectivo = v_egr_ef,
      saldo_esperado_efectivo = v_esperado,
      efectivo_contado = round(p_efectivo_contado, 2),
      diferencia = round(p_efectivo_contado - v_esperado, 2),
      ingresos_total = v_ing, egresos_total = v_egr,
      nota = nullif(btrim(p_nota), ''), idempotency_key = p_idempotency_key,
      cerrado_por = auth.uid(), cerrado_at = now(),
      motivo_reapertura = null, reabierto_por = null, reabierto_at = null
    where id = c.id returning * into c;
  end if;

  insert into public.franquicia_caja_cierre_eventos(
    cierre_id, tipo, detalle, usuario_id, idempotency_key
  ) values (
    c.id, 'cerrado',
    'Cierre diario confirmado. Saldo inicial ' || v_origen ||
    ' de ' || c.saldo_inicial_efectivo || '. Diferencia: ' || c.diferencia,
    auth.uid(), p_idempotency_key
  );
  return to_jsonb(c);
end;
$fn$;

create or replace function public.reabrir_caja_franquicia_v47(
  p_cierre_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare c public.franquicia_caja_cierres%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'franquiciado', 'tienda') then
    raise exception 'No tienes permiso para reabrir esta caja';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica la reapertura con al menos 10 caracteres';
  end if;
  select * into c from public.franquicia_caja_cierres where id = p_cierre_id for update;
  if not found then raise exception 'El cierre no existe'; end if;
  if public.rol_usuario_actual() <> 'admin' and not (
    (c.franquicia_id is not null and public.usuario_puede_franquicia_v42(c.franquicia_id, true, true))
    or (
      c.franquicia_id is null and public.rol_usuario_actual() = 'tienda'
      and public.usuario_puede_almacen(c.almacen_id, true)
      and public.usuario_tiene_permiso_v35('franquicia.caja')
    )
  ) then raise exception 'No tienes acceso a ese cierre'; end if;
  if c.estado <> 'cerrado' then raise exception 'El cierre ya esta reabierto'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(c.almacen_id::text || c.fecha::text, 47)
  );
  update public.franquicia_caja_cierres
  set estado = 'reabierto', motivo_reapertura = btrim(p_motivo),
      reabierto_por = auth.uid(), reabierto_at = now()
  where id = c.id;
  insert into public.franquicia_caja_cierre_eventos(cierre_id, tipo, detalle, usuario_id)
  values (c.id, 'reabierto', btrim(p_motivo), auth.uid());
end;
$fn$;

-- La reversa de una factura anulada respeta el candado del dia, ahora por
-- almacen_id (antes comparaba franquicia_id, que en tienda propia es null y
-- nunca calzaba con si mismo).
create or replace function public.revertir_caja_factura_franquicia_v45(
  p_documento_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  m public.franquicia_caja_movimientos%rowtype;
  v_cerrado date;
begin
  select min(mm.fecha) into v_cerrado
  from public.franquicia_caja_movimientos mm
  join public.franquicia_caja_cierres cc
    on cc.almacen_id = mm.almacen_id and cc.fecha = mm.fecha and cc.estado = 'cerrado'
  where mm.documento_xml_id = p_documento_id and mm.estado = 'vigente'
    and mm.reversa_de_id is null;
  if v_cerrado is not null then
    raise exception
      'El ingreso de esa factura esta en la caja del % , que ya fue cerrada. Reabre ese dia con un motivo y vuelve a anular.',
      to_char(v_cerrado, 'DD/MM/YYYY');
  end if;

  for m in
    select * from public.franquicia_caja_movimientos
    where documento_xml_id = p_documento_id and estado = 'vigente'
      and reversa_de_id is null
    order by documento_pago_numero nulls last, id for update
  loop
    update public.franquicia_caja_movimientos
    set estado = 'revertido', motivo_reversa = btrim(p_motivo)
    where id = m.id;
    insert into public.franquicia_caja_movimientos (
      franquicia_id, almacen_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, reversa_de_id, motivo_reversa, idempotency_key, creado_por
    ) values (
      m.franquicia_id, m.almacen_id, (now() at time zone 'America/Guayaquil')::date,
      case when m.tipo = 'ingreso' then 'egreso' else 'ingreso' end,
      'reversa', 'Anulacion ' || m.concepto, m.monto, m.medio_pago,
      m.referencia, m.id, btrim(p_motivo), gen_random_uuid(),
      coalesce(auth.uid(), m.creado_por)
    );
  end loop;
end;
$fn$;

-- ------------------------------------------------------------
-- 5. Trigger de dia cerrado: la clave pasa de franquicia_id a almacen_id
--    (con franquicia_id, una fila de tienda propia -null- nunca calzaba
--    consigo misma y el candado no protegia nada ahi).
-- ------------------------------------------------------------
create or replace function public.bloquear_caja_cerrada_v47()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_almacen uuid;
  v_fecha date;
  v_clave_actual bigint;
  v_clave_anterior bigint;
begin
  v_almacen := case when tg_op = 'DELETE' then old.almacen_id else new.almacen_id end;
  v_fecha := case when tg_op = 'DELETE' then old.fecha else new.fecha end;
  v_clave_actual := pg_catalog.hashtextextended(v_almacen::text || v_fecha::text, 47);
  if tg_op = 'UPDATE'
     and (old.almacen_id, old.fecha) is distinct from (new.almacen_id, new.fecha) then
    v_clave_anterior := pg_catalog.hashtextextended(
      old.almacen_id::text || old.fecha::text, 47
    );
    perform pg_catalog.pg_advisory_xact_lock(least(v_clave_actual, v_clave_anterior));
    perform pg_catalog.pg_advisory_xact_lock(greatest(v_clave_actual, v_clave_anterior));
  else
    perform pg_catalog.pg_advisory_xact_lock(v_clave_actual);
  end if;
  if exists (
    select 1 from public.franquicia_caja_cierres c
    where c.almacen_id = v_almacen and c.fecha = v_fecha
      and c.estado = 'cerrado'
  ) then
    raise exception 'La caja de esa fecha esta cerrada. Reabre el dia con un motivo antes de modificarlo';
  end if;
  if tg_op = 'UPDATE' and exists (
    select 1 from public.franquicia_caja_cierres c
    where c.almacen_id = old.almacen_id and c.fecha = old.fecha
      and c.estado = 'cerrado'
  ) then
    raise exception 'La caja de la fecha original esta cerrada. Reabre el dia con un motivo antes de modificarlo';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$fn$;

-- ------------------------------------------------------------
-- 6. Vistas: agregan almacen_id y dejan de excluir tiendas propias
-- ------------------------------------------------------------
-- Hay que SOLTARLAS, no reemplazarlas: al agregar almacen_id a la tabla, el
-- "m.*" de la vista expande una columna mas y create or replace no admite
-- cambiar el conjunto ni el orden de columnas de una vista existente.
-- Nada en la base depende de estas dos vistas (solo las consulta el frontend),
-- asi que se sueltan sin cascade: si algo dependiera, es preferible que falle
-- a la vista aqui y no en silencio.
drop view if exists public.vista_caja_franquicia_v42;
drop view if exists public.vista_resumen_caja_diaria_franquicia_v47;

-- El saldo acumulado ahora se particiona por almacen (antes por franquicia;
-- para una franquicia es exactamente el mismo orden, porque almacen_id es
-- unico por franquicia). "franquicia" en el nombre de columna se mantiene por
-- compatibilidad con el frontend actual; para tienda propia trae el nombre
-- del almacen.
--
-- OJO: el "reversa_de_id is null" del saldo viene de v44 y NO se puede quitar.
-- revertir_caja_franquicia_v42 marca el original como 'revertido' (que ya sale
-- del saldo) y ademas crea una contrapartida vigente de signo contrario; sin
-- este filtro, revertir un ingreso de 100 daria -100 en vez de 0.
create or replace view public.vista_caja_franquicia_v42
with (security_invoker = true) as
select m.*,
       coalesce(f.nombre, a.nombre) as franquicia,
       sum(case when m.estado = 'vigente' and m.reversa_de_id is null and m.tipo = 'ingreso' then m.monto
                when m.estado = 'vigente' and m.reversa_de_id is null and m.tipo = 'egreso' then -m.monto
                else 0 end)
         over (partition by m.almacen_id order by m.fecha, m.created_at, m.id)
         as saldo_acumulado
from public.franquicia_caja_movimientos m
left join public.franquicias f on f.id = m.franquicia_id
join public.almacenes a on a.id = m.almacen_id;

create or replace view public.vista_resumen_caja_diaria_franquicia_v47
with (security_invoker = true) as
select m.almacen_id, m.franquicia_id, m.fecha,
  coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0) ingresos_total,
  coalesce(sum(m.monto) filter (where m.tipo = 'egreso'), 0) egresos_total,
  coalesce(sum(m.monto) filter (
    where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'
  ), 0) ingresos_efectivo,
  coalesce(sum(m.monto) filter (
    where m.tipo = 'egreso' and m.medio_pago = 'efectivo'
  ), 0) egresos_efectivo
from public.franquicia_caja_movimientos m
where m.estado = 'vigente' and m.reversa_de_id is null
group by m.almacen_id, m.franquicia_id, m.fecha;

-- ------------------------------------------------------------
-- 7. RLS: agrega el camino tienda propia sin tocar el de franquicia
-- ------------------------------------------------------------
drop policy if exists "leer_caja_franquicia_v42" on public.franquicia_caja_movimientos;
create policy "leer_caja_franquicia_v42" on public.franquicia_caja_movimientos for select to authenticated using (
  (franquicia_id is not null and public.usuario_puede_franquicia_v42(franquicia_id, false, true))
  or (franquicia_id is null and public.usuario_puede_almacen(almacen_id, false))
);

drop policy if exists "leer_cierres_franquicia_v47" on public.franquicia_caja_cierres;
create policy "leer_cierres_franquicia_v47" on public.franquicia_caja_cierres for select to authenticated using (
  (franquicia_id is not null and public.usuario_puede_franquicia_v42(franquicia_id, false, true))
  or (franquicia_id is null and public.usuario_puede_almacen(almacen_id, false))
);

alter function public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid) owner to postgres;
alter function public.revertir_caja_franquicia_v42(uuid,text,uuid) owner to postgres;
alter function public.saldo_inicial_caja_franquicia_v49(uuid,date) owner to postgres;
alter function public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid) owner to postgres;
alter function public.reabrir_caja_franquicia_v47(uuid,text) owner to postgres;
alter function public.revertir_caja_factura_franquicia_v45(uuid,text) owner to postgres;
alter function public.bloquear_caja_cerrada_v47() owner to postgres;

revoke execute on function public.saldo_inicial_caja_franquicia_v49(uuid,date) from public, anon;
grant execute on function public.saldo_inicial_caja_franquicia_v49(uuid,date) to authenticated;

-- Soltar una vista se lleva sus permisos: hay que devolverlos o el panel de
-- caja queda sin acceso de lectura.
alter view public.vista_caja_franquicia_v42 owner to postgres;
alter view public.vista_resumen_caja_diaria_franquicia_v47 owner to postgres;
revoke all on public.vista_caja_franquicia_v42,
  public.vista_resumen_caja_diaria_franquicia_v47 from public, anon;
grant select on public.vista_caja_franquicia_v42,
  public.vista_resumen_caja_diaria_franquicia_v47 to authenticated;

comment on table public.franquicia_caja_movimientos is
  'Diario operativo de control interno (franquicias y tiendas propias); no sustituye contabilidad ni registros tributarios.';

notify pgrst, 'reload schema';
