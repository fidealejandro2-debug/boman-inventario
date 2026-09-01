-- ============================================================
-- BOMAN INVENTARIO - v45: la anulacion de una factura tambien limpia la caja
--
-- v44 hizo que la factura XML del local registrara su ingreso en la caja de la
-- franquicia. Faltaba el otro extremo: anular esa factura -o revertir su
-- importacion- dejaba el ingreso sumando como si la venta siguiera en pie.
--
-- Ejecutar despues de v44.
-- ============================================================

-- 1. El movimiento de caja queda atado al documento que lo origino ----------
-- Antes solo se guardaba el numero en 'referencia', que es texto y no sirve
-- para encontrarlo con certeza.
alter table public.franquicia_caja_movimientos
  add column if not exists documento_xml_id uuid
    references public.documentos_venta_xml(id) on delete restrict;

create unique index if not exists uq_caja_franquicia_documento_xml
  on public.franquicia_caja_movimientos(documento_xml_id)
  where documento_xml_id is not null;

create index if not exists idx_caja_franquicia_documento_xml
  on public.franquicia_caja_movimientos(documento_xml_id)
  where documento_xml_id is not null;

-- 2. Reversa del ingreso de una factura ------------------------------------
-- Mismo criterio que el resto de la caja: el original sale del saldo y queda
-- su contrapartida como evidencia. La vista de v44 no cuenta contrapartidas,
-- asi que el neto es cero.
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
  select * into m from public.franquicia_caja_movimientos
  where documento_xml_id = p_documento_id and estado = 'vigente'
  for update;
  if not found then return; end if;

  update public.franquicia_caja_movimientos
  set estado = 'revertido', motivo_reversa = btrim(p_motivo)
  where id = m.id;

  insert into public.franquicia_caja_movimientos (
    franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
    referencia, reversa_de_id, motivo_reversa, idempotency_key, creado_por
  ) values (
    m.franquicia_id, current_date,
    case when m.tipo = 'ingreso' then 'egreso' else 'ingreso' end,
    'reversa', 'Anulacion ' || m.concepto, m.monto, m.medio_pago,
    m.referencia, m.id, btrim(p_motivo), gen_random_uuid(),
    -- auth.uid() es null cuando la anulacion viene de un proceso interno; en
    -- ese caso responde el autor del movimiento original.
    coalesce(auth.uid(), m.creado_por)
  );
end;
$fn$;

-- 3. Se dispara sola al anular o revertir la factura ------------------------
-- Es un trigger y no una llamada dentro de admin_anular_factura_venta_xml
-- porque esa funcion es de v20 y la tocan otros flujos: asi ninguna via de
-- anulacion puede olvidarse de la caja.
create or replace function public.sincronizar_caja_factura_franquicia_v45()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if new.anulado and not coalesce(old.anulado, false) then
    perform public.revertir_caja_factura_franquicia_v45(
      new.id, 'Factura anulada: ' || coalesce(new.motivo_anulacion, 'sin motivo registrado'));
  elsif new.anulacion_stock_estado = 'reversion_tecnica'
        and coalesce(old.anulacion_stock_estado, '') <> 'reversion_tecnica' then
    perform public.revertir_caja_factura_franquicia_v45(
      new.id, 'Importacion revertida tecnicamente');
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_sincronizar_caja_factura_franquicia on public.documentos_venta_xml;
create trigger trg_sincronizar_caja_factura_franquicia
  after update on public.documentos_venta_xml
  for each row execute function public.sincronizar_caja_factura_franquicia_v45();

-- 4. El envoltorio del local guarda el vinculo -----------------------------
-- Reemplaza la version de v44: unico cambio real, documento_xml_id.
create or replace function public.aplicar_factura_venta_franquicia_v44(
  p_documento jsonb,
  p_asignaciones jsonb,
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
begin
  if public.rol_usuario_actual() not in ('franquiciado', 'vendedor_franquicia')
     or not public.usuario_tiene_permiso_v35('franquicia.ventas') then
    raise exception 'Solo el local puede aplicar sus facturas de venta';
  end if;

  select * into f from public.franquicias where id = public.franquicia_usuario_actual_v42();
  if not found or not f.activo then
    raise exception 'No tienes una franquicia activa asignada';
  end if;

  v_resultado := public.aplicar_factura_venta_xml_v20(
    p_documento, f.almacen_id, p_asignaciones, p_nota, false, null
  );

  if coalesce((v_resultado->>'duplicado')::boolean, false) then
    return v_resultado;
  end if;

  v_doc_id := nullif(v_resultado->>'id', '')::uuid;
  v_total := round(coalesce((p_documento->>'importe_total')::numeric, 0), 2);
  v_numero := coalesce(v_resultado->>'numero_documento', p_documento->>'numero_documento');

  if v_total > 0 and v_doc_id is not null then
    insert into public.franquicia_caja_movimientos (
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, documento_xml_id, idempotency_key, creado_por
    ) values (
      f.id, coalesce((p_documento->>'fecha_emision')::date, current_date),
      'ingreso', 'venta', 'Factura ' || v_numero, v_total, 'otro',
      v_numero, v_doc_id,
      -- La clave de acceso del SRI es unica por factura: derivar de ella la
      -- idempotencia impide un segundo ingreso por el mismo documento.
      md5(coalesce(p_documento->>'clave_acceso', v_numero))::uuid,
      auth.uid()
    )
    on conflict (idempotency_key) do nothing;
  end if;

  return v_resultado || jsonb_build_object('caja', v_total);
end;
$fn$;

alter function public.revertir_caja_factura_franquicia_v45(uuid, text) owner to postgres;
alter function public.sincronizar_caja_factura_franquicia_v45() owner to postgres;
alter function public.aplicar_factura_venta_franquicia_v44(jsonb, jsonb, text) owner to postgres;

-- Solo la dispara el trigger; nadie la llama desde el navegador.
revoke execute on function public.revertir_caja_factura_franquicia_v45(uuid, text)
  from public, anon, authenticated;
revoke execute on function public.aplicar_factura_venta_franquicia_v44(jsonb, jsonb, text) from public, anon;
grant execute on function public.aplicar_factura_venta_franquicia_v44(jsonb, jsonb, text) to authenticated;

notify pgrst, 'reload schema';
