-- ============================================================
-- BOMAN INVENTARIO - v58: comprobantes de compra y retenciones
--
-- Compras guardaba la orden y la recepcion con su costo, pero no el
-- comprobante del proveedor: sin numero de factura, sin autorizacion, sin
-- desglose por tarifa y sin retenciones no hay libro de compras ni ATS, y el
-- contador termina rearmando a mano lo que el sistema ya sabe.
--
-- Tres piezas:
--   1. El comprobante recibido, con su desglose tributario.
--   2. Las retenciones que se le practican, de IVA y de renta.
--   3. El libro de compras del mes, listo para el contador.
--
-- Ejecutar despues de v57.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Catalogos tributarios, como DATOS y no como constantes
-- ------------------------------------------------------------
-- Los porcentajes y codigos de retencion los cambia el SRI por resolucion. Si
-- vivieran dentro de un CHECK, cada cambio exigiria una migracion y hasta
-- entonces el sistema estaria calculando mal en silencio. Aqui se editan.
create table if not exists public.retencion_conceptos (
  codigo text primary key check (btrim(codigo) <> ''),
  clase text not null check (clase in ('iva', 'renta')),
  nombre text not null check (btrim(nombre) <> ''),
  porcentaje numeric(7,4) not null check (porcentaje >= 0 and porcentaje <= 100),
  activo boolean not null default true,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  updated_at timestamptz not null default now()
);

comment on table public.retencion_conceptos is
  'Codigos y porcentajes de retencion. Verificar contra la resolucion vigente del SRI antes de usarlos: se siembran los habituales, no son ley.';

insert into public.retencion_conceptos (codigo, clase, nombre, porcentaje) values
  ('721', 'iva', 'Retencion IVA 30% - bienes', 30),
  ('723', 'iva', 'Retencion IVA 70% - servicios', 70),
  ('725', 'iva', 'Retencion IVA 100% - profesionales y arriendos', 100),
  ('312', 'renta', 'Compra de bienes muebles 1.75%', 1.75),
  ('320', 'renta', 'Servicios donde predomina la mano de obra 2%', 2),
  ('322', 'renta', 'Servicios donde predomina el intelecto 8%', 8),
  ('303', 'renta', 'Honorarios profesionales 10%', 10),
  ('332', 'renta', 'Otras compras de bienes y servicios 2.75%', 2.75)
on conflict (codigo) do nothing;

-- Sustento tributario: para que sirve la compra frente al SRI.
create table if not exists public.sustentos_tributarios (
  codigo text primary key,
  nombre text not null,
  activo boolean not null default true
);
insert into public.sustentos_tributarios (codigo, nombre) values
  ('01', 'Credito tributario para declaracion de IVA'),
  ('02', 'Costo o gasto para declaracion de impuesto a la renta'),
  ('03', 'Activo fijo - credito tributario para IVA'),
  ('04', 'Activo fijo - costo o gasto para renta'),
  ('05', 'Liquidacion de gastos de viaje, hospedaje y alimentacion'),
  ('06', 'Inventario - credito tributario para IVA'),
  ('07', 'Inventario - costo o gasto para renta'),
  ('08', 'Valor pagado para solicitar reembolso'),
  ('00', 'Casos especiales cuyo sustento no aplica')
on conflict (codigo) do nothing;

-- ------------------------------------------------------------
-- 1. El comprobante recibido
-- ------------------------------------------------------------
create table if not exists public.comprobantes_compra (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  proveedor_id uuid not null references public.proveedores(id) on delete restrict,
  tipo text not null check (tipo in (
    'factura', 'nota_venta', 'liquidacion_compra',
    'nota_credito', 'nota_debito', 'comprobante_retencion'
  )),
  establecimiento text not null check (establecimiento ~ '^[0-9]{3}$'),
  punto_emision text not null check (punto_emision ~ '^[0-9]{3}$'),
  secuencial text not null check (secuencial ~ '^[0-9]{9}$'),
  numero_documento text generated always as
    (establecimiento || '-' || punto_emision || '-' || secuencial) stored,
  clave_acceso text check (clave_acceso is null or clave_acceso ~ '^[0-9]{49}$'),
  numero_autorizacion text,
  fecha_emision date not null,
  fecha_autorizacion timestamptz,
  sustento_codigo text not null default '01'
    references public.sustentos_tributarios(codigo) on delete restrict,

  -- Desglose por tarifa. Se guarda el porcentaje y no un enum 12/15: la tarifa
  -- general ya cambio una vez y volvera a cambiar.
  base_cero numeric(14,2) not null default 0 check (base_cero >= 0),
  base_gravada numeric(14,2) not null default 0 check (base_gravada >= 0),
  tarifa_gravada numeric(7,4) not null default 15 check (tarifa_gravada >= 0 and tarifa_gravada <= 100),
  base_no_objeto numeric(14,2) not null default 0 check (base_no_objeto >= 0),
  base_exenta numeric(14,2) not null default 0 check (base_exenta >= 0),
  monto_iva numeric(14,2) not null default 0 check (monto_iva >= 0),
  monto_ice numeric(14,2) not null default 0 check (monto_ice >= 0),
  propina numeric(14,2) not null default 0 check (propina >= 0),
  total numeric(14,2) not null check (total >= 0),

  forma_pago text,
  orden_compra_id uuid references public.ordenes_compra(id) on delete restrict,
  recepcion_id uuid references public.recepciones_compra(id) on delete restrict,
  nota text,
  archivo_nombre text,
  archivo_hash text check (archivo_hash is null or archivo_hash ~ '^[0-9a-f]{64}$'),

  estado text not null default 'registrado'
    check (estado in ('registrado', 'anulado')),
  motivo_anulacion text,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,

  idempotency_key uuid not null unique,
  registrado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),

  -- El mismo comprobante no se registra dos veces para la misma empresa.
  unique (empresa_id, proveedor_id, tipo, establecimiento, punto_emision, secuencial),
  -- El total tiene que cuadrar con su desglose, o el libro de compras no sirve.
  check (
    round(total, 2) = round(
      base_cero + base_gravada + base_no_objeto + base_exenta
      + monto_iva + monto_ice + propina, 2)
  )
);

create unique index if not exists uq_comprobante_compra_clave_v58
  on public.comprobantes_compra(clave_acceso)
  where clave_acceso is not null;
create index if not exists idx_comprobante_compra_empresa_fecha_v58
  on public.comprobantes_compra(empresa_id, fecha_emision desc);
create index if not exists idx_comprobante_compra_proveedor_v58
  on public.comprobantes_compra(proveedor_id, fecha_emision desc);

create table if not exists public.comprobante_compra_lineas (
  id uuid primary key default gen_random_uuid(),
  comprobante_id uuid not null
    references public.comprobantes_compra(id) on delete cascade,
  numero_linea integer not null check (numero_linea > 0),
  codigo_proveedor text,
  descripcion text not null check (btrim(descripcion) <> ''),
  cantidad numeric(14,4) not null check (cantidad > 0),
  precio_unitario numeric(16,4) not null check (precio_unitario >= 0),
  descuento numeric(14,2) not null default 0 check (descuento >= 0),
  subtotal numeric(14,2) not null check (subtotal >= 0),
  tarifa_iva numeric(7,4) not null default 0 check (tarifa_iva >= 0 and tarifa_iva <= 100),
  valor_iva numeric(14,2) not null default 0 check (valor_iva >= 0),
  -- Opcional: la factura del proveedor no siempre corresponde a una prenda del
  -- catalogo (servicios, fletes, suministros).
  producto_id uuid references public.productos(id) on delete restrict,
  unique (comprobante_id, numero_linea)
);

-- ------------------------------------------------------------
-- 2. Retenciones practicadas
-- ------------------------------------------------------------
create table if not exists public.retenciones_compra (
  id uuid primary key default gen_random_uuid(),
  comprobante_id uuid not null
    references public.comprobantes_compra(id) on delete cascade,
  concepto_codigo text not null
    references public.retencion_conceptos(codigo) on delete restrict,
  base_imponible numeric(14,2) not null check (base_imponible >= 0),
  porcentaje numeric(7,4) not null check (porcentaje >= 0 and porcentaje <= 100),
  valor numeric(14,2) not null check (valor >= 0),
  -- El comprobante de retencion es un documento propio, con su numeracion.
  establecimiento text check (establecimiento is null or establecimiento ~ '^[0-9]{3}$'),
  punto_emision text check (punto_emision is null or punto_emision ~ '^[0-9]{3}$'),
  secuencial text check (secuencial is null or secuencial ~ '^[0-9]{9}$'),
  clave_acceso text check (clave_acceso is null or clave_acceso ~ '^[0-9]{49}$'),
  fecha_emision date,
  created_at timestamptz not null default now(),
  unique (comprobante_id, concepto_codigo),
  -- El valor se recalcula, no se cree: un dedazo en la retencion se paga con
  -- una glosa.
  check (round(valor, 2) = round(base_imponible * porcentaje / 100, 2))
);

create index if not exists idx_retenciones_compra_comprobante_v58
  on public.retenciones_compra(comprobante_id);

-- ------------------------------------------------------------
-- 3. Registro del comprobante
-- ------------------------------------------------------------
create or replace function public.registrar_comprobante_compra_v58(
  p_comprobante jsonb,
  p_lineas jsonb,
  p_retenciones jsonb,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
  v_empresa uuid := nullif(p_comprobante->>'empresa_id', '')::uuid;
  v_proveedor uuid := nullif(p_comprobante->>'proveedor_id', '')::uuid;
  v_total numeric(14,2);
  v_suma_lineas numeric(14,2);
  r record;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'gerencia') then
    raise exception 'No tienes permiso para registrar comprobantes de compra';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;

  select id into v_id from public.comprobantes_compra
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_id, 'duplicado', true);
  end if;

  if v_empresa is null or not public.usuario_puede_empresa(v_empresa, true) then
    raise exception 'No tienes permiso sobre la empresa que recibe la compra';
  end if;
  if v_proveedor is null then raise exception 'Falta el proveedor'; end if;
  if jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'El comprobante debe tener al menos una linea';
  end if;

  v_total := round((p_comprobante->>'total')::numeric, 2);

  insert into public.comprobantes_compra (
    empresa_id, proveedor_id, tipo, establecimiento, punto_emision, secuencial,
    clave_acceso, numero_autorizacion, fecha_emision, fecha_autorizacion,
    sustento_codigo, base_cero, base_gravada, tarifa_gravada, base_no_objeto,
    base_exenta, monto_iva, monto_ice, propina, total, forma_pago,
    orden_compra_id, recepcion_id, nota, archivo_nombre, archivo_hash,
    idempotency_key, registrado_por
  ) values (
    v_empresa, v_proveedor,
    coalesce(p_comprobante->>'tipo', 'factura'),
    p_comprobante->>'establecimiento',
    p_comprobante->>'punto_emision',
    p_comprobante->>'secuencial',
    nullif(p_comprobante->>'clave_acceso', ''),
    nullif(p_comprobante->>'numero_autorizacion', ''),
    (p_comprobante->>'fecha_emision')::date,
    nullif(p_comprobante->>'fecha_autorizacion', '')::timestamptz,
    coalesce(nullif(p_comprobante->>'sustento_codigo', ''), '01'),
    coalesce((p_comprobante->>'base_cero')::numeric, 0),
    coalesce((p_comprobante->>'base_gravada')::numeric, 0),
    coalesce((p_comprobante->>'tarifa_gravada')::numeric, 15),
    coalesce((p_comprobante->>'base_no_objeto')::numeric, 0),
    coalesce((p_comprobante->>'base_exenta')::numeric, 0),
    coalesce((p_comprobante->>'monto_iva')::numeric, 0),
    coalesce((p_comprobante->>'monto_ice')::numeric, 0),
    coalesce((p_comprobante->>'propina')::numeric, 0),
    v_total,
    nullif(p_comprobante->>'forma_pago', ''),
    nullif(p_comprobante->>'orden_compra_id', '')::uuid,
    nullif(p_comprobante->>'recepcion_id', '')::uuid,
    nullif(p_comprobante->>'nota', ''),
    nullif(p_comprobante->>'archivo_nombre', ''),
    nullif(p_comprobante->>'archivo_hash', ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;

  insert into public.comprobante_compra_lineas (
    comprobante_id, numero_linea, codigo_proveedor, descripcion, cantidad,
    precio_unitario, descuento, subtotal, tarifa_iva, valor_iva, producto_id
  )
  select
    v_id, x.numero_linea, nullif(x.codigo_proveedor, ''), x.descripcion,
    x.cantidad, x.precio_unitario, coalesce(x.descuento, 0), x.subtotal,
    coalesce(x.tarifa_iva, 0), coalesce(x.valor_iva, 0), x.producto_id
  from jsonb_to_recordset(p_lineas) x(
    numero_linea integer, codigo_proveedor text, descripcion text,
    cantidad numeric, precio_unitario numeric, descuento numeric,
    subtotal numeric, tarifa_iva numeric, valor_iva numeric, producto_id uuid
  );

  -- Las lineas tienen que sumar la base del comprobante. Si no cuadra, el
  -- libro de compras nace mal y se detecta en la declaracion, no aqui.
  select round(coalesce(sum(subtotal), 0), 2) into v_suma_lineas
  from public.comprobante_compra_lineas where comprobante_id = v_id;

  if v_suma_lineas <> round(
       coalesce((p_comprobante->>'base_cero')::numeric, 0)
     + coalesce((p_comprobante->>'base_gravada')::numeric, 0)
     + coalesce((p_comprobante->>'base_no_objeto')::numeric, 0)
     + coalesce((p_comprobante->>'base_exenta')::numeric, 0), 2) then
    raise exception
      'Las lineas suman % y las bases del comprobante suman otra cosa. Revisa el desglose antes de registrarlo.',
      v_suma_lineas;
  end if;

  if jsonb_typeof(coalesce(p_retenciones, '[]'::jsonb)) = 'array' then
    for r in
      select * from jsonb_to_recordset(coalesce(p_retenciones, '[]'::jsonb)) y(
        concepto_codigo text, base_imponible numeric, porcentaje numeric,
        establecimiento text, punto_emision text, secuencial text,
        clave_acceso text, fecha_emision date
      )
    loop
      insert into public.retenciones_compra (
        comprobante_id, concepto_codigo, base_imponible, porcentaje, valor,
        establecimiento, punto_emision, secuencial, clave_acceso, fecha_emision
      ) values (
        v_id, r.concepto_codigo, round(r.base_imponible, 2), r.porcentaje,
        -- El valor se calcula aqui: lo que mande la interfaz es una sugerencia.
        round(r.base_imponible * r.porcentaje / 100, 2),
        nullif(r.establecimiento, ''), nullif(r.punto_emision, ''),
        nullif(r.secuencial, ''), nullif(r.clave_acceso, ''), r.fecha_emision
      );
    end loop;
  end if;

  return jsonb_build_object('id', v_id, 'duplicado', false,
    'numero_documento', (select numero_documento from public.comprobantes_compra where id = v_id));
end;
$fn$;

create or replace function public.anular_comprobante_compra_v58(
  p_comprobante_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare c public.comprobantes_compra%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control puede anular un comprobante de compra';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La anulacion requiere un motivo de al menos 10 caracteres';
  end if;
  select * into c from public.comprobantes_compra where id = p_comprobante_id for update;
  if not found then raise exception 'El comprobante no existe'; end if;
  if c.estado = 'anulado' then raise exception 'Ese comprobante ya estaba anulado'; end if;

  -- No se borra: un comprobante anulado tambien se declara, con su motivo.
  update public.comprobantes_compra
  set estado = 'anulado', motivo_anulacion = btrim(p_motivo),
      anulado_por = auth.uid(), anulado_at = now()
  where id = c.id;
end;
$fn$;

-- ------------------------------------------------------------
-- 4. Libro de compras del mes
-- ------------------------------------------------------------
create or replace view public.vista_libro_compras_v58
with (security_invoker = true) as
select
  c.id as comprobante_id,
  c.empresa_id,
  e.razon_social as empresa,
  e.ruc as ruc_empresa,
  date_trunc('month', c.fecha_emision)::date as mes,
  extract(year from c.fecha_emision)::integer as anio,
  extract(month from c.fecha_emision)::integer as numero_mes,
  c.fecha_emision,
  c.tipo,
  c.numero_documento,
  c.numero_autorizacion,
  c.clave_acceso,
  p.tipo_identificacion,
  p.identificacion as ruc_proveedor,
  p.razon_social as proveedor,
  c.sustento_codigo,
  s.nombre as sustento,
  c.base_cero,
  c.base_gravada,
  c.tarifa_gravada,
  c.base_no_objeto,
  c.base_exenta,
  c.monto_iva,
  c.monto_ice,
  c.total,
  coalesce(ret.retencion_iva, 0) as retencion_iva,
  coalesce(ret.retencion_renta, 0) as retencion_renta,
  round(c.total - coalesce(ret.retencion_iva, 0) - coalesce(ret.retencion_renta, 0), 2)
    as neto_a_pagar,
  c.estado,
  c.forma_pago
from public.comprobantes_compra c
join public.empresas e on e.id = c.empresa_id
join public.proveedores p on p.id = c.proveedor_id
left join public.sustentos_tributarios s on s.codigo = c.sustento_codigo
left join lateral (
  select
    coalesce(sum(r.valor) filter (where rc.clase = 'iva'), 0) as retencion_iva,
    coalesce(sum(r.valor) filter (where rc.clase = 'renta'), 0) as retencion_renta
  from public.retenciones_compra r
  join public.retencion_conceptos rc on rc.codigo = r.concepto_codigo
  where r.comprobante_id = c.id
) ret on true;

-- Resumen por mes y empresa, que es lo que se le entrega al contador.
create or replace view public.vista_resumen_compras_mes_v58
with (security_invoker = true) as
select
  empresa_id, empresa, ruc_empresa, mes, anio, numero_mes,
  count(*) filter (where estado = 'registrado') as comprobantes,
  count(*) filter (where estado = 'anulado') as anulados,
  sum(base_cero) filter (where estado = 'registrado') as base_cero,
  sum(base_gravada) filter (where estado = 'registrado') as base_gravada,
  sum(base_no_objeto) filter (where estado = 'registrado') as base_no_objeto,
  sum(base_exenta) filter (where estado = 'registrado') as base_exenta,
  sum(monto_iva) filter (where estado = 'registrado') as iva_credito,
  sum(retencion_iva) filter (where estado = 'registrado') as retencion_iva,
  sum(retencion_renta) filter (where estado = 'registrado') as retencion_renta,
  sum(total) filter (where estado = 'registrado') as total_compras
from public.vista_libro_compras_v58
group by empresa_id, empresa, ruc_empresa, mes, anio, numero_mes;

-- ------------------------------------------------------------
-- 5. RLS y privilegios
-- ------------------------------------------------------------
alter table public.comprobantes_compra enable row level security;
alter table public.comprobante_compra_lineas enable row level security;
alter table public.retenciones_compra enable row level security;
alter table public.retencion_conceptos enable row level security;
alter table public.sustentos_tributarios enable row level security;

drop policy if exists "leer_comprobantes_compra_v58" on public.comprobantes_compra;
create policy "leer_comprobantes_compra_v58" on public.comprobantes_compra
for select to authenticated using (public.usuario_puede_empresa(empresa_id, false));

drop policy if exists "leer_lineas_comprobante_v58" on public.comprobante_compra_lineas;
create policy "leer_lineas_comprobante_v58" on public.comprobante_compra_lineas
for select to authenticated using (
  exists (select 1 from public.comprobantes_compra c where c.id = comprobante_id)
);

drop policy if exists "leer_retenciones_compra_v58" on public.retenciones_compra;
create policy "leer_retenciones_compra_v58" on public.retenciones_compra
for select to authenticated using (
  exists (select 1 from public.comprobantes_compra c where c.id = comprobante_id)
);

drop policy if exists "leer_retencion_conceptos_v58" on public.retencion_conceptos;
create policy "leer_retencion_conceptos_v58" on public.retencion_conceptos
for select to authenticated using (true);

drop policy if exists "leer_sustentos_v58" on public.sustentos_tributarios;
create policy "leer_sustentos_v58" on public.sustentos_tributarios
for select to authenticated using (true);

-- Toda escritura pasa por las RPC.
revoke all on public.comprobantes_compra from public, anon;
revoke all on public.comprobante_compra_lineas from public, anon;
revoke all on public.retenciones_compra from public, anon;
revoke all on public.retencion_conceptos from public, anon;
revoke all on public.sustentos_tributarios from public, anon;
revoke insert, update, delete on public.comprobantes_compra from authenticated;
revoke insert, update, delete on public.comprobante_compra_lineas from authenticated;
revoke insert, update, delete on public.retenciones_compra from authenticated;
revoke insert, update, delete on public.retencion_conceptos from authenticated;
revoke insert, update, delete on public.sustentos_tributarios from authenticated;
grant select on public.comprobantes_compra to authenticated;
grant select on public.comprobante_compra_lineas to authenticated;
grant select on public.retenciones_compra to authenticated;
grant select on public.retencion_conceptos to authenticated;
grant select on public.sustentos_tributarios to authenticated;

revoke all on public.vista_libro_compras_v58 from public, anon;
revoke all on public.vista_resumen_compras_mes_v58 from public, anon;
grant select on public.vista_libro_compras_v58 to authenticated;
grant select on public.vista_resumen_compras_mes_v58 to authenticated;

alter function public.registrar_comprobante_compra_v58(jsonb, jsonb, jsonb, uuid) owner to postgres;
alter function public.anular_comprobante_compra_v58(uuid, text) owner to postgres;
revoke execute on function public.registrar_comprobante_compra_v58(jsonb, jsonb, jsonb, uuid) from public, anon;
revoke execute on function public.anular_comprobante_compra_v58(uuid, text) from public, anon;
grant execute on function public.registrar_comprobante_compra_v58(jsonb, jsonb, jsonb, uuid) to authenticated;
grant execute on function public.anular_comprobante_compra_v58(uuid, text) to authenticated;

notify pgrst, 'reload schema';
