-- ============================================================
-- BOMAN INVENTARIO - v73: cuentas por pagar y efectivo comprometido
--
-- Separa la empresa que recibio la factura de la empresa que desembolsa.
-- Los cheques posfechados comprometen efectivo en su fecha prevista, pero
-- solo reducen el saldo por pagar cuando se confirman como pagados/cobrados.
-- Ejecutar despues de v72 y antes de verificacion_v73.sql.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.comprobantes_compra') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null
     or to_regprocedure('public.grupo_tiene_capacidad_v68(uuid,text)') is null then
    raise exception 'Faltan v58, v35 o v68. Instalalas antes de v73';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Permisos configurables
-- ------------------------------------------------------------
insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('tesoreria.acceder', 'Finanzas', 'Consultar cuentas por pagar',
   'Consulta cartera de proveedores, vencimientos y efectivo comprometido.', 170),
  ('tesoreria.editar', 'Finanzas', 'Gestionar pagos y cheques',
   'Configura la pagadora, programa desembolsos y controla cheques posfechados.', 171)
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

update public.rol_permisos
set permitido = true, updated_at = now()
where permiso_codigo = 'tesoreria.acceder'
  and rol::text in ('control', 'gerencia');

update public.rol_permisos
set permitido = true, updated_at = now()
where permiso_codigo = 'tesoreria.editar'
  and rol::text = 'control';

create or replace view public.vista_matriz_permisos_v35
with (security_invoker = true) as
select
  r.rol::text as rol,
  ps.codigo as permiso_codigo,
  ps.modulo,
  ps.nombre,
  ps.descripcion,
  ps.orden,
  case when r.rol::text = 'admin' then true else coalesce(rp.permitido, false) end
    as permitido,
  r.rol::text <> 'admin' as configurable,
  rp.updated_at
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema ps
left join public.rol_permisos rp
  on rp.rol = r.rol and rp.permiso_codigo = ps.codigo
where ps.activo;

-- ------------------------------------------------------------
-- 2. Configuracion, obligaciones, pagos y auditoria
-- ------------------------------------------------------------
create table if not exists public.tesoreria_configuracion (
  grupo_id uuid primary key references public.grupos_economicos(id) on delete restrict,
  empresa_pagadora_predeterminada_id uuid not null
    references public.empresas(id) on delete restrict,
  dias_credito_predeterminados integer not null default 30
    check (dias_credito_predeterminados between 0 and 365),
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  updated_at timestamptz not null default now()
);

create table if not exists public.cuentas_por_pagar (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  comprobante_id uuid not null unique
    references public.comprobantes_compra(id) on delete restrict,
  empresa_deudora_id uuid not null references public.empresas(id) on delete restrict,
  empresa_pagadora_id uuid not null references public.empresas(id) on delete restrict,
  proveedor_id uuid not null references public.proveedores(id) on delete restrict,
  fecha_documento date not null,
  fecha_vencimiento date not null,
  nota text,
  estado_registro text not null default 'activa'
    check (estado_registro in ('activa', 'anulada')),
  creado_por uuid references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fecha_vencimiento >= fecha_documento)
);

create table if not exists public.cuentas_por_pagar_pagos (
  id uuid primary key default gen_random_uuid(),
  cuenta_id uuid not null references public.cuentas_por_pagar(id) on delete restrict,
  empresa_pagadora_id uuid not null references public.empresas(id) on delete restrict,
  medio text not null check (medio in (
    'cheque', 'transferencia', 'efectivo', 'tarjeta', 'otro'
  )),
  monto numeric(14,2) not null check (monto > 0),
  fecha_programada date not null,
  estado text not null default 'programado' check (estado in (
    'programado', 'emitido', 'entregado', 'pagado', 'anulado'
  )),
  banco text,
  numero_cuenta text,
  numero_cheque text,
  fecha_pago date,
  nota text,
  motivo_anulacion text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    medio <> 'cheque' or (
      btrim(coalesce(banco, '')) <> ''
      and btrim(coalesce(numero_cuenta, '')) <> ''
      and btrim(coalesce(numero_cheque, '')) <> ''
    )
  ),
  check (estado <> 'pagado' or fecha_pago is not null),
  check (estado <> 'anulado' or btrim(coalesce(motivo_anulacion, '')) <> '')
);

create table if not exists public.cuentas_por_pagar_eventos (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  cuenta_id uuid references public.cuentas_por_pagar(id) on delete restrict,
  pago_id uuid references public.cuentas_por_pagar_pagos(id) on delete restrict,
  tipo text not null check (btrim(tipo) <> ''),
  detalle text not null check (length(btrim(detalle)) >= 5),
  datos jsonb not null default '{}'::jsonb,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_cuentas_pagar_vencimiento_v73
  on public.cuentas_por_pagar(grupo_id, estado_registro, fecha_vencimiento);
create index if not exists idx_cuentas_pagar_proveedor_v73
  on public.cuentas_por_pagar(proveedor_id, fecha_vencimiento);
create index if not exists idx_pagos_cuenta_fecha_v73
  on public.cuentas_por_pagar_pagos(cuenta_id, estado, fecha_programada);
create index if not exists idx_pagos_pagadora_fecha_v73
  on public.cuentas_por_pagar_pagos(empresa_pagadora_id, estado, fecha_programada);
create unique index if not exists uq_cheque_pagadora_v73
  on public.cuentas_por_pagar_pagos(
    empresa_pagadora_id, lower(btrim(banco)), lower(btrim(numero_cuenta)),
    lower(btrim(numero_cheque))
  ) where medio = 'cheque';

-- ------------------------------------------------------------
-- 3. Acceso por grupo, permiso y plan contratado
-- ------------------------------------------------------------
create or replace function public.usuario_puede_tesoreria_v73(
  p_grupo_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select p_grupo_id is not null
    and exists (
      select 1 from public.perfiles p
      where p.id = auth.uid() and p.activo and p.grupo_id = p_grupo_id
    )
    and public.grupo_tiene_capacidad_v68(p_grupo_id, 'contabilidad.acceder')
    and public.usuario_tiene_permiso_v35(
      case when p_escritura then 'tesoreria.editar' else 'tesoreria.acceder' end
    );
$fn$;

-- ------------------------------------------------------------
-- 4. Toda factura registrada crea su obligacion automaticamente
-- ------------------------------------------------------------
create or replace function public.sincronizar_cuenta_comprobante_v73()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_grupo_id uuid;
  v_pagadora_id uuid;
  v_dias integer := 30;
begin
  if new.tipo not in ('factura', 'nota_venta', 'liquidacion_compra', 'nota_debito') then
    return new;
  end if;
  select e.grupo_id into v_grupo_id
  from public.empresas e where e.id = new.empresa_id;

  if tg_op = 'UPDATE' then
    if new.estado = 'anulado' and old.estado <> 'anulado' then
      if exists (
        select 1
        from public.cuentas_por_pagar c
        join public.cuentas_por_pagar_pagos p on p.cuenta_id = c.id
        where c.comprobante_id = new.id and p.estado <> 'anulado'
      ) then
        raise exception 'Anula primero los pagos y cheques vinculados antes de anular la factura';
      end if;
      update public.cuentas_por_pagar
      set estado_registro = 'anulada', actualizado_por = auth.uid(), updated_at = now()
      where comprobante_id = new.id;
      return new;
    end if;
  end if;

  if new.estado <> 'registrado' then return new; end if;
  select c.empresa_pagadora_predeterminada_id, c.dias_credito_predeterminados
    into v_pagadora_id, v_dias
  from public.tesoreria_configuracion c where c.grupo_id = v_grupo_id;

  insert into public.cuentas_por_pagar (
    grupo_id, comprobante_id, empresa_deudora_id, empresa_pagadora_id,
    proveedor_id, fecha_documento, fecha_vencimiento, nota, creado_por
  ) values (
    v_grupo_id, new.id, new.empresa_id, coalesce(v_pagadora_id, new.empresa_id),
    new.proveedor_id, new.fecha_emision, new.fecha_emision + coalesce(v_dias, 30),
    'Generada automaticamente desde ' || new.numero_documento,
    new.registrado_por
  ) on conflict (comprobante_id) do update set
    estado_registro = 'activa', updated_at = now();
  return new;
end;
$fn$;

drop trigger if exists trg_sincronizar_cuenta_comprobante_v73
  on public.comprobantes_compra;
create trigger trg_sincronizar_cuenta_comprobante_v73
after insert or update of estado on public.comprobantes_compra
for each row execute function public.sincronizar_cuenta_comprobante_v73();

-- Cartera historica: no se inventa una pagadora central. Hasta configurarla,
-- cada factura queda pagadera por su propia empresa receptora.
insert into public.cuentas_por_pagar (
  grupo_id, comprobante_id, empresa_deudora_id, empresa_pagadora_id,
  proveedor_id, fecha_documento, fecha_vencimiento, nota, creado_por
)
select
  e.grupo_id, c.id, c.empresa_id,
  coalesce(tc.empresa_pagadora_predeterminada_id, c.empresa_id),
  c.proveedor_id, c.fecha_emision,
  c.fecha_emision + coalesce(tc.dias_credito_predeterminados, 30),
  'Migrada desde comprobante registrado', c.registrado_por
from public.comprobantes_compra c
join public.empresas e on e.id = c.empresa_id
left join public.tesoreria_configuracion tc on tc.grupo_id = e.grupo_id
where c.estado = 'registrado'
  and c.tipo in ('factura', 'nota_venta', 'liquidacion_compra', 'nota_debito')
on conflict (comprobante_id) do nothing;

-- ------------------------------------------------------------
-- 5. Vistas: saldo documental, compromisos y calendario de caja
-- ------------------------------------------------------------
create or replace view public.vista_cuentas_por_pagar_v73
with (security_invoker = true) as
select
  c.id, c.grupo_id, c.comprobante_id,
  c.empresa_deudora_id, ed.codigo as empresa_deudora_codigo,
  ed.razon_social as empresa_deudora,
  c.empresa_pagadora_id, ep.codigo as empresa_pagadora_codigo,
  ep.razon_social as empresa_pagadora,
  c.proveedor_id, p.identificacion as proveedor_identificacion,
  p.razon_social as proveedor,
  cc.tipo as comprobante_tipo, cc.numero_documento,
  c.fecha_documento, c.fecha_vencimiento,
  cc.total as total_documento,
  coalesce(r.total_retenciones, 0)::numeric(14,2) as total_retenciones,
  greatest(cc.total - coalesce(r.total_retenciones, 0), 0)::numeric(14,2)
    as total_exigible,
  coalesce(pg.total_pagado, 0)::numeric(14,2) as total_pagado,
  coalesce(pg.total_comprometido, 0)::numeric(14,2) as total_comprometido,
  greatest(
    cc.total - coalesce(r.total_retenciones, 0) - coalesce(pg.total_pagado, 0), 0
  )::numeric(14,2) as saldo_pendiente,
  greatest(
    cc.total - coalesce(r.total_retenciones, 0)
      - coalesce(pg.total_pagado, 0) - coalesce(pg.total_comprometido, 0), 0
  )::numeric(14,2) as saldo_por_programar,
  (current_date - c.fecha_vencimiento)::integer as dias_vencida,
  case
    when c.estado_registro = 'anulada' or cc.estado = 'anulado' then 'anulada'
    when cc.total - coalesce(r.total_retenciones, 0) <= coalesce(pg.total_pagado, 0)
      then 'pagada'
    when c.fecha_vencimiento < current_date then 'vencida'
    when coalesce(pg.total_pagado, 0) > 0 then 'parcial'
    when coalesce(pg.total_comprometido, 0) > 0 then 'programada'
    else 'pendiente'
  end as estado,
  c.nota, c.created_at, c.updated_at
from public.cuentas_por_pagar c
join public.comprobantes_compra cc on cc.id = c.comprobante_id
join public.empresas ed on ed.id = c.empresa_deudora_id
join public.empresas ep on ep.id = c.empresa_pagadora_id
join public.proveedores p on p.id = c.proveedor_id
left join lateral (
  select coalesce(sum(r.valor), 0) as total_retenciones
  from public.retenciones_compra r where r.comprobante_id = cc.id
) r on true
left join lateral (
  select
    coalesce(sum(pp.monto) filter (where pp.estado = 'pagado'), 0) as total_pagado,
    coalesce(sum(pp.monto) filter (
      where pp.estado in ('programado', 'emitido', 'entregado')
    ), 0) as total_comprometido
  from public.cuentas_por_pagar_pagos pp where pp.cuenta_id = c.id
) pg on true;

create or replace view public.vista_efectivo_comprometido_v73
with (security_invoker = true) as
select
  pp.id as pago_id, pp.cuenta_id, c.grupo_id,
  pp.empresa_pagadora_id, ep.codigo as empresa_pagadora_codigo,
  ep.razon_social as empresa_pagadora,
  c.empresa_deudora_id, ed.codigo as empresa_deudora_codigo,
  p.razon_social as proveedor, cc.numero_documento,
  pp.medio, pp.monto, pp.fecha_programada,
  (pp.fecha_programada - current_date)::integer as dias_para_salida,
  pp.estado, pp.banco, pp.numero_cuenta, pp.numero_cheque,
  pp.fecha_pago, pp.nota, pp.created_at
from public.cuentas_por_pagar_pagos pp
join public.cuentas_por_pagar c on c.id = pp.cuenta_id
join public.comprobantes_compra cc on cc.id = c.comprobante_id
join public.empresas ep on ep.id = pp.empresa_pagadora_id
join public.empresas ed on ed.id = c.empresa_deudora_id
join public.proveedores p on p.id = c.proveedor_id
where pp.estado <> 'anulado';

create or replace view public.vista_resumen_tesoreria_v73
with (security_invoker = true) as
select
  ep.grupo_id, ep.id as empresa_pagadora_id, ep.codigo as empresa_pagadora_codigo,
  ep.razon_social as empresa_pagadora,
  coalesce(c.saldo_pendiente, 0)::numeric(14,2) as saldo_total,
  coalesce(c.saldo_vencido, 0)::numeric(14,2) as saldo_vencido,
  coalesce(c.saldo_por_programar, 0)::numeric(14,2) as saldo_por_programar,
  coalesce(pg.comprometido_total, 0)::numeric(14,2) as comprometido_total,
  coalesce(pg.comprometido_hoy, 0)::numeric(14,2) as comprometido_hoy,
  coalesce(pg.comprometido_7_dias, 0)::numeric(14,2) as comprometido_7_dias,
  coalesce(pg.comprometido_30_dias, 0)::numeric(14,2) as comprometido_30_dias,
  coalesce(pg.cheques_en_transito, 0)::integer as cheques_en_transito
from public.empresas ep
left join lateral (
  select
    coalesce(sum(v.saldo_pendiente) filter (where v.estado <> 'anulada'), 0) saldo_pendiente,
    coalesce(sum(v.saldo_pendiente) filter (where v.estado = 'vencida'), 0) saldo_vencido,
    coalesce(sum(v.saldo_por_programar) filter (where v.estado <> 'anulada'), 0) saldo_por_programar
  from public.vista_cuentas_por_pagar_v73 v
  where v.empresa_pagadora_id = ep.id
) c on true
left join lateral (
  select
    coalesce(sum(v.monto) filter (
      where v.estado in ('programado', 'emitido', 'entregado')
    ), 0) comprometido_total,
    coalesce(sum(v.monto) filter (
      where v.estado in ('programado', 'emitido', 'entregado')
        and v.fecha_programada <= current_date
    ), 0) comprometido_hoy,
    coalesce(sum(v.monto) filter (
      where v.estado in ('programado', 'emitido', 'entregado')
        and v.fecha_programada between current_date and current_date + 7
    ), 0) comprometido_7_dias,
    coalesce(sum(v.monto) filter (
      where v.estado in ('programado', 'emitido', 'entregado')
        and v.fecha_programada between current_date and current_date + 30
    ), 0) comprometido_30_dias,
    count(*) filter (
      where v.medio = 'cheque' and v.estado in ('programado', 'emitido', 'entregado')
    ) cheques_en_transito
  from public.vista_efectivo_comprometido_v73 v
  where v.empresa_pagadora_id = ep.id
) pg on true
where ep.activo
  and public.usuario_puede_tesoreria_v73(ep.grupo_id, false);

create or replace view public.vista_empresas_tesoreria_v73
with (security_invoker = true) as
select e.id, e.grupo_id, e.codigo, e.razon_social
from public.empresas e
where e.activo
  and public.usuario_puede_tesoreria_v73(e.grupo_id, false);

-- ------------------------------------------------------------
-- 6. RPC de configuracion y operacion
-- ------------------------------------------------------------
create or replace function public.configurar_tesoreria_v73(
  p_empresa_pagadora_id uuid,
  p_dias_credito integer,
  p_aplicar_pendientes boolean,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_grupo_id uuid;
  v_actualizadas integer := 0;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  select p.grupo_id into v_grupo_id from public.perfiles p
  where p.id = v_uid and p.activo;
  if not public.usuario_puede_tesoreria_v73(v_grupo_id, true) then
    raise exception 'No tienes permiso para configurar Tesoreria';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Indica un motivo de al menos 10 caracteres';
  end if;
  if p_dias_credito is null or p_dias_credito not between 0 and 365 then
    raise exception 'Los dias de credito deben estar entre 0 y 365';
  end if;
  if not exists (
    select 1 from public.empresas e
    where e.id = p_empresa_pagadora_id and e.grupo_id = v_grupo_id and e.activo
  ) then raise exception 'La empresa pagadora no pertenece a tu grupo'; end if;
  if exists (
    select 1 from public.cuentas_por_pagar_eventos e
    where e.idempotency_key = p_idempotency_key
  ) then return jsonb_build_object('duplicado', true); end if;

  insert into public.tesoreria_configuracion (
    grupo_id, empresa_pagadora_predeterminada_id,
    dias_credito_predeterminados, actualizado_por
  ) values (
    v_grupo_id, p_empresa_pagadora_id, p_dias_credito, v_uid
  ) on conflict (grupo_id) do update set
    empresa_pagadora_predeterminada_id = excluded.empresa_pagadora_predeterminada_id,
    dias_credito_predeterminados = excluded.dias_credito_predeterminados,
    actualizado_por = excluded.actualizado_por, updated_at = now();

  if coalesce(p_aplicar_pendientes, false) then
    update public.cuentas_por_pagar c
    set empresa_pagadora_id = p_empresa_pagadora_id,
        fecha_vencimiento = c.fecha_documento + p_dias_credito,
        actualizado_por = v_uid, updated_at = now()
    where c.grupo_id = v_grupo_id and c.estado_registro = 'activa'
      and not exists (
        select 1 from public.cuentas_por_pagar_pagos pp
        where pp.cuenta_id = c.id and pp.estado <> 'anulado'
      );
    get diagnostics v_actualizadas = row_count;
  end if;

  insert into public.cuentas_por_pagar_eventos (
    grupo_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_grupo_id, 'configuracion', btrim(p_motivo),
    jsonb_build_object('empresa_pagadora_id', p_empresa_pagadora_id,
      'dias_credito', p_dias_credito, 'cuentas_actualizadas', v_actualizadas),
    v_uid, p_idempotency_key
  );
  return jsonb_build_object('duplicado', false, 'cuentas_actualizadas', v_actualizadas);
end;
$fn$;

create or replace function public.actualizar_cuenta_por_pagar_v73(
  p_cuenta_id uuid,
  p_empresa_pagadora_id uuid,
  p_fecha_vencimiento date,
  p_nota text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_cuenta public.cuentas_por_pagar%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if exists (select 1 from public.cuentas_por_pagar_eventos where idempotency_key = p_idempotency_key) then return; end if;
  select * into v_cuenta from public.cuentas_por_pagar
  where id = p_cuenta_id for update;
  if not found then raise exception 'La cuenta por pagar no existe'; end if;
  if not public.usuario_puede_tesoreria_v73(v_cuenta.grupo_id, true) then
    raise exception 'No tienes permiso para modificar esta cuenta';
  end if;
  if v_cuenta.estado_registro <> 'activa' then raise exception 'La cuenta esta anulada'; end if;
  if p_fecha_vencimiento is null or p_fecha_vencimiento < v_cuenta.fecha_documento then
    raise exception 'El vencimiento no puede ser anterior a la factura';
  end if;
  if not exists (
    select 1 from public.empresas e where e.id = p_empresa_pagadora_id
      and e.grupo_id = v_cuenta.grupo_id and e.activo
  ) then raise exception 'La empresa pagadora no pertenece al grupo'; end if;
  if p_empresa_pagadora_id <> v_cuenta.empresa_pagadora_id and exists (
    select 1 from public.cuentas_por_pagar_pagos pp
    where pp.cuenta_id = v_cuenta.id and pp.estado <> 'anulado'
  ) then raise exception 'No puedes cambiar la pagadora mientras existan pagos o cheques activos'; end if;

  update public.cuentas_por_pagar
  set empresa_pagadora_id = p_empresa_pagadora_id,
      fecha_vencimiento = p_fecha_vencimiento,
      nota = nullif(btrim(p_nota), ''), actualizado_por = v_uid, updated_at = now()
  where id = v_cuenta.id;
  insert into public.cuentas_por_pagar_eventos (
    grupo_id, cuenta_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_cuenta.grupo_id, v_cuenta.id, 'cuenta_actualizada',
    'Condiciones de pago actualizadas',
    jsonb_build_object('empresa_pagadora_id', p_empresa_pagadora_id,
      'fecha_vencimiento', p_fecha_vencimiento, 'nota', nullif(btrim(p_nota), '')),
    v_uid, p_idempotency_key
  );
end;
$fn$;

create or replace function public.programar_pago_cuenta_v73(
  p_cuenta_id uuid,
  p_medio text,
  p_monto numeric,
  p_fecha_programada date,
  p_banco text,
  p_numero_cuenta text,
  p_numero_cheque text,
  p_ya_pagado boolean,
  p_fecha_pago date,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_cuenta public.cuentas_por_pagar%rowtype;
  v_pago_id uuid;
  v_neto numeric(14,2);
  v_cubierto numeric(14,2);
  v_estado text;
  v_fecha_pago date;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select pp.id into v_pago_id from public.cuentas_por_pagar_pagos pp
  where pp.idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('duplicado', true, 'pago_id', v_pago_id); end if;
  select * into v_cuenta from public.cuentas_por_pagar
  where id = p_cuenta_id for update;
  if not found then raise exception 'La cuenta por pagar no existe'; end if;
  if not public.usuario_puede_tesoreria_v73(v_cuenta.grupo_id, true) then
    raise exception 'No tienes permiso para programar pagos';
  end if;
  if v_cuenta.estado_registro <> 'activa' then raise exception 'La cuenta esta anulada'; end if;
  if p_medio not in ('cheque', 'transferencia', 'efectivo', 'tarjeta', 'otro') then
    raise exception 'Selecciona un medio de pago valido';
  end if;
  if p_monto is null or round(p_monto, 2) <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_fecha_programada is null then raise exception 'Indica la fecha prevista de salida de efectivo'; end if;
  if p_medio = 'cheque' and (
    btrim(coalesce(p_banco, '')) = '' or btrim(coalesce(p_numero_cuenta, '')) = ''
    or btrim(coalesce(p_numero_cheque, '')) = ''
  ) then raise exception 'El cheque exige banco, cuenta y numero'; end if;
  if not exists (
    select 1 from public.empresas e
    where e.id = v_cuenta.empresa_pagadora_id
      and e.grupo_id = v_cuenta.grupo_id and e.activo
  ) then raise exception 'La empresa pagadora esta inactiva o no pertenece al grupo'; end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then raise exception 'Indica una referencia de al menos 5 caracteres'; end if;

  select greatest(cc.total - coalesce(sum(r.valor), 0), 0)::numeric(14,2)
    into v_neto
  from public.comprobantes_compra cc
  left join public.retenciones_compra r on r.comprobante_id = cc.id
  where cc.id = v_cuenta.comprobante_id and cc.estado = 'registrado'
  group by cc.total;
  if v_neto is null then raise exception 'El comprobante ya no esta vigente'; end if;
  select coalesce(sum(pp.monto) filter (
    where pp.estado in ('programado', 'emitido', 'entregado', 'pagado')
  ), 0)::numeric(14,2) into v_cubierto
  from public.cuentas_por_pagar_pagos pp where pp.cuenta_id = v_cuenta.id;
  if round(v_cubierto + p_monto, 2) > round(v_neto, 2) then
    raise exception 'El pago supera el saldo disponible para programar (%)', round(v_neto - v_cubierto, 2);
  end if;

  v_estado := case when coalesce(p_ya_pagado, false) then 'pagado' else 'programado' end;
  if v_estado = 'pagado' then
    v_fecha_pago := coalesce(p_fecha_pago, current_date);
    if v_fecha_pago > current_date then raise exception 'Un pago realizado no puede tener fecha futura'; end if;
    if p_fecha_programada > current_date then raise exception 'La salida efectiva de un pago realizado no puede ser futura'; end if;
  end if;
  insert into public.cuentas_por_pagar_pagos (
    cuenta_id, empresa_pagadora_id, medio, monto, fecha_programada, estado,
    banco, numero_cuenta, numero_cheque, fecha_pago, nota,
    creado_por, actualizado_por, idempotency_key
  ) values (
    v_cuenta.id, v_cuenta.empresa_pagadora_id, p_medio, round(p_monto, 2),
    p_fecha_programada, v_estado, nullif(btrim(p_banco), ''),
    nullif(btrim(p_numero_cuenta), ''), nullif(btrim(p_numero_cheque), ''),
    v_fecha_pago, btrim(p_nota), v_uid, v_uid, p_idempotency_key
  ) returning id into v_pago_id;
  update public.cuentas_por_pagar set actualizado_por = v_uid, updated_at = now()
  where id = v_cuenta.id;
  insert into public.cuentas_por_pagar_eventos (
    grupo_id, cuenta_id, pago_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_cuenta.grupo_id, v_cuenta.id, v_pago_id,
    case when v_estado = 'pagado' then 'pago_registrado' else 'pago_programado' end,
    btrim(p_nota), jsonb_build_object('medio', p_medio, 'monto', round(p_monto, 2),
      'fecha_programada', p_fecha_programada, 'estado', v_estado),
    v_uid, p_idempotency_key
  );
  return jsonb_build_object('duplicado', false, 'pago_id', v_pago_id, 'estado', v_estado);
end;
$fn$;

create or replace function public.gestionar_pago_cuenta_v73(
  p_pago_id uuid,
  p_nuevo_estado text,
  p_fecha_pago date,
  p_detalle text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_pago public.cuentas_por_pagar_pagos%rowtype;
  v_cuenta public.cuentas_por_pagar%rowtype;
  v_fecha date;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_detalle, ''))) < 5 then raise exception 'Indica un detalle de al menos 5 caracteres'; end if;
  if exists (select 1 from public.cuentas_por_pagar_eventos where idempotency_key = p_idempotency_key) then return; end if;
  select * into v_pago from public.cuentas_por_pagar_pagos where id = p_pago_id for update;
  if not found then raise exception 'El pago no existe'; end if;
  select * into v_cuenta from public.cuentas_por_pagar where id = v_pago.cuenta_id for update;
  if not public.usuario_puede_tesoreria_v73(v_cuenta.grupo_id, true) then
    raise exception 'No tienes permiso para gestionar el pago';
  end if;
  if p_nuevo_estado = v_pago.estado then return; end if;
  if v_pago.estado = 'anulado' then raise exception 'Un pago anulado es inmutable'; end if;
  if v_pago.estado = 'pagado' and p_nuevo_estado <> 'anulado' then
    raise exception 'Un pago confirmado solo puede anularse mediante reversa';
  end if;
  if v_pago.estado = 'pagado' and p_nuevo_estado = 'anulado'
     and public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede revertir un pago confirmado';
  end if;
  if p_nuevo_estado not in ('emitido', 'entregado', 'pagado', 'anulado') then
    raise exception 'Estado de pago invalido';
  end if;
  if p_nuevo_estado in ('emitido', 'entregado') and v_pago.medio <> 'cheque' then
    raise exception 'Emitido y entregado solo aplican a cheques';
  end if;
  if p_nuevo_estado = 'emitido' and v_pago.estado <> 'programado' then
    raise exception 'Solo un cheque programado puede marcarse emitido';
  end if;
  if p_nuevo_estado = 'entregado' and v_pago.estado not in ('programado', 'emitido') then
    raise exception 'El cheque no esta pendiente de entrega';
  end if;
  if p_nuevo_estado = 'pagado' and v_pago.estado not in ('programado', 'emitido', 'entregado') then
    raise exception 'El pago no esta pendiente de confirmacion';
  end if;
  v_fecha := case when p_nuevo_estado = 'pagado'
    then coalesce(p_fecha_pago, current_date) else v_pago.fecha_pago end;
  if p_nuevo_estado = 'pagado' and v_fecha > current_date then
    raise exception 'La fecha efectiva no puede ser futura';
  end if;

  update public.cuentas_por_pagar_pagos
  set estado = p_nuevo_estado, fecha_pago = v_fecha,
      motivo_anulacion = case when p_nuevo_estado = 'anulado' then btrim(p_detalle) else motivo_anulacion end,
      anulado_por = case when p_nuevo_estado = 'anulado' then v_uid else anulado_por end,
      anulado_at = case when p_nuevo_estado = 'anulado' then now() else anulado_at end,
      actualizado_por = v_uid, updated_at = now()
  where id = v_pago.id;
  update public.cuentas_por_pagar set actualizado_por = v_uid, updated_at = now()
  where id = v_cuenta.id;
  insert into public.cuentas_por_pagar_eventos (
    grupo_id, cuenta_id, pago_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_cuenta.grupo_id, v_cuenta.id, v_pago.id,
    case when p_nuevo_estado = 'anulado' then 'pago_revertido' else 'pago_' || p_nuevo_estado end,
    btrim(p_detalle), jsonb_build_object('estado_anterior', v_pago.estado,
      'estado_nuevo', p_nuevo_estado, 'fecha_pago', v_fecha),
    v_uid, p_idempotency_key
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 7. RLS y privilegios
-- ------------------------------------------------------------
alter table public.tesoreria_configuracion enable row level security;
alter table public.cuentas_por_pagar enable row level security;
alter table public.cuentas_por_pagar_pagos enable row level security;
alter table public.cuentas_por_pagar_eventos enable row level security;

drop policy if exists "leer_configuracion_tesoreria_v73" on public.tesoreria_configuracion;
create policy "leer_configuracion_tesoreria_v73" on public.tesoreria_configuracion
for select to authenticated using (public.usuario_puede_tesoreria_v73(grupo_id, false));
drop policy if exists "leer_cuentas_pagar_v73" on public.cuentas_por_pagar;
create policy "leer_cuentas_pagar_v73" on public.cuentas_por_pagar
for select to authenticated using (public.usuario_puede_tesoreria_v73(grupo_id, false));
drop policy if exists "leer_pagos_cuentas_v73" on public.cuentas_por_pagar_pagos;
create policy "leer_pagos_cuentas_v73" on public.cuentas_por_pagar_pagos
for select to authenticated using (
  exists (select 1 from public.cuentas_por_pagar c where c.id = cuenta_id)
);
drop policy if exists "leer_eventos_cuentas_v73" on public.cuentas_por_pagar_eventos;
create policy "leer_eventos_cuentas_v73" on public.cuentas_por_pagar_eventos
for select to authenticated using (public.usuario_puede_tesoreria_v73(grupo_id, false));

revoke all on public.tesoreria_configuracion from public, anon;
revoke all on public.cuentas_por_pagar from public, anon;
revoke all on public.cuentas_por_pagar_pagos from public, anon;
revoke all on public.cuentas_por_pagar_eventos from public, anon;
revoke insert, update, delete on public.tesoreria_configuracion from authenticated;
revoke insert, update, delete on public.cuentas_por_pagar from authenticated;
revoke insert, update, delete on public.cuentas_por_pagar_pagos from authenticated;
revoke insert, update, delete on public.cuentas_por_pagar_eventos from authenticated;
grant select on public.tesoreria_configuracion to authenticated;
grant select on public.cuentas_por_pagar to authenticated;
grant select on public.cuentas_por_pagar_pagos to authenticated;
grant select on public.cuentas_por_pagar_eventos to authenticated;

revoke all on public.vista_cuentas_por_pagar_v73 from public, anon;
revoke all on public.vista_efectivo_comprometido_v73 from public, anon;
revoke all on public.vista_resumen_tesoreria_v73 from public, anon;
revoke all on public.vista_empresas_tesoreria_v73 from public, anon;
grant select on public.vista_cuentas_por_pagar_v73 to authenticated;
grant select on public.vista_efectivo_comprometido_v73 to authenticated;
grant select on public.vista_resumen_tesoreria_v73 to authenticated;
grant select on public.vista_empresas_tesoreria_v73 to authenticated;

alter function public.usuario_puede_tesoreria_v73(uuid,boolean) owner to postgres;
alter function public.sincronizar_cuenta_comprobante_v73() owner to postgres;
alter function public.configurar_tesoreria_v73(uuid,integer,boolean,text,uuid) owner to postgres;
alter function public.actualizar_cuenta_por_pagar_v73(uuid,uuid,date,text,uuid) owner to postgres;
alter function public.programar_pago_cuenta_v73(uuid,text,numeric,date,text,text,text,boolean,date,text,uuid) owner to postgres;
alter function public.gestionar_pago_cuenta_v73(uuid,text,date,text,uuid) owner to postgres;

revoke all on function public.usuario_puede_tesoreria_v73(uuid,boolean) from public, anon;
revoke all on function public.sincronizar_cuenta_comprobante_v73() from public, anon, authenticated;
revoke all on function public.configurar_tesoreria_v73(uuid,integer,boolean,text,uuid) from public, anon;
revoke all on function public.actualizar_cuenta_por_pagar_v73(uuid,uuid,date,text,uuid) from public, anon;
revoke all on function public.programar_pago_cuenta_v73(uuid,text,numeric,date,text,text,text,boolean,date,text,uuid) from public, anon;
revoke all on function public.gestionar_pago_cuenta_v73(uuid,text,date,text,uuid) from public, anon;
grant execute on function public.usuario_puede_tesoreria_v73(uuid,boolean) to authenticated;
grant execute on function public.configurar_tesoreria_v73(uuid,integer,boolean,text,uuid) to authenticated;
grant execute on function public.actualizar_cuenta_por_pagar_v73(uuid,uuid,date,text,uuid) to authenticated;
grant execute on function public.programar_pago_cuenta_v73(uuid,text,numeric,date,text,text,text,boolean,date,text,uuid) to authenticated;
grant execute on function public.gestionar_pago_cuenta_v73(uuid,text,date,text,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
