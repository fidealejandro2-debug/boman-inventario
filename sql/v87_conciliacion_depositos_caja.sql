-- ============================================================
-- BOMAN INVENTARIO - v87: conciliacion y depositos de caja
-- Sirve para franquicias y tiendas propias. Ejecutar despues de v86.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.almacen_caja_operativo_v71()') is null
     or to_regprocedure('public.registrar_caja_franquicia_v42(date,text,text,text,numeric,text,text,uuid,uuid)') is null then
    raise exception 'Faltan v71/v83. Instalalas antes de v87';
  end if;
end $$;

create table if not exists public.caja_depositos_v87 (
  id uuid primary key default gen_random_uuid(),
  cierre_id uuid not null references public.franquicia_caja_cierres(id) on delete restrict,
  almacen_id uuid not null references public.almacenes(id) on delete restrict,
  movimiento_id uuid not null unique references public.franquicia_caja_movimientos(id) on delete restrict,
  fecha_deposito date not null,
  monto numeric(14,2) not null check (monto > 0),
  banco text not null check (btrim(banco) <> ''),
  referencia text not null check (btrim(referencia) <> ''),
  comprobante_url text,
  nota text,
  estado text not null default 'registrado'
    check (estado in ('registrado', 'confirmado', 'anulado')),
  registrado_por uuid not null references public.perfiles(id) on delete restrict,
  confirmado_por uuid references public.perfiles(id) on delete restrict,
  confirmado_at timestamptz,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((estado in ('registrado', 'anulado') and confirmado_por is null and confirmado_at is null)
      or (estado = 'confirmado' and confirmado_por is not null and confirmado_at is not null))
);

create index if not exists idx_caja_depositos_almacen_fecha_v87
  on public.caja_depositos_v87(almacen_id, fecha_deposito desc);
create index if not exists idx_caja_depositos_pendientes_v87
  on public.caja_depositos_v87(estado, created_at desc);

create or replace function public.registrar_deposito_caja_v87(
  p_cierre_id uuid,
  p_fecha date,
  p_monto numeric,
  p_banco text,
  p_referencia text,
  p_comprobante_url text,
  p_nota text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.franquicia_caja_cierres%rowtype;
  v_id uuid;
  v_movimiento uuid;
  v_depositado numeric(14,2);
  v_rol text := public.rol_usuario_actual();
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.caja_depositos_v87
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  select * into c from public.franquicia_caja_cierres
  where id = p_cierre_id for update;
  if not found or c.estado <> 'cerrado' then
    raise exception 'Selecciona un cierre diario confirmado';
  end if;
  if v_rol not in ('admin', 'franquiciado', 'tienda')
     or (v_rol <> 'admin' and (
       not public.usuario_tiene_permiso_v35('franquicia.caja')
       or not public.usuario_puede_almacen(c.almacen_id, true)
     )) then
    raise exception 'No tienes permiso para registrar el deposito de este local';
  end if;
  if p_fecha is null
     or p_fecha <= c.fecha
     or p_fecha > (now() at time zone 'America/Guayaquil')::date then
    raise exception 'El deposito debe registrarse en un dia posterior al cierre y no puede ser futuro';
  end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if btrim(coalesce(p_banco, '')) = '' or btrim(coalesce(p_referencia, '')) = '' then
    raise exception 'Banco y referencia del deposito son obligatorios';
  end if;

  select coalesce(sum(d.monto), 0) into v_depositado
  from public.caja_depositos_v87 d
  where d.cierre_id = c.id and d.estado <> 'anulado';
  if round(v_depositado + p_monto, 2) > c.efectivo_contado then
    raise exception 'El total depositado no puede superar el efectivo contado en el cierre';
  end if;

  select public.registrar_caja_franquicia_v42(
    p_fecha, 'egreso', 'deposito_bancario',
    'Deposito de efectivo del cierre ' || c.fecha::text,
    round(p_monto, 2), 'efectivo', btrim(p_referencia),
    p_idempotency_key, c.almacen_id
  ) into v_movimiento;

  insert into public.caja_depositos_v87 (
    cierre_id, almacen_id, movimiento_id, fecha_deposito, monto,
    banco, referencia, comprobante_url, nota, registrado_por,
    idempotency_key
  ) values (
    c.id, c.almacen_id, v_movimiento, p_fecha, round(p_monto, 2),
    btrim(p_banco), btrim(p_referencia),
    nullif(btrim(coalesce(p_comprobante_url, '')), ''),
    nullif(btrim(coalesce(p_nota, '')), ''), auth.uid(), p_idempotency_key
  ) returning id into v_id;

  insert into public.notificaciones_comunicados (
    origen_clave, origen_tipo, almacen_id, rol_destino,
    modulo, nivel, titulo, mensaje, href, creado_por
  )
  select 'caja:deposito:' || v_id::text || ':' || r.rol::text,
    'deposito_caja', c.almacen_id, r.rol,
    'Caja', 'accion', 'Deposito de caja por confirmar',
    'Se registro un deposito de ' || round(p_monto, 2)::text ||
      ' en ' || btrim(p_banco) || '. Revisa el comprobante y la referencia.',
    case when c.franquicia_id is null then '/tienda' else '/franquicia' end,
    auth.uid()
  from unnest(array['admin', 'control']::public.rol_usuario[]) r(rol)
  on conflict (origen_clave) do nothing;

  return v_id;
end;
$$;

create or replace function public.confirmar_deposito_caja_v87(
  p_deposito_id uuid,
  p_nota text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare d public.caja_depositos_v87%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden confirmar depositos';
  end if;
  if char_length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'Registra una verificacion de al menos 5 caracteres';
  end if;
  select * into d from public.caja_depositos_v87
  where id = p_deposito_id for update;
  if not found then raise exception 'El deposito no existe'; end if;
  if d.estado = 'confirmado' then return; end if;
  if d.estado = 'anulado' then raise exception 'El deposito fue anulado y no se puede confirmar'; end if;

  update public.caja_depositos_v87
  set estado = 'confirmado', confirmado_por = auth.uid(), confirmado_at = now(),
      nota = concat_ws(E'\n', nota, btrim(p_nota)), updated_at = now()
  where id = d.id;
  update public.notificaciones_comunicados
  set activo = false, updated_at = now()
  where origen_clave like 'caja:deposito:' || d.id::text || ':%';
end;
$$;

-- Un deposito pendiente puede revertirse desde el diario, pero ambas piezas
-- deben cambiar juntas. Una vez conciliado por Administracion queda protegido.
create or replace function public.proteger_movimiento_deposito_v87()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare d public.caja_depositos_v87%rowtype;
begin
  if old.estado = new.estado then return new; end if;
  select * into d from public.caja_depositos_v87
  where movimiento_id = old.id for update;
  if not found then return new; end if;
  if d.estado = 'confirmado' then
    raise exception 'El deposito ya fue confirmado y no se puede revertir como un movimiento comun';
  end if;
  if old.estado = 'vigente' and new.estado = 'revertido' then
    update public.caja_depositos_v87
    set estado = 'anulado', updated_at = now()
    where id = d.id;
    update public.notificaciones_comunicados
    set activo = false, updated_at = now()
    where origen_clave like 'caja:deposito:' || d.id::text || ':%';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_proteger_movimiento_deposito_v87
  on public.franquicia_caja_movimientos;
create trigger trg_proteger_movimiento_deposito_v87
before update of estado on public.franquicia_caja_movimientos
for each row execute function public.proteger_movimiento_deposito_v87();

create or replace view public.vista_depositos_caja_v87
with (security_invoker = true)
as
select d.id, d.cierre_id, d.almacen_id, a.nombre as almacen,
  c.fecha as fecha_cierre, c.efectivo_contado,
  d.fecha_deposito, d.monto, d.banco, d.referencia,
  d.comprobante_url, d.nota, d.estado, d.movimiento_id,
  d.registrado_por, rp.nombre_completo as registrado_por_nombre,
  d.confirmado_por, cp.nombre_completo as confirmado_por_nombre,
  d.confirmado_at, d.created_at
from public.caja_depositos_v87 d
join public.franquicia_caja_cierres c on c.id = d.cierre_id
join public.almacenes a on a.id = d.almacen_id
join public.perfiles rp on rp.id = d.registrado_por
left join public.perfiles cp on cp.id = d.confirmado_por;

alter table public.caja_depositos_v87 enable row level security;
drop policy if exists leer_depositos_caja_v87 on public.caja_depositos_v87;
create policy leer_depositos_caja_v87 on public.caja_depositos_v87
for select to authenticated
using (public.usuario_puede_almacen(almacen_id, false));

alter table public.caja_depositos_v87 owner to postgres;
alter function public.registrar_deposito_caja_v87(uuid,date,numeric,text,text,text,text,uuid) owner to postgres;
alter function public.confirmar_deposito_caja_v87(uuid,text) owner to postgres;
alter function public.proteger_movimiento_deposito_v87() owner to postgres;
alter view public.vista_depositos_caja_v87 owner to postgres;

revoke all on public.caja_depositos_v87, public.vista_depositos_caja_v87
  from public, anon;
revoke insert, update, delete on public.caja_depositos_v87 from authenticated;
grant select on public.caja_depositos_v87, public.vista_depositos_caja_v87
  to authenticated;
revoke execute on function public.registrar_deposito_caja_v87(uuid,date,numeric,text,text,text,text,uuid)
  from public, anon;
revoke execute on function public.confirmar_deposito_caja_v87(uuid,text)
  from public, anon;
revoke execute on function public.proteger_movimiento_deposito_v87()
  from public, anon, authenticated;
grant execute on function public.registrar_deposito_caja_v87(uuid,date,numeric,text,text,text,text,uuid),
  public.confirmar_deposito_caja_v87(uuid,text) to authenticated;

commit;

notify pgrst, 'reload schema';
