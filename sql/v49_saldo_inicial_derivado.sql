-- ============================================================
-- BOMAN INVENTARIO - v49: el saldo inicial del cierre deja de ser declarado
--
-- v47 calcula la diferencia como:
--     efectivo_contado - (saldo_inicial + ingresos - egresos)
-- y el saldo inicial llegaba escrito desde la interfaz. La misma persona que
-- cuenta el efectivo elegia contra que cifra se compara, asi que cualquier
-- faltante se podia dejar en cero sin dejar rastro. Un cierre que se puede
-- cuadrar a voluntad no controla nada.
--
-- Ahora el saldo inicial se deriva del ultimo cierre del local. Solo se acepta
-- declarado cuando no existe ningun cierre previo, que es el arranque real.
--
-- Ejecutar despues de v48.
-- ============================================================

-- 1. Queda registrado de donde salio la cifra ------------------------------
alter table public.franquicia_caja_cierres
  add column if not exists saldo_inicial_origen text
    check (saldo_inicial_origen in ('derivado', 'declarado'));

-- 2. Saldo inicial derivado del ultimo cierre ------------------------------
-- No basta con tomar el efectivo contado del cierre anterior: si el local paso
-- dias sin cerrar, el efectivo de esos dias intermedios tambien forma parte de
-- lo que hay en la gaveta hoy.
create or replace function public.saldo_inicial_caja_franquicia_v49(
  p_franquicia_id uuid,
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
    where franquicia_id = p_franquicia_id
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
    where m.franquicia_id = p_franquicia_id
      and m.medio_pago = 'efectivo'
      and m.estado = 'vigente'
      and m.reversa_de_id is null
      and m.fecha > a.fecha
      and m.fecha < p_fecha
  )
  select round(a.efectivo_contado + i.neto, 2)
  from anterior a, intermedios i;
$fn$;

-- 3. Cierre que ya no acepta el saldo inicial a dedo -----------------------
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
  f public.franquicias%rowtype;
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
  if coalesce(p_efectivo_contado, -1) < 0 then
    raise exception 'El efectivo contado no puede ser negativo';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(f.id::text || p_fecha::text, 47));
  select * into c from public.franquicia_caja_cierres
  where franquicia_id = f.id and fecha = p_fecha for update;
  if found and c.estado = 'cerrado' then raise exception 'La caja de ese dia ya esta cerrada'; end if;

  -- El saldo inicial se toma del historico. Solo el primer cierre del local
  -- puede declararlo, porque no hay nada anterior de donde sacarlo.
  v_derivado := public.saldo_inicial_caja_franquicia_v49(f.id, p_fecha);
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
  where m.franquicia_id = f.id and m.fecha = p_fecha
    and m.estado = 'vigente' and m.reversa_de_id is null;

  v_esperado := round(v_inicial + v_ing_ef - v_egr_ef, 2);

  if c.id is null then
    insert into public.franquicia_caja_cierres (
      franquicia_id, fecha, saldo_inicial_efectivo, saldo_inicial_origen,
      ingresos_efectivo, egresos_efectivo, saldo_esperado_efectivo,
      efectivo_contado, diferencia, ingresos_total, egresos_total,
      nota, idempotency_key, cerrado_por
    ) values (
      f.id, p_fecha, v_inicial, v_origen, v_ing_ef, v_egr_ef, v_esperado,
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

-- 4. Mensaje util cuando la anulacion choca con un dia cerrado -------------
-- Anular una factura revierte su ingreso, y si ese ingreso cae en un dia ya
-- cerrado el trigger de v47 lo impide. El error original no decia que hacer.
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
    on cc.franquicia_id = mm.franquicia_id and cc.fecha = mm.fecha and cc.estado = 'cerrado'
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

alter function public.saldo_inicial_caja_franquicia_v49(uuid, date) owner to postgres;
alter function public.cerrar_caja_franquicia_v49(date, numeric, numeric, text, uuid) owner to postgres;
alter function public.revertir_caja_factura_franquicia_v45(uuid, text) owner to postgres;

-- La version de v47 dejaba elegir el saldo inicial: se cierra el paso.
revoke execute on function public.cerrar_caja_franquicia_v47(date,numeric,numeric,text,uuid)
  from public, anon, authenticated;

revoke execute on function public.saldo_inicial_caja_franquicia_v49(uuid, date) from public, anon;
revoke execute on function public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid) from public, anon;
grant execute on function public.saldo_inicial_caja_franquicia_v49(uuid, date) to authenticated;
grant execute on function public.cerrar_caja_franquicia_v49(date,numeric,numeric,text,uuid) to authenticated;

notify pgrst, 'reload schema';
