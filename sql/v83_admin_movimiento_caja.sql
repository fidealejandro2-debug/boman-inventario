-- ============================================================
-- BOMAN INVENTARIO - v83: admin registra depositos/ajustes de caja
--
-- Un dia ya cerrado deja su efectivo contado como saldo inicial del
-- siguiente (v49, saldo_inicial_caja_franquicia_v49). Cuando ese efectivo se
-- lleva al banco no hace falta reabrir el dia cerrado: el deposito se
-- registra en el dia ABIERTO en que ocurre, como un egreso mas, y la formula
-- de saldo inicial ya lo resta solo al derivar manana. Lo unico que faltaba
-- era que el admin pudiera registrar ese movimiento: registrar_caja_franquicia_v42
-- rechaza a admin de plano porque resuelve "mi local" por sesion, y admin no
-- tiene uno propio -por eso revertir_caja_franquicia_v42 (que opera sobre un
-- id explicito) ya admite admin, y este RPC no.
--
-- Se agrega p_almacen_id como parametro OPCIONAL al final (create or replace
-- no admite reordenar ni renombrar los que ya existen, pero si anexar uno
-- nuevo con default): para franquiciado/tienda se ignora, siguen resolviendo
-- su propio local igual que hoy; para admin es obligatorio, porque no hay
-- sesion de la que derivarlo.
--
-- Ejecutar despues de v82.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid)') is null then
    raise exception 'Falta v71 (registrar_caja_franquicia_v42). Instalalo antes de v83';
  end if;
end $$;

create or replace function public.registrar_caja_franquicia_v42(
  p_fecha date,
  p_tipo text,
  p_categoria text,
  p_concepto text,
  p_monto numeric,
  p_medio_pago text,
  p_referencia text,
  p_idempotency_key uuid,
  p_almacen_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_rol text := public.rol_usuario_actual();
  v_almacen_id uuid;
  v_franquicia_id uuid;
  v_id uuid;
begin
  if v_rol in ('franquiciado', 'tienda') and public.usuario_tiene_permiso_v35('franquicia.caja') then
    select o.almacen_id, o.franquicia_id into v_almacen_id, v_franquicia_id
    from public.almacen_caja_operativo_v71() o;
    if v_almacen_id is null then raise exception 'No tienes un local activo asignado para caja'; end if;
  elsif v_rol = 'admin' then
    if p_almacen_id is null then raise exception 'Indica a que local pertenece el movimiento'; end if;
    if not exists (select 1 from public.almacenes a where a.id = p_almacen_id and a.activo) then
      raise exception 'El almacen indicado no existe o esta inactivo';
    end if;
    v_almacen_id := p_almacen_id;
    -- Igual criterio que almacen_caja_operativo_v71(): franquicia si el
    -- almacen tiene una activa, null si es tienda propia. El movimiento no
    -- deja de pertenecer al local por no tener franquicia_id: almacen_id
    -- es la clave real desde v71.
    select f.id into v_franquicia_id from public.franquicias f
    where f.almacen_id = p_almacen_id and f.activo;
  else
    raise exception 'No tienes permiso para registrar movimientos de caja';
  end if;

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
    v_franquicia_id, v_almacen_id, p_fecha, p_tipo, btrim(p_categoria), btrim(p_concepto),
    round(p_monto, 2), p_medio_pago, nullif(btrim(p_referencia), ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;
  return v_id;
end;
$fn$;

alter function public.registrar_caja_franquicia_v42(date, text, text, text, numeric, text, text, uuid, uuid)
  owner to postgres;
revoke execute on function public.registrar_caja_franquicia_v42(date, text, text, text, numeric, text, text, uuid, uuid)
  from public, anon;
grant execute on function public.registrar_caja_franquicia_v42(date, text, text, text, numeric, text, text, uuid, uuid)
  to authenticated;

commit;

notify pgrst, 'reload schema';
