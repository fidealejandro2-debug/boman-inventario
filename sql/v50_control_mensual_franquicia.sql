-- ============================================================
-- BOMAN INVENTARIO - v50: control mensual del local
--
--   1. Permisos separados para cambiar precio y para aplicar descuento.
--   2. Conteo fisico hecho por el local, aprobado por Control.
--   3. Resumen mensual de ingresos, egresos, resultado e inventario.
--
-- Ejecutar despues de v49.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Quien puede tocar el precio y quien puede descontar
-- ------------------------------------------------------------
-- Hasta ahora cualquiera que pudiera vender escribia el precio que quisiera y
-- el descuento que quisiera. Son dos decisiones distintas y de distinto riesgo,
-- asi que son dos permisos: el titular normalmente los tiene, el vendedor no.
insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('franquicia.precio_libre', 'Franquicias', 'Cambiar el precio de venta',
   'Permite vender a un precio distinto al del catalogo. Sin esto, la venta se registra al precio de lista.', 125),
  ('franquicia.descuento', 'Franquicias', 'Aplicar descuentos',
   'Permite descontar sobre la linea o sobre el total de la venta.', 126)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.activo
on conflict (rol, permiso_codigo) do nothing;

-- El titular del local decide sus precios; el vendedor vende al precio de
-- lista. Se puede cambiar despues en Administracion -> Permisos por rol.
update public.rol_permisos set permitido = true, updated_at = now()
where rol::text = 'franquiciado'
  and permiso_codigo in ('franquicia.precio_libre', 'franquicia.descuento');

-- ------------------------------------------------------------
-- 2. Venta que respeta esos permisos
-- ------------------------------------------------------------
-- Reemplaza a v47. Unico cambio de fondo: valida precio y descuento contra el
-- permiso de quien registra, antes de tocar stock o caja.
create or replace function public.registrar_venta_franquicia_v50(
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
  v_puede_precio boolean;
  v_puede_descuento boolean;
  v_linea record;
begin
  v_puede_precio := public.usuario_tiene_permiso_v35('franquicia.precio_libre');
  v_puede_descuento := public.usuario_tiene_permiso_v35('franquicia.descuento');

  if not v_puede_descuento then
    if coalesce(p_descuento, 0) <> 0 then
      raise exception 'No tienes permiso para aplicar descuentos';
    end if;
    if exists (
      select 1 from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
        x(descuento numeric)
      where coalesce(x.descuento, 0) <> 0
    ) then
      raise exception 'No tienes permiso para aplicar descuentos';
    end if;
  end if;

  if not v_puede_precio then
    -- El precio de lista es el del catalogo. Si la prenda no tiene precio
    -- cargado no hay contra que comparar, y vender "a lo que salga" es
    -- justamente lo que este permiso evita.
    for v_linea in
      select x.producto_id, x.precio_unitario, pr.precio as precio_lista, pr.sku
      from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
        x(producto_id uuid, precio_unitario numeric)
      left join public.productos pr on pr.id = x.producto_id
    loop
      if v_linea.precio_lista is null then
        raise exception
          'La prenda % no tiene precio de catalogo. Pide que lo carguen o que te habiliten el cambio de precio.',
          coalesce(v_linea.sku, '(desconocida)');
      end if;
      if round(coalesce(v_linea.precio_unitario, -1), 2) <> round(v_linea.precio_lista, 2) then
        raise exception
          'No tienes permiso para cambiar el precio. La prenda % se vende a %.',
          v_linea.sku, round(v_linea.precio_lista, 2);
      end if;
    end loop;
  end if;

  return public.registrar_venta_franquicia_v47(
    p_fecha, p_items, p_pagos, p_descuento, p_referencia, p_nota, p_idempotency_key
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 3. Conteo fisico del local
-- ------------------------------------------------------------
-- El motor de conteos de v12 ya hace lo necesario: congela el stock del
-- sistema, admite reconteo, calcula diferencias y aplica el ajuste auditado.
-- Solo desconocia al franquiciado. Se le habilita el conteo y el reconteo,
-- NUNCA la resolucion: resolver_conteo_inventario sigue siendo de Control y ya
-- impide aprobar el conteo propio. El local cuenta, otro aprueba.
do $migra$
declare
  v_fn text;
  v_oid oid;
  v_def text;
  v_nuevo text;
begin
  foreach v_fn in array array[
    'crear_conteo_inventario',
    'guardar_conteo_inventario',
    'guardar_reconteo_inventario'
  ] loop
    select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_fn
    order by p.oid desc limit 1;
    if v_oid is null then
      raise exception 'No se encontro %; ejecuta v12 antes que v50', v_fn;
    end if;

    v_def := pg_get_functiondef(v_oid);
    if v_def like '%franquiciado%' then
      raise notice '% ya admite al franquiciado', v_fn;
      continue;
    end if;

    v_nuevo := regexp_replace(v_def,
      '(not\s+in\s*\(\s*''admin''\s*,\s*''control''\s*,\s*''bodega''\s*,\s*''tienda''\s*)(\))',
      '\1, ''franquiciado''\2');

    if v_nuevo = v_def then
      raise exception
        'No se pudo habilitar el conteo del local en %: la validacion de rol cambio de forma', v_fn;
    end if;
    execute v_nuevo;
  end loop;
end;
$migra$;

-- La pantalla de conteos ya existe y filtra por almacen asignado, asi que el
-- local entra a la suya sin ninguna interfaz nueva.
update public.rol_permisos set permitido = true, updated_at = now()
where rol::text = 'franquiciado' and permiso_codigo = 'conteos.acceder';

-- ------------------------------------------------------------
-- 4. Resumen mensual
-- ------------------------------------------------------------
-- El resultado es de CAJA: lo que entro menos lo que salio del local. No
-- descuenta el costo de la mercaderia, porque el local la recibe por
-- transferencia y ese costo se controla a nivel de grupo. Se nombra
-- 'resultado_operativo' y no 'utilidad' justamente para no confundirlo con una
-- utilidad contable.
create or replace view public.vista_resumen_mensual_franquicia_v50
with (security_invoker = true) as
with movimientos as (
  select
    m.franquicia_id,
    date_trunc('month', m.fecha)::date as mes,
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso'), 0) as ingresos,
    coalesce(sum(m.monto) filter (where m.tipo = 'egreso'), 0) as egresos,
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.categoria = 'venta'), 0) as ingresos_venta,
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'), 0) as ingresos_efectivo,
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'transferencia'), 0) as ingresos_transferencia,
    coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'tarjeta'), 0) as ingresos_tarjeta
  from public.franquicia_caja_movimientos m
  -- Misma regla que el saldo: el original revertido ya salio, y su
  -- contrapartida es evidencia, no un movimiento mas.
  where m.estado = 'vigente' and m.reversa_de_id is null
  group by m.franquicia_id, date_trunc('month', m.fecha)
),
ventas as (
  select
    v.franquicia_id,
    date_trunc('month', v.fecha)::date as mes,
    count(*) filter (where v.estado = 'registrada') as ventas_registradas,
    count(*) filter (where v.estado = 'anulada') as ventas_anuladas,
    coalesce(sum(v.total) filter (where v.estado = 'registrada'), 0) as total_vendido,
    coalesce(sum(v.descuento) filter (where v.estado = 'registrada'), 0) as descuentos,
    coalesce(sum(l.unidades) filter (where v.estado = 'registrada'), 0) as unidades
  from public.ventas_franquicia v
  left join lateral (
    select sum(cantidad) as unidades
    from public.venta_franquicia_lineas where venta_id = v.id
  ) l on true
  group by v.franquicia_id, date_trunc('month', v.fecha)
),
-- Un mes existe en el reporte si tuvo movimientos de caja o ventas. Armar la
-- lista de claves primero evita el full outer join, que con tres origenes se
-- vuelve ilegible y pierde filas en cuanto uno de los lados es nulo.
claves as (
  select franquicia_id, mes from movimientos
  union
  select franquicia_id, mes from ventas
),
cierres as (
  select franquicia_id, date_trunc('month', fecha)::date as mes,
         count(*) as dias_cerrados,
         coalesce(sum(diferencia), 0) as diferencia_acumulada,
         count(*) filter (where abs(diferencia) >= 0.01) as dias_con_diferencia
  from public.franquicia_caja_cierres
  where estado = 'cerrado'
  group by franquicia_id, date_trunc('month', fecha)
)
select
  k.franquicia_id,
  f.nombre as franquicia,
  k.mes,
  extract(year from k.mes)::integer as anio,
  extract(month from k.mes)::integer as numero_mes,
  coalesce(m.ingresos, 0) as ingresos,
  coalesce(m.egresos, 0) as egresos,
  coalesce(m.ingresos, 0) - coalesce(m.egresos, 0) as resultado_operativo,
  coalesce(m.ingresos_venta, 0) as ingresos_por_venta,
  coalesce(m.ingresos, 0) - coalesce(m.ingresos_venta, 0) as otros_ingresos,
  coalesce(m.ingresos_efectivo, 0) as ingresos_efectivo,
  coalesce(m.ingresos_transferencia, 0) as ingresos_transferencia,
  coalesce(m.ingresos_tarjeta, 0) as ingresos_tarjeta,
  coalesce(v.ventas_registradas, 0) as ventas_registradas,
  coalesce(v.ventas_anuladas, 0) as ventas_anuladas,
  coalesce(v.total_vendido, 0) as total_vendido,
  coalesce(v.descuentos, 0) as descuentos_otorgados,
  coalesce(v.unidades, 0) as unidades_vendidas,
  coalesce(c.dias_cerrados, 0) as dias_cerrados,
  coalesce(c.dias_con_diferencia, 0) as dias_con_diferencia,
  coalesce(c.diferencia_acumulada, 0) as diferencia_acumulada
from claves k
join public.franquicias f on f.id = k.franquicia_id
left join movimientos m on m.franquicia_id = k.franquicia_id and m.mes = k.mes
left join ventas v on v.franquicia_id = k.franquicia_id and v.mes = k.mes
left join cierres c on c.franquicia_id = k.franquicia_id and c.mes = k.mes;

-- Valor del inventario del local, hoy. Se valora a precio de catalogo porque
-- es el unico valor unitario que el local tiene cargado.
create or replace view public.vista_inventario_valorizado_franquicia_v50
with (security_invoker = true) as
select
  f.id as franquicia_id,
  f.nombre as franquicia,
  count(*) filter (where s.stock_fisico > 0) as prendas_con_stock,
  coalesce(sum(s.stock_fisico), 0) as unidades,
  coalesce(sum(s.stock_fisico * coalesce(s.precio, 0)), 0) as valor_a_precio_venta,
  count(*) filter (where s.bajo_minimo and s.stock_fisico > 0) as prendas_bajo_minimo,
  count(*) filter (where s.stock_fisico = 0) as prendas_sin_stock
from public.franquicias f
join public.vista_stock_operativo s on s.almacen_id = f.almacen_id
group by f.id, f.nombre;

alter function public.registrar_venta_franquicia_v50(date,jsonb,jsonb,numeric,text,text,uuid)
  owner to postgres;

revoke all on public.vista_resumen_mensual_franquicia_v50 from public, anon;
revoke all on public.vista_inventario_valorizado_franquicia_v50 from public, anon;
grant select on public.vista_resumen_mensual_franquicia_v50 to authenticated;
grant select on public.vista_inventario_valorizado_franquicia_v50 to authenticated;

-- La version de v47 no valida los permisos de precio ni descuento: se cierra.
revoke execute on function public.registrar_venta_franquicia_v47(date,jsonb,jsonb,numeric,text,text,uuid)
  from public, anon, authenticated;
revoke execute on function public.registrar_venta_franquicia_v50(date,jsonb,jsonb,numeric,text,text,uuid)
  from public, anon;
grant execute on function public.registrar_venta_franquicia_v50(date,jsonb,jsonb,numeric,text,text,uuid)
  to authenticated;

notify pgrst, 'reload schema';
