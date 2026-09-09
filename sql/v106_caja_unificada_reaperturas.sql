-- ============================================================
-- BOMAN INVENTARIO - v106: caja unificada y reaperturas autorizadas
-- Corrige aperturas duplicadas, protege turnos cerrados y limita la
-- reapertura al titular de la franquicia o a Administracion.
-- Ejecutar una sola vez DESPUES de v105.
-- ============================================================
begin;

do $$
begin
  if to_regclass('public.franquicia_caja_turnos') is null then
    raise exception 'Falta v81. Instalalo antes de v106';
  end if;
  if to_regprocedure('public.reabrir_caja_franquicia_v47(uuid,text)') is null then
    raise exception 'Falta v71. Instalalo antes de v106';
  end if;
end;
$$;

alter table public.franquicia_caja_turnos
  add column if not exists reabierto_por uuid references public.perfiles(id) on delete restrict,
  add column if not exists reabierto_at timestamptz;

create table if not exists public.franquicia_caja_turno_eventos_v106 (
  id uuid primary key default gen_random_uuid(),
  turno_id uuid not null references public.franquicia_caja_turnos(id) on delete restrict,
  tipo text not null check (tipo in ('reapertura_autorizada')),
  detalle text not null check (btrim(detalle) <> ''),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_turno_eventos_turno_v106
  on public.franquicia_caja_turno_eventos_v106(turno_id, created_at desc);

-- Si una instalacion antigua ya usaba el estado reabierto, conserva ese
-- historial como migrado en lugar de dejar filas imposibles de auditar.
update public.franquicia_caja_turnos
set reabierto_por = coalesce(reabierto_por, cerrado_por, abierto_por),
    reabierto_at = coalesce(reabierto_at, cerrado_at, abierto_at),
    motivo_reapertura = coalesce(nullif(btrim(motivo_reapertura), ''), 'Reapertura anterior a v106')
where estado = 'reabierto'
  and (reabierto_por is null or reabierto_at is null);

insert into public.franquicia_caja_turno_eventos_v106(
  turno_id, tipo, detalle, usuario_id, created_at
)
select t.id, 'reapertura_autorizada',
       coalesce(nullif(btrim(t.motivo_reapertura), ''), 'Reapertura anterior a v106'),
       coalesce(t.reabierto_por, t.cerrado_por, t.abierto_por),
       coalesce(t.reabierto_at, t.cerrado_at, t.abierto_at)
from public.franquicia_caja_turnos t
where t.estado = 'reabierto'
  and not exists (
    select 1 from public.franquicia_caja_turno_eventos_v106 e
    where e.turno_id = t.id and e.tipo = 'reapertura_autorizada'
  );

-- El consolidado diario no puede cerrarse mientras quede un turno de esa
-- fecha abierto. Asi no se congela el dia con ventas todavia en curso.
create or replace function public.validar_turnos_antes_cierre_general_v106()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if new.estado = 'cerrado' and exists (
    select 1 from public.franquicia_caja_turnos t
    where t.almacen_id = new.almacen_id
      and t.estado in ('abierto', 'reabierto')
      and (t.abierto_at at time zone 'America/Guayaquil')::date <= new.fecha
  ) then
    raise exception 'Cierra primero todos los turnos de caja de ese dia antes de confirmar el cierre general';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_validar_turnos_cierre_general_v106
  on public.franquicia_caja_cierres;
create trigger trg_validar_turnos_cierre_general_v106
before insert or update of estado on public.franquicia_caja_cierres
for each row execute function public.validar_turnos_antes_cierre_general_v106();

-- Conserva el nombre v81 para que clientes ya publicados reciban tambien el
-- mensaje legible. La comprobacion previa evita exponer el nombre de indices.
create or replace function public.abrir_turno_caja_v81(
  p_caja_codigo text,
  p_turno text,
  p_saldo numeric,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  f public.franquicias%rowtype;
  t public.franquicia_caja_turnos%rowtype;
  v_ocupante text;
  v_caja text := upper(btrim(coalesce(p_caja_codigo, '')));
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
begin
  if not public.usuario_tiene_permiso_v35('franquicia.turnos') then
    raise exception 'No tienes permiso para operar turnos';
  end if;
  if p_idempotency_key is null or v_caja = ''
     or btrim(coalesce(p_turno, '')) = '' or coalesce(p_saldo, -1) < 0 then
    raise exception 'Caja, turno, saldo e idempotencia son obligatorios';
  end if;

  select * into f from public.franquicias
  where id = public.franquicia_usuario_actual_v42() and activo;
  if not found then raise exception 'No tienes una franquicia activa'; end if;

  select * into t from public.franquicia_caja_turnos
  where idempotency_apertura = p_idempotency_key;
  if found then return to_jsonb(t); end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(f.almacen_id::text || ':' || v_caja, 106)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(auth.uid()::text, 106)
  );

  select tt.* into t
  from public.franquicia_caja_turnos tt
  where tt.almacen_id = f.almacen_id and tt.caja_codigo = v_caja
    and tt.estado in ('abierto', 'reabierto')
  limit 1;
  if found then
    select p.nombre_completo into v_ocupante
    from public.perfiles p where p.id = t.abierto_por;
    if t.abierto_por = auth.uid() then
      raise exception 'Ya tienes abierta % desde las %. Cierra ese turno antes de abrir otro.',
        t.caja_codigo, to_char(t.abierto_at at time zone 'America/Guayaquil', 'HH24:MI');
    end if;
    raise exception '% ya esta abierta por %. Esa persona debe cerrar su turno antes de reutilizar la caja.',
      t.caja_codigo, v_ocupante;
  end if;

  select tt.* into t
  from public.franquicia_caja_turnos tt
  where tt.abierto_por = auth.uid() and tt.estado in ('abierto', 'reabierto')
  limit 1;
  if found then
    raise exception 'Ya tienes abierto el turno % en %. Cierralo antes de abrir otro.',
      t.turno, t.caja_codigo;
  end if;

  if exists (
    select 1 from public.franquicia_caja_turnos tt
    where tt.franquicia_id = f.id and tt.abierto_por = auth.uid()
      and tt.estado = 'cerrado'
      and (tt.abierto_at at time zone 'America/Guayaquil')::date = v_hoy
  ) then
    raise exception 'Ya cerraste tu turno de hoy. El franquiciado o un administrador debe autorizar su reapertura.';
  end if;

  insert into public.franquicia_caja_turnos(
    franquicia_id, almacen_id, caja_codigo, turno, saldo_inicial,
    abierto_por, idempotency_apertura
  ) values (
    f.id, f.almacen_id, v_caja, btrim(p_turno), round(p_saldo, 2),
    auth.uid(), p_idempotency_key
  ) returning * into t;
  return to_jsonb(t);
exception
  when unique_violation then
    raise exception 'La caja o el operador ya tienen un turno abierto. Actualiza la pantalla para ver quien debe cerrarlo.';
end;
$fn$;

create or replace function public.reabrir_turno_caja_v106(
  p_turno_id uuid,
  p_motivo text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  t public.franquicia_caja_turnos%rowtype;
  v_rol text := public.rol_usuario_actual();
begin
  if v_rol not in ('admin', 'franquiciado') then
    raise exception 'Solo el franquiciado titular o un administrador pueden autorizar la reapertura';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica la reapertura con al menos 10 caracteres';
  end if;

  select * into t from public.franquicia_caja_turnos
  where id = p_turno_id for update;
  if not found then raise exception 'El turno no existe'; end if;
  if v_rol = 'franquiciado'
     and not public.usuario_puede_franquicia_v42(t.franquicia_id, true, true) then
    raise exception 'No puedes autorizar reaperturas de otro local';
  end if;
  if t.estado <> 'cerrado' then
    raise exception 'El turno debe estar cerrado para autorizar su reapertura';
  end if;
  if exists (
    select 1 from public.franquicia_caja_cierres c
    where c.almacen_id = t.almacen_id and c.estado = 'cerrado'
      and c.fecha = (t.abierto_at at time zone 'America/Guayaquil')::date
  ) then
    raise exception 'Primero autoriza la reapertura del cierre general de ese dia';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(t.almacen_id::text || ':' || t.caja_codigo, 106)
  );
  if exists (
    select 1 from public.franquicia_caja_turnos x
    where x.id <> t.id and x.estado in ('abierto', 'reabierto')
      and (x.almacen_id = t.almacen_id and x.caja_codigo = t.caja_codigo
        or x.abierto_por = t.abierto_por)
  ) then
    raise exception 'No se puede reabrir: la caja o el operador ya tienen otro turno abierto';
  end if;

  update public.franquicia_caja_turnos
  set estado = 'reabierto', motivo_reapertura = btrim(p_motivo),
      reabierto_por = auth.uid(), reabierto_at = now()
  where id = t.id
  returning * into t;

  insert into public.franquicia_caja_turno_eventos_v106(
    turno_id, tipo, detalle, usuario_id
  ) values (
    t.id, 'reapertura_autorizada', btrim(p_motivo), auth.uid()
  );
  return to_jsonb(t);
end;
$fn$;

-- El cierre general de una franquicia solo puede reabrirlo su titular o un
-- administrador. En tiendas propias queda reservado a Administracion.
create or replace function public.reabrir_caja_franquicia_v47(
  p_cierre_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c public.franquicia_caja_cierres%rowtype;
  v_rol text := public.rol_usuario_actual();
begin
  if v_rol not in ('admin', 'franquiciado') then
    raise exception 'Solo el franquiciado titular o un administrador pueden autorizar la reapertura';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Explica la reapertura con al menos 10 caracteres';
  end if;
  select * into c from public.franquicia_caja_cierres
  where id = p_cierre_id for update;
  if not found then raise exception 'El cierre no existe'; end if;
  if v_rol = 'franquiciado' and (
    c.franquicia_id is null
    or not public.usuario_puede_franquicia_v42(c.franquicia_id, true, true)
    or not public.usuario_tiene_permiso_v35('franquicia.caja')
  ) then
    raise exception 'No puedes autorizar la reapertura de otro local';
  end if;
  if c.estado <> 'cerrado' then raise exception 'El cierre ya esta reabierto'; end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(c.almacen_id::text || c.fecha::text, 47)
  );
  update public.franquicia_caja_cierres
  set estado = 'reabierto', motivo_reapertura = btrim(p_motivo),
      reabierto_por = auth.uid(), reabierto_at = now()
  where id = c.id;
  insert into public.franquicia_caja_cierre_eventos(
    cierre_id, tipo, detalle, usuario_id
  ) values (c.id, 'reabierto', btrim(p_motivo), auth.uid());
end;
$fn$;

alter table public.franquicia_caja_turno_eventos_v106 enable row level security;
drop policy if exists leer_turno_eventos_v106 on public.franquicia_caja_turno_eventos_v106;
create policy leer_turno_eventos_v106
on public.franquicia_caja_turno_eventos_v106 for select to authenticated
using (
  exists (
    select 1 from public.franquicia_caja_turnos t
    where t.id = turno_id
      and public.usuario_puede_franquicia_v42(t.franquicia_id, false, false)
  )
);

alter table public.franquicia_caja_turno_eventos_v106 owner to postgres;
alter function public.abrir_turno_caja_v81(text,text,numeric,uuid) owner to postgres;
alter function public.reabrir_turno_caja_v106(uuid,text) owner to postgres;
alter function public.reabrir_caja_franquicia_v47(uuid,text) owner to postgres;
alter function public.validar_turnos_antes_cierre_general_v106() owner to postgres;

revoke all on public.franquicia_caja_turno_eventos_v106 from public, anon;
revoke insert, update, delete on public.franquicia_caja_turno_eventos_v106 from authenticated;
grant select on public.franquicia_caja_turno_eventos_v106 to authenticated;

revoke all on function public.reabrir_turno_caja_v106(uuid,text) from public, anon;
grant execute on function public.reabrir_turno_caja_v106(uuid,text) to authenticated;
revoke execute on function public.abrir_turno_caja_v81(text,text,numeric,uuid),
  public.reabrir_caja_franquicia_v47(uuid,text) from public, anon;
grant execute on function public.abrir_turno_caja_v81(text,text,numeric,uuid),
  public.reabrir_caja_franquicia_v47(uuid,text) to authenticated;
revoke execute on function public.validar_turnos_antes_cierre_general_v106()
  from public, anon, authenticated;

commit;
notify pgrst, 'reload schema';
