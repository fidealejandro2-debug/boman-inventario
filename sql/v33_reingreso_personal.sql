-- ============================================================
-- BOMAN INVENTARIO - Reingreso de personal v33
-- Hay gente que sale y vuelve. Separa dos cosas que hasta ahora vivian en
-- un solo campo: cuando empezo ESTE vinculo laboral y desde que fecha
-- cuenta la antiguedad. La persona sigue siendo la misma fila en empleados,
-- asi su expediente, su historial disciplinario y el de sueldos no se
-- parten nunca.
-- Ejecutar una sola vez DESPUES de v32.
--
-- Reglas que implementa:
--   fecha_ingreso_real  = inicio del vinculo VIGENTE. La usa v30 para
--                         prorratear el mes, asi nadie cobra dias en los que
--                         no habia relacion laboral.
--   antiguedad_desde    = fecha que manda para vacaciones, decimos y
--                         finiquito. En un reingreso con finiquito pagado
--                         arranca de cero; si se respeta la antiguedad,
--                         conserva la fecha del primer vinculo.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Vinculos laborales
-- ------------------------------------------------------------
create table if not exists public.empleado_vinculos (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  secuencia integer not null check (secuencia > 0),
  tipo_vinculo text not null check (tipo_vinculo in (
    'inicial', 'reingreso_continuidad', 'reingreso_nueva_relacion'
  )),
  fecha_ingreso date not null,
  fecha_salida date,
  antiguedad_desde date not null,
  tipo_salida text check (tipo_salida in (
    'renuncia', 'despido', 'visto_bueno', 'fin_contrato', 'abandono', 'mutuo_acuerdo'
  )),
  motivo_salida text,
  liquidado boolean not null default false,
  documento_finiquito_id uuid references public.empleado_documentos(id) on delete restrict,
  motivo_ingreso text,
  documento_ingreso_id uuid references public.empleado_documentos(id) on delete restrict,
  registrado_por uuid references public.perfiles(id) on delete restrict,
  cerrado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (empleado_id, secuencia),
  check (fecha_salida is null or fecha_salida >= fecha_ingreso),
  -- La antiguedad nunca puede empezar despues de este vinculo.
  check (antiguedad_desde <= fecha_ingreso),
  -- Un vinculo cerrado dice como y por que termino.
  check (
    fecha_salida is null
    or (tipo_salida is not null and btrim(coalesce(motivo_salida, '')) <> '')
  ),
  -- El primer vinculo arranca su propia antiguedad.
  check (tipo_vinculo <> 'inicial' or antiguedad_desde = fecha_ingreso),
  -- Una relacion nueva tambien: si se pago finiquito, se cuenta desde cero.
  check (tipo_vinculo <> 'reingreso_nueva_relacion' or antiguedad_desde = fecha_ingreso),
  -- La continuidad solo tiene sentido conservando una fecha anterior.
  check (tipo_vinculo <> 'reingreso_continuidad' or antiguedad_desde < fecha_ingreso)
);

-- Un solo vinculo abierto por persona.
create unique index if not exists uq_empleado_vinculo_abierto_v33
  on public.empleado_vinculos(empleado_id)
  where fecha_salida is null;

create index if not exists idx_empleado_vinculos_empleado_v33
  on public.empleado_vinculos(empleado_id, secuencia desc);

comment on column public.empleado_vinculos.antiguedad_desde is
  'Fecha que manda para vacaciones, decimos y finiquito. Distinta de fecha_ingreso cuando se respeta la antiguedad de un vinculo anterior.';
comment on column public.empleado_vinculos.liquidado is
  'Si se pago finiquito al cerrar el vinculo. Es lo que decide si la antiguedad se reinicia.';

-- ------------------------------------------------------------
-- 2. Backfill: nadie cambia de saldo al instalar
-- ------------------------------------------------------------
-- Un vinculo inicial por cada empleado ya registrado, con la antiguedad que
-- ya tenia. Es idempotente: si se corre dos veces no duplica.
insert into public.empleado_vinculos (
  empleado_id, secuencia, tipo_vinculo, fecha_ingreso, fecha_salida,
  antiguedad_desde, tipo_salida, motivo_salida, liquidado, registrado_por
)
select
  e.id, 1, 'inicial', e.fecha_ingreso_real, e.fecha_salida,
  e.fecha_ingreso_real,
  case when e.fecha_salida is not null then 'fin_contrato' end,
  case when e.fecha_salida is not null
    then 'Migrado desde el registro anterior a v33' end,
  e.estado = 'liquidado',
  e.creado_por
from public.empleados e
where not exists (
  select 1 from public.empleado_vinculos v where v.empleado_id = e.id
);

-- ------------------------------------------------------------
-- 3. Vacaciones por vinculo
-- ------------------------------------------------------------
-- Sin esto, un reingreso con relacion nueva choca contra la unicidad por
-- anos_servicio: su ano 1 ya existe y el periodo nuevo nunca se crea.
alter table public.vacaciones_periodos
  add column if not exists vinculo_id uuid
    references public.empleado_vinculos(id) on delete restrict;

update public.vacaciones_periodos vp
set vinculo_id = v.id
from public.empleado_vinculos v
where vp.vinculo_id is null
  and v.empleado_id = vp.empleado_id
  and v.secuencia = 1;

alter table public.vacaciones_periodos
  drop constraint if exists vacaciones_periodos_empleado_id_anos_servicio_key;
alter table public.vacaciones_periodos
  drop constraint if exists vacaciones_periodos_empleado_id_periodo_desde_key;

create unique index if not exists uq_vacaciones_periodo_vinculo_anio_v33
  on public.vacaciones_periodos(empleado_id, vinculo_id, anos_servicio);
create unique index if not exists uq_vacaciones_periodo_vinculo_desde_v33
  on public.vacaciones_periodos(empleado_id, vinculo_id, periodo_desde);

-- ------------------------------------------------------------
-- 4. Consulta de antiguedad
-- ------------------------------------------------------------
-- Una sola fuente de verdad para vacaciones, decimos y finiquito.
-- No es security definer: respeta el RLS como el resto de consultas.
create or replace function public.vinculo_vigente_v33(p_empleado_id uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  select id from public.empleado_vinculos
  where empleado_id = p_empleado_id and fecha_salida is null
  limit 1;
$$;

create or replace function public.antiguedad_desde_v33(
  p_empleado_id uuid,
  p_fecha date default null
) returns date
language sql
stable
set search_path = ''
as $$
  select v.antiguedad_desde
  from public.empleado_vinculos v
  where v.empleado_id = p_empleado_id
    and v.fecha_ingreso <= coalesce(p_fecha, current_date)
    and (v.fecha_salida is null or v.fecha_salida >= coalesce(p_fecha, current_date))
  order by v.secuencia desc
  limit 1;
$$;

-- ------------------------------------------------------------
-- 5. Salida
-- ------------------------------------------------------------
-- Reemplaza a dar_baja_empleado_v26, que queda revocada al final.
-- Anade lo que faltaba: como termino, si se pago finiquito y con que
-- documento. Eso es lo que decidira la antiguedad si la persona vuelve.
create or replace function public.registrar_salida_v33(
  p_empleado_id uuid,
  p_fecha_salida date,
  p_tipo_salida text,
  p_motivo text,
  p_liquidado boolean,
  p_documento_finiquito_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.empleado_vinculos%rowtype;
  v_retroactiva boolean := false;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar una salida';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo de la salida es obligatorio';
  end if;
  if p_tipo_salida is null then
    raise exception 'Debe indicar el tipo de salida';
  end if;
  if p_fecha_salida is null then
    raise exception 'La fecha de salida es obligatoria';
  end if;

  select * into v from public.empleado_vinculos
  where empleado_id = p_empleado_id and fecha_salida is null
  for update;
  if not found then
    raise exception 'El empleado no tiene un vinculo laboral abierto';
  end if;
  if p_fecha_salida < v.fecha_ingreso then
    raise exception 'La salida no puede ser anterior al ingreso de este vinculo';
  end if;
  -- Una salida en un periodo ya cerrado se admite: el hecho ya ocurrio y no
  -- registrarlo es peor que registrarlo tarde. Queda marcada como excepcion
  -- para que Control la revise contra lo que se pago ese mes.
  if public.fecha_en_periodo_cerrado_v32(p_fecha_salida) then
    v_retroactiva := true;
  end if;
  if coalesce(p_liquidado, false) and p_documento_finiquito_id is null then
    raise exception 'Si se pago finiquito debe adjuntarse el acta que lo respalda';
  end if;
  if p_documento_finiquito_id is not null and not exists (
    select 1 from public.empleado_documentos
    where id = p_documento_finiquito_id and empleado_id = p_empleado_id and activo
  ) then
    raise exception 'El acta de finiquito no pertenece al empleado o esta archivada';
  end if;

  update public.empleado_vinculos
  set fecha_salida = p_fecha_salida,
      tipo_salida = p_tipo_salida,
      motivo_salida = btrim(p_motivo),
      liquidado = coalesce(p_liquidado, false),
      documento_finiquito_id = p_documento_finiquito_id,
      cerrado_por = auth.uid(),
      updated_at = now()
  where id = v.id;

  perform set_config('nomina.motivo', 'Salida: ' || btrim(p_motivo), true);

  update public.empleados
  set estado = case when coalesce(p_liquidado, false) then 'liquidado' else 'inactivo' end,
      fecha_salida = p_fecha_salida,
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_empleado_id;

  -- Cierra afiliacion y compensacion vigentes en la misma fecha.
  update public.empleado_afiliaciones
  set fecha_hasta = p_fecha_salida
  where empleado_id = p_empleado_id and fecha_hasta is null
    and fecha_desde <= p_fecha_salida;

  update public.empleado_compensacion
  set fecha_hasta = p_fecha_salida
  where empleado_id = p_empleado_id and fecha_hasta is null
    and fecha_desde <= p_fecha_salida;

  -- Con finiquito pagado, los periodos de vacaciones de este vinculo ya se
  -- liquidaron; sin el, siguen siendo deuda y quedan abiertos.
  if coalesce(p_liquidado, false) then
    update public.vacaciones_periodos
    set estado = 'liquidado'
    where vinculo_id = v.id and estado not in ('liquidado', 'caducado');
  end if;

  perform public.registrar_evento_nomina_v26(
    'empleado', p_empleado_id, p_empleado_id,
    case when v_retroactiva then 'salida_registrada_retroactiva' else 'salida_registrada' end,
    p_tipo_salida || ' - ' || btrim(p_motivo) ||
    case when coalesce(p_liquidado, false) then ' (liquidado)' else ' (sin liquidar)' end ||
    case when v_retroactiva
      then ' [EXCEPCION: cae en un periodo de nomina ya cerrado]' else '' end
  );
  return v.id;
end;
$$;

-- ------------------------------------------------------------
-- 6. Reingreso
-- ------------------------------------------------------------
-- La unica pregunta que el sistema no puede responder solo: al salir, se le
-- pago finiquito? Si se pago, la antiguedad arranca de cero. Si no, se
-- respeta la que traia. El valor por defecto sale del propio vinculo
-- anterior para que nadie tenga que recordarlo.
create or replace function public.registrar_reingreso_v33(
  p_empleado_id uuid,
  p_fecha_ingreso date,
  p_respeta_antiguedad boolean,
  p_motivo text,
  p_cargo text default null,
  p_documento_ingreso_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anterior public.empleado_vinculos%rowtype;
  v_id uuid;
  v_secuencia integer;
  v_tipo text;
  v_antiguedad date;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar un reingreso';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo del reingreso es obligatorio';
  end if;
  if p_fecha_ingreso is null then
    raise exception 'La fecha de reingreso es obligatoria';
  end if;
  if p_fecha_ingreso > current_date then
    raise exception 'La fecha de reingreso no puede ser futura';
  end if;

  if exists (
    select 1 from public.empleado_vinculos
    where empleado_id = p_empleado_id and fecha_salida is null
  ) then
    raise exception
      'El empleado tiene un vinculo abierto: si nunca se liquido, esto es una ausencia, no un reingreso';
  end if;

  select * into v_anterior from public.empleado_vinculos
  where empleado_id = p_empleado_id
  order by secuencia desc
  limit 1;
  if not found then
    raise exception 'El empleado no tiene ningun vinculo anterior';
  end if;
  if p_fecha_ingreso <= v_anterior.fecha_salida then
    raise exception 'El reingreso debe ser posterior a la salida del % ', v_anterior.fecha_salida;
  end if;

  -- Un finiquito pagado ya cerro la antiguedad: no se puede reclamar dos veces.
  if coalesce(p_respeta_antiguedad, false) and v_anterior.liquidado then
    raise exception
      'El vinculo anterior se liquido con finiquito: la antiguedad ya se pago y no puede conservarse';
  end if;

  if coalesce(p_respeta_antiguedad, false) then
    v_tipo := 'reingreso_continuidad';
    v_antiguedad := v_anterior.antiguedad_desde;
  else
    v_tipo := 'reingreso_nueva_relacion';
    v_antiguedad := p_fecha_ingreso;
  end if;

  if p_documento_ingreso_id is not null and not exists (
    select 1 from public.empleado_documentos
    where id = p_documento_ingreso_id and empleado_id = p_empleado_id and activo
  ) then
    raise exception 'El documento de reingreso no pertenece al empleado o esta archivado';
  end if;

  select coalesce(max(secuencia), 0) + 1 into v_secuencia
  from public.empleado_vinculos where empleado_id = p_empleado_id;

  insert into public.empleado_vinculos (
    empleado_id, secuencia, tipo_vinculo, fecha_ingreso, antiguedad_desde,
    motivo_ingreso, documento_ingreso_id, registrado_por
  ) values (
    p_empleado_id, v_secuencia, v_tipo, p_fecha_ingreso, v_antiguedad,
    btrim(p_motivo), p_documento_ingreso_id, auth.uid()
  ) returning id into v_id;

  perform set_config('nomina.motivo', 'Reingreso: ' || btrim(p_motivo), true);

  -- fecha_ingreso_real pasa a ser la de este vinculo: v30 prorratea el mes
  -- con ella y asi no paga dias anteriores al regreso.
  update public.empleados
  set estado = 'activo',
      fecha_ingreso_real = p_fecha_ingreso,
      fecha_salida = null,
      cargo = coalesce(nullif(btrim(p_cargo), ''), cargo),
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_empleado_id;

  perform public.registrar_evento_nomina_v26(
    'empleado', p_empleado_id, p_empleado_id, 'reingreso_registrado',
    v_tipo || ' - antiguedad desde ' || v_antiguedad::text || ' - ' || btrim(p_motivo)
  );
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 7. Periodos de vacaciones sobre la antiguedad correcta
-- ------------------------------------------------------------
-- Reemplaza a asegurar_periodos_vacaciones_v27, que contaba contra
-- fecha_ingreso_real y por tanto perdia o inflaba la antiguedad al reingresar.
create or replace function public.asegurar_periodos_vacaciones_v33(
  p_empleado_id uuid,
  p_hasta date
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.empleados%rowtype;
  v public.empleado_vinculos%rowtype;
  v_hasta date;
  v_anios integer;
  v_i integer;
  v_desde date;
  v_hasta_periodo date;
  v_edad integer;
  v_dias numeric(7,2);
  v_insertados integer := 0;
begin
  select * into e from public.empleados where id = p_empleado_id for update;
  if not found then raise exception 'El empleado no existe'; end if;
  if e.tipo_contrato = 'servicios_profesionales' then
    raise exception 'Servicios profesionales no genera vacaciones laborales automaticamente';
  end if;

  select * into v from public.empleado_vinculos
  where empleado_id = p_empleado_id
  order by secuencia desc
  limit 1;
  if not found then
    raise exception 'El empleado no tiene ningun vinculo laboral registrado';
  end if;

  v_hasta := least(
    coalesce(p_hasta, current_date),
    coalesce(v.fecha_salida, p_hasta, current_date)
  );
  if v_hasta < v.antiguedad_desde then return 0; end if;

  -- Los anos se cuentan sobre la antiguedad reconocida, no sobre el inicio
  -- de este vinculo: quien vuelve con continuidad conserva su escala.
  v_anios := extract(year from age(v_hasta, v.antiguedad_desde))::integer;

  for v_i in 1..v_anios loop
    v_desde := (v.antiguedad_desde + make_interval(years => v_i - 1))::date;
    v_hasta_periodo := (v.antiguedad_desde + make_interval(years => v_i))::date - 1;

    -- Un periodo cerrado en el vinculo anterior no se vuelve a crear aqui.
    if v_desde < v.fecha_ingreso and v.tipo_vinculo <> 'inicial' then
      continue;
    end if;

    v_edad := case when e.fecha_nacimiento is null then 99 else
      extract(year from age(v_hasta_periodo + 1, e.fecha_nacimiento))::integer end;
    v_dias := greatest(
      case when v_edad < 16 then 20 when v_edad < 18 then 18 else 15 end,
      least(30, 15 + greatest(v_i - 5, 0))
    );

    insert into public.vacaciones_periodos(
      empleado_id, vinculo_id, periodo_desde, periodo_hasta, anos_servicio,
      dias_derecho, creado_por
    ) values (
      e.id, v.id, v_desde, v_hasta_periodo, v_i, v_dias, auth.uid()
    ) on conflict (empleado_id, vinculo_id, anos_servicio) do nothing;
    if found then v_insertados := v_insertados + 1; end if;
  end loop;
  return v_insertados;
end;
$$;

create or replace function public.generar_periodos_vacaciones_v33(
  p_empleado_id uuid,
  p_hasta date,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_insertados integer;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden generar periodos de vacaciones';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 33)
  );

  v_insertados := public.asegurar_periodos_vacaciones_v33(p_empleado_id, p_hasta);

  perform public.registrar_evento_nomina_v26(
    'periodos_vacaciones', p_empleado_id, p_empleado_id, 'periodos_generados',
    v_insertados::text || ' periodo(s)'
  );
  return jsonb_build_object('empleado_id', p_empleado_id, 'periodos_creados', v_insertados);
end;
$$;

-- ------------------------------------------------------------
-- 8. Vistas
-- ------------------------------------------------------------
alter table public.empleado_vinculos enable row level security;

drop policy if exists "leer_empleado_vinculos_v33" on public.empleado_vinculos;
create policy "leer_empleado_vinculos_v33" on public.empleado_vinculos
for select to authenticated using (public.usuario_puede_nomina(false));

create or replace view public.vista_vinculos_empleado_v33
with (security_invoker = true) as
select
  v.id as vinculo_id,
  v.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  v.secuencia,
  v.tipo_vinculo,
  v.fecha_ingreso,
  v.fecha_salida,
  v.antiguedad_desde,
  v.fecha_salida is null as vigente,
  v.tipo_salida,
  v.motivo_salida,
  v.liquidado,
  v.motivo_ingreso,
  -- Antiguedad reconocida a hoy, o a la salida si el vinculo ya cerro.
  extract(year from age(
    coalesce(v.fecha_salida, current_date), v.antiguedad_desde
  ))::integer as anios_antiguedad,
  case
    when v.tipo_vinculo = 'reingreso_continuidad'
      then v.fecha_ingreso - v.antiguedad_desde
  end as dias_antiguedad_reconocida,
  fin.nombre as acta_finiquito,
  reg.nombre_completo as registrado_por
from public.empleado_vinculos v
join public.empleados e on e.id = v.empleado_id
left join public.empleado_documentos fin on fin.id = v.documento_finiquito_id
left join public.perfiles reg on reg.id = v.registrado_por;

-- Personal que salio y podria volver: la lista que se consulta antes de
-- crear una persona nueva por error.
create or replace view public.vista_reingresables_v33
with (security_invoker = true) as
select
  e.id as empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  e.cargo,
  e.estado,
  v.secuencia as vinculos,
  v.fecha_ingreso as ultimo_ingreso,
  v.fecha_salida as ultima_salida,
  v.tipo_salida,
  v.liquidado,
  current_date - v.fecha_salida as dias_fuera,
  -- Sin finiquito pagado, al volver puede conservar su antiguedad.
  not v.liquidado as puede_conservar_antiguedad,
  v.antiguedad_desde as antiguedad_previa
from public.empleados e
join public.empleado_vinculos v on v.empleado_id = e.id
where v.fecha_salida is not null
  and not exists (
    select 1 from public.empleado_vinculos v2
    where v2.empleado_id = e.id and v2.secuencia > v.secuencia
  );

-- ------------------------------------------------------------
-- 9. Propiedad y permisos
-- ------------------------------------------------------------
alter function public.vinculo_vigente_v33(uuid) owner to postgres;
alter function public.antiguedad_desde_v33(uuid, date) owner to postgres;
alter function public.registrar_salida_v33(uuid, date, text, text, boolean, uuid) owner to postgres;
alter function public.registrar_reingreso_v33(uuid, date, boolean, text, text, uuid) owner to postgres;
alter function public.asegurar_periodos_vacaciones_v33(uuid, date) owner to postgres;
alter function public.generar_periodos_vacaciones_v33(uuid, date, uuid) owner to postgres;

revoke all on public.empleado_vinculos from public, anon;
revoke all on public.vista_vinculos_empleado_v33 from public, anon;
revoke all on public.vista_reingresables_v33 from public, anon;

grant select on public.empleado_vinculos to authenticated;
grant select on public.vista_vinculos_empleado_v33 to authenticated;
grant select on public.vista_reingresables_v33 to authenticated;

revoke execute on function public.vinculo_vigente_v33(uuid) from public, anon;
revoke execute on function public.antiguedad_desde_v33(uuid, date) from public, anon;
revoke execute on function public.registrar_salida_v33(uuid, date, text, text, boolean, uuid) from public, anon;
revoke execute on function public.registrar_reingreso_v33(uuid, date, boolean, text, text, uuid) from public, anon;
revoke execute on function public.generar_periodos_vacaciones_v33(uuid, date, uuid) from public, anon;

grant execute on function public.vinculo_vigente_v33(uuid) to authenticated;
grant execute on function public.antiguedad_desde_v33(uuid, date) to authenticated;
grant execute on function public.registrar_salida_v33(uuid, date, text, text, boolean, uuid) to authenticated;
grant execute on function public.registrar_reingreso_v33(uuid, date, boolean, text, text, uuid) to authenticated;
grant execute on function public.generar_periodos_vacaciones_v33(uuid, date, uuid) to authenticated;

-- Solo se invoca desde generar_periodos_vacaciones_v33.
revoke execute on function public.asegurar_periodos_vacaciones_v33(uuid, date)
  from public, anon, authenticated;

-- Las versiones que contaban contra fecha_ingreso_real quedan fuera de
-- servicio: al reingresar perdian los periodos anteriores o inflaban la
-- antiguedad, y ademas chocaban con la unicidad nueva.
revoke execute on function public.generar_periodos_vacaciones_v27(uuid, date, uuid)
  from public, anon, authenticated;
revoke execute on function public.asegurar_periodos_vacaciones_v27(uuid, date)
  from public, anon, authenticated;
revoke execute on function public.dar_baja_empleado_v26(uuid, date, text)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
