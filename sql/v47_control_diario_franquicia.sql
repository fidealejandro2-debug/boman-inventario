-- ============================================================
-- BOMAN INVENTARIO - v47: control diario de franquicia
--
-- 1. Desglose real de pagos de venta.
-- 2. Cierre diario de caja con efectivo esperado y diferencia.
-- 3. Minimos por producto y reposicion sugerida del local.
-- 4. Alertas derivadas del estado real de solicitudes y transferencias.
--
-- Ejecutar despues de v46.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Pagos desglosados
-- ------------------------------------------------------------
create table if not exists public.venta_franquicia_pagos (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references public.ventas_franquicia(id) on delete restrict,
  numero integer not null check (numero > 0),
  medio_pago text not null check (
    medio_pago in ('efectivo', 'transferencia', 'tarjeta', 'mixto', 'otro')
  ),
  monto numeric(14,2) not null check (monto > 0),
  referencia text,
  created_at timestamptz not null default now(),
  unique (venta_id, numero)
);

alter table public.franquicia_caja_movimientos
  drop constraint if exists franquicia_caja_movimientos_venta_id_key;
alter table public.franquicia_caja_movimientos
  add column if not exists venta_pago_id uuid
    references public.venta_franquicia_pagos(id) on delete restrict;
alter table public.franquicia_caja_movimientos
  add column if not exists documento_pago_numero integer
    check (documento_pago_numero is null or documento_pago_numero > 0);
create unique index if not exists uq_caja_franquicia_venta_pago_v47
  on public.franquicia_caja_movimientos(venta_pago_id)
  where venta_pago_id is not null;

-- v45 permitia un solo ingreso por XML. v47 permite una fila por medio.
drop index if exists public.uq_caja_franquicia_documento_xml;
update public.franquicia_caja_movimientos
set documento_pago_numero = 1
where documento_xml_id is not null and documento_pago_numero is null;
create unique index if not exists uq_caja_franquicia_documento_pago_v47
  on public.franquicia_caja_movimientos(documento_xml_id, documento_pago_numero)
  where documento_xml_id is not null and documento_pago_numero is not null;

-- Las ventas anteriores quedan representadas por un pago legado. Si decian
-- "mixto" no se inventa una distribucion que nunca fue capturada.
insert into public.venta_franquicia_pagos (
  venta_id, numero, medio_pago, monto, referencia
)
select v.id, 1, v.medio_pago, v.total, v.referencia
from public.ventas_franquicia v
where v.total > 0
  and not exists (
    select 1 from public.venta_franquicia_pagos p where p.venta_id = v.id
  )
on conflict do nothing;

update public.franquicia_caja_movimientos m
set venta_pago_id = p.id
from public.venta_franquicia_pagos p
where m.venta_id = p.venta_id and p.numero = 1
  and m.venta_pago_id is null and m.reversa_de_id is null;

create or replace function public.registrar_venta_franquicia_v47(
  p_fecha date,
  p_items jsonb,
  p_pagos jsonb,
  p_descuento numeric,
  p_referencia text,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  f public.franquicias%rowtype;
  v_venta_id uuid;
  v_numero integer;
  v_subtotal numeric(14,2);
  v_descuento numeric(14,2) := round(coalesce(p_descuento, 0), 2);
  v_total numeric(14,2);
  v_medio text;
  it record;
  pg record;
  v_pago_id uuid;
begin
  if public.rol_usuario_actual() not in ('franquiciado', 'vendedor_franquicia')
     or not public.usuario_tiene_permiso_v35('franquicia.ventas') then
    raise exception 'No tienes permiso para registrar ventas de franquicia';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  select * into f from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'No tienes una franquicia activa asignada'; end if;
  if p_fecha is null or p_fecha > (now() at time zone 'America/Guayaquil')::date then
    raise exception 'La fecha de venta no es valida';
  end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta debe tener productos';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items)
      x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric)
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or coalesce(x.cantidad, 0) <= 0
      or coalesce(x.precio_unitario, -1) < 0 or coalesce(x.descuento, 0) < 0
      or coalesce(x.descuento, 0) > x.cantidad * x.precio_unitario
  ) then raise exception 'La venta contiene productos, cantidades o valores invalidos'; end if;
  if exists (
    select producto_id from jsonb_to_recordset(p_items)
      x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric)
    group by producto_id having count(*) > 1
  ) then raise exception 'La venta contiene productos repetidos'; end if;

  select id into v_venta_id from public.ventas_franquicia
  where idempotency_key = p_idempotency_key and franquicia_id = f.id;
  if found then return jsonb_build_object('id', v_venta_id, 'duplicado', true); end if;

  select round(sum(x.cantidad * x.precio_unitario - coalesce(x.descuento, 0)), 2)
  into v_subtotal
  from jsonb_to_recordset(p_items)
    x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric);
  if v_descuento < 0 or v_descuento > v_subtotal then
    raise exception 'El descuento general no es valido';
  end if;
  v_total := v_subtotal - v_descuento;

  if jsonb_typeof(coalesce(p_pagos, '[]'::jsonb)) <> 'array' then
    raise exception 'El desglose de pagos no es valido';
  end if;
  if v_total > 0 then
    if jsonb_array_length(p_pagos) = 0 then
      raise exception 'Distribuye el total entre los medios de pago';
    end if;
    if exists (
      select 1 from jsonb_to_recordset(p_pagos)
        x(medio_pago text, monto numeric, referencia text)
      where x.medio_pago not in ('efectivo', 'transferencia', 'tarjeta', 'otro')
         or round(coalesce(x.monto, 0), 2) <= 0
    ) then raise exception 'El desglose contiene un medio o monto invalido'; end if;
    if exists (
      select medio_pago from jsonb_to_recordset(p_pagos)
        x(medio_pago text, monto numeric, referencia text)
      group by medio_pago having count(*) > 1
    ) then raise exception 'Agrupa cada medio de pago en una sola linea'; end if;
    if (select round(sum(x.monto), 2) from jsonb_to_recordset(p_pagos)
          x(medio_pago text, monto numeric, referencia text)) <> v_total then
      raise exception 'La suma de pagos debe ser exactamente igual al total de la venta';
    end if;
  elsif jsonb_array_length(coalesce(p_pagos, '[]'::jsonb)) > 0 then
    raise exception 'Una venta sin valor no debe registrar pagos';
  end if;

  select case when count(*) = 1 then min(x.medio_pago) else 'mixto' end
  into v_medio
  from jsonb_to_recordset(coalesce(p_pagos, '[]'::jsonb))
    x(medio_pago text, monto numeric, referencia text);
  v_medio := coalesce(v_medio, 'otro');

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(f.id::text, 47));
  select coalesce(max(numero), 0) + 1 into v_numero
  from public.ventas_franquicia where franquicia_id = f.id;

  insert into public.ventas_franquicia (
    franquicia_id, numero, fecha, medio_pago, subtotal, descuento, total,
    referencia, nota, idempotency_key, creada_por
  ) values (
    f.id, v_numero, p_fecha, v_medio, v_subtotal, v_descuento, v_total,
    nullif(btrim(p_referencia), ''), nullif(btrim(p_nota), ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_venta_id;

  insert into public.venta_franquicia_lineas
    (venta_id, producto_id, cantidad, precio_unitario, descuento, total)
  select v_venta_id, x.producto_id, x.cantidad, round(x.precio_unitario, 2),
         round(coalesce(x.descuento, 0), 2),
         round(x.cantidad * x.precio_unitario - coalesce(x.descuento, 0), 2)
  from jsonb_to_recordset(p_items)
    x(producto_id uuid, cantidad integer, precio_unitario numeric, descuento numeric);

  for it in select * from public.venta_franquicia_lineas
            where venta_id = v_venta_id order by producto_id
  loop
    perform public.aplicar_movimiento_stock_v20(
      it.producto_id, f.almacen_id, f.empresa_id,
      'salida'::public.tipo_movimiento, -it.cantidad, v_venta_id,
      'venta_franquicia', 'Venta franquicia #' || v_numero,
      null, null, gen_random_uuid()
    );
  end loop;

  for pg in
    select a.numero::integer, x.*
    from jsonb_array_elements(coalesce(p_pagos, '[]'::jsonb))
      with ordinality a(valor, numero)
    cross join lateral jsonb_to_record(a.valor)
      as x(medio_pago text, monto numeric, referencia text)
  loop
    insert into public.venta_franquicia_pagos
      (venta_id, numero, medio_pago, monto, referencia)
    values (
      v_venta_id, pg.numero, pg.medio_pago, round(pg.monto, 2),
      nullif(btrim(pg.referencia), '')
    ) returning id into v_pago_id;

    insert into public.franquicia_caja_movimientos (
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, venta_id, venta_pago_id, idempotency_key, creado_por
    ) values (
      f.id, p_fecha, 'ingreso', 'venta', 'Venta #' || v_numero,
      round(pg.monto, 2), pg.medio_pago, nullif(btrim(pg.referencia), ''),
      v_venta_id, v_pago_id,
      md5(v_venta_id::text || ':' || v_pago_id::text)::uuid, auth.uid()
    );
  end loop;

  return jsonb_build_object('id', v_venta_id, 'numero', v_numero,
    'total', v_total, 'duplicado', false);
end;
$fn$;

-- Anula todos los pagos, no solamente el primero de una venta mixta.
create or replace function public.anular_venta_franquicia_v47(
  p_venta_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v public.ventas_franquicia%rowtype;
  f public.franquicias%rowtype;
  it record;
  m record;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica el motivo con al menos 10 caracteres';
  end if;
  select * into v from public.ventas_franquicia where id = p_venta_id for update;
  if not found then raise exception 'La venta no existe'; end if;
  if v.estado = 'anulada' then
    return jsonb_build_object('id', v.id, 'duplicado', true, 'mensaje', 'La venta ya estaba anulada');
  end if;
  if public.rol_usuario_actual() <> 'admin' and (
    not public.usuario_puede_franquicia_v42(v.franquicia_id, true, true)
    or not public.usuario_tiene_permiso_v35('franquicia.ventas')
  ) then raise exception 'No tienes permiso para anular esta venta'; end if;
  select * into f from public.franquicias where id = v.franquicia_id and activo;
  if not found then raise exception 'La franquicia no esta activa'; end if;

  for it in select * from public.venta_franquicia_lineas
            where venta_id = v.id order by producto_id
  loop
    perform public.aplicar_movimiento_stock_v20(
      it.producto_id, f.almacen_id, f.empresa_id,
      'devolucion_venta'::public.tipo_movimiento, it.cantidad, v.id,
      'anulacion_venta_franquicia',
      'Anulacion venta franquicia #' || v.numero || ': ' || btrim(p_motivo),
      null, null, gen_random_uuid()
    );
  end loop;

  for m in select * from public.franquicia_caja_movimientos
           where venta_id = v.id and estado = 'vigente' and reversa_de_id is null
           order by id for update
  loop
    update public.franquicia_caja_movimientos
    set estado = 'revertido', motivo_reversa = 'Venta anulada: ' || btrim(p_motivo)
    where id = m.id;
    insert into public.franquicia_caja_movimientos (
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, reversa_de_id, motivo_reversa, idempotency_key, creado_por
    ) values (
      m.franquicia_id, (now() at time zone 'America/Guayaquil')::date,
      case when m.tipo = 'ingreso' then 'egreso' else 'ingreso' end,
      'reversa', 'Anulacion venta #' || v.numero, m.monto, m.medio_pago,
      m.referencia, m.id, btrim(p_motivo),
      md5(p_idempotency_key::text || ':' || m.id::text)::uuid, auth.uid()
    );
  end loop;

  update public.ventas_franquicia
  set estado = 'anulada', anulada_por = auth.uid(), anulada_at = now(),
      motivo_anulacion = btrim(p_motivo)
  where id = v.id;
  return jsonb_build_object('id', v.id, 'numero', v.numero, 'duplicado', false,
    'mensaje', 'Venta anulada; stock y todos sus pagos fueron revertidos');
end;
$fn$;

-- La factura XML usa el mismo desglose de efectivo, transferencia y tarjeta.
create or replace function public.aplicar_factura_venta_franquicia_v47(
  p_documento jsonb,
  p_asignaciones jsonb,
  p_pagos jsonb,
  p_nota text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  f public.franquicias%rowtype;
  v_resultado jsonb;
  v_total numeric(14,2);
  v_numero text;
  v_doc_id uuid;
  pg record;
begin
  if public.rol_usuario_actual() not in ('franquiciado', 'vendedor_franquicia')
     or not public.usuario_tiene_permiso_v35('franquicia.ventas') then
    raise exception 'Solo el local puede aplicar sus facturas de venta';
  end if;
  select * into f from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'No tienes una franquicia activa asignada'; end if;

  v_total := round(coalesce((p_documento->>'importe_total')::numeric, 0), 2);
  if v_total > 0 then
    if jsonb_typeof(coalesce(p_pagos, 'null'::jsonb)) <> 'array'
       or jsonb_array_length(p_pagos) = 0 then
      raise exception 'Distribuye el total de la factura entre los medios de pago';
    end if;
    if exists (
      select 1 from jsonb_to_recordset(p_pagos)
        x(medio_pago text, monto numeric, referencia text)
      where x.medio_pago not in ('efectivo', 'transferencia', 'tarjeta', 'otro')
         or round(coalesce(x.monto, 0), 2) <= 0
    ) then raise exception 'El desglose contiene un medio o monto invalido'; end if;
    if exists (
      select medio_pago from jsonb_to_recordset(p_pagos)
        x(medio_pago text, monto numeric, referencia text)
      group by medio_pago having count(*) > 1
    ) then raise exception 'Agrupa cada medio de pago en una sola linea'; end if;
    if (select round(sum(x.monto), 2) from jsonb_to_recordset(p_pagos)
          x(medio_pago text, monto numeric, referencia text)) <> v_total then
      raise exception 'La suma de pagos debe ser exactamente igual al total de la factura';
    end if;
  elsif jsonb_array_length(coalesce(p_pagos, '[]'::jsonb)) > 0 then
    raise exception 'Una factura sin valor no debe registrar pagos';
  end if;

  v_resultado := public.aplicar_factura_venta_xml_v20(
    p_documento, f.almacen_id, p_asignaciones, p_nota, false, null
  );
  if coalesce((v_resultado->>'duplicado')::boolean, false) then return v_resultado; end if;

  v_doc_id := nullif(v_resultado->>'id', '')::uuid;
  v_numero := coalesce(v_resultado->>'numero_documento', p_documento->>'numero_documento');
  for pg in
    select a.numero::integer, x.*
    from jsonb_array_elements(coalesce(p_pagos, '[]'::jsonb))
      with ordinality a(valor, numero)
    cross join lateral jsonb_to_record(a.valor)
      as x(medio_pago text, monto numeric, referencia text)
  loop
    insert into public.franquicia_caja_movimientos (
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, documento_xml_id, documento_pago_numero,
      idempotency_key, creado_por
    ) values (
      f.id, coalesce((p_documento->>'fecha_emision')::date,
        (now() at time zone 'America/Guayaquil')::date),
      'ingreso', 'venta', 'Factura ' || v_numero, round(pg.monto, 2),
      pg.medio_pago, coalesce(nullif(btrim(pg.referencia), ''), v_numero),
      v_doc_id, pg.numero,
      md5(coalesce(p_documento->>'clave_acceso', v_numero) || ':' || pg.numero)::uuid,
      auth.uid()
    );
  end loop;
  return v_resultado || jsonb_build_object('caja', v_total, 'pagos', p_pagos);
end;
$fn$;

-- El trigger de v45 conserva su nombre, pero ahora revierte todos los medios.
create or replace function public.revertir_caja_factura_franquicia_v45(
  p_documento_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare m public.franquicia_caja_movimientos%rowtype;
begin
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
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, reversa_de_id, motivo_reversa, idempotency_key, creado_por
    ) values (
      m.franquicia_id, (now() at time zone 'America/Guayaquil')::date,
      case when m.tipo = 'ingreso' then 'egreso' else 'ingreso' end,
      'reversa', 'Anulacion ' || m.concepto, m.monto, m.medio_pago,
      m.referencia, m.id, btrim(p_motivo), gen_random_uuid(),
      coalesce(auth.uid(), m.creado_por)
    );
  end loop;
end;
$fn$;

-- ------------------------------------------------------------
-- 2. Cierre diario de caja
-- ------------------------------------------------------------
create table if not exists public.franquicia_caja_cierres (
  id uuid primary key default gen_random_uuid(),
  franquicia_id uuid not null references public.franquicias(id) on delete restrict,
  fecha date not null,
  estado text not null default 'cerrado' check (estado in ('cerrado', 'reabierto')),
  saldo_inicial_efectivo numeric(14,2) not null check (saldo_inicial_efectivo >= 0),
  ingresos_efectivo numeric(14,2) not null,
  egresos_efectivo numeric(14,2) not null,
  saldo_esperado_efectivo numeric(14,2) not null,
  efectivo_contado numeric(14,2) not null check (efectivo_contado >= 0),
  diferencia numeric(14,2) not null,
  ingresos_total numeric(14,2) not null,
  egresos_total numeric(14,2) not null,
  nota text,
  motivo_reapertura text,
  idempotency_key uuid not null unique,
  cerrado_por uuid not null references public.perfiles(id) on delete restrict,
  cerrado_at timestamptz not null default now(),
  reabierto_por uuid references public.perfiles(id) on delete restrict,
  reabierto_at timestamptz,
  unique (franquicia_id, fecha)
);

create table if not exists public.franquicia_caja_cierre_eventos (
  id uuid primary key default gen_random_uuid(),
  cierre_id uuid not null references public.franquicia_caja_cierres(id) on delete restrict,
  tipo text not null check (tipo in ('cerrado', 'reabierto')),
  detalle text not null,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid,
  created_at timestamptz not null default now()
);
alter table public.franquicia_caja_cierre_eventos
  add column if not exists idempotency_key uuid;
create unique index if not exists uq_cierre_evento_idempotencia_v47
  on public.franquicia_caja_cierre_eventos(idempotency_key)
  where idempotency_key is not null;

create or replace function public.bloquear_caja_cerrada_v47()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_franquicia uuid;
  v_fecha date;
  v_clave_actual bigint;
  v_clave_anterior bigint;
begin
  v_franquicia := case when tg_op = 'DELETE' then old.franquicia_id else new.franquicia_id end;
  v_fecha := case when tg_op = 'DELETE' then old.fecha else new.fecha end;
  v_clave_actual := pg_catalog.hashtextextended(v_franquicia::text || v_fecha::text, 47);
  if tg_op = 'UPDATE'
     and (old.franquicia_id, old.fecha) is distinct from (new.franquicia_id, new.fecha) then
    v_clave_anterior := pg_catalog.hashtextextended(
      old.franquicia_id::text || old.fecha::text, 47
    );
    perform pg_catalog.pg_advisory_xact_lock(least(v_clave_actual, v_clave_anterior));
    perform pg_catalog.pg_advisory_xact_lock(greatest(v_clave_actual, v_clave_anterior));
  else
    perform pg_catalog.pg_advisory_xact_lock(v_clave_actual);
  end if;
  if exists (
    select 1 from public.franquicia_caja_cierres c
    where c.franquicia_id = v_franquicia and c.fecha = v_fecha
      and c.estado = 'cerrado'
  ) then
    raise exception 'La caja de esa fecha esta cerrada. Reabre el dia con un motivo antes de modificarlo';
  end if;
  -- En una actualizacion tambien se protege la fecha original. De otro modo
  -- bastaria mover una fila de un dia cerrado a otro abierto para alterarlo.
  if tg_op = 'UPDATE' and exists (
    select 1 from public.franquicia_caja_cierres c
    where c.franquicia_id = old.franquicia_id and c.fecha = old.fecha
      and c.estado = 'cerrado'
  ) then
    raise exception 'La caja de la fecha original esta cerrada. Reabre el dia con un motivo antes de modificarlo';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$fn$;

drop trigger if exists trg_bloquear_caja_cerrada_v47 on public.franquicia_caja_movimientos;
create trigger trg_bloquear_caja_cerrada_v47
before insert or update or delete on public.franquicia_caja_movimientos
for each row execute function public.bloquear_caja_cerrada_v47();

create or replace function public.cerrar_caja_franquicia_v47(
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
  f public.franquicias%rowtype;
  c public.franquicia_caja_cierres%rowtype;
  v_ing_ef numeric(14,2);
  v_egr_ef numeric(14,2);
  v_ing numeric(14,2);
  v_egr numeric(14,2);
  v_esperado numeric(14,2);
begin
  if public.rol_usuario_actual() <> 'franquiciado'
     or not public.usuario_tiene_permiso_v35('franquicia.caja') then
    raise exception 'No tienes permiso para cerrar esta caja';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into f from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'No tienes una franquicia activa asignada'; end if;
  select cc.* into c
  from public.franquicia_caja_cierres cc
  left join public.franquicia_caja_cierre_eventos e on e.cierre_id = cc.id
  where cc.franquicia_id = f.id
    and (cc.idempotency_key = p_idempotency_key or e.idempotency_key = p_idempotency_key)
  limit 1;
  if found then return to_jsonb(c); end if;
  if p_fecha is null or p_fecha > (now() at time zone 'America/Guayaquil')::date then
    raise exception 'La fecha de cierre no es valida';
  end if;
  if coalesce(p_saldo_inicial_efectivo, -1) < 0 or coalesce(p_efectivo_contado, -1) < 0 then
    raise exception 'El saldo inicial y el efectivo contado no pueden ser negativos';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(f.id::text || p_fecha::text, 47));
  select * into c from public.franquicia_caja_cierres
  where franquicia_id = f.id and fecha = p_fecha for update;
  if found and c.estado = 'cerrado' then raise exception 'La caja de ese dia ya esta cerrada'; end if;

  select
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'egreso' and m.medio_pago = 'efectivo'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0),
    coalesce(sum(m.monto) filter (where m.tipo = 'egreso'), 0)
  into v_ing_ef, v_egr_ef, v_ing, v_egr
  from public.franquicia_caja_movimientos m
  where m.franquicia_id = f.id and m.fecha = p_fecha
    and m.estado = 'vigente' and m.reversa_de_id is null;
  v_esperado := round(p_saldo_inicial_efectivo + v_ing_ef - v_egr_ef, 2);

  if c.id is null then
    insert into public.franquicia_caja_cierres (
      franquicia_id, fecha, saldo_inicial_efectivo, ingresos_efectivo,
      egresos_efectivo, saldo_esperado_efectivo, efectivo_contado, diferencia,
      ingresos_total, egresos_total, nota, idempotency_key, cerrado_por
    ) values (
      f.id, p_fecha, round(p_saldo_inicial_efectivo, 2), v_ing_ef, v_egr_ef,
      v_esperado, round(p_efectivo_contado, 2), round(p_efectivo_contado - v_esperado, 2),
      v_ing, v_egr, nullif(btrim(p_nota), ''), p_idempotency_key, auth.uid()
    ) returning * into c;
  else
    update public.franquicia_caja_cierres set
      estado = 'cerrado', saldo_inicial_efectivo = round(p_saldo_inicial_efectivo, 2),
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
    c.id, 'cerrado', 'Cierre diario confirmado. Diferencia: ' || c.diferencia,
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
  if public.rol_usuario_actual() not in ('admin', 'franquiciado') then
    raise exception 'No tienes permiso para reabrir esta caja';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica la reapertura con al menos 10 caracteres';
  end if;
  select * into c from public.franquicia_caja_cierres where id = p_cierre_id for update;
  if not found then raise exception 'El cierre no existe'; end if;
  if public.rol_usuario_actual() <> 'admin' and (
    not public.usuario_puede_franquicia_v42(c.franquicia_id, true, true)
    or not public.usuario_tiene_permiso_v35('franquicia.caja')
  ) then raise exception 'No tienes acceso a ese cierre'; end if;
  if c.estado <> 'cerrado' then raise exception 'El cierre ya esta reabierto'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(c.franquicia_id::text || c.fecha::text, 47)
  );
  update public.franquicia_caja_cierres
  set estado = 'reabierto', motivo_reapertura = btrim(p_motivo),
      reabierto_por = auth.uid(), reabierto_at = now()
  where id = c.id;
  insert into public.franquicia_caja_cierre_eventos(cierre_id, tipo, detalle, usuario_id)
  values (c.id, 'reabierto', btrim(p_motivo), auth.uid());
end;
$fn$;

-- ------------------------------------------------------------
-- 3. Minimos y sugerencias del local
-- ------------------------------------------------------------
create or replace function public.guardar_minimos_franquicia_v47(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare f public.franquicias%rowtype; v_total integer;
begin
  if public.rol_usuario_actual() <> 'franquiciado'
     or not public.usuario_tiene_permiso_v35('franquicia.reposicion') then
    raise exception 'No tienes permiso para configurar reposicion';
  end if;
  select * into f from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'No tienes una franquicia activa asignada'; end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'No hay minimos para guardar';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items)
      x(producto_id uuid, stock_minimo integer, stock_maximo integer)
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or coalesce(x.stock_minimo, -1) < 0
      or x.stock_maximo is null or x.stock_maximo < x.stock_minimo
  ) then raise exception 'Hay productos o limites invalidos'; end if;
  if exists (
    select producto_id from jsonb_to_recordset(p_items)
      x(producto_id uuid, stock_minimo integer, stock_maximo integer)
    group by producto_id having count(*) > 1
  ) then raise exception 'Hay productos repetidos en la configuracion'; end if;

  insert into public.producto_almacen_config as c (
    producto_id, almacen_id, stock_minimo, stock_maximo, stock_seguridad,
    punto_reposicion, activo, updated_by, updated_at
  )
  select x.producto_id, f.almacen_id, x.stock_minimo, x.stock_maximo, 0,
         x.stock_minimo, true, auth.uid(), now()
  from jsonb_to_recordset(p_items)
    x(producto_id uuid, stock_minimo integer, stock_maximo integer)
  on conflict (producto_id, almacen_id) do update
  set stock_minimo = excluded.stock_minimo,
      stock_maximo = excluded.stock_maximo,
      punto_reposicion = excluded.punto_reposicion,
      activo = true, updated_by = auth.uid(), updated_at = now();
  get diagnostics v_total = row_count;
  return v_total;
end;
$fn$;

create or replace function public.crear_reposicion_sugerida_franquicia_v47(
  p_nota text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  f public.franquicias%rowtype;
  v_items jsonb;
  v_id uuid;
begin
  if public.rol_usuario_actual() <> 'franquiciado'
     or not public.usuario_tiene_permiso_v35('franquicia.reposicion') then
    raise exception 'No tienes permiso para solicitar reposicion';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into f from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'No tienes una franquicia activa asignada'; end if;
  select id into v_id from public.documentos_inventario
  where idempotency_key = p_idempotency_key and destino_id = f.almacen_id;
  if found then return v_id; end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(f.id::text || ':reposicion', 47)
  );
  if exists (
    select 1 from public.documentos_inventario d
    where d.tipo = 'solicitud_reposicion' and d.destino_id = f.almacen_id
      and d.estado = 'solicitado'
  ) then
    raise exception 'Ya existe una solicitud de reposicion pendiente de aprobacion';
  end if;

  select jsonb_agg(jsonb_build_object(
    'producto_id', s.producto_id, 'cantidad', s.sugerido_reponer
  ) order by s.sku)
  into v_items
  from public.vista_stock_operativo s
  where s.almacen_id = f.almacen_id and s.sugerido_reponer > 0;
  if v_items is null then raise exception 'No hay productos que requieran reposicion'; end if;

  return public.crear_solicitud_reposicion_v42(
    f.almacen_id, v_items, 'normal',
    coalesce(nullif(btrim(p_nota), ''),
      'Solicitud automatica segun minimos y mercaderia en transito'),
    p_idempotency_key
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 4. Vistas de consulta y alertas vivas
-- ------------------------------------------------------------
create or replace view public.vista_ventas_franquicia_v47
with (security_invoker = true) as
select v.id, v.franquicia_id, f.nombre franquicia, f.almacen_id,
       v.numero, v.fecha, v.estado, v.medio_pago, v.subtotal,
       v.descuento, v.total, v.referencia, v.nota, v.created_at,
       p.nombre_completo vendedor,
       coalesce(sum(l.cantidad), 0)::integer unidades,
       coalesce((
         select jsonb_agg(jsonb_build_object(
           'medio_pago', pg.medio_pago, 'monto', pg.monto,
           'referencia', pg.referencia
         ) order by pg.numero)
         from public.venta_franquicia_pagos pg where pg.venta_id = v.id
       ), '[]'::jsonb) pagos
from public.ventas_franquicia v
join public.franquicias f on f.id = v.franquicia_id
join public.perfiles p on p.id = v.creada_por
left join public.venta_franquicia_lineas l on l.venta_id = v.id
group by v.id, f.id, p.id;

create or replace view public.vista_resumen_caja_diaria_franquicia_v47
with (security_invoker = true) as
select m.franquicia_id, m.fecha,
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
group by m.franquicia_id, m.fecha;

create or replace view public.vista_alertas_franquicia_v47
with (security_invoker = true) as
select f.id franquicia_id, d.id documento_id, d.numero,
       'solicitud_aprobada'::text tipo_alerta, d.estado,
       'Solicitud aprobada'::text titulo,
       'Bodega aprobo la reposicion y genero una transferencia.'::text detalle,
       d.prioridad, d.updated_at
from public.franquicias f
join public.documentos_inventario d on d.destino_id = f.almacen_id
where f.activo and d.tipo = 'solicitud_reposicion' and d.estado = 'aprobado'
  and exists (
    select 1 from public.documentos_inventario t
    where t.documento_origen_id = d.id and t.tipo = 'transferencia'
      and t.estado in ('aprobado', 'preparando')
  )
union all
select f.id, d.id, d.numero, 'transferencia_despachada', d.estado,
       'Mercaderia despachada',
       'La transferencia salio de bodega y esta pendiente de recepcion.',
       d.prioridad, d.updated_at
from public.franquicias f
join public.documentos_inventario d on d.destino_id = f.almacen_id
where f.activo and d.tipo = 'transferencia' and d.estado = 'despachado'
union all
select f.id, d.id, d.numero, 'pendiente_recepcion', d.estado,
       'Pendiente de recibir',
       case when d.estado = 'en_transito'
         then 'La mercaderia esta en transito. Confirma las cantidades al llegar.'
         else 'La mercaderia fue despachada. Registra la recepcion cuando llegue.' end,
       d.prioridad, d.updated_at
from public.franquicias f
join public.documentos_inventario d on d.destino_id = f.almacen_id
where f.activo and d.tipo = 'transferencia'
  and d.estado = 'en_transito';

-- ------------------------------------------------------------
-- 5. RLS, privilegios y cierre de RPC anteriores
-- ------------------------------------------------------------
alter table public.venta_franquicia_pagos enable row level security;
alter table public.franquicia_caja_cierres enable row level security;
alter table public.franquicia_caja_cierre_eventos enable row level security;

drop policy if exists "leer_pagos_franquicia_v47" on public.venta_franquicia_pagos;
create policy "leer_pagos_franquicia_v47" on public.venta_franquicia_pagos
for select to authenticated using (
  exists (
    select 1 from public.ventas_franquicia v
    where v.id = venta_id
      and public.usuario_puede_franquicia_v42(v.franquicia_id, false, false)
  )
);
drop policy if exists "leer_cierres_franquicia_v47" on public.franquicia_caja_cierres;
create policy "leer_cierres_franquicia_v47" on public.franquicia_caja_cierres
for select to authenticated using (
  public.usuario_puede_franquicia_v42(franquicia_id, false, true)
);
drop policy if exists "leer_eventos_cierre_v47" on public.franquicia_caja_cierre_eventos;
create policy "leer_eventos_cierre_v47" on public.franquicia_caja_cierre_eventos
for select to authenticated using (
  exists (
    select 1 from public.franquicia_caja_cierres c
    where c.id = cierre_id
      and public.usuario_puede_franquicia_v42(c.franquicia_id, false, true)
  )
);

revoke all on public.venta_franquicia_pagos,
  public.franquicia_caja_cierres, public.franquicia_caja_cierre_eventos
  from public, anon;
revoke insert, update, delete on public.venta_franquicia_pagos,
  public.franquicia_caja_cierres, public.franquicia_caja_cierre_eventos
  from authenticated;
grant select on public.venta_franquicia_pagos,
  public.franquicia_caja_cierres, public.franquicia_caja_cierre_eventos
  to authenticated;
grant select on public.vista_ventas_franquicia_v47,
  public.vista_resumen_caja_diaria_franquicia_v47,
  public.vista_alertas_franquicia_v47 to authenticated;

alter function public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid) owner to postgres;
alter function public.anular_venta_franquicia_v47(uuid,text,uuid) owner to postgres;
alter function public.aplicar_factura_venta_franquicia_v47(jsonb,jsonb,jsonb,text) owner to postgres;
alter function public.revertir_caja_factura_franquicia_v45(uuid,text) owner to postgres;
alter function public.bloquear_caja_cerrada_v47() owner to postgres;
alter function public.cerrar_caja_franquicia_v47(date,numeric,numeric,text,uuid) owner to postgres;
alter function public.reabrir_caja_franquicia_v47(uuid,text) owner to postgres;
alter function public.guardar_minimos_franquicia_v47(jsonb) owner to postgres;
alter function public.crear_reposicion_sugerida_franquicia_v47(text,uuid) owner to postgres;

revoke execute on function public.registrar_venta_franquicia_v42(date,jsonb,text,numeric,text,text,uuid)
  from authenticated;
revoke execute on function public.anular_venta_franquicia_v44(uuid,text,uuid)
  from authenticated;
revoke execute on function public.aplicar_factura_venta_franquicia_v44(jsonb,jsonb,text)
  from authenticated;
revoke execute on function public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid)
  from public, anon;
revoke execute on function public.anular_venta_franquicia_v47(uuid,text,uuid)
  from public, anon;
revoke execute on function public.aplicar_factura_venta_franquicia_v47(jsonb,jsonb,jsonb,text)
  from public, anon;
revoke execute on function public.cerrar_caja_franquicia_v47(date,numeric,numeric,text,uuid)
  from public, anon;
revoke execute on function public.reabrir_caja_franquicia_v47(uuid,text)
  from public, anon;
revoke execute on function public.guardar_minimos_franquicia_v47(jsonb)
  from public, anon;
revoke execute on function public.crear_reposicion_sugerida_franquicia_v47(text,uuid)
  from public, anon;
grant execute on function public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid)
  to authenticated;
grant execute on function public.anular_venta_franquicia_v47(uuid,text,uuid)
  to authenticated;
grant execute on function public.aplicar_factura_venta_franquicia_v47(jsonb,jsonb,jsonb,text)
  to authenticated;
grant execute on function public.cerrar_caja_franquicia_v47(date,numeric,numeric,text,uuid)
  to authenticated;
grant execute on function public.reabrir_caja_franquicia_v47(uuid,text)
  to authenticated;
grant execute on function public.guardar_minimos_franquicia_v47(jsonb)
  to authenticated;
grant execute on function public.crear_reposicion_sugerida_franquicia_v47(text,uuid)
  to authenticated;

notify pgrst, 'reload schema';
