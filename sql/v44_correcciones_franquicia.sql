-- ============================================================
-- BOMAN INVENTARIO - v44: correcciones de la operacion de franquicia
--
-- Corrige tres defectos de v42 y habilita la factura XML en el local:
--   1. La reversa de caja restaba dos veces.
--   2. No existia forma de anular una venta.
--   3. El motor de facturas XML rechaza los roles de franquicia.
--
-- Ejecutar despues de v42. Es independiente de v43.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Saldo de caja: la reversa neutraliza, no resta de nuevo
-- ------------------------------------------------------------
-- revertir_caja_franquicia_v42 hace dos cosas: marca el original como
-- 'revertido' (con lo que ya deja de sumar en la vista) y ademas crea una
-- contrapartida 'vigente' de signo contrario. Revertir un ingreso de 100
-- terminaba mostrando -100 en vez de 0. La contrapartida se conserva porque es
-- la evidencia de la reversa en el diario, pero no debe entrar al saldo: el
-- original ya salio de el.
create or replace view public.vista_caja_franquicia_v42
with (security_invoker = true) as
select m.*, f.nombre franquicia,
       sum(case when m.estado = 'vigente' and m.reversa_de_id is null and m.tipo = 'ingreso' then m.monto
                when m.estado = 'vigente' and m.reversa_de_id is null and m.tipo = 'egreso' then -m.monto
                else 0 end)
         over (partition by m.franquicia_id order by m.fecha, m.created_at, m.id)
         as saldo_acumulado
from public.franquicia_caja_movimientos m
join public.franquicias f on f.id = m.franquicia_id;

-- ------------------------------------------------------------
-- 2. Anulacion de venta de franquicia
-- ------------------------------------------------------------
-- Devuelve el stock, neutraliza el ingreso de caja y conserva la venta con su
-- motivo. No borra nada: la venta queda 'anulada' y los movimientos de
-- inventario quedan como devolucion, que es lo que exige la auditoria.
create or replace function public.anular_venta_franquicia_v44(
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
  mov public.franquicia_caja_movimientos%rowtype;
  it record;
begin
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica el motivo de la anulacion con al menos 10 caracteres';
  end if;

  select * into v from public.ventas_franquicia where id = p_venta_id for update;
  if not found then raise exception 'La venta no existe'; end if;

  -- Idempotencia: si esta venta ya fue anulada con esta misma clave, se
  -- responde igual en vez de devolver stock por segunda vez.
  if v.estado = 'anulada' then
    if exists (
      select 1 from public.franquicia_caja_movimientos
      where idempotency_key = p_idempotency_key and reversa_de_id is not null
    ) or v.total = 0 then
      return jsonb_build_object('id', v.id, 'duplicado', true,
        'mensaje', 'La venta ya estaba anulada; no se repitio el movimiento');
    end if;
    raise exception 'La venta ya fue anulada';
  end if;

  if public.rol_usuario_actual() <> 'admin' then
    if not public.usuario_puede_franquicia_v42(v.franquicia_id, true, true)
       or not public.usuario_tiene_permiso_v35('franquicia.ventas') then
      raise exception 'No tienes permiso para anular ventas de este local';
    end if;
  end if;

  select * into f from public.franquicias where id = v.franquicia_id;
  if not found or not f.activo then
    raise exception 'La franquicia no esta activa';
  end if;

  -- Stock de vuelta al local.
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

  -- Caja: el ingreso original sale del saldo y queda su contrapartida como
  -- evidencia. La contrapartida no lleva venta_id porque la tabla admite un
  -- solo movimiento por venta.
  select * into mov from public.franquicia_caja_movimientos
  where venta_id = v.id and estado = 'vigente' for update;
  if found then
    update public.franquicia_caja_movimientos
    set estado = 'revertido',
        motivo_reversa = 'Venta anulada: ' || btrim(p_motivo)
    where id = mov.id;
    insert into public.franquicia_caja_movimientos (
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, reversa_de_id, motivo_reversa, idempotency_key, creado_por
    ) values (
      mov.franquicia_id, current_date,
      case when mov.tipo = 'ingreso' then 'egreso' else 'ingreso' end,
      'reversa', 'Anulacion venta #' || v.numero, mov.monto, mov.medio_pago,
      mov.referencia, mov.id, btrim(p_motivo), p_idempotency_key, auth.uid()
    );
  end if;

  update public.ventas_franquicia
  set estado = 'anulada', anulada_por = auth.uid(), anulada_at = now(),
      motivo_anulacion = btrim(p_motivo)
  where id = v.id;

  return jsonb_build_object('id', v.id, 'numero', v.numero, 'duplicado', false,
    'mensaje', 'Venta anulada; el stock volvio al local y la caja quedo en cero');
end;
$fn$;

-- ------------------------------------------------------------
-- 3. Factura XML emitida por el propio local
-- ------------------------------------------------------------
-- El motor historico (v13) valida el rol contra una lista fija que no conoce a
-- la franquicia. Se le agregan los dos roles nuevos con la misma tecnica que ya
-- usa v42, sin tocar ninguna de sus reglas de stock. La contencion sigue siendo
-- la de siempre: mas abajo exige usuario_puede_almacen(p_almacen_id, true) y
-- v20 exige usuario_puede_capacidad_empresa, de modo que el titular solo puede
-- aplicar facturas contra su propio local y su propio RUC.
do $migra$
declare
  v_oid oid;
  v_def text;
  v_nuevo text;
  v_check text;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'aplicar_factura_venta_xml'
  order by p.oid desc limit 1;
  if v_oid is null then
    raise exception 'No se encontro aplicar_factura_venta_xml; ejecuta v13 antes que v44';
  end if;
  v_def := pg_get_functiondef(v_oid);

  -- Ya habilitado (v44 reejecutado): no hay nada que hacer.
  if v_def like '%vendedor_franquicia%' then
    raise notice 'aplicar_factura_venta_xml ya admite los roles de franquicia';
    return;
  end if;

  -- La lista de roles se busca por forma, no por texto literal, porque la
  -- version instalada puede tener otros roles o distinto espaciado que el
  -- archivo v13 original.
  v_nuevo := regexp_replace(v_def,
    '(v_rol\s+not\s+in\s*\()([^)]*)(\))',
    '\1\2, ''franquiciado'', ''vendedor_franquicia''\3');

  if v_nuevo = v_def then
    v_nuevo := regexp_replace(v_def,
      '(public\.rol_usuario_actual\(\)\s+not\s+in\s*\()([^)]*)(\))',
      '\1\2, ''franquiciado'', ''vendedor_franquicia''\3');
  end if;

  if v_nuevo = v_def then
    v_check := coalesce((regexp_match(v_def, '[^\n]*not\s+in\s*\([^)]*\)[^\n]*'))[1],
                        '(no se encontro ninguna validacion de rol)');
    raise exception
      'No se pudo habilitar el rol de franquicia en aplicar_factura_venta_xml. La validacion instalada es: %', v_check;
  end if;

  execute v_nuevo;
end;
$migra$;

-- Envoltorio que el panel del local usa: resuelve solo su almacen, aplica la
-- factura y registra el ingreso en la caja de la franquicia, que era lo que
-- faltaba para que el XML sustituyera de verdad a la venta simple.
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

  v_total := round(coalesce((p_documento->>'importe_total')::numeric, 0), 2);
  v_numero := coalesce(v_resultado->>'numero_documento', p_documento->>'numero_documento');

  if v_total > 0 then
    insert into public.franquicia_caja_movimientos (
      franquicia_id, fecha, tipo, categoria, concepto, monto, medio_pago,
      referencia, idempotency_key, creado_por
    ) values (
      f.id, coalesce((p_documento->>'fecha_emision')::date, current_date),
      'ingreso', 'venta', 'Factura ' || v_numero, v_total, 'otro',
      v_numero,
      -- La clave de acceso del SRI es unica por factura, asi que derivar de
      -- ella la idempotencia impide un segundo ingreso por el mismo documento.
      md5(coalesce(p_documento->>'clave_acceso', v_numero))::uuid,
      auth.uid()
    )
    on conflict (idempotency_key) do nothing;
  end if;

  return v_resultado || jsonb_build_object('caja', v_total);
end;
$fn$;

alter function public.anular_venta_franquicia_v44(uuid, text, uuid) owner to postgres;
alter function public.aplicar_factura_venta_franquicia_v44(jsonb, jsonb, text) owner to postgres;

revoke execute on function public.anular_venta_franquicia_v44(uuid, text, uuid) from public, anon;
revoke execute on function public.aplicar_factura_venta_franquicia_v44(jsonb, jsonb, text) from public, anon;
grant execute on function public.anular_venta_franquicia_v44(uuid, text, uuid) to authenticated;
grant execute on function public.aplicar_factura_venta_franquicia_v44(jsonb, jsonb, text) to authenticated;

-- ------------------------------------------------------------
-- 4. La clave temporal deja de ser permanente
-- ------------------------------------------------------------
-- Crear un usuario con clave temporal evita el limite de correos de Supabase,
-- pero esa clave viaja por WhatsApp o de viva voz. Mientras la marca este
-- puesta, el middleware manda al usuario a /establecer-clave y no lo deja
-- entrar a ninguna otra pantalla.
alter table public.perfiles
  add column if not exists clave_temporal_desde timestamptz;

comment on column public.perfiles.clave_temporal_desde is
  'Fecha en que se emitio una clave temporal. Distinto de null obliga a cambiarla antes de usar el sistema.';

-- La limpia el propio usuario, pero solo si su contrasena cambio de verdad
-- despues de la emision. Llamar la funcion sin cambiarla no sirve de nada.
create or replace function public.confirmar_cambio_clave_v44()
returns boolean
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_desde timestamptz;
  v_actualizado timestamptz;
begin
  select clave_temporal_desde into v_desde from public.perfiles where id = auth.uid();
  if v_desde is null then return true; end if;

  select updated_at into v_actualizado from auth.users where id = auth.uid();
  if v_actualizado is null or v_actualizado <= v_desde then
    return false;
  end if;

  update public.perfiles set clave_temporal_desde = null where id = auth.uid();
  return true;
end;
$fn$;

alter function public.confirmar_cambio_clave_v44() owner to postgres;
revoke execute on function public.confirmar_cambio_clave_v44() from public, anon;
grant execute on function public.confirmar_cambio_clave_v44() to authenticated;

notify pgrst, 'reload schema';

-- Salida de emergencia si un usuario quedara atrapado en /establecer-clave:
--   update public.perfiles set clave_temporal_desde = null where id = '<uuid>';
