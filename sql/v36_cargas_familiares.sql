-- ============================================================
-- BOMAN INVENTARIO - Cargas familiares de nomina v36
-- Registra parentesco, vigencia y respaldo documental sin confundir el
-- expediente familiar con el calculo anual de utilidades.
-- Ejecutar una sola vez DESPUES de v35.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Expediente de cargas familiares
-- ------------------------------------------------------------
create table if not exists public.empleado_cargas_familiares (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  tipo text not null check (tipo in (
    'conyuge', 'conviviente_union_hecho', 'hijo'
  )),
  tipo_identificacion text not null check (tipo_identificacion in (
    'cedula', 'pasaporte', 'partida_nacimiento', 'otro', 'sin_identificacion'
  )),
  identificacion text,
  nombres text not null check (btrim(nombres) <> ''),
  apellidos text not null check (btrim(apellidos) <> ''),
  fecha_nacimiento date,
  tiene_discapacidad boolean not null default false,
  porcentaje_discapacidad numeric(5,2),
  fecha_desde date not null,
  fecha_hasta date,
  fecha_acreditacion date not null,
  documento_parentesco_id uuid not null
    references public.empleado_documentos(id) on delete restrict,
  documento_discapacidad_id uuid
    references public.empleado_documentos(id) on delete restrict,
  observacion text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (tipo_identificacion = 'sin_identificacion' and identificacion is null)
    or (tipo_identificacion <> 'sin_identificacion'
        and btrim(coalesce(identificacion, '')) <> '')
  ),
  check (tipo <> 'hijo' or fecha_nacimiento is not null),
  check (fecha_nacimiento is null or fecha_nacimiento <= fecha_desde),
  check (fecha_hasta is null or fecha_hasta >= fecha_desde),
  check (fecha_acreditacion >= fecha_desde),
  check (
    (not tiene_discapacidad
      and porcentaje_discapacidad is null
      and documento_discapacidad_id is null)
    or (tiene_discapacidad
      and documento_discapacidad_id is not null
      and (porcentaje_discapacidad is null
        or porcentaje_discapacidad > 0 and porcentaje_discapacidad <= 100))
  )
);

create index if not exists idx_cargas_familiares_empleado_v36
  on public.empleado_cargas_familiares(empleado_id, fecha_desde, fecha_hasta);
create index if not exists idx_cargas_familiares_nacimiento_v36
  on public.empleado_cargas_familiares(fecha_nacimiento)
  where tipo = 'hijo' and fecha_hasta is null;
create unique index if not exists uq_carga_identificacion_vigente_v36
  on public.empleado_cargas_familiares(empleado_id, identificacion)
  where fecha_hasta is null and identificacion is not null;
create unique index if not exists uq_pareja_vigente_empleado_v36
  on public.empleado_cargas_familiares(empleado_id)
  where fecha_hasta is null and tipo in ('conyuge', 'conviviente_union_hecho');

comment on table public.empleado_cargas_familiares is
  'Historia de cargas familiares acreditadas. No se eliminan: su vigencia se cierra con fecha y evento auditado.';
comment on column public.empleado_cargas_familiares.fecha_acreditacion is
  'Fecha en que el empleador recibio respaldo suficiente; permite controlar el plazo de utilidades sin usar created_at.';

-- El documento familiar queda identificado en el expediente privado.
alter table public.empleado_documentos
  drop constraint if exists empleado_documentos_tipo_check;
alter table public.empleado_documentos
  add constraint empleado_documentos_tipo_check check (tipo in (
    'hoja_vida', 'cedula', 'papeleta_votacion', 'contrato', 'adendum',
    'titulo', 'certificado_laboral', 'certificado_medico', 'antecedentes',
    'firma', 'foto', 'aviso_entrada_iess', 'acta_finiquito',
    'carga_familiar', 'otro'
  ));

-- Amplia la auditoria compartida sin alterar los eventos anteriores.
alter table public.nomina_eventos
  drop constraint if exists nomina_eventos_entidad_check;
alter table public.nomina_eventos
  add constraint nomina_eventos_entidad_check check (entidad in (
    'empleado', 'afiliacion', 'compensacion', 'documento', 'parametros',
    'calendario_feriados', 'periodos_vacaciones', 'ausencia', 'novedad',
    'anticipo', 'descuento', 'descuento_aplicacion',
    'nomina_periodo', 'nomina_rol', 'departamento', 'carga_familiar'
  ));

-- ------------------------------------------------------------
-- 2. Elegibilidad para el 5% de utilidades
-- ------------------------------------------------------------
-- Regla vigente: pareja legal o de hecho; hijos menores de 18 al cierre
-- del ejercicio; hijos con discapacidad de cualquier edad. El respaldo
-- debe haberse acreditado hasta el 31 de marzo del anio de pago.
create or replace function public.carga_familiar_elegible_utilidades_v36(
  p_carga_id uuid,
  p_ejercicio integer
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.usuario_puede_nomina(false) and exists (
    select 1
    from public.empleado_cargas_familiares c
    where c.id = p_carga_id
      and p_ejercicio between 2000 and 2100
      and c.fecha_desde <= make_date(p_ejercicio, 12, 31)
      and (c.fecha_hasta is null
        or c.fecha_hasta >= make_date(p_ejercicio, 12, 31))
      and c.fecha_acreditacion <= make_date(p_ejercicio + 1, 3, 31)
      and (
        c.tipo in ('conyuge', 'conviviente_union_hecho')
        or (
          c.tipo = 'hijo'
          and (
            c.tiene_discapacidad
            or c.fecha_nacimiento + interval '18 years'
              > make_date(p_ejercicio, 12, 31)
          )
        )
      )
  );
$$;

create or replace function public.contar_cargas_utilidades_v36(
  p_empleado_id uuid,
  p_ejercicio integer
) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case when public.usuario_puede_nomina(false) then count(*)::integer else 0 end
  from public.empleado_cargas_familiares c
  where c.empleado_id = p_empleado_id
    and public.carga_familiar_elegible_utilidades_v36(c.id, p_ejercicio);
$$;

-- ------------------------------------------------------------
-- 3. Administracion atomica y auditada
-- ------------------------------------------------------------
create or replace function public.guardar_carga_familiar_v36(
  p_carga_id uuid,
  p_empleado_id uuid,
  p_tipo text,
  p_tipo_identificacion text,
  p_identificacion text,
  p_nombres text,
  p_apellidos text,
  p_fecha_nacimiento date,
  p_tiene_discapacidad boolean,
  p_porcentaje_discapacidad numeric,
  p_fecha_desde date,
  p_fecha_acreditacion date,
  p_documento_parentesco_id uuid,
  p_documento_discapacidad_id uuid,
  p_observacion text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_antes jsonb;
  v_despues jsonb;
  v_evento public.nomina_eventos%rowtype;
  v_identificacion text := nullif(btrim(p_identificacion), '');
  v_tipo_identificacion text := btrim(coalesce(p_tipo_identificacion, ''));
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden gestionar cargas familiares';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 36)
  );
  select * into v_evento
  from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then
    if v_evento.entidad <> 'carga_familiar' then
      raise exception 'La clave de idempotencia ya fue utilizada en otra operacion';
    end if;
    return jsonb_build_object(
      'id', v_evento.entidad_id, 'duplicado', true,
      'mensaje', 'La carga familiar ya estaba guardada'
    );
  end if;

  if not exists (select 1 from public.empleados e where e.id = p_empleado_id) then
    raise exception 'La persona no existe';
  end if;
  if p_tipo not in ('conyuge', 'conviviente_union_hecho', 'hijo') then
    raise exception 'El parentesco no es valido';
  end if;
  if v_tipo_identificacion not in (
    'cedula', 'pasaporte', 'partida_nacimiento', 'otro', 'sin_identificacion'
  ) then
    raise exception 'El tipo de identificacion no es valido';
  end if;
  if v_tipo_identificacion = 'sin_identificacion' then
    v_identificacion := null;
  elsif v_identificacion is null then
    raise exception 'Escribe la identificacion de la carga familiar';
  end if;
  if p_tipo in ('conyuge', 'conviviente_union_hecho') and v_identificacion is null then
    raise exception 'La pareja requiere cedula, pasaporte u otra identificacion';
  end if;
  if btrim(coalesce(p_nombres, '')) = ''
     or btrim(coalesce(p_apellidos, '')) = '' then
    raise exception 'Nombres y apellidos son obligatorios';
  end if;
  if p_tipo = 'hijo' and p_fecha_nacimiento is null then
    raise exception 'La fecha de nacimiento del hijo es obligatoria';
  end if;
  if p_fecha_nacimiento is not null and p_fecha_nacimiento > current_date then
    raise exception 'La fecha de nacimiento no puede estar en el futuro';
  end if;
  if p_fecha_desde is null or p_fecha_desde > current_date then
    raise exception 'La vigencia debe empezar en una fecha valida y no futura';
  end if;
  if p_fecha_nacimiento is not null and p_fecha_desde < p_fecha_nacimiento then
    raise exception 'La vigencia no puede empezar antes del nacimiento';
  end if;
  if p_fecha_acreditacion is null
     or p_fecha_acreditacion < p_fecha_desde
     or p_fecha_acreditacion > current_date then
    raise exception 'La fecha de acreditacion debe estar entre el inicio de vigencia y hoy';
  end if;
  if not coalesce(p_tiene_discapacidad, false)
     and (p_porcentaje_discapacidad is not null
       or p_documento_discapacidad_id is not null) then
    raise exception 'Marca discapacidad antes de registrar su porcentaje o respaldo';
  end if;
  if coalesce(p_tiene_discapacidad, false)
     and p_documento_discapacidad_id is null then
    raise exception 'La discapacidad requiere un documento de respaldo';
  end if;
  if p_porcentaje_discapacidad is not null
     and (p_porcentaje_discapacidad <= 0 or p_porcentaje_discapacidad > 100) then
    raise exception 'El porcentaje de discapacidad debe estar entre 0 y 100';
  end if;

  if not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_parentesco_id
      and d.empleado_id = p_empleado_id and d.activo
  ) then
    raise exception 'El respaldo de parentesco no pertenece al expediente o esta archivado';
  end if;
  if p_documento_discapacidad_id is not null and not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_discapacidad_id
      and d.empleado_id = p_empleado_id and d.activo
  ) then
    raise exception 'El respaldo de discapacidad no pertenece al expediente o esta archivado';
  end if;

  if p_carga_id is not null then
    select to_jsonb(c) into v_antes
    from public.empleado_cargas_familiares c
    where c.id = p_carga_id for update;
    if not found then raise exception 'La carga familiar no existe'; end if;
    if (v_antes ->> 'empleado_id')::uuid <> p_empleado_id then
      raise exception 'No se puede trasladar una carga familiar a otra persona';
    end if;
    if v_antes ->> 'fecha_hasta' is not null then
      raise exception 'Una carga con vigencia cerrada no se puede editar';
    end if;
  end if;

  if p_tipo in ('conyuge', 'conviviente_union_hecho') and exists (
    select 1 from public.empleado_cargas_familiares c
    where c.empleado_id = p_empleado_id
      and c.id is distinct from p_carga_id
      and c.tipo in ('conyuge', 'conviviente_union_hecho')
      and c.fecha_hasta is null
  ) then
    raise exception 'La persona ya tiene conyuge o conviviente vigente';
  end if;
  if v_identificacion is not null and exists (
    select 1 from public.empleado_cargas_familiares c
    where c.empleado_id = p_empleado_id
      and c.id is distinct from p_carga_id
      and c.identificacion = v_identificacion and c.fecha_hasta is null
  ) then
    raise exception 'Esa identificacion ya esta registrada como carga vigente';
  end if;
  if v_identificacion is null and p_tipo = 'hijo' and exists (
    select 1 from public.empleado_cargas_familiares c
    where c.empleado_id = p_empleado_id
      and c.id is distinct from p_carga_id
      and c.tipo = 'hijo' and c.fecha_hasta is null
      and c.fecha_nacimiento = p_fecha_nacimiento
      and lower(btrim(c.nombres)) = lower(btrim(p_nombres))
      and lower(btrim(c.apellidos)) = lower(btrim(p_apellidos))
  ) then
    raise exception 'Ese hijo ya esta registrado como carga vigente';
  end if;

  if p_carga_id is null then
    insert into public.empleado_cargas_familiares (
      empleado_id, tipo, tipo_identificacion, identificacion,
      nombres, apellidos, fecha_nacimiento, tiene_discapacidad,
      porcentaje_discapacidad, fecha_desde, fecha_acreditacion,
      documento_parentesco_id, documento_discapacidad_id, observacion,
      creado_por, actualizado_por
    ) values (
      p_empleado_id, p_tipo, v_tipo_identificacion, v_identificacion,
      btrim(p_nombres), btrim(p_apellidos), p_fecha_nacimiento,
      coalesce(p_tiene_discapacidad, false),
      case when coalesce(p_tiene_discapacidad, false)
        then p_porcentaje_discapacidad end,
      p_fecha_desde, p_fecha_acreditacion, p_documento_parentesco_id,
      case when coalesce(p_tiene_discapacidad, false)
        then p_documento_discapacidad_id end,
      nullif(btrim(p_observacion), ''), auth.uid(), auth.uid()
    ) returning id into v_id;
  else
    update public.empleado_cargas_familiares
    set tipo = p_tipo,
        tipo_identificacion = v_tipo_identificacion,
        identificacion = v_identificacion,
        nombres = btrim(p_nombres),
        apellidos = btrim(p_apellidos),
        fecha_nacimiento = p_fecha_nacimiento,
        tiene_discapacidad = coalesce(p_tiene_discapacidad, false),
        porcentaje_discapacidad = case
          when coalesce(p_tiene_discapacidad, false)
            then p_porcentaje_discapacidad end,
        fecha_desde = p_fecha_desde,
        fecha_acreditacion = p_fecha_acreditacion,
        documento_parentesco_id = p_documento_parentesco_id,
        documento_discapacidad_id = case
          when coalesce(p_tiene_discapacidad, false)
            then p_documento_discapacidad_id end,
        observacion = nullif(btrim(p_observacion), ''),
        actualizado_por = auth.uid(),
        updated_at = now()
    where id = p_carga_id
    returning id into v_id;
  end if;

  select to_jsonb(c) into v_despues
  from public.empleado_cargas_familiares c where c.id = v_id;

  insert into public.nomina_eventos (
    entidad, entidad_id, empleado_id, tipo, detalle, usuario_id,
    estado_anterior, estado_nuevo, datos, idempotency_key
  ) values (
    'carga_familiar', v_id, p_empleado_id,
    case when p_carga_id is null then 'carga_creada' else 'carga_actualizada' end,
    case when p_carga_id is null
      then 'Carga familiar acreditada'
      else 'Datos de carga familiar actualizados' end,
    auth.uid(),
    case when p_carga_id is null then null else 'vigente' end,
    'vigente',
    jsonb_build_object('antes', v_antes, 'despues', v_despues),
    p_idempotency_key
  );

  return jsonb_build_object(
    'id', v_id, 'duplicado', false,
    'mensaje', case when p_carga_id is null
      then 'Carga familiar registrada' else 'Carga familiar actualizada' end
  );
end;
$$;

create or replace function public.cerrar_carga_familiar_v36(
  p_carga_id uuid,
  p_fecha_hasta date,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.empleado_cargas_familiares%rowtype;
  v_evento public.nomina_eventos%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden cerrar cargas familiares';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo del cierre es obligatorio';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 36)
  );
  select * into v_evento
  from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then
    if v_evento.entidad <> 'carga_familiar' then
      raise exception 'La clave de idempotencia ya fue utilizada en otra operacion';
    end if;
    return jsonb_build_object(
      'id', v_evento.entidad_id, 'duplicado', true,
      'mensaje', 'La vigencia ya estaba cerrada'
    );
  end if;

  select * into c from public.empleado_cargas_familiares
  where id = p_carga_id for update;
  if not found then raise exception 'La carga familiar no existe'; end if;
  if c.fecha_hasta is not null then
    raise exception 'La carga familiar ya tiene su vigencia cerrada';
  end if;
  if p_fecha_hasta is null or p_fecha_hasta < c.fecha_desde
     or p_fecha_hasta > current_date then
    raise exception 'La fecha de cierre debe estar entre el inicio de vigencia y hoy';
  end if;

  update public.empleado_cargas_familiares
  set fecha_hasta = p_fecha_hasta,
      observacion = concat_ws(' | ', nullif(observacion, ''), btrim(p_motivo)),
      actualizado_por = auth.uid(), updated_at = now()
  where id = c.id;

  insert into public.nomina_eventos (
    entidad, entidad_id, empleado_id, tipo, detalle, usuario_id,
    estado_anterior, estado_nuevo, datos, idempotency_key
  ) values (
    'carga_familiar', c.id, c.empleado_id, 'carga_vigencia_cerrada',
    btrim(p_motivo), auth.uid(), 'vigente', 'finalizada',
    jsonb_build_object('fecha_hasta', p_fecha_hasta, 'motivo', btrim(p_motivo)),
    p_idempotency_key
  );

  return jsonb_build_object(
    'id', c.id, 'duplicado', false,
    'mensaje', 'Vigencia de la carga familiar cerrada'
  );
end;
$$;

-- ------------------------------------------------------------
-- 4. Lectura operativa
-- ------------------------------------------------------------
create or replace view public.vista_cargas_familiares_v36
with (security_invoker = true) as
select
  c.id,
  c.empleado_id,
  e.identificacion as empleado_identificacion,
  e.apellidos || ' ' || e.nombres as empleado_nombre,
  e.estado as empleado_estado,
  c.tipo,
  c.tipo_identificacion,
  c.identificacion,
  c.nombres,
  c.apellidos,
  c.fecha_nacimiento,
  case when c.fecha_nacimiento is not null
    then extract(year from age(current_date, c.fecha_nacimiento))::integer end
    as edad_hoy,
  c.tiene_discapacidad,
  c.porcentaje_discapacidad,
  c.fecha_desde,
  c.fecha_hasta,
  c.fecha_acreditacion,
  c.documento_parentesco_id,
  parentesco.nombre as documento_parentesco,
  c.documento_discapacidad_id,
  discapacidad.nombre as documento_discapacidad,
  c.observacion,
  c.fecha_desde <= current_date
    and (c.fecha_hasta is null or c.fecha_hasta >= current_date) as vigente_hoy,
  public.carga_familiar_elegible_utilidades_v36(
    c.id, extract(year from current_date)::integer
  ) as elegible_utilidades_ejercicio_actual,
  case when c.tipo = 'hijo' and not c.tiene_discapacidad
    then c.fecha_nacimiento + interval '18 years' end as cumple_18_at,
  c.created_at,
  c.updated_at
from public.empleado_cargas_familiares c
join public.empleados e on e.id = c.empleado_id
join public.empleado_documentos parentesco on parentesco.id = c.documento_parentesco_id
left join public.empleado_documentos discapacidad
  on discapacidad.id = c.documento_discapacidad_id;

-- ------------------------------------------------------------
-- 5. RLS, propiedad y privilegios
-- ------------------------------------------------------------
alter table public.empleado_cargas_familiares enable row level security;

drop policy if exists "leer_cargas_familiares_v36"
  on public.empleado_cargas_familiares;
create policy "leer_cargas_familiares_v36"
on public.empleado_cargas_familiares for select to authenticated using (
  public.usuario_puede_nomina(false)
);

alter function public.carga_familiar_elegible_utilidades_v36(uuid, integer)
  owner to postgres;
alter function public.contar_cargas_utilidades_v36(uuid, integer)
  owner to postgres;
alter function public.guardar_carga_familiar_v36(uuid, uuid, text, text, text, text, text, date, boolean, numeric, date, date, uuid, uuid, text, uuid)
  owner to postgres;
alter function public.cerrar_carga_familiar_v36(uuid, date, text, uuid)
  owner to postgres;

revoke all on public.empleado_cargas_familiares from public, anon;
revoke insert, update, delete on public.empleado_cargas_familiares from authenticated;
grant select on public.empleado_cargas_familiares to authenticated;

revoke all on public.vista_cargas_familiares_v36 from public, anon;
grant select on public.vista_cargas_familiares_v36 to authenticated;

revoke execute on function public.carga_familiar_elegible_utilidades_v36(uuid, integer)
  from public, anon;
revoke execute on function public.contar_cargas_utilidades_v36(uuid, integer)
  from public, anon;
revoke execute on function public.guardar_carga_familiar_v36(uuid, uuid, text, text, text, text, text, date, boolean, numeric, date, date, uuid, uuid, text, uuid)
  from public, anon;
revoke execute on function public.cerrar_carga_familiar_v36(uuid, date, text, uuid)
  from public, anon;
grant execute on function public.carga_familiar_elegible_utilidades_v36(uuid, integer)
  to authenticated;
grant execute on function public.contar_cargas_utilidades_v36(uuid, integer)
  to authenticated;
grant execute on function public.guardar_carga_familiar_v36(uuid, uuid, text, text, text, text, text, date, boolean, numeric, date, date, uuid, uuid, text, uuid)
  to authenticated;
grant execute on function public.cerrar_carga_familiar_v36(uuid, date, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';
