-- ============================================================
-- v131 - Cola durable de sincronizacion BomanSport / Sheets
-- Ejecutar una sola vez y despues verificacion_v131.sql.
-- Nunca ejecutar migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v131', 0));

create table if not exists public.bomansport_sincronizaciones (
  id uuid primary key default gen_random_uuid(),
  operacion text not null check (operacion in ('marcar_etapa')),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  estado text not null default 'pendiente'
    check (estado in ('pendiente', 'procesando', 'sincronizado', 'intervencion')),
  intentos integer not null default 0 check (intentos >= 0),
  proximo_intento_at timestamptz not null default now(),
  ultimo_intento_at timestamptz,
  sincronizado_at timestamptz,
  ultimo_error text,
  idempotency_key uuid not null unique,
  usuario_id uuid references public.perfiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_bomansport_sinc_pendientes_v131
  on public.bomansport_sincronizaciones(proximo_intento_at, created_at)
  where estado = 'pendiente';

alter table public.bomansport_sincronizaciones enable row level security;
alter table public.bomansport_sincronizaciones force row level security;
revoke all on public.bomansport_sincronizaciones from public, anon, authenticated;

create or replace function public.reclamar_sincronizaciones_bomansport_v131(
  p_limite integer default 20
)
returns setof public.bomansport_sincronizaciones
language plpgsql security definer set search_path = '' as $v131$
begin
  return query
  with candidatas as (
    select s.id
    from public.bomansport_sincronizaciones s
    where s.estado = 'pendiente'
      and s.proximo_intento_at <= now()
    order by s.proximo_intento_at, s.created_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limite, 20), 100))
  )
  update public.bomansport_sincronizaciones s
     set estado = 'procesando',
         intentos = s.intentos + 1,
         ultimo_intento_at = now(),
         updated_at = now()
    from candidatas c
   where s.id = c.id
  returning s.*;
end;
$v131$;

create or replace function public.resolver_sincronizacion_bomansport_v131(
  p_id uuid,
  p_exitosa boolean,
  p_error text default null
)
returns void
language plpgsql security definer set search_path = '' as $v131$
begin
  update public.bomansport_sincronizaciones s
     set estado = case
           when coalesce(p_exitosa, false) then 'sincronizado'
           when s.intentos >= 8 then 'intervencion'
           else 'pendiente'
         end,
         sincronizado_at = case when coalesce(p_exitosa, false) then now() else null end,
         proximo_intento_at = case
           when coalesce(p_exitosa, false) then s.proximo_intento_at
           else now() + make_interval(mins => least(1440, (power(2, least(s.intentos, 8)))::integer))
         end,
         ultimo_error = case
           when coalesce(p_exitosa, false) then null
           else left(coalesce(nullif(btrim(p_error), ''), 'Error de sincronizacion no especificado'), 2000)
         end,
         updated_at = now()
   where s.id = p_id and s.estado = 'procesando';

  if not found then
    raise exception 'La sincronizacion no existe o no esta siendo procesada';
  end if;
end;
$v131$;

revoke all on function public.reclamar_sincronizaciones_bomansport_v131(integer)
  from public, anon, authenticated;
revoke all on function public.resolver_sincronizacion_bomansport_v131(uuid,boolean,text)
  from public, anon, authenticated;
grant execute on function public.reclamar_sincronizaciones_bomansport_v131(integer)
  to service_role;
grant execute on function public.resolver_sincronizacion_bomansport_v131(uuid,boolean,text)
  to service_role;

comment on table public.bomansport_sincronizaciones is
  'Bandeja durable de operaciones confirmadas en Supabase pendientes de reflejarse en BomanSport/Sheets.';

commit;
