-- ============================================================
-- BOMAN INVENTARIO - v97: Expediente y brief de contratos
-- Ejecutar despues de v96.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.contrato_prendas') is null
     or to_regclass('public.contrato_jugadores') is null
     or to_regclass('public.contrato_archivos') is null
     or to_regclass('public.contrato_specs') is null
     or to_regclass('public.contrato_facturacion') is null
     or to_regclass('public.contrato_etapas') is null
     or to_regclass('public.contrato_eventos') is null then
    raise exception 'Falta instalar v79 antes de v97';
  end if;
  if to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta instalar v35 antes de v97';
  end if;
  if to_regprocedure('extensions.digest(text,text)') is null
     or to_regprocedure('extensions.gen_random_bytes(integer)') is null then
    raise exception 'La extension pgcrypto no esta disponible en el esquema extensions';
  end if;
end;
$requisitos$;

create table if not exists public.contrato_enlaces_compartidos_v97 (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  vence_en timestamptz not null,
  revocado_en timestamptz,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (vence_en > created_at)
);

create index if not exists idx_contrato_enlaces_v97_contrato
  on public.contrato_enlaces_compartidos_v97(contrato_id, created_at desc);
create index if not exists idx_contrato_enlaces_v97_vigentes
  on public.contrato_enlaces_compartidos_v97(vence_en)
  where revocado_en is null;

alter table public.contrato_enlaces_compartidos_v97 enable row level security;
revoke all on public.contrato_enlaces_compartidos_v97 from public, anon, authenticated;

create or replace function public.listar_contratos_v97(
  p_busqueda text default null,
  p_estado text default null,
  p_pagina integer default 1,
  p_por_pagina integer default 40
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_pagina integer := greatest(coalesce(p_pagina, 1), 1);
  v_por_pagina integer := least(greatest(coalesce(p_por_pagina, 40), 1), 100);
  v_resultado jsonb;
begin
  if auth.uid() is null
     or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar contratos';
  end if;

  with filtrados as materialized (
    select c.*
    from public.contratos c
    where (nullif(btrim(p_busqueda), '') is null
      or c.numero ilike '%' || btrim(p_busqueda) || '%'
      or c.cliente ilike '%' || btrim(p_busqueda) || '%'
      or c.vendedor ilike '%' || btrim(p_busqueda) || '%'
      or coalesce(c.disenador, '') ilike '%' || btrim(p_busqueda) || '%')
      and (nullif(btrim(p_estado), '') is null
        or lower(c.estado) = lower(btrim(p_estado)))
  ),
  pagina as (
    select f.*,
      (select ca.drive_id from public.contrato_archivos ca
       where ca.contrato_id = f.id and ca.tipo = 'mockup'
         and nullif(btrim(ca.drive_id), '') is not null
       order by ca.orden, ca.id limit 1) as mockup_drive_id
    from filtrados f
    order by f.fecha_entrega desc nulls last, f.numero desc
    limit v_por_pagina offset (v_pagina - 1) * v_por_pagina
  )
  select jsonb_build_object(
    'total', (select count(*) from filtrados),
    'pagina', v_pagina,
    'por_pagina', v_por_pagina,
    'estados', coalesce((select jsonb_agg(e order by e) from (
      select distinct estado as e from public.contratos where btrim(estado) <> ''
    ) q), '[]'::jsonb),
    'filas', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'numero', numero, 'cliente', cliente, 'vendedor', vendedor,
      'disenador', disenador, 'estado', estado, 'prioridad', prioridad,
      'fecha_ingreso', fecha_ingreso, 'fecha_inicio', fecha_inicio_produccion,
      'fecha_entrega', fecha_entrega, 'total_prendas', total_prendas,
      'presupuesto', presupuesto, 'abono', abono,
      'saldo', greatest(presupuesto - abono, 0),
      'mockup_drive_id', mockup_drive_id, 'updated_at', updated_at
    ) order by fecha_entrega desc nulls last, numero desc) from pagina), '[]'::jsonb)
  ) into v_resultado;
  return v_resultado;
end;
$fn$;

create or replace function public.obtener_expediente_contrato_v97(p_contrato_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_resultado jsonb;
begin
  if auth.uid() is null
     or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para consultar contratos';
  end if;
  if not exists (select 1 from public.contratos where id = p_contrato_id) then
    raise exception 'El contrato no existe';
  end if;

  select jsonb_build_object(
    'contrato', to_jsonb(c),
    'prendas', coalesce((select jsonb_agg(to_jsonb(x) order by x.prenda, x.calidad, x.genero, x.talla)
      from public.contrato_prendas x where x.contrato_id = c.id), '[]'::jsonb),
    'jugadores', coalesce((select jsonb_agg(to_jsonb(x) order by x.orden, x.id)
      from public.contrato_jugadores x where x.contrato_id = c.id), '[]'::jsonb),
    'archivos', coalesce((select jsonb_agg(to_jsonb(x) order by x.tipo, x.orden, x.id)
      from public.contrato_archivos x where x.contrato_id = c.id), '[]'::jsonb),
    'especificaciones', coalesce((select jsonb_agg(to_jsonb(x) order by x.orden, x.id)
      from public.contrato_specs x where x.contrato_id = c.id), '[]'::jsonb),
    'facturacion', coalesce((select jsonb_agg(to_jsonb(x) order by x.orden, x.id)
      from public.contrato_facturacion x where x.contrato_id = c.id), '[]'::jsonb),
    'etapas', coalesce((select jsonb_agg(to_jsonb(x) order by x.marcado_en desc, x.id)
      from public.contrato_etapas x where x.contrato_id = c.id), '[]'::jsonb),
    'eventos', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc, x.id)
      from public.contrato_eventos x where x.contrato_id = c.id), '[]'::jsonb),
    'enlaces', coalesce((select jsonb_agg(jsonb_build_object(
        'id', x.id, 'vence_en', x.vence_en, 'revocado_en', x.revocado_en,
        'created_at', x.created_at,
        'vigente', x.revocado_en is null and x.vence_en > now()
      ) order by x.created_at desc)
      from public.contrato_enlaces_compartidos_v97 x where x.contrato_id = c.id), '[]'::jsonb)
  ) into v_resultado
  from public.contratos c where c.id = p_contrato_id;
  return v_resultado;
end;
$fn$;

create or replace function public.crear_enlace_brief_v97(
  p_contrato_id uuid,
  p_dias_vigencia integer default 7
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  v_token text;
  v_id uuid;
  v_vence timestamptz;
begin
  if auth.uid() is null
     or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para compartir contratos';
  end if;
  if not exists (select 1 from public.contratos where id = p_contrato_id) then
    raise exception 'El contrato no existe';
  end if;
  if coalesce(p_dias_vigencia, 0) < 1 or p_dias_vigencia > 30 then
    raise exception 'La vigencia debe estar entre 1 y 30 dias';
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_vence := now() + make_interval(days => p_dias_vigencia);
  insert into public.contrato_enlaces_compartidos_v97(
    contrato_id, token_hash, vence_en, creado_por
  ) values (
    p_contrato_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), v_vence, auth.uid()
  ) returning id into v_id;

  insert into public.contrato_eventos(contrato_id, campo, valor_nuevo, quien, perfil_id)
  select p_contrato_id, 'brief_compartido', v_vence::text,
         coalesce(p.nombre_completo, auth.uid()::text), auth.uid()
  from public.perfiles p where p.id = auth.uid();

  return jsonb_build_object('id', v_id, 'token', v_token, 'vence_en', v_vence);
end;
$fn$;

create or replace function public.revocar_enlace_brief_v97(p_enlace_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  v_contrato uuid;
begin
  if auth.uid() is null
     or not public.usuario_tiene_permiso_v35('produccion.acceder') then
    raise exception 'No tienes permiso para revocar enlaces';
  end if;
  update public.contrato_enlaces_compartidos_v97
  set revocado_en = now()
  where id = p_enlace_id and revocado_en is null
  returning contrato_id into v_contrato;
  if v_contrato is null then raise exception 'El enlace no existe o ya fue revocado'; end if;

  insert into public.contrato_eventos(contrato_id, campo, valor_nuevo, quien, perfil_id)
  select v_contrato, 'brief_revocado', p_enlace_id::text,
         coalesce(p.nombre_completo, auth.uid()::text), auth.uid()
  from public.perfiles p where p.id = auth.uid();
end;
$fn$;

create or replace function public.obtener_brief_publico_v97(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_contrato_id uuid;
  v_resultado jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'El enlace no es valido';
  end if;
  select e.contrato_id into v_contrato_id
  from public.contrato_enlaces_compartidos_v97 e
  where e.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and e.revocado_en is null and e.vence_en > now();
  if v_contrato_id is null then
    raise exception 'El enlace vencio, fue revocado o no existe';
  end if;

  select jsonb_build_object(
    'contrato', jsonb_build_object(
      'numero', c.numero, 'cliente', c.cliente, 'estado', c.estado,
      'prioridad', c.prioridad, 'fecha_entrega', c.fecha_entrega,
      'total_prendas', c.total_prendas, 'prendas_txt', c.prendas_txt,
      'estado_mockup', c.estado_mockup, 'colores_generales', c.colores_generales,
      'adicionales', c.adicionales, 'forma_entrega', c.forma_entrega,
      'instrucciones', c.instrucciones, 'autorizacion_produccion', c.autorizacion_produccion
    ),
    'prendas', coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id'
      order by x.prenda, x.calidad, x.genero, x.talla)
      from public.contrato_prendas x where x.contrato_id = c.id), '[]'::jsonb),
    'jugadores', coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id'
      order by x.orden, x.id)
      from public.contrato_jugadores x where x.contrato_id = c.id), '[]'::jsonb),
    'archivos', coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id'
      order by x.tipo, x.orden, x.id)
      from public.contrato_archivos x where x.contrato_id = c.id), '[]'::jsonb),
    'especificaciones', coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id'
      order by x.orden, x.id)
      from public.contrato_specs x where x.contrato_id = c.id), '[]'::jsonb),
    'generado_at', now()
  ) into v_resultado
  from public.contratos c where c.id = v_contrato_id;
  return v_resultado;
end;
$fn$;

alter table public.contrato_enlaces_compartidos_v97 owner to postgres;
alter function public.listar_contratos_v97(text,text,integer,integer) owner to postgres;
alter function public.obtener_expediente_contrato_v97(uuid) owner to postgres;
alter function public.crear_enlace_brief_v97(uuid,integer) owner to postgres;
alter function public.revocar_enlace_brief_v97(uuid) owner to postgres;
alter function public.obtener_brief_publico_v97(text) owner to postgres;

revoke all on function public.listar_contratos_v97(text,text,integer,integer) from public, anon;
revoke all on function public.obtener_expediente_contrato_v97(uuid) from public, anon;
revoke all on function public.crear_enlace_brief_v97(uuid,integer) from public, anon;
revoke all on function public.revocar_enlace_brief_v97(uuid) from public, anon;
revoke all on function public.obtener_brief_publico_v97(text) from public;
grant execute on function public.listar_contratos_v97(text,text,integer,integer) to authenticated;
grant execute on function public.obtener_expediente_contrato_v97(uuid) to authenticated;
grant execute on function public.crear_enlace_brief_v97(uuid,integer) to authenticated;
grant execute on function public.revocar_enlace_brief_v97(uuid) to authenticated;
grant execute on function public.obtener_brief_publico_v97(text) to anon, authenticated;

comment on table public.contrato_enlaces_compartidos_v97 is
  'Enlaces temporales de brief. Solo se guarda SHA-256; el token original se entrega una vez.';

commit;
notify pgrst, 'reload schema';
