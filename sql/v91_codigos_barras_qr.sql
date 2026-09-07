-- ============================================================
-- BOMAN INVENTARIO - v91: codigos de barras y QR de productos
--
-- Un producto conserva su SKU y puede tener codigos alternos (EAN/UPC,
-- proveedor o interno). Cada producto recibe ademas un QR estable BOMAN:P:id.
-- Las escrituras son solo por RPC administrativa; el escaneo respeta los
-- almacenes visibles del usuario.
-- Ejecutar una sola vez DESPUES de v90.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.productos') is null
     or to_regprocedure('public.usuario_puede_almacen(uuid,boolean)') is null then
    raise exception 'Falta la base de inventario requerida para v91';
  end if;
end $$;

create or replace function public.validar_gtin_v91(p_codigo text, p_longitud integer)
returns boolean
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  v_suma integer := 0;
  v_indice integer;
  v_peso integer;
begin
  if p_codigo !~ ('^[0-9]{' || p_longitud::text || '}$') then return false; end if;
  for v_indice in 1..p_longitud - 1 loop
    v_peso := case when mod((p_longitud - 1) - v_indice, 2) = 0 then 3 else 1 end;
    v_suma := v_suma + substring(p_codigo from v_indice for 1)::integer * v_peso;
  end loop;
  return mod(10 - mod(v_suma, 10), 10) = right(p_codigo, 1)::integer;
end;
$fn$;

create table if not exists public.producto_codigos_v91 (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references public.productos(id) on delete restrict,
  codigo text not null check (btrim(codigo) <> '' and length(btrim(codigo)) <= 120),
  codigo_normalizado text generated always as (
    upper(regexp_replace(btrim(codigo), '[[:space:]]+', '', 'g'))
  ) stored,
  tipo text not null check (tipo in ('ean13', 'upca', 'code128', 'qr', 'proveedor', 'interno')),
  descripcion text,
  principal boolean not null default false,
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id) on delete set null,
  actualizado_por uuid references public.perfiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (tipo <> 'ean13' or public.validar_gtin_v91(codigo, 13)),
  check (tipo <> 'upca' or public.validar_gtin_v91(codigo, 12))
);

create unique index if not exists uq_producto_codigo_activo_v91
  on public.producto_codigos_v91(codigo_normalizado) where activo;
create unique index if not exists uq_producto_codigo_principal_v91
  on public.producto_codigos_v91(producto_id) where activo and principal;
create index if not exists idx_producto_codigos_producto_v91
  on public.producto_codigos_v91(producto_id, activo, principal desc);

create table if not exists public.producto_codigo_eventos_v91 (
  id uuid primary key default gen_random_uuid(),
  producto_codigo_id uuid not null references public.producto_codigos_v91(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  tipo text not null check (tipo in ('creado', 'actualizado', 'archivado')),
  valores_anteriores jsonb,
  valores_nuevos jsonb,
  motivo text not null check (btrim(motivo) <> ''),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_producto_codigo_eventos_v91
  on public.producto_codigo_eventos_v91(producto_id, created_at desc);

create or replace function public.sembrar_qr_producto_v91()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  insert into public.producto_codigos_v91(
    producto_id, codigo, tipo, descripcion, principal
  ) values (
    new.id, 'BOMAN:P:' || new.id::text, 'qr', 'QR interno permanente', true
  ) on conflict do nothing;
  return new;
end;
$fn$;

drop trigger if exists trg_sembrar_qr_producto_v91 on public.productos;
create trigger trg_sembrar_qr_producto_v91
after insert on public.productos
for each row execute function public.sembrar_qr_producto_v91();

insert into public.producto_codigos_v91(producto_id, codigo, tipo, descripcion, principal)
select p.id, 'BOMAN:P:' || p.id::text, 'qr', 'QR interno permanente',
  not exists (
    select 1 from public.producto_codigos_v91 principal
    where principal.producto_id = p.id and principal.activo and principal.principal
  )
from public.productos p
where not exists (
  select 1 from public.producto_codigos_v91 c
  where c.producto_id = p.id and c.activo and c.tipo = 'qr'
    and c.codigo = 'BOMAN:P:' || p.id::text
)
on conflict do nothing;

create or replace function public.validar_sku_sin_codigo_v91()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if exists (
    select 1 from public.producto_codigos_v91 c
    where c.activo
      and c.codigo_normalizado = upper(regexp_replace(btrim(new.sku), '[[:space:]]+', '', 'g'))
      and c.producto_id <> new.id
  ) then
    raise exception 'El SKU ya esta registrado como codigo alterno de otro producto';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_validar_sku_sin_codigo_v91 on public.productos;
create trigger trg_validar_sku_sin_codigo_v91
before insert or update of sku on public.productos
for each row execute function public.validar_sku_sin_codigo_v91();

create or replace function public.resolver_codigo_producto_v91(
  p_codigo text
) returns table (
  producto_id uuid,
  sku text,
  producto text,
  talla text,
  color text,
  codigo text,
  tipo_codigo text
)
language sql
stable
security definer
set search_path = ''
as $$
  with entrada as (
    select upper(regexp_replace(btrim(coalesce(p_codigo, '')), '[[:space:]]+', '', 'g')) valor
  ), encontrado as (
    select p.id, p.sku, p.nombre, p.talla, p.color,
      c.codigo, c.tipo, case when c.principal then 0 else 1 end prioridad
    from public.producto_codigos_v91 c
    join public.productos p on p.id = c.producto_id and p.activo
    cross join entrada e
    where c.activo and c.codigo_normalizado = e.valor
    union all
    select p.id, p.sku, p.nombre, p.talla, p.color,
      p.sku, 'sku'::text, 2
    from public.productos p cross join entrada e
    where p.activo
      and upper(regexp_replace(btrim(p.sku), '[[:space:]]+', '', 'g')) = e.valor
  )
  select e.id, e.sku, e.nombre, e.talla, e.color, e.codigo, e.tipo
  from encontrado e
  where auth.uid() is not null
    and public.usuario_tiene_permiso_v35('inventario.acceder')
    and (
      public.rol_usuario_actual() = 'admin'
      or exists (
        select 1 from public.producto_almacen_config pac
        where pac.producto_id = e.id
          and public.usuario_puede_almacen(pac.almacen_id, false)
      )
    )
  order by e.prioridad
  limit 1;
$$;

create or replace function public.guardar_codigo_producto_v91(
  p_producto_id uuid,
  p_codigo_id uuid,
  p_codigo text,
  p_tipo text,
  p_descripcion text,
  p_principal boolean,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_anterior jsonb;
  v_nuevo jsonb;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if not exists (
    select 1 from public.perfiles p
    where p.id = v_uid and p.activo and p.rol::text = 'admin'
  ) then raise exception 'Solo un administrador puede administrar codigos'; end if;
  select e.producto_codigo_id into v_id from public.producto_codigo_eventos_v91 e
  where e.idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  if not exists (select 1 from public.productos p where p.id = p_producto_id) then
    raise exception 'Producto no encontrado';
  end if;
  if length(btrim(coalesce(p_codigo, ''))) < 3 then raise exception 'El codigo debe tener al menos 3 caracteres'; end if;
  if coalesce(p_tipo, '') not in ('ean13', 'upca', 'code128', 'qr', 'proveedor', 'interno') then
    raise exception 'Tipo de codigo invalido';
  end if;
  if p_tipo = 'ean13' and not public.validar_gtin_v91(btrim(p_codigo), 13) then
    raise exception 'EAN-13 invalido: revisa los 13 digitos y el digito verificador';
  end if;
  if p_tipo = 'upca' and not public.validar_gtin_v91(btrim(p_codigo), 12) then
    raise exception 'UPC-A invalido: revisa los 12 digitos y el digito verificador';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Indica un motivo de al menos 5 caracteres'; end if;
  if exists (
    select 1 from public.productos p
    where upper(regexp_replace(btrim(p.sku), '[[:space:]]+', '', 'g')) =
      upper(regexp_replace(btrim(p_codigo), '[[:space:]]+', '', 'g'))
  ) then raise exception 'Ese codigo ya existe como SKU de producto'; end if;

  -- Libera primero la portada logica para no chocar con el indice unico.
  if coalesce(p_principal, false) then
    update public.producto_codigos_v91 set principal = false,
      actualizado_por = v_uid, updated_at = now()
    where producto_id = p_producto_id and activo and principal
      and (p_codigo_id is null or id <> p_codigo_id);
  end if;

  if p_codigo_id is null then
    insert into public.producto_codigos_v91(
      producto_id, codigo, tipo, descripcion, principal, creado_por, actualizado_por
    ) values (
      p_producto_id, btrim(p_codigo), p_tipo, nullif(btrim(coalesce(p_descripcion, '')), ''),
      coalesce(p_principal, false), v_uid, v_uid
    ) returning id into v_id;
    select to_jsonb(c) into v_nuevo from public.producto_codigos_v91 c where c.id = v_id;
    insert into public.producto_codigo_eventos_v91(
      producto_codigo_id, producto_id, tipo, valores_nuevos, motivo, usuario_id, idempotency_key
    ) values (v_id, p_producto_id, 'creado', v_nuevo, btrim(p_motivo), v_uid, p_idempotency_key);
  else
    select to_jsonb(c) into v_anterior from public.producto_codigos_v91 c
    where c.id = p_codigo_id and c.producto_id = p_producto_id and c.activo for update;
    if v_anterior is null then raise exception 'Codigo no encontrado'; end if;
    update public.producto_codigos_v91 set
      codigo = btrim(p_codigo), tipo = p_tipo,
      descripcion = nullif(btrim(coalesce(p_descripcion, '')), ''),
      principal = coalesce(p_principal, false), actualizado_por = v_uid, updated_at = now()
    where id = p_codigo_id returning id into v_id;
    select to_jsonb(c) into v_nuevo from public.producto_codigos_v91 c where c.id = v_id;
    insert into public.producto_codigo_eventos_v91(
      producto_codigo_id, producto_id, tipo, valores_anteriores, valores_nuevos, motivo, usuario_id, idempotency_key
    ) values (v_id, p_producto_id, 'actualizado', v_anterior, v_nuevo, btrim(p_motivo), v_uid, p_idempotency_key);
  end if;

  return v_id;
exception when unique_violation then
  raise exception 'Ese codigo ya esta asignado a otro producto o ya existe una etiqueta principal';
end;
$fn$;

create or replace function public.archivar_codigo_producto_v91(
  p_codigo_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_codigo public.producto_codigos_v91%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if not exists (
    select 1 from public.perfiles p
    where p.id = v_uid and p.activo and p.rol::text = 'admin'
  ) then raise exception 'Solo un administrador puede administrar codigos'; end if;
  if exists (
    select 1 from public.producto_codigo_eventos_v91 e
    where e.idempotency_key = p_idempotency_key
  ) then return; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Indica un motivo de al menos 5 caracteres'; end if;
  select * into v_codigo from public.producto_codigos_v91 where id = p_codigo_id and activo for update;
  if not found then raise exception 'Codigo no encontrado'; end if;
  if v_codigo.tipo = 'qr' and v_codigo.codigo = 'BOMAN:P:' || v_codigo.producto_id::text then
    raise exception 'El QR interno permanente no se puede retirar';
  end if;
  update public.producto_codigos_v91 set activo = false, principal = false,
    actualizado_por = v_uid, updated_at = now() where id = v_codigo.id;
  insert into public.producto_codigo_eventos_v91(
    producto_codigo_id, producto_id, tipo, valores_anteriores, motivo, usuario_id, idempotency_key
  ) values (
    v_codigo.id, v_codigo.producto_id, 'archivado', to_jsonb(v_codigo), btrim(p_motivo), v_uid, p_idempotency_key
  );
end;
$fn$;

create or replace view public.vista_codigos_productos_v91
with (security_invoker = true) as
select c.id, c.producto_id, p.sku, p.nombre as producto, p.talla, p.color,
  c.codigo, c.codigo_normalizado, c.tipo, c.descripcion, c.principal,
  c.created_at, c.updated_at
from public.producto_codigos_v91 c
join public.productos p on p.id = c.producto_id
where c.activo;

alter table public.producto_codigos_v91 enable row level security;
alter table public.producto_codigo_eventos_v91 enable row level security;
drop policy if exists "leer_producto_codigos_v91" on public.producto_codigos_v91;
create policy "leer_producto_codigos_v91" on public.producto_codigos_v91
for select to authenticated using (
  public.usuario_tiene_permiso_v35('inventario.acceder')
  and (
    public.rol_usuario_actual() = 'admin'
    or exists (
      select 1 from public.producto_almacen_config pac
      where pac.producto_id = producto_codigos_v91.producto_id
        and public.usuario_puede_almacen(pac.almacen_id, false)
    )
  )
);
drop policy if exists "leer_producto_codigo_eventos_v91" on public.producto_codigo_eventos_v91;
create policy "leer_producto_codigo_eventos_v91" on public.producto_codigo_eventos_v91
for select to authenticated using (public.rol_usuario_actual() = 'admin');

alter function public.validar_gtin_v91(text, integer) owner to postgres;
alter function public.sembrar_qr_producto_v91() owner to postgres;
alter function public.validar_sku_sin_codigo_v91() owner to postgres;
alter function public.resolver_codigo_producto_v91(text) owner to postgres;
alter function public.guardar_codigo_producto_v91(uuid, uuid, text, text, text, boolean, text, uuid) owner to postgres;
alter function public.archivar_codigo_producto_v91(uuid, text, uuid) owner to postgres;
alter view public.vista_codigos_productos_v91 owner to postgres;

revoke all on public.producto_codigos_v91, public.producto_codigo_eventos_v91,
  public.vista_codigos_productos_v91 from public, anon;
revoke insert, update, delete on public.producto_codigos_v91,
  public.producto_codigo_eventos_v91 from authenticated;
grant select on public.producto_codigos_v91, public.vista_codigos_productos_v91 to authenticated;
grant select on public.producto_codigo_eventos_v91 to authenticated;

revoke all on function public.validar_gtin_v91(text, integer) from public, anon, authenticated;
revoke all on function public.sembrar_qr_producto_v91() from public, anon, authenticated;
revoke all on function public.validar_sku_sin_codigo_v91() from public, anon, authenticated;
revoke all on function public.resolver_codigo_producto_v91(text) from public, anon;
revoke all on function public.guardar_codigo_producto_v91(uuid, uuid, text, text, text, boolean, text, uuid) from public, anon;
revoke all on function public.archivar_codigo_producto_v91(uuid, text, uuid) from public, anon;
grant execute on function public.resolver_codigo_producto_v91(text) to authenticated;
grant execute on function public.guardar_codigo_producto_v91(uuid, uuid, text, text, text, boolean, text, uuid) to authenticated;
grant execute on function public.archivar_codigo_producto_v91(uuid, text, uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
