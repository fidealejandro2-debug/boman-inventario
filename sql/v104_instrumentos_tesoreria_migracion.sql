-- ============================================================
-- BOMAN INVENTARIO - v104
-- Instrumentos de tesoreria y migracion controlada de cheques
--
-- Separa el cheque de la factura: un instrumento puede cubrir varias
-- cuentas por pagar y un cheque legado puede quedar sin homologar.
-- La bandeja de importacion nunca compromete efectivo hasta confirmar.
-- Ejecutar despues de v73 y v93.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.cuentas_por_pagar') is null
     or to_regclass('public.cuentas_por_pagar_pagos') is null
     or to_regprocedure('public.usuario_puede_tesoreria_v73(uuid,boolean)') is null then
    raise exception 'Falta v73. Instalala antes de v104';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Catalogos, instrumentos, aplicaciones e importacion
-- ------------------------------------------------------------
create table if not exists public.tesoreria_cuentas_bancarias (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empresa_titular_id uuid not null references public.empresas(id) on delete restrict,
  banco text not null check(length(btrim(banco)) >= 3),
  numero_cuenta text not null check(length(btrim(numero_cuenta)) >= 3),
  alias text not null check(length(btrim(alias)) >= 3),
  prefijo_importacion text,
  tipo_cuenta text not null default 'corriente'
    check(tipo_cuenta in ('corriente','ahorros','otra')),
  moneda text not null default 'USD' check(moneda = 'USD'),
  activa boolean not null default true,
  creado_por uuid references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_cuenta_bancaria_v104
  on public.tesoreria_cuentas_bancarias(
    grupo_id, empresa_titular_id, lower(btrim(banco)), lower(btrim(numero_cuenta))
  );
create unique index if not exists uq_prefijo_cuenta_bancaria_v104
  on public.tesoreria_cuentas_bancarias(grupo_id, upper(btrim(prefijo_importacion)))
  where activa and prefijo_importacion is not null;

create table if not exists public.tesoreria_saldos_bancarios (
  id uuid primary key default gen_random_uuid(),
  cuenta_bancaria_id uuid not null
    references public.tesoreria_cuentas_bancarias(id) on delete restrict,
  fecha date not null,
  saldo_disponible numeric(16,2) not null,
  fuente text not null default 'manual' check(fuente in ('manual','estado_cuenta','integracion')),
  nota text not null check(length(btrim(nota)) >= 5),
  registrado_por uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  unique(cuenta_bancaria_id, fecha)
);

create table if not exists public.tesoreria_importaciones (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  nombre_archivo text not null check(length(btrim(nombre_archivo)) >= 3),
  hoja_origen text not null check(length(btrim(hoja_origen)) >= 1),
  fecha_corte date not null,
  estado text not null default 'cargada'
    check(estado in ('cargada','en_revision','confirmada','cancelada')),
  total_filas integer not null default 0 check(total_filas >= 0),
  filas_validas integer not null default 0 check(filas_validas >= 0),
  filas_observadas integer not null default 0 check(filas_observadas >= 0),
  filas_migradas integer not null default 0 check(filas_migradas >= 0),
  monto_detectado numeric(16,2) not null default 0 check(monto_detectado >= 0),
  nota text,
  cargado_por uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tesoreria_importacion_lineas (
  id uuid primary key default gen_random_uuid(),
  importacion_id uuid not null references public.tesoreria_importaciones(id) on delete restrict,
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  fila_origen integer not null check(fila_origen > 0),
  fecha_compromiso date,
  beneficiario text,
  codigo_original text,
  prefijo_detectado text,
  numero_instrumento text,
  monto numeric(16,2),
  observacion text,
  cuenta_bancaria_sugerida_id uuid
    references public.tesoreria_cuentas_bancarias(id) on delete restrict,
  estado text not null default 'pendiente'
    check(estado in ('pendiente','lista','observada','descartada','migrada')),
  errores jsonb not null default '[]'::jsonb check(jsonb_typeof(errores) = 'array'),
  datos_origen jsonb not null default '{}'::jsonb check(jsonb_typeof(datos_origen) = 'object'),
  instrumento_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(importacion_id, fila_origen)
);

create table if not exists public.tesoreria_instrumentos_pago (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  cuenta_bancaria_id uuid references public.tesoreria_cuentas_bancarias(id) on delete restrict,
  empresa_pagadora_id uuid not null references public.empresas(id) on delete restrict,
  proveedor_id uuid references public.proveedores(id) on delete restrict,
  beneficiario text not null check(length(btrim(beneficiario)) >= 2),
  medio text not null check(medio in ('cheque','transferencia','efectivo','tarjeta','otro')),
  numero_instrumento text,
  monto numeric(16,2) not null check(monto > 0),
  fecha_emision date,
  fecha_compromiso date not null,
  fecha_efectiva date,
  estado text not null default 'borrador' check(estado in (
    'borrador','programado','emitido','entregado','cobrado',
    'devuelto','protestado','reemplazado','anulado'
  )),
  origen text not null default 'manual'
    check(origen in ('manual','migracion_excel','cuenta_por_pagar_v73')),
  pago_v73_id uuid unique references public.cuentas_por_pagar_pagos(id) on delete restrict,
  importacion_linea_id uuid unique
    references public.tesoreria_importacion_lineas(id) on delete restrict,
  reemplaza_instrumento_id uuid
    references public.tesoreria_instrumentos_pago(id) on delete restrict,
  nota text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(medio <> 'cheque' or (
    cuenta_bancaria_id is not null
    and length(btrim(coalesce(numero_instrumento,''))) > 0
  )),
  check(estado <> 'cobrado' or fecha_efectiva is not null),
  check(reemplaza_instrumento_id is null or reemplaza_instrumento_id <> id)
);

alter table public.tesoreria_importacion_lineas
  drop constraint if exists tesoreria_importacion_lineas_instrumento_id_fkey;
alter table public.tesoreria_importacion_lineas
  add constraint tesoreria_importacion_lineas_instrumento_id_fkey
  foreign key(instrumento_id) references public.tesoreria_instrumentos_pago(id) on delete restrict;

create unique index if not exists uq_numero_instrumento_v104
  on public.tesoreria_instrumentos_pago(
    cuenta_bancaria_id, lower(btrim(numero_instrumento))
  ) where medio = 'cheque';
create index if not exists idx_instrumentos_compromiso_v104
  on public.tesoreria_instrumentos_pago(grupo_id, estado, fecha_compromiso);

create table if not exists public.tesoreria_instrumento_aplicaciones (
  id uuid primary key default gen_random_uuid(),
  instrumento_id uuid not null
    references public.tesoreria_instrumentos_pago(id) on delete restrict,
  cuenta_por_pagar_id uuid not null references public.cuentas_por_pagar(id) on delete restrict,
  monto numeric(16,2) not null check(monto > 0),
  nota text,
  aplicado_por uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  unique(instrumento_id, cuenta_por_pagar_id)
);

create table if not exists public.tesoreria_instrumento_eventos (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  instrumento_id uuid references public.tesoreria_instrumentos_pago(id) on delete restrict,
  tipo text not null check(length(btrim(tipo)) >= 3),
  detalle text not null check(length(btrim(detalle)) >= 5),
  datos jsonb not null default '{}'::jsonb check(jsonb_typeof(datos) = 'object'),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. Compatibilidad: convertir cheques v73 sin duplicarlos
-- ------------------------------------------------------------
insert into public.tesoreria_cuentas_bancarias(
  grupo_id, empresa_titular_id, banco, numero_cuenta, alias, creado_por
)
select distinct c.grupo_id, p.empresa_pagadora_id, btrim(p.banco),
  btrim(p.numero_cuenta), btrim(p.banco) || ' · ' || btrim(p.numero_cuenta), p.creado_por
from public.cuentas_por_pagar_pagos p
join public.cuentas_por_pagar c on c.id = p.cuenta_id
where p.medio = 'cheque'
on conflict do nothing;

insert into public.tesoreria_instrumentos_pago(
  grupo_id, cuenta_bancaria_id, empresa_pagadora_id, proveedor_id,
  beneficiario, medio, numero_instrumento, monto, fecha_emision,
  fecha_compromiso, fecha_efectiva, estado, origen, pago_v73_id,
  nota, creado_por, actualizado_por, idempotency_key, created_at, updated_at
)
select c.grupo_id, cb.id, p.empresa_pagadora_id, c.proveedor_id,
  pr.razon_social, 'cheque', p.numero_cheque, p.monto, p.created_at::date,
  p.fecha_programada, p.fecha_pago,
  case p.estado when 'pagado' then 'cobrado' else p.estado end,
  'cuenta_por_pagar_v73', p.id, p.nota, p.creado_por, p.actualizado_por,
  p.idempotency_key, p.created_at, p.updated_at
from public.cuentas_por_pagar_pagos p
join public.cuentas_por_pagar c on c.id = p.cuenta_id
join public.proveedores pr on pr.id = c.proveedor_id
join public.tesoreria_cuentas_bancarias cb
  on cb.grupo_id = c.grupo_id and cb.empresa_titular_id = p.empresa_pagadora_id
 and lower(btrim(cb.banco)) = lower(btrim(p.banco))
 and lower(btrim(cb.numero_cuenta)) = lower(btrim(p.numero_cuenta))
where p.medio = 'cheque'
on conflict(pago_v73_id) do nothing;

insert into public.tesoreria_instrumento_aplicaciones(
  instrumento_id, cuenta_por_pagar_id, monto, nota, aplicado_por,
  idempotency_key, created_at
)
select i.id, p.cuenta_id, p.monto, 'Aplicacion heredada de v73',
  p.creado_por, gen_random_uuid(), p.created_at
from public.tesoreria_instrumentos_pago i
join public.cuentas_por_pagar_pagos p on p.id = i.pago_v73_id
on conflict(instrumento_id, cuenta_por_pagar_id) do nothing;

-- ------------------------------------------------------------
-- 3. Integridad de aplicaciones
-- ------------------------------------------------------------
create or replace function public.validar_aplicacion_instrumento_v104()
returns trigger language plpgsql security definer set search_path = ''
as $fn$
declare
  v_i public.tesoreria_instrumentos_pago%rowtype;
  v_c public.cuentas_por_pagar%rowtype;
  v_aplicado numeric(16,2);
  v_disponible numeric(16,2);
begin
  select * into v_i from public.tesoreria_instrumentos_pago
  where id = new.instrumento_id for update;
  select * into v_c from public.cuentas_por_pagar
  where id = new.cuenta_por_pagar_id for update;
  if v_i.pago_v73_id is not null then
    if exists(
      select 1 from public.cuentas_por_pagar_pagos p
      where p.id=v_i.pago_v73_id and p.cuenta_id=new.cuenta_por_pagar_id
        and round(p.monto,2)=round(new.monto,2)
    ) then return new;
    else raise exception 'Un cheque heredado de v73 no admite aplicaciones adicionales';
    end if;
  end if;
  if v_i.grupo_id <> v_c.grupo_id or v_i.empresa_pagadora_id <> v_c.empresa_pagadora_id then
    raise exception 'El instrumento y la cuenta por pagar no pertenecen a la misma pagadora';
  end if;
  if v_i.estado in ('anulado','reemplazado') then
    raise exception 'No se puede aplicar un instrumento anulado o reemplazado';
  end if;
  if v_i.estado not in('programado','emitido','entregado','cobrado') then
    raise exception 'Primero programa el instrumento antes de aplicarlo a facturas';
  end if;
  select coalesce(sum(a.monto),0) into v_aplicado
  from public.tesoreria_instrumento_aplicaciones a
  where a.instrumento_id = v_i.id and a.id is distinct from new.id;
  if round(v_aplicado + new.monto,2) > round(v_i.monto,2) then
    raise exception 'Las aplicaciones superan el valor del instrumento';
  end if;
  select v.saldo_por_programar into v_disponible
  from public.vista_cuentas_por_pagar_v73 v where v.id = v_c.id;
  if v_disponible is null then raise exception 'La cuenta por pagar no esta vigente'; end if;
  select v_disponible-coalesce(sum(a.monto),0) into v_disponible
  from public.tesoreria_instrumento_aplicaciones a
  join public.tesoreria_instrumentos_pago i on i.id=a.instrumento_id
  where a.cuenta_por_pagar_id=v_c.id
    and a.id is distinct from new.id
    and i.pago_v73_id is null
    and i.estado in('programado','emitido','entregado','cobrado');
  if round(new.monto,2) > round(v_disponible,2) then
    raise exception 'La aplicacion supera el saldo por programar de la factura (%)', v_disponible;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_validar_aplicacion_instrumento_v104
  on public.tesoreria_instrumento_aplicaciones;
create trigger trg_validar_aplicacion_instrumento_v104
before insert or update on public.tesoreria_instrumento_aplicaciones
for each row execute function public.validar_aplicacion_instrumento_v104();

-- Mientras la interfaz v73 siga operativa, todo cheque nuevo o cambio de
-- estado se refleja automaticamente en el modelo v104.
create or replace function public.sincronizar_instrumento_pago_v73_v104()
returns trigger language plpgsql security definer set search_path=''
as $fn$
declare v_c public.cuentas_por_pagar%rowtype; v_cb uuid; v_i uuid; v_proveedor text;
begin
  if new.medio<>'cheque' then return new; end if;
  select * into v_c from public.cuentas_por_pagar where id=new.cuenta_id;
  select razon_social into v_proveedor from public.proveedores where id=v_c.proveedor_id;
  insert into public.tesoreria_cuentas_bancarias(grupo_id,empresa_titular_id,banco,numero_cuenta,alias,creado_por)
  values(v_c.grupo_id,new.empresa_pagadora_id,btrim(new.banco),btrim(new.numero_cuenta),btrim(new.banco)||' · '||btrim(new.numero_cuenta),new.creado_por)
  on conflict do nothing;
  select id into v_cb from public.tesoreria_cuentas_bancarias
  where grupo_id=v_c.grupo_id and empresa_titular_id=new.empresa_pagadora_id
    and lower(btrim(banco))=lower(btrim(new.banco))
    and lower(btrim(numero_cuenta))=lower(btrim(new.numero_cuenta));
  insert into public.tesoreria_instrumentos_pago(
    grupo_id,cuenta_bancaria_id,empresa_pagadora_id,proveedor_id,beneficiario,
    medio,numero_instrumento,monto,fecha_emision,fecha_compromiso,fecha_efectiva,
    estado,origen,pago_v73_id,nota,creado_por,actualizado_por,idempotency_key,
    created_at,updated_at
  ) values(
    v_c.grupo_id,v_cb,new.empresa_pagadora_id,v_c.proveedor_id,v_proveedor,
    'cheque',new.numero_cheque,new.monto,new.created_at::date,new.fecha_programada,
    new.fecha_pago,case new.estado when 'pagado' then 'cobrado' else new.estado end,
    'cuenta_por_pagar_v73',new.id,new.nota,new.creado_por,new.actualizado_por,
    new.idempotency_key,new.created_at,new.updated_at
  ) on conflict(pago_v73_id) do update set
    monto=excluded.monto,fecha_compromiso=excluded.fecha_compromiso,
    fecha_efectiva=excluded.fecha_efectiva,estado=excluded.estado,
    nota=excluded.nota,actualizado_por=excluded.actualizado_por,updated_at=excluded.updated_at
  returning id into v_i;
  insert into public.tesoreria_instrumento_aplicaciones(
    instrumento_id,cuenta_por_pagar_id,monto,nota,aplicado_por,idempotency_key,created_at
  ) values(v_i,new.cuenta_id,new.monto,'Aplicacion sincronizada desde v73',new.creado_por,gen_random_uuid(),new.created_at)
  on conflict(instrumento_id,cuenta_por_pagar_id) do update set monto=excluded.monto;
  return new;
end;$fn$;

drop trigger if exists trg_sincronizar_instrumento_pago_v73_v104
  on public.cuentas_por_pagar_pagos;
create trigger trg_sincronizar_instrumento_pago_v73_v104
after insert or update of monto,fecha_programada,estado,fecha_pago,nota
on public.cuentas_por_pagar_pagos
for each row execute function public.sincronizar_instrumento_pago_v73_v104();

-- ------------------------------------------------------------
-- 4. Vistas operativas y de liquidez
-- ------------------------------------------------------------
create or replace view public.vista_instrumentos_tesoreria_v104
with(security_invoker = true) as
select i.id, i.grupo_id, i.cuenta_bancaria_id,
  cb.alias as cuenta_alias, cb.banco, cb.numero_cuenta,
  i.empresa_pagadora_id, e.codigo as empresa_pagadora_codigo,
  e.razon_social as empresa_pagadora, i.proveedor_id,
  coalesce(p.razon_social,i.beneficiario) as beneficiario,
  i.medio, i.numero_instrumento, i.monto, i.fecha_emision,
  i.fecha_compromiso, i.fecha_efectiva, i.estado, i.origen,
  coalesce(a.monto_aplicado,0)::numeric(16,2) as monto_aplicado,
  greatest(i.monto-coalesce(a.monto_aplicado,0),0)::numeric(16,2) as monto_sin_asignar,
  i.pago_v73_id, i.importacion_linea_id, i.reemplaza_instrumento_id,
  i.nota, i.created_at, i.updated_at
from public.tesoreria_instrumentos_pago i
left join public.tesoreria_cuentas_bancarias cb on cb.id=i.cuenta_bancaria_id
join public.empresas e on e.id=i.empresa_pagadora_id
left join public.proveedores p on p.id=i.proveedor_id
left join lateral(
  select sum(x.monto) monto_aplicado
  from public.tesoreria_instrumento_aplicaciones x where x.instrumento_id=i.id
) a on true
where public.usuario_puede_tesoreria_v73(i.grupo_id,false);

create or replace view public.vista_efectivo_comprometido_v104
with(security_invoker = true) as
select v.*, (v.fecha_compromiso-current_date)::integer as dias_para_salida,
  case
    when v.fecha_compromiso < current_date then 'vencido'
    when v.fecha_compromiso <= current_date+7 then 'hasta_7_dias'
    when v.fecha_compromiso <= current_date+30 then 'hasta_30_dias'
    when v.fecha_compromiso <= current_date+60 then 'hasta_60_dias'
    when v.fecha_compromiso <= current_date+90 then 'hasta_90_dias'
    else 'mas_90_dias'
  end as horizonte
from public.vista_instrumentos_tesoreria_v104 v
where v.estado in ('programado','emitido','entregado');

create or replace view public.vista_cuentas_por_pagar_v104
with(security_invoker = true) as
select v.id,v.grupo_id,v.comprobante_id,v.empresa_deudora_id,
  v.empresa_deudora_codigo,v.empresa_deudora,v.empresa_pagadora_id,
  v.empresa_pagadora_codigo,v.empresa_pagadora,v.proveedor_id,
  v.proveedor_identificacion,v.proveedor,v.comprobante_tipo,v.numero_documento,
  v.fecha_documento,v.fecha_vencimiento,v.total_documento,v.total_retenciones,
  v.total_exigible,
  (v.total_pagado+coalesce(x.pagado,0))::numeric(14,2) total_pagado,
  (v.total_comprometido+coalesce(x.comprometido,0))::numeric(14,2) total_comprometido,
  greatest(v.total_exigible-v.total_pagado-coalesce(x.pagado,0),0)::numeric(14,2) saldo_pendiente,
  greatest(v.total_exigible-v.total_pagado-v.total_comprometido-
    coalesce(x.pagado,0)-coalesce(x.comprometido,0),0)::numeric(14,2) saldo_por_programar,
  v.dias_vencida,
  case
    when v.estado='anulada' then 'anulada'
    when v.total_exigible<=v.total_pagado+coalesce(x.pagado,0) then 'pagada'
    when v.fecha_vencimiento<current_date then 'vencida'
    when v.total_pagado+coalesce(x.pagado,0)>0 then 'parcial'
    when v.total_comprometido+coalesce(x.comprometido,0)>0 then 'programada'
    else 'pendiente'
  end estado,
  v.nota,v.created_at,v.updated_at
from public.vista_cuentas_por_pagar_v73 v
left join lateral(
  select
    coalesce(sum(a.monto) filter(where i.estado='cobrado'),0) pagado,
    coalesce(sum(a.monto) filter(where i.estado in('programado','emitido','entregado')),0) comprometido
  from public.tesoreria_instrumento_aplicaciones a
  join public.tesoreria_instrumentos_pago i on i.id=a.instrumento_id
  where a.cuenta_por_pagar_id=v.id and i.pago_v73_id is null
) x on true;

create or replace view public.vista_resumen_compromisos_v104
with(security_invoker = true) as
select cb.id as cuenta_bancaria_id, cb.grupo_id, cb.empresa_titular_id,
  e.codigo as empresa_pagadora_codigo, cb.alias, cb.banco, cb.numero_cuenta,
  s.fecha as saldo_fecha, coalesce(s.saldo_disponible,0)::numeric(16,2) saldo_disponible,
  coalesce(x.total,0)::numeric(16,2) comprometido_total,
  coalesce(x.vencido,0)::numeric(16,2) comprometido_vencido,
  coalesce(x.d7,0)::numeric(16,2) comprometido_7_dias,
  coalesce(x.d30,0)::numeric(16,2) comprometido_30_dias,
  coalesce(x.d60,0)::numeric(16,2) comprometido_60_dias,
  coalesce(x.d90,0)::numeric(16,2) comprometido_90_dias,
  (coalesce(s.saldo_disponible,0)-coalesce(x.vencido,0)-coalesce(x.d30,0))::numeric(16,2) saldo_proyectado_30_dias,
  (coalesce(s.saldo_disponible,0)-coalesce(x.total,0))::numeric(16,2) saldo_proyectado_total,
  coalesce(x.cheques,0)::integer as cheques_pendientes
from public.tesoreria_cuentas_bancarias cb
join public.empresas e on e.id=cb.empresa_titular_id
left join lateral(
  select sb.fecha,sb.saldo_disponible from public.tesoreria_saldos_bancarios sb
  where sb.cuenta_bancaria_id=cb.id order by sb.fecha desc,sb.created_at desc limit 1
) s on true
left join lateral(
  select sum(v.monto) total,
    sum(v.monto) filter(where v.fecha_compromiso<current_date) vencido,
    sum(v.monto) filter(where v.fecha_compromiso between current_date and current_date+7) d7,
    sum(v.monto) filter(where v.fecha_compromiso between current_date and current_date+30) d30,
    sum(v.monto) filter(where v.fecha_compromiso between current_date and current_date+60) d60,
    sum(v.monto) filter(where v.fecha_compromiso between current_date and current_date+90) d90,
    count(*) filter(where v.medio='cheque') cheques
  from public.vista_efectivo_comprometido_v104 v where v.cuenta_bancaria_id=cb.id
) x on true
where cb.activa and public.usuario_puede_tesoreria_v73(cb.grupo_id,false);

create or replace view public.vista_importacion_cheques_v104
with(security_invoker = true) as
select l.id, l.importacion_id, l.grupo_id, i.nombre_archivo, i.hoja_origen,
  i.fecha_corte, l.fila_origen, l.fecha_compromiso, l.beneficiario,
  l.codigo_original, l.prefijo_detectado, l.numero_instrumento, l.monto,
  l.observacion, l.cuenta_bancaria_sugerida_id, cb.alias cuenta_sugerida,
  l.estado, l.errores, l.instrumento_id, l.created_at
from public.tesoreria_importacion_lineas l
join public.tesoreria_importaciones i on i.id=l.importacion_id
left join public.tesoreria_cuentas_bancarias cb on cb.id=l.cuenta_bancaria_sugerida_id
where public.usuario_puede_tesoreria_v73(l.grupo_id,false);

-- ------------------------------------------------------------
-- 5. RPC: cuentas, saldos e importacion por lotes
-- ------------------------------------------------------------
create or replace function public.guardar_cuenta_bancaria_v104(
  p_id uuid, p_empresa_titular_id uuid, p_banco text, p_numero_cuenta text,
  p_alias text, p_prefijo text, p_tipo_cuenta text, p_activa boolean,
  p_motivo text, p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid(); v_grupo uuid; v_id uuid; v_resultado jsonb;
begin
  select grupo_id into v_grupo from public.perfiles where id=v_uid and activo;
  if not public.usuario_puede_tesoreria_v73(v_grupo,true) then raise exception 'No tienes permiso para gestionar cuentas bancarias'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select (datos->>'cuenta_bancaria_id')::uuid into v_id from public.tesoreria_instrumento_eventos where idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  if length(btrim(coalesce(p_motivo,'')))<5 then raise exception 'Indica un motivo de al menos 5 caracteres'; end if;
  if not exists(select 1 from public.empresas where id=p_empresa_titular_id and grupo_id=v_grupo and activo) then raise exception 'La empresa titular no pertenece al grupo'; end if;
  if p_tipo_cuenta not in('corriente','ahorros','otra') then raise exception 'El tipo de cuenta no es valido'; end if;
  if p_id is null then
    insert into public.tesoreria_cuentas_bancarias(grupo_id,empresa_titular_id,banco,numero_cuenta,alias,prefijo_importacion,tipo_cuenta,activa,creado_por,actualizado_por)
    values(v_grupo,p_empresa_titular_id,btrim(p_banco),btrim(p_numero_cuenta),btrim(p_alias),nullif(upper(btrim(p_prefijo)),''),p_tipo_cuenta,coalesce(p_activa,true),v_uid,v_uid) returning id into v_id;
  else
    update public.tesoreria_cuentas_bancarias set banco=btrim(p_banco),numero_cuenta=btrim(p_numero_cuenta),alias=btrim(p_alias),prefijo_importacion=nullif(upper(btrim(p_prefijo)),''),tipo_cuenta=p_tipo_cuenta,activa=coalesce(p_activa,true),actualizado_por=v_uid,updated_at=now()
    where id=p_id and grupo_id=v_grupo returning id into v_id;
    if v_id is null then raise exception 'La cuenta bancaria no existe'; end if;
  end if;
  v_resultado:=jsonb_build_object('cuenta_bancaria_id',v_id);
  insert into public.tesoreria_instrumento_eventos(grupo_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_grupo,'cuenta_bancaria',btrim(p_motivo),v_resultado,v_uid,p_idempotency_key);
  return v_id;
end;$fn$;

create or replace function public.registrar_saldo_bancario_v104(
  p_cuenta_bancaria_id uuid,p_fecha date,p_saldo numeric,p_fuente text,
  p_nota text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid(); v_grupo uuid; v_id uuid;
begin
  select grupo_id into v_grupo from public.tesoreria_cuentas_bancarias where id=p_cuenta_bancaria_id;
  if not public.usuario_puede_tesoreria_v73(v_grupo,true) then raise exception 'No tienes permiso para registrar saldos'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.tesoreria_saldos_bancarios where idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  if p_fecha is null or p_fecha>current_date then raise exception 'La fecha del saldo no puede ser futura'; end if;
  insert into public.tesoreria_saldos_bancarios(cuenta_bancaria_id,fecha,saldo_disponible,fuente,nota,registrado_por,idempotency_key)
  values(p_cuenta_bancaria_id,p_fecha,round(p_saldo,2),p_fuente,btrim(p_nota),v_uid,p_idempotency_key)
  on conflict(cuenta_bancaria_id,fecha) do update set saldo_disponible=excluded.saldo_disponible,fuente=excluded.fuente,nota=excluded.nota,registrado_por=excluded.registrado_por,idempotency_key=excluded.idempotency_key,created_at=now()
  returning id into v_id;
  return v_id;
end;$fn$;

create or replace function public.cargar_cheques_migracion_v104(
  p_nombre_archivo text,p_hoja text,p_fecha_corte date,p_filas jsonb,
  p_nota text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path=''
as $fn$
declare
  v_uid uuid:=auth.uid(); v_grupo uuid; v_importacion uuid; v_fila jsonb;
  v_fecha date; v_monto numeric; v_codigo text; v_prefijo text; v_numero text;
  v_cuenta uuid; v_errores jsonb; v_n integer:=0;
begin
  select grupo_id into v_grupo from public.perfiles where id=v_uid and activo;
  if not public.usuario_puede_tesoreria_v73(v_grupo,true) then raise exception 'No tienes permiso para importar cheques'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_importacion from public.tesoreria_importaciones where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('duplicado',true,'importacion_id',v_importacion); end if;
  if jsonb_typeof(coalesce(p_filas,'null'::jsonb))<>'array' then raise exception 'Las filas deben enviarse como arreglo JSON'; end if;
  if jsonb_array_length(p_filas)=0 or jsonb_array_length(p_filas)>2500 then raise exception 'Cada lote debe contener entre 1 y 2500 filas'; end if;
  if p_fecha_corte is null then raise exception 'Indica la fecha de corte'; end if;
  insert into public.tesoreria_importaciones(grupo_id,nombre_archivo,hoja_origen,fecha_corte,nota,cargado_por,idempotency_key)
  values(v_grupo,btrim(p_nombre_archivo),btrim(p_hoja),p_fecha_corte,nullif(btrim(p_nota),''),v_uid,p_idempotency_key) returning id into v_importacion;
  for v_fila in select value from jsonb_array_elements(p_filas) loop
    v_n:=v_n+1; v_codigo:=upper(btrim(coalesce(v_fila->>'codigo_cheque','')));
    v_prefijo:=case when v_codigo~'^BM([[:space:]]|$)' then 'BM' when v_codigo~'^IN([[:space:]]|$)' then 'IN' else null end;
    v_numero:=nullif(substring(v_codigo from '([0-9]+)[[:space:]]*$'),'');
    v_fecha:=case when coalesce(v_fila->>'fecha','')~'^\d{4}-\d{2}-\d{2}$' then (v_fila->>'fecha')::date else null end;
    v_monto:=case when replace(coalesce(v_fila->>'monto',''),',','.')~'^\d+(\.\d{1,2})?$' then replace(v_fila->>'monto',',','.')::numeric else null end;
    select id into v_cuenta from public.tesoreria_cuentas_bancarias where grupo_id=v_grupo and activa and upper(btrim(prefijo_importacion))=v_prefijo;
    v_errores:='[]'::jsonb;
    if v_fecha is null then v_errores:=v_errores||'"fecha_invalida"'::jsonb; end if;
    if v_fecha is not null and v_fecha<p_fecha_corte then v_errores:=v_errores||'"fecha_antes_del_corte"'::jsonb; end if;
    if length(btrim(coalesce(v_fila->>'beneficiario','')))<2 then v_errores:=v_errores||'"beneficiario_vacio"'::jsonb; end if;
    if upper(btrim(coalesce(v_fila->>'beneficiario','')))='TOTAL' then v_errores:=v_errores||'"fila_total"'::jsonb; end if;
    if v_numero is null then v_errores:=v_errores||'"numero_no_detectado"'::jsonb; end if;
    if v_monto is null or v_monto<=0 then v_errores:=v_errores||'"monto_invalido"'::jsonb; end if;
    if v_prefijo is null then v_errores:=v_errores||'"pagador_no_detectado"'::jsonb; end if;
    if v_prefijo is not null and v_cuenta is null then v_errores:=v_errores||'"cuenta_no_configurada"'::jsonb; end if;
    if v_cuenta is not null and v_numero is not null and exists(select 1 from public.tesoreria_instrumentos_pago where cuenta_bancaria_id=v_cuenta and lower(btrim(numero_instrumento))=lower(v_numero)) then v_errores:=v_errores||'"cheque_ya_existe"'::jsonb; end if;
    if v_cuenta is not null and v_numero is not null and exists(select 1 from public.tesoreria_importacion_lineas where importacion_id=v_importacion and cuenta_bancaria_sugerida_id=v_cuenta and lower(btrim(numero_instrumento))=lower(v_numero)) then v_errores:=v_errores||'"cheque_duplicado_en_archivo"'::jsonb; end if;
    if upper(coalesce(v_fila->>'observacion',''))~'(DEVUEL|PROTEST|ANUL|NO COBR|CAMBIO)' then v_errores:=v_errores||'"estado_requiere_revision"'::jsonb; end if;
    insert into public.tesoreria_importacion_lineas(importacion_id,grupo_id,fila_origen,fecha_compromiso,beneficiario,codigo_original,prefijo_detectado,numero_instrumento,monto,observacion,cuenta_bancaria_sugerida_id,estado,errores,datos_origen)
    values(v_importacion,v_grupo,case when coalesce(v_fila->>'fila','')~'^[1-9]\d*$' then (v_fila->>'fila')::integer else v_n end,v_fecha,nullif(btrim(v_fila->>'beneficiario'),''),nullif(v_codigo,''),v_prefijo,v_numero,v_monto,nullif(btrim(v_fila->>'observacion'),''),v_cuenta,case when jsonb_array_length(v_errores)=0 then 'lista' else 'observada' end,v_errores,v_fila);
  end loop;
  update public.tesoreria_importaciones i set total_filas=x.total,filas_validas=x.validas,filas_observadas=x.observadas,monto_detectado=x.monto,estado='en_revision',updated_at=now()
  from(select count(*)::integer total,count(*) filter(where estado='lista')::integer validas,count(*) filter(where estado='observada')::integer observadas,coalesce(sum(monto) filter(where estado='lista'),0) monto from public.tesoreria_importacion_lineas where importacion_id=v_importacion)x where i.id=v_importacion;
  return jsonb_build_object('duplicado',false,'importacion_id',v_importacion,'filas',v_n);
end;$fn$;

create or replace function public.confirmar_cheque_importado_v104(
  p_linea_id uuid,p_cuenta_bancaria_id uuid,p_proveedor_id uuid,
  p_estado text,p_nota text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid(); v_l public.tesoreria_importacion_lineas%rowtype; v_cb public.tesoreria_cuentas_bancarias%rowtype; v_id uuid; v_corte date;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.tesoreria_instrumentos_pago where idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  select * into v_l from public.tesoreria_importacion_lineas where id=p_linea_id for update;
  if not found then raise exception 'La fila importada no existe'; end if;
  if not public.usuario_puede_tesoreria_v73(v_l.grupo_id,true) then raise exception 'No tienes permiso para confirmar cheques'; end if;
  if v_l.estado in('descartada','migrada') then raise exception 'La fila ya fue resuelta'; end if;
  if v_l.fecha_compromiso is null or v_l.monto is null or v_l.monto<=0 or v_l.numero_instrumento is null or length(btrim(coalesce(v_l.beneficiario,'')))<2 then raise exception 'Corrige fecha, beneficiario, numero y monto antes de confirmar'; end if;
  select fecha_corte into v_corte from public.tesoreria_importaciones where id=v_l.importacion_id;
  if v_l.fecha_compromiso<v_corte then raise exception 'La fila es anterior al corte y debe descartarse o migrarse como historico en una fase posterior'; end if;
  select * into v_cb from public.tesoreria_cuentas_bancarias where id=p_cuenta_bancaria_id and grupo_id=v_l.grupo_id and activa;
  if not found then raise exception 'Selecciona una cuenta bancaria activa del grupo'; end if;
  if p_proveedor_id is not null and not exists(select 1 from public.proveedores where id=p_proveedor_id and grupo_id=v_l.grupo_id) then raise exception 'El proveedor no pertenece al grupo'; end if;
  if p_estado not in('programado','emitido','entregado') then raise exception 'La migracion inicial solo admite compromisos pendientes'; end if;
  if length(btrim(coalesce(p_nota,'')))<5 then raise exception 'Indica una nota de al menos 5 caracteres'; end if;
  insert into public.tesoreria_instrumentos_pago(grupo_id,cuenta_bancaria_id,empresa_pagadora_id,proveedor_id,beneficiario,medio,numero_instrumento,monto,fecha_compromiso,estado,origen,importacion_linea_id,nota,creado_por,actualizado_por,idempotency_key)
  values(v_l.grupo_id,v_cb.id,v_cb.empresa_titular_id,p_proveedor_id,v_l.beneficiario,'cheque',v_l.numero_instrumento,round(v_l.monto,2),v_l.fecha_compromiso,p_estado,'migracion_excel',v_l.id,btrim(p_nota),v_uid,v_uid,p_idempotency_key) returning id into v_id;
  update public.tesoreria_importacion_lineas set estado='migrada',instrumento_id=v_id,cuenta_bancaria_sugerida_id=v_cb.id,updated_at=now() where id=v_l.id;
  update public.tesoreria_importaciones i set filas_migradas=x.migradas,estado=case when x.pendientes=0 then 'confirmada' else 'en_revision' end,updated_at=now()
  from(select count(*) filter(where estado='migrada')::integer migradas,count(*) filter(where estado in('lista','observada','pendiente'))::integer pendientes from public.tesoreria_importacion_lineas where importacion_id=v_l.importacion_id)x where i.id=v_l.importacion_id;
  insert into public.tesoreria_instrumento_eventos(grupo_id,instrumento_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_l.grupo_id,v_id,'importado',btrim(p_nota),jsonb_build_object('linea_id',v_l.id,'fila_origen',v_l.fila_origen),v_uid,gen_random_uuid());
  return v_id;
end;$fn$;

create or replace function public.descartar_linea_importacion_v104(
  p_linea_id uuid,p_detalle text,p_idempotency_key uuid
) returns void language plpgsql security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid(); v_l public.tesoreria_importacion_lineas%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if exists(select 1 from public.tesoreria_instrumento_eventos where idempotency_key=p_idempotency_key) then return; end if;
  if length(btrim(coalesce(p_detalle,'')))<5 then raise exception 'Indica por que se descarta la fila'; end if;
  select * into v_l from public.tesoreria_importacion_lineas where id=p_linea_id for update;
  if not found then raise exception 'La fila importada no existe'; end if;
  if not public.usuario_puede_tesoreria_v73(v_l.grupo_id,true) then raise exception 'No tienes permiso para descartar filas'; end if;
  if v_l.estado='migrada' then raise exception 'Un cheque ya migrado no se puede descartar'; end if;
  update public.tesoreria_importacion_lineas set estado='descartada',
    observacion=concat_ws(E'\n',observacion,'DESCARTADA: '||btrim(p_detalle)),updated_at=now()
  where id=v_l.id;
  update public.tesoreria_importaciones i set estado=case when x.pendientes=0 then 'confirmada' else 'en_revision' end,updated_at=now()
  from(select count(*) filter(where estado in('lista','observada','pendiente'))::integer pendientes from public.tesoreria_importacion_lineas where importacion_id=v_l.importacion_id)x where i.id=v_l.importacion_id;
  insert into public.tesoreria_instrumento_eventos(grupo_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_l.grupo_id,'linea_descartada',btrim(p_detalle),jsonb_build_object('linea_id',v_l.id,'fila_origen',v_l.fila_origen),v_uid,p_idempotency_key);
end;$fn$;

create or replace function public.registrar_cheque_v104(
  p_cuenta_bancaria_id uuid,p_proveedor_id uuid,p_beneficiario text,
  p_numero_cheque text,p_monto numeric,p_fecha_emision date,
  p_fecha_compromiso date,p_estado text,p_nota text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid(); v_cb public.tesoreria_cuentas_bancarias%rowtype; v_id uuid;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.tesoreria_instrumentos_pago where idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  select * into v_cb from public.tesoreria_cuentas_bancarias where id=p_cuenta_bancaria_id and activa;
  if not found then raise exception 'La cuenta bancaria no existe o esta inactiva'; end if;
  if not public.usuario_puede_tesoreria_v73(v_cb.grupo_id,true) then raise exception 'No tienes permiso para registrar cheques'; end if;
  if p_proveedor_id is not null and not exists(select 1 from public.proveedores where id=p_proveedor_id and grupo_id=v_cb.grupo_id) then raise exception 'El proveedor no pertenece al grupo'; end if;
  if length(btrim(coalesce(p_beneficiario,'')))<2 then raise exception 'Indica el beneficiario'; end if;
  if length(btrim(coalesce(p_numero_cheque,'')))<1 then raise exception 'Indica el numero de cheque'; end if;
  if p_monto is null or p_monto<=0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_fecha_compromiso is null then raise exception 'Indica la fecha prevista de debito'; end if;
  if p_fecha_emision is not null and p_fecha_compromiso<p_fecha_emision then raise exception 'La fecha prevista no puede ser anterior a la emision'; end if;
  if p_estado not in('borrador','programado','emitido','entregado') then raise exception 'El estado inicial no es valido'; end if;
  if length(btrim(coalesce(p_nota,'')))<5 then raise exception 'Indica una referencia de al menos 5 caracteres'; end if;
  insert into public.tesoreria_instrumentos_pago(grupo_id,cuenta_bancaria_id,empresa_pagadora_id,proveedor_id,beneficiario,medio,numero_instrumento,monto,fecha_emision,fecha_compromiso,estado,origen,nota,creado_por,actualizado_por,idempotency_key)
  values(v_cb.grupo_id,v_cb.id,v_cb.empresa_titular_id,p_proveedor_id,btrim(p_beneficiario),'cheque',btrim(p_numero_cheque),round(p_monto,2),p_fecha_emision,p_fecha_compromiso,p_estado,'manual',btrim(p_nota),v_uid,v_uid,p_idempotency_key) returning id into v_id;
  insert into public.tesoreria_instrumento_eventos(grupo_id,instrumento_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_cb.grupo_id,v_id,'creado',btrim(p_nota),jsonb_build_object('estado',p_estado,'monto',round(p_monto,2),'fecha_compromiso',p_fecha_compromiso),v_uid,gen_random_uuid());
  return v_id;
end;$fn$;

create or replace function public.gestionar_instrumento_v104(
  p_instrumento_id uuid,p_nuevo_estado text,p_fecha_efectiva date,
  p_detalle text,p_idempotency_key uuid
) returns void language plpgsql security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid(); v_i public.tesoreria_instrumentos_pago%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if exists(select 1 from public.tesoreria_instrumento_eventos where idempotency_key=p_idempotency_key) then return; end if;
  if length(btrim(coalesce(p_detalle,'')))<5 then raise exception 'Indica un detalle de al menos 5 caracteres'; end if;
  select * into v_i from public.tesoreria_instrumentos_pago where id=p_instrumento_id for update;
  if not found then raise exception 'El instrumento no existe'; end if;
  if not public.usuario_puede_tesoreria_v73(v_i.grupo_id,true) then raise exception 'No tienes permiso para gestionar el instrumento'; end if;
  if v_i.pago_v73_id is not null then raise exception 'Gestiona este cheque desde su pago de Cuentas por pagar'; end if;
  if p_nuevo_estado=v_i.estado then return; end if;
  if v_i.estado in('cobrado','reemplazado','anulado') then raise exception 'El estado actual es terminal y exige una reversa especializada'; end if;
  if not (
    (v_i.estado='borrador' and p_nuevo_estado in('programado','anulado')) or
    (v_i.estado='programado' and p_nuevo_estado in('emitido','entregado','cobrado','anulado')) or
    (v_i.estado='emitido' and p_nuevo_estado in('entregado','cobrado','anulado')) or
    (v_i.estado='entregado' and p_nuevo_estado in('cobrado','devuelto','protestado')) or
    (v_i.estado in('devuelto','protestado') and p_nuevo_estado='anulado')
  ) then raise exception 'Transicion de estado no permitida: % a %',v_i.estado,p_nuevo_estado; end if;
  if p_nuevo_estado='cobrado' and (p_fecha_efectiva is null or p_fecha_efectiva>current_date) then raise exception 'Indica una fecha efectiva no futura'; end if;
  update public.tesoreria_instrumentos_pago set estado=p_nuevo_estado,
    fecha_efectiva=case when p_nuevo_estado='cobrado' then p_fecha_efectiva else fecha_efectiva end,
    actualizado_por=v_uid,updated_at=now(),nota=concat_ws(E'\n',nota,btrim(p_detalle))
  where id=v_i.id;
  insert into public.tesoreria_instrumento_eventos(grupo_id,instrumento_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_i.grupo_id,v_i.id,'estado',btrim(p_detalle),jsonb_build_object('estado_anterior',v_i.estado,'estado_nuevo',p_nuevo_estado,'fecha_efectiva',p_fecha_efectiva),v_uid,p_idempotency_key);
end;$fn$;

create or replace function public.aplicar_instrumento_cxp_v104(
  p_instrumento_id uuid,p_cuenta_por_pagar_id uuid,p_monto numeric,
  p_nota text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid(); v_grupo uuid; v_id uuid;
begin
  select grupo_id into v_grupo from public.tesoreria_instrumentos_pago where id=p_instrumento_id;
  if not public.usuario_puede_tesoreria_v73(v_grupo,true) then raise exception 'No tienes permiso para aplicar instrumentos'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.tesoreria_instrumento_aplicaciones where idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  if p_monto is null or p_monto<=0 then raise exception 'El monto debe ser mayor que cero'; end if;
  insert into public.tesoreria_instrumento_aplicaciones(instrumento_id,cuenta_por_pagar_id,monto,nota,aplicado_por,idempotency_key)
  values(p_instrumento_id,p_cuenta_por_pagar_id,round(p_monto,2),nullif(btrim(p_nota),''),v_uid,p_idempotency_key) returning id into v_id;
  insert into public.tesoreria_instrumento_eventos(grupo_id,instrumento_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_grupo,p_instrumento_id,'aplicado',coalesce(nullif(btrim(p_nota),''),'Aplicado a cuenta por pagar'),jsonb_build_object('cuenta_por_pagar_id',p_cuenta_por_pagar_id,'monto',round(p_monto,2)),v_uid,gen_random_uuid());
  return v_id;
end;$fn$;

-- ------------------------------------------------------------
-- 6. Seguridad
-- ------------------------------------------------------------
alter table public.tesoreria_cuentas_bancarias enable row level security;
alter table public.tesoreria_saldos_bancarios enable row level security;
alter table public.tesoreria_importaciones enable row level security;
alter table public.tesoreria_importacion_lineas enable row level security;
alter table public.tesoreria_instrumentos_pago enable row level security;
alter table public.tesoreria_instrumento_aplicaciones enable row level security;
alter table public.tesoreria_instrumento_eventos enable row level security;

drop policy if exists "leer_cuentas_bancarias_v104" on public.tesoreria_cuentas_bancarias;
create policy "leer_cuentas_bancarias_v104" on public.tesoreria_cuentas_bancarias for select to authenticated using(public.usuario_puede_tesoreria_v73(grupo_id,false));
drop policy if exists "leer_saldos_bancarios_v104" on public.tesoreria_saldos_bancarios;
create policy "leer_saldos_bancarios_v104" on public.tesoreria_saldos_bancarios for select to authenticated using(exists(select 1 from public.tesoreria_cuentas_bancarias c where c.id=cuenta_bancaria_id));
drop policy if exists "leer_importaciones_tesoreria_v104" on public.tesoreria_importaciones;
create policy "leer_importaciones_tesoreria_v104" on public.tesoreria_importaciones for select to authenticated using(public.usuario_puede_tesoreria_v73(grupo_id,false));
drop policy if exists "leer_lineas_importacion_tesoreria_v104" on public.tesoreria_importacion_lineas;
create policy "leer_lineas_importacion_tesoreria_v104" on public.tesoreria_importacion_lineas for select to authenticated using(public.usuario_puede_tesoreria_v73(grupo_id,false));
drop policy if exists "leer_instrumentos_tesoreria_v104" on public.tesoreria_instrumentos_pago;
create policy "leer_instrumentos_tesoreria_v104" on public.tesoreria_instrumentos_pago for select to authenticated using(public.usuario_puede_tesoreria_v73(grupo_id,false));
drop policy if exists "leer_aplicaciones_tesoreria_v104" on public.tesoreria_instrumento_aplicaciones;
create policy "leer_aplicaciones_tesoreria_v104" on public.tesoreria_instrumento_aplicaciones for select to authenticated using(exists(select 1 from public.tesoreria_instrumentos_pago i where i.id=instrumento_id));
drop policy if exists "leer_eventos_tesoreria_v104" on public.tesoreria_instrumento_eventos;
create policy "leer_eventos_tesoreria_v104" on public.tesoreria_instrumento_eventos for select to authenticated using(public.usuario_puede_tesoreria_v73(grupo_id,false));

do $$ declare v_tabla text; begin
  foreach v_tabla in array array['tesoreria_cuentas_bancarias','tesoreria_saldos_bancarios','tesoreria_importaciones','tesoreria_importacion_lineas','tesoreria_instrumentos_pago','tesoreria_instrumento_aplicaciones','tesoreria_instrumento_eventos'] loop
    execute format('alter table public.%I owner to postgres',v_tabla);
    execute format('revoke all on public.%I from public,anon',v_tabla);
    execute format('revoke insert,update,delete on public.%I from authenticated',v_tabla);
    execute format('grant select on public.%I to authenticated',v_tabla);
  end loop;
end $$;

alter function public.validar_aplicacion_instrumento_v104() owner to postgres;
alter function public.sincronizar_instrumento_pago_v73_v104() owner to postgres;
alter function public.guardar_cuenta_bancaria_v104(uuid,uuid,text,text,text,text,text,boolean,text,uuid) owner to postgres;
alter function public.registrar_saldo_bancario_v104(uuid,date,numeric,text,text,uuid) owner to postgres;
alter function public.cargar_cheques_migracion_v104(text,text,date,jsonb,text,uuid) owner to postgres;
alter function public.confirmar_cheque_importado_v104(uuid,uuid,uuid,text,text,uuid) owner to postgres;
alter function public.descartar_linea_importacion_v104(uuid,text,uuid) owner to postgres;
alter function public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid) owner to postgres;
alter function public.gestionar_instrumento_v104(uuid,text,date,text,uuid) owner to postgres;
alter function public.aplicar_instrumento_cxp_v104(uuid,uuid,numeric,text,uuid) owner to postgres;

revoke all on function public.validar_aplicacion_instrumento_v104() from public,anon,authenticated;
revoke all on function public.sincronizar_instrumento_pago_v73_v104() from public,anon,authenticated;
revoke all on function public.guardar_cuenta_bancaria_v104(uuid,uuid,text,text,text,text,text,boolean,text,uuid) from public,anon;
revoke all on function public.registrar_saldo_bancario_v104(uuid,date,numeric,text,text,uuid) from public,anon;
revoke all on function public.cargar_cheques_migracion_v104(text,text,date,jsonb,text,uuid) from public,anon;
revoke all on function public.confirmar_cheque_importado_v104(uuid,uuid,uuid,text,text,uuid) from public,anon;
revoke all on function public.descartar_linea_importacion_v104(uuid,text,uuid) from public,anon;
revoke all on function public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid) from public,anon;
revoke all on function public.gestionar_instrumento_v104(uuid,text,date,text,uuid) from public,anon;
revoke all on function public.aplicar_instrumento_cxp_v104(uuid,uuid,numeric,text,uuid) from public,anon;
grant execute on function public.guardar_cuenta_bancaria_v104(uuid,uuid,text,text,text,text,text,boolean,text,uuid) to authenticated;
grant execute on function public.registrar_saldo_bancario_v104(uuid,date,numeric,text,text,uuid) to authenticated;
grant execute on function public.cargar_cheques_migracion_v104(text,text,date,jsonb,text,uuid) to authenticated;
grant execute on function public.confirmar_cheque_importado_v104(uuid,uuid,uuid,text,text,uuid) to authenticated;
grant execute on function public.descartar_linea_importacion_v104(uuid,text,uuid) to authenticated;
grant execute on function public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid) to authenticated;
grant execute on function public.gestionar_instrumento_v104(uuid,text,date,text,uuid) to authenticated;
grant execute on function public.aplicar_instrumento_cxp_v104(uuid,uuid,numeric,text,uuid) to authenticated;

do $$ declare v_vista text; begin
  foreach v_vista in array array['vista_instrumentos_tesoreria_v104','vista_efectivo_comprometido_v104','vista_cuentas_por_pagar_v104','vista_resumen_compromisos_v104','vista_importacion_cheques_v104'] loop
    execute format('alter view public.%I owner to postgres',v_vista);
    execute format('revoke all on public.%I from public,anon',v_vista);
    execute format('grant select on public.%I to authenticated',v_vista);
  end loop;
end $$;

comment on table public.tesoreria_importacion_lineas is
  'Bandeja temporal. Una fila no compromete efectivo hasta confirmar_cheque_importado_v104.';
comment on table public.tesoreria_instrumentos_pago is
  'Instrumentos que comprometen o materializan salidas de efectivo, independientes de sus aplicaciones documentales.';

commit;
notify pgrst,'reload schema';
