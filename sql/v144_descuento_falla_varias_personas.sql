-- ============================================================
-- v144 - Una falla de calidad puede involucrar a varias personas
--
-- El monto indicado en Calidad es el total de la solicitud. Se reparte en
-- centavos entre los responsables y cada persona recibe su propio expediente
-- laboral. Los campos singulares de v74 se conservan como compatibilidad y
-- apuntan al primer responsable de la lista.
-- ============================================================

begin;

create table if not exists public.novedad_calidad_responsables_v144 (
  id uuid primary key default gen_random_uuid(),
  novedad_id uuid not null
    references public.novedades_calidad_produccion(id) on delete restrict,
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  orden integer not null check (orden > 0),
  monto_solicitado numeric(14,2) not null check (monto_solicitado > 0),
  novedad_empleado_id uuid unique
    references public.novedades_empleado(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (novedad_id, empleado_id),
  unique (novedad_id, orden)
);

comment on table public.novedad_calidad_responsables_v144 is
  'Responsables y reparto del descuento solicitado por una falla de calidad.';

insert into public.novedad_calidad_responsables_v144 (
  novedad_id, empleado_id, orden, monto_solicitado, novedad_empleado_id
)
select n.id, n.empleado_responsable_id, 1, n.monto_descuento_solicitado,
       n.novedad_empleado_id
from public.novedades_calidad_produccion n
where n.solicita_descuento
  and n.empleado_responsable_id is not null
  and n.monto_descuento_solicitado > 0
on conflict (novedad_id, empleado_id) do update set
  monto_solicitado = excluded.monto_solicitado,
  novedad_empleado_id = coalesce(
    public.novedad_calidad_responsables_v144.novedad_empleado_id,
    excluded.novedad_empleado_id
  ),
  updated_at = now();

create index if not exists novedad_calidad_responsables_v144_novedad_idx
  on public.novedad_calidad_responsables_v144(novedad_id, orden);
create index if not exists novedad_calidad_responsables_v144_empleado_idx
  on public.novedad_calidad_responsables_v144(empleado_id);

create or replace function public.validar_responsables_calidad_v144(
  p_grupo_id uuid,
  p_datos jsonb
) returns uuid[]
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_ids uuid[];
  v_total integer;
begin
  if coalesce((p_datos->>'solicita_descuento')::boolean, false) = false then
    return array[]::uuid[];
  end if;
  if jsonb_typeof(p_datos->'empleados_responsables_ids') = 'array' then
    begin
      select coalesce(array_agg(x.valor::uuid order by x.orden), array[]::uuid[]),
             count(*)
      into v_ids, v_total
      from jsonb_array_elements_text(p_datos->'empleados_responsables_ids')
        with ordinality as x(valor, orden);
    exception when invalid_text_representation then
      raise exception 'La lista de empleados contiene un identificador invalido';
    end;
  else
    v_ids := case
      when nullif(p_datos->>'empleado_responsable_id', '') is null
        then array[]::uuid[]
      else array[(p_datos->>'empleado_responsable_id')::uuid]
    end;
    v_total := cardinality(v_ids);
  end if;
  if coalesce(v_total, 0) = 0 then
    raise exception 'Selecciona al menos una persona para la solicitud de descuento';
  end if;
  if (select count(distinct id) from unnest(v_ids) id) <> v_total then
    raise exception 'No se puede seleccionar dos veces a la misma persona';
  end if;
  if exists (
    select 1 from unnest(v_ids) id
    left join public.empleados e on e.id = id
    where e.id is null or e.grupo_id <> p_grupo_id
      or e.estado <> 'activo' or e.fecha_salida is not null
  ) then
    raise exception 'Una de las personas seleccionadas no pertenece al grupo o no esta activa';
  end if;
  return v_ids;
end;
$fn$;

create or replace function public.guardar_responsables_calidad_v144(
  p_novedad_id uuid,
  p_empleados uuid[],
  p_monto_total numeric
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_total_centavos bigint := round(p_monto_total * 100)::bigint;
  v_cantidad integer := cardinality(p_empleados);
begin
  if v_cantidad = 0 or v_total_centavos < v_cantidad then
    raise exception 'El total debe permitir asignar al menos 0,01 USD a cada persona';
  end if;
  delete from public.novedad_calidad_responsables_v144
  where novedad_id = p_novedad_id;
  insert into public.novedad_calidad_responsables_v144 (
    novedad_id, empleado_id, orden, monto_solicitado
  )
  select p_novedad_id, x.empleado_id, x.orden::integer,
    ((v_total_centavos / v_cantidad)
      + case when x.orden <= (v_total_centavos % v_cantidad) then 1 else 0 end
    )::numeric / 100
  from unnest(p_empleados) with ordinality x(empleado_id, orden);
end;
$fn$;

create or replace function public.registrar_novedad_calidad_v144(
  p_datos jsonb,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_grupo_id uuid;
  v_ids uuid[];
  v_id uuid;
  v_solicita boolean := coalesce((p_datos->>'solicita_descuento')::boolean, false);
  v_monto numeric := nullif(p_datos->>'monto_descuento_solicitado', '')::numeric;
  v_datos jsonb;
begin
  select e.grupo_id into v_grupo_id
  from public.empresas e
  where e.id = nullif(p_datos->>'empresa_id', '')::uuid and e.activo;
  if not found then raise exception 'La empresa seleccionada no existe o esta inactiva'; end if;
  v_ids := public.validar_responsables_calidad_v144(v_grupo_id, p_datos);
  if v_solicita and coalesce(v_monto, 0) <= 0 then
    raise exception 'El monto total solicitado debe ser mayor que cero';
  end if;
  v_datos := jsonb_set(
    p_datos,
    '{empleado_responsable_id}',
    case when v_solicita then to_jsonb(v_ids[1]::text) else 'null'::jsonb end,
    true
  );
  v_id := public.registrar_novedad_calidad_v74(v_datos, p_idempotency_key);
  if v_solicita and not exists (
    select 1 from public.novedad_calidad_responsables_v144 r where r.novedad_id = v_id
  ) then
    perform public.guardar_responsables_calidad_v144(v_id, v_ids, v_monto);
  end if;
  return v_id;
end;
$fn$;

create or replace function public.resolver_novedad_calidad_v144(
  p_novedad_id uuid,
  p_datos jsonb,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  n public.novedades_calidad_produccion%rowtype;
  v_ids uuid[];
  v_solicita boolean := coalesce((p_datos->>'solicita_descuento')::boolean, false);
  v_monto numeric := nullif(p_datos->>'monto_descuento_solicitado', '')::numeric;
  v_datos jsonb;
begin
  select * into n from public.novedades_calidad_produccion
  where id = p_novedad_id for update;
  if not found then raise exception 'La novedad de calidad no existe'; end if;
  v_ids := public.validar_responsables_calidad_v144(n.grupo_id, p_datos);
  if exists (
    select 1 from public.novedad_calidad_responsables_v144 r
    where r.novedad_id = n.id and r.novedad_empleado_id is not null
  ) then
    if not v_solicita
      or round(coalesce(v_monto, 0), 2) <> round(coalesce(n.monto_descuento_solicitado, 0), 2)
      or v_ids <> array(
        select r.empleado_id from public.novedad_calidad_responsables_v144 r
        where r.novedad_id = n.id order by r.orden
      )
    then raise exception 'Los expedientes laborales ya fueron generados y la solicitud no puede alterarse'; end if;
  end if;
  v_datos := jsonb_set(
    p_datos,
    '{empleado_responsable_id}',
    case when v_solicita then to_jsonb(v_ids[1]::text) else 'null'::jsonb end,
    true
  );
  perform public.resolver_novedad_calidad_v74(p_novedad_id, v_datos, p_idempotency_key);
  if not exists (
    select 1 from public.novedad_calidad_responsables_v144 r
    where r.novedad_id = n.id and r.novedad_empleado_id is not null
  ) then
    if v_solicita then
      perform public.guardar_responsables_calidad_v144(n.id, v_ids, v_monto);
    else
      delete from public.novedad_calidad_responsables_v144 where novedad_id = n.id;
    end if;
  end if;
end;
$fn$;

create or replace function public.generar_novedades_laborales_calidad_v144(
  p_novedad_id uuid,
  p_empresa_emisora_id uuid,
  p_base_reglamento text,
  p_base_legal text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  n public.novedades_calidad_produccion%rowtype;
  r record;
  v_expediente_id uuid;
  v_primero uuid;
  v_hechos text;
  v_resultado jsonb := '[]'::jsonb;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into n from public.novedades_calidad_produccion
  where id = p_novedad_id for update;
  if not found then raise exception 'La novedad de calidad no existe'; end if;
  if not public.usuario_puede_calidad_v74(n.grupo_id, 'descuento') then
    raise exception 'Solo Administracion o Nomina pueden iniciar el tramite de descuento';
  end if;
  if n.estado <> 'cerrada' then
    raise exception 'Cierra primero el analisis de calidad antes de derivarlo a Nomina';
  end if;
  if not n.solicita_descuento or coalesce(n.monto_descuento_solicitado, 0) <= 0 then
    raise exception 'La novedad no contiene una solicitud de descuento completa';
  end if;
  if length(btrim(coalesce(p_base_reglamento, ''))) < 5 then
    raise exception 'Indica la disposicion del reglamento interno aplicable';
  end if;
  if exists (
    select 1 from public.novedad_calidad_eventos e
    where e.novedad_id = n.id and e.idempotency_key = p_idempotency_key
  ) then
    return jsonb_build_object(
      'novedad_id', n.id,
      'expedientes', (select coalesce(jsonb_agg(jsonb_build_object(
        'empleado_id', x.empleado_id, 'novedad_empleado_id', x.novedad_empleado_id,
        'monto', x.monto_solicitado) order by x.orden), '[]'::jsonb)
        from public.novedad_calidad_responsables_v144 x where x.novedad_id = n.id)
    );
  end if;
  if exists (
    select 1 from public.novedad_calidad_responsables_v144 x
    where x.novedad_id = n.id and x.novedad_empleado_id is not null
  ) then raise exception 'Los expedientes de esta falla ya fueron generados'; end if;
  if not exists (
    select 1 from public.novedad_calidad_responsables_v144 x where x.novedad_id = n.id
  ) then raise exception 'La falla no tiene personas responsables registradas'; end if;

  v_hechos := concat_ws(E'\n',
    'Referencia de calidad: ' || n.codigo,
    'Descripcion: ' || n.descripcion,
    'Causa raiz: ' || n.causa_raiz,
    'Accion correctiva: ' || n.accion_correctiva,
    'Justificacion solicitada: ' || n.motivo_descuento
  );
  for r in
    select * from public.novedad_calidad_responsables_v144
    where novedad_id = n.id order by orden for update
  loop
    v_expediente_id := public.guardar_novedad_v28(
      null, r.empleado_id, p_empresa_emisora_id,
      'sancion_economica', (n.fecha_hora at time zone 'America/Guayaquil')::date,
      'Novedad de calidad ' || n.codigo, v_hechos,
      btrim(p_base_reglamento), nullif(btrim(p_base_legal), ''),
      true, r.monto_solicitado, gen_random_uuid()
    );
    update public.novedad_calidad_responsables_v144 set
      novedad_empleado_id = v_expediente_id, updated_at = now()
    where id = r.id;
    v_primero := coalesce(v_primero, v_expediente_id);
    v_resultado := v_resultado || jsonb_build_array(jsonb_build_object(
      'empleado_id', r.empleado_id,
      'novedad_empleado_id', v_expediente_id,
      'monto', r.monto_solicitado
    ));
  end loop;
  update public.novedades_calidad_produccion set
    novedad_empleado_id = v_primero,
    actualizado_por = auth.uid(), updated_at = now()
  where id = n.id;
  update public.notificaciones_comunicados set activo = false, updated_at = now()
  where origen_clave = 'calidad:descuento:' || n.id::text;
  insert into public.novedad_calidad_eventos (
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle,
    datos, usuario_id, idempotency_key
  ) values (
    n.id, 'derivada_nomina', n.estado, n.estado,
    cardinality(array(select x.empleado_id from public.novedad_calidad_responsables_v144 x
      where x.novedad_id = n.id))::text || ' expedientes laborales generados',
    jsonb_build_object('expedientes', v_resultado,
      'monto_total', n.monto_descuento_solicitado),
    auth.uid(), p_idempotency_key
  );
  return jsonb_build_object('novedad_id', n.id, 'expedientes', v_resultado);
end;
$fn$;

alter table public.novedad_calidad_responsables_v144 enable row level security;
drop policy if exists "leer_responsables_calidad_v144"
  on public.novedad_calidad_responsables_v144;
create policy "leer_responsables_calidad_v144"
on public.novedad_calidad_responsables_v144
for select to authenticated using (
  exists (
    select 1 from public.novedades_calidad_produccion n
    where n.id = novedad_id and public.usuario_puede_calidad_v74(n.grupo_id, 'ver')
  )
);

revoke all on public.novedad_calidad_responsables_v144 from public, anon;
revoke insert, update, delete on public.novedad_calidad_responsables_v144 from authenticated;
grant select on public.novedad_calidad_responsables_v144 to authenticated;

alter function public.validar_responsables_calidad_v144(uuid,jsonb) owner to postgres;
alter function public.guardar_responsables_calidad_v144(uuid,uuid[],numeric) owner to postgres;
alter function public.registrar_novedad_calidad_v144(jsonb,uuid) owner to postgres;
alter function public.resolver_novedad_calidad_v144(uuid,jsonb,uuid) owner to postgres;
alter function public.generar_novedades_laborales_calidad_v144(uuid,uuid,text,text,uuid) owner to postgres;

revoke all on function public.validar_responsables_calidad_v144(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.guardar_responsables_calidad_v144(uuid,uuid[],numeric) from public, anon, authenticated;
revoke all on function public.registrar_novedad_calidad_v144(jsonb,uuid) from public, anon;
revoke all on function public.resolver_novedad_calidad_v144(uuid,jsonb,uuid) from public, anon;
revoke all on function public.generar_novedades_laborales_calidad_v144(uuid,uuid,text,text,uuid) from public, anon;
grant execute on function public.registrar_novedad_calidad_v144(jsonb,uuid) to authenticated;
grant execute on function public.resolver_novedad_calidad_v144(uuid,jsonb,uuid) to authenticated;
grant execute on function public.generar_novedades_laborales_calidad_v144(uuid,uuid,text,text,uuid) to authenticated;

-- Evita que una pantalla antigua omita la tabla de responsables múltiples.
revoke execute on function public.registrar_novedad_calidad_v74(jsonb,uuid) from authenticated;
revoke execute on function public.resolver_novedad_calidad_v74(uuid,jsonb,uuid) from authenticated;
revoke execute on function public.generar_novedad_laboral_calidad_v74(uuid,uuid,text,text,uuid) from authenticated;

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v144','144','v144_descuento_falla_varias_personas.sql',
  'Varias personas por falla, reparto exacto y un expediente laboral por responsable')
on conflict(id) do update set version=excluded.version,archivo=excluded.archivo,
  notas=excluded.notas,aplicada_at=now();

notify pgrst, 'reload schema';
commit;
