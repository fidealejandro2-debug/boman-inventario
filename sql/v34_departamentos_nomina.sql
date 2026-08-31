-- ============================================================
-- BOMAN INVENTARIO - Departamentos de nomina v34
-- Convierte el texto libre `empleados.area` en un catalogo controlado por
-- grupo economico. Conserva `area` como instantanea compatible con v26-v33
-- y con los roles historicos de v30.
-- Ejecutar una sola vez DESPUES de v33.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Catalogo organizacional del grupo
-- ------------------------------------------------------------
create table if not exists public.departamentos_nomina (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  codigo text not null check (codigo ~ '^[A-Z0-9][A-Z0-9_-]{0,19}$'),
  nombre text not null check (btrim(nombre) <> ''),
  descripcion text,
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, codigo)
);

create unique index if not exists uq_departamentos_nombre_grupo_v34
  on public.departamentos_nomina(grupo_id, lower(btrim(nombre)));
create index if not exists idx_departamentos_grupo_activo_v34
  on public.departamentos_nomina(grupo_id, activo, nombre);

alter table public.empleados
  add column if not exists departamento_id uuid
    references public.departamentos_nomina(id) on delete restrict;

create index if not exists idx_empleados_departamento_estado_v34
  on public.empleados(departamento_id, estado);

comment on table public.departamentos_nomina is
  'Catalogo organizacional transversal al grupo economico; no pertenece a un solo RUC.';
comment on column public.empleados.departamento_id is
  'Departamento actual. empleados.area conserva el nombre compatible con roles y reportes anteriores.';
comment on column public.empleados.area is
  'Campo legado de solo compatibilidad. No editar directamente; v34 lo sincroniza desde departamento_id.';

-- Migra sin perder los nombres escritos antes de v34. Los codigos LEG-* son
-- estables y luego pueden editarse desde la interfaz.
insert into public.departamentos_nomina (
  grupo_id, codigo, nombre, descripcion, activo
)
select
  e.grupo_id,
  'LEG-' || upper(substr(md5(e.grupo_id::text || ':' || lower(btrim(e.area))), 1, 8)),
  min(btrim(e.area)),
  'Migrado automaticamente desde el campo area al instalar v34',
  true
from public.empleados e
where btrim(coalesce(e.area, '')) <> ''
group by e.grupo_id, lower(btrim(e.area))
on conflict (grupo_id, codigo) do nothing;

update public.empleados e
set departamento_id = d.id,
    area = d.nombre,
    updated_at = now()
from public.departamentos_nomina d
where e.departamento_id is null
  and d.grupo_id = e.grupo_id
  and lower(btrim(d.nombre)) = lower(btrim(e.area));

-- v33 migro los empleados existentes, pero no dejo un trigger para las altas
-- posteriores. Se completa cualquier caso pendiente y se protege el futuro.
insert into public.empleado_vinculos (
  empleado_id, secuencia, tipo_vinculo, fecha_ingreso, fecha_salida,
  antiguedad_desde, tipo_salida, motivo_salida, liquidado, registrado_por
)
select
  e.id, 1, 'inicial', e.fecha_ingreso_real, e.fecha_salida,
  e.fecha_ingreso_real,
  case when e.fecha_salida is not null then 'fin_contrato' end,
  case when e.fecha_salida is not null
    then 'Regularizado al instalar v34: alta posterior a v33' end,
  e.estado = 'liquidado', e.creado_por
from public.empleados e
where not exists (
  select 1 from public.empleado_vinculos v where v.empleado_id = e.id
);

create or replace function public.crear_vinculo_inicial_empleado_v34()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.empleado_vinculos (
    empleado_id, secuencia, tipo_vinculo, fecha_ingreso,
    antiguedad_desde, registrado_por
  ) values (
    new.id, 1, 'inicial', new.fecha_ingreso_real,
    new.fecha_ingreso_real, coalesce(new.creado_por, auth.uid())
  )
  on conflict (empleado_id, secuencia) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_crear_vinculo_inicial_empleado_v34 on public.empleados;
create trigger trg_crear_vinculo_inicial_empleado_v34
after insert on public.empleados
for each row execute function public.crear_vinculo_inicial_empleado_v34();

-- ------------------------------------------------------------
-- 2. Consistencia y auditoria
-- ------------------------------------------------------------
alter table public.nomina_eventos
  drop constraint if exists nomina_eventos_entidad_check;
alter table public.nomina_eventos
  add constraint nomina_eventos_entidad_check check (entidad in (
    'empleado', 'afiliacion', 'compensacion', 'documento', 'parametros',
    'calendario_feriados', 'periodos_vacaciones', 'ausencia', 'novedad',
    'anticipo', 'descuento', 'descuento_aplicacion',
    'nomina_periodo', 'nomina_rol', 'departamento'
  ));

-- La asignacion de departamento es un dato sensible de organizacion para la
-- trazabilidad de v32.
create or replace function public.campo_sensible_nomina_v32(p_campo text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_campo in (
    'identificacion', 'tipo_identificacion', 'numero_cuenta', 'banco',
    'tipo_cuenta', 'forma_pago', 'sueldo_real', 'sueldo_declarado',
    'afiliado', 'empresa_id', 'empresa_pagadora_id', 'fecha_afiliacion',
    'fecha_ingreso_real', 'fecha_salida', 'estado', 'departamento_id',
    'salario_basico_unificado', 'pct_aporte_personal', 'pct_aporte_patronal',
    'pct_fondos_reserva', 'tope_multa_pct', 'tope_descuento_total_pct'
  );
$$;

create or replace function public.validar_departamento_empleado_v34()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grupo_id uuid;
  v_nombre text;
begin
  if new.departamento_id is null then
    return new;
  end if;

  select d.grupo_id, d.nombre
  into v_grupo_id, v_nombre
  from public.departamentos_nomina d
  where d.id = new.departamento_id;

  if not found then
    raise exception 'El departamento no existe';
  end if;
  if v_grupo_id <> new.grupo_id then
    raise exception 'El departamento no pertenece al grupo economico del empleado';
  end if;

  -- area sigue siendo la instantanea textual usada por v26-v33 y por v30.
  new.area := v_nombre;
  return new;
end;
$$;

drop trigger if exists trg_validar_departamento_empleado_v34 on public.empleados;
create trigger trg_validar_departamento_empleado_v34
before insert or update of departamento_id, area, grupo_id on public.empleados
for each row execute function public.validar_departamento_empleado_v34();

-- ------------------------------------------------------------
-- 3. Administracion auditada
-- ------------------------------------------------------------
create or replace function public.guardar_departamento_nomina_v34(
  p_departamento_id uuid,
  p_grupo_id uuid,
  p_codigo text,
  p_nombre text,
  p_descripcion text,
  p_activo boolean,
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
  v_tipo text;
  v_evento public.nomina_eventos%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden configurar departamentos';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 34)
  );

  select * into v_evento
  from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then
    if v_evento.entidad <> 'departamento' then
      raise exception 'La clave de idempotencia ya fue utilizada en otra operacion';
    end if;
    return jsonb_build_object(
      'id', v_evento.entidad_id, 'duplicado', true,
      'mensaje', 'El departamento ya habia sido guardado'
    );
  end if;

  if p_grupo_id is null or not exists (
    select 1 from public.grupos_economicos g where g.id = p_grupo_id and g.activo
  ) then
    raise exception 'El grupo economico no existe o esta inactivo';
  end if;
  if upper(btrim(coalesce(p_codigo, ''))) !~ '^[A-Z0-9][A-Z0-9_-]{0,19}$' then
    raise exception 'El codigo debe tener entre 1 y 20 caracteres: letras, numeros, guion o guion bajo';
  end if;
  if btrim(coalesce(p_nombre, '')) = '' then
    raise exception 'El nombre del departamento es obligatorio';
  end if;

  if exists (
    select 1 from public.departamentos_nomina d
    where d.grupo_id = p_grupo_id
      and lower(btrim(d.nombre)) = lower(btrim(p_nombre))
      and d.id is distinct from p_departamento_id
  ) then
    raise exception 'Ya existe un departamento con ese nombre en el grupo';
  end if;
  if exists (
    select 1 from public.departamentos_nomina d
    where d.grupo_id = p_grupo_id
      and d.codigo = upper(btrim(p_codigo))
      and d.id is distinct from p_departamento_id
  ) then
    raise exception 'Ya existe un departamento con ese codigo en el grupo';
  end if;

  if p_departamento_id is null then
    insert into public.departamentos_nomina (
      grupo_id, codigo, nombre, descripcion, activo, creado_por, actualizado_por
    ) values (
      p_grupo_id, upper(btrim(p_codigo)), btrim(p_nombre),
      nullif(btrim(p_descripcion), ''), coalesce(p_activo, true),
      auth.uid(), auth.uid()
    ) returning id into v_id;
    v_tipo := 'departamento_creado';
  else
    select to_jsonb(d) into v_antes
    from public.departamentos_nomina d
    where d.id = p_departamento_id
    for update;
    if not found then
      raise exception 'El departamento no existe';
    end if;
    if (v_antes ->> 'grupo_id')::uuid <> p_grupo_id then
      raise exception 'No se puede mover un departamento a otro grupo economico';
    end if;
    if not coalesce(p_activo, true) and exists (
      select 1 from public.empleados e
      where e.departamento_id = p_departamento_id and e.estado = 'activo'
    ) then
      raise exception 'Reasigna primero al personal activo antes de desactivar el departamento';
    end if;

    update public.departamentos_nomina
    set codigo = upper(btrim(p_codigo)),
        nombre = btrim(p_nombre),
        descripcion = nullif(btrim(p_descripcion), ''),
        activo = coalesce(p_activo, true),
        actualizado_por = auth.uid(),
        updated_at = now()
    where id = p_departamento_id
    returning id into v_id;

    -- Mantiene el espejo de compatibilidad al renombrar el departamento.
    perform set_config(
      'nomina.motivo', 'Actualizacion del catalogo de departamentos', true
    );
    update public.empleados
    set area = btrim(p_nombre),
        actualizado_por = auth.uid(),
        updated_at = now()
    where departamento_id = v_id and area is distinct from btrim(p_nombre);
    v_tipo := 'departamento_actualizado';
  end if;

  select to_jsonb(d) into v_despues
  from public.departamentos_nomina d where d.id = v_id;

  insert into public.nomina_eventos (
    entidad, entidad_id, empleado_id, tipo, detalle, usuario_id,
    estado_anterior, estado_nuevo, datos, idempotency_key
  ) values (
    'departamento', v_id, null, v_tipo,
    'Departamento ' || btrim(p_nombre) || ' (' || upper(btrim(p_codigo)) || ')',
    auth.uid(), v_antes ->> 'activo', v_despues ->> 'activo',
    jsonb_build_object('antes', v_antes, 'despues', v_despues),
    p_idempotency_key
  );

  return jsonb_build_object(
    'id', v_id, 'duplicado', false,
    'mensaje', case when v_tipo = 'departamento_creado'
      then 'Departamento creado correctamente'
      else 'Departamento actualizado correctamente' end
  );
end;
$$;

create or replace function public.asignar_departamento_empleado_v34(
  p_empleado_id uuid,
  p_departamento_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empleado public.empleados%rowtype;
  v_departamento public.departamentos_nomina%rowtype;
  v_evento public.nomina_eventos%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden asignar departamentos';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo de la asignacion es obligatorio';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 34)
  );

  select * into v_evento
  from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then
    if v_evento.entidad <> 'departamento'
       or v_evento.empleado_id is distinct from p_empleado_id then
      raise exception 'La clave de idempotencia ya fue utilizada en otra operacion';
    end if;
    return jsonb_build_object(
      'empleado_id', p_empleado_id, 'departamento_id',
      v_evento.datos ->> 'departamento_nuevo_id', 'duplicado', true,
      'mensaje', 'La asignacion ya habia sido aplicada'
    );
  end if;

  select * into v_empleado
  from public.empleados where id = p_empleado_id for update;
  if not found then
    raise exception 'El empleado no existe';
  end if;

  if p_departamento_id is not null then
    select * into v_departamento
    from public.departamentos_nomina where id = p_departamento_id;
    if not found then
      raise exception 'El departamento no existe';
    end if;
    if not v_departamento.activo then
      raise exception 'No se puede asignar un departamento inactivo';
    end if;
    if v_departamento.grupo_id <> v_empleado.grupo_id then
      raise exception 'El departamento no pertenece al grupo economico del empleado';
    end if;
  end if;

  perform set_config('nomina.motivo', btrim(p_motivo), true);
  update public.empleados
  set departamento_id = p_departamento_id,
      area = case when p_departamento_id is null then null
                  else v_departamento.nombre end,
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_empleado_id;

  insert into public.nomina_eventos (
    entidad, entidad_id, empleado_id, tipo, detalle, usuario_id,
    estado_anterior, estado_nuevo, datos, idempotency_key
  ) values (
    'departamento', p_empleado_id, p_empleado_id,
    case when p_departamento_id is null
      then 'departamento_desasignado' else 'departamento_asignado' end,
    btrim(p_motivo), auth.uid(),
    v_empleado.departamento_id::text, p_departamento_id::text,
    jsonb_build_object(
      'departamento_anterior_id', v_empleado.departamento_id,
      'departamento_anterior_nombre', v_empleado.area,
      'departamento_nuevo_id', p_departamento_id,
      'departamento_nuevo_nombre', v_departamento.nombre
    ),
    p_idempotency_key
  );

  return jsonb_build_object(
    'empleado_id', p_empleado_id,
    'departamento_id', p_departamento_id,
    'duplicado', false,
    'mensaje', 'Departamento asignado correctamente'
  );
end;
$$;

-- Alta atomica: si falla banco, departamento, afiliacion o sueldo, no queda
-- una persona parcial. Los motores v26 y v32 conservan todas sus validaciones.
create or replace function public.crear_empleado_completo_v34(
  p_datos jsonb,
  p_departamento_id uuid,
  p_afiliacion jsonb,
  p_compensacion jsonb,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empleado_id uuid;
  v_departamento public.departamentos_nomina%rowtype;
  v_evento public.nomina_eventos%rowtype;
  v_fecha_ingreso date;
  v_afiliado boolean;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar personal';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if coalesce(jsonb_typeof(p_datos), 'null') <> 'object'
     or coalesce(jsonb_typeof(p_afiliacion), 'null') <> 'object'
     or coalesce(jsonb_typeof(p_compensacion), 'null') <> 'object' then
    raise exception 'Los datos del empleado no tienen el formato esperado';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 34)
  );
  select * into v_evento
  from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then
    if v_evento.entidad <> 'empleado'
       or v_evento.tipo <> 'empleado_alta_completa' then
      raise exception 'La clave de idempotencia ya fue utilizada en otra operacion';
    end if;
    return jsonb_build_object(
      'id', v_evento.entidad_id, 'duplicado', true,
      'mensaje', 'La persona ya habia sido registrada'
    );
  end if;

  select * into v_departamento
  from public.departamentos_nomina
  where id = p_departamento_id and activo;
  if not found then
    raise exception 'El departamento no existe o esta inactivo';
  end if;
  if v_departamento.grupo_id <> nullif(p_datos ->> 'grupo_id', '')::uuid then
    raise exception 'El departamento no pertenece al grupo economico del empleado';
  end if;

  v_fecha_ingreso := nullif(p_datos ->> 'fecha_ingreso_real', '')::date;
  v_afiliado := coalesce((p_afiliacion ->> 'afiliado')::boolean, true);

  v_empleado_id := public.guardar_empleado_v26(
    null,
    nullif(p_datos ->> 'grupo_id', '')::uuid,
    p_datos ->> 'tipo_identificacion',
    p_datos ->> 'identificacion',
    p_datos ->> 'nombres',
    p_datos ->> 'apellidos',
    v_fecha_ingreso,
    p_datos ->> 'cargo',
    nullif(p_datos ->> 'fecha_nacimiento', '')::date,
    nullif(p_datos ->> 'estado_civil', ''),
    nullif(p_datos ->> 'direccion', ''),
    nullif(p_datos ->> 'telefono', ''),
    nullif(p_datos ->> 'email', ''),
    nullif(p_datos ->> 'contacto_emergencia_nombre', ''),
    nullif(p_datos ->> 'contacto_emergencia_telefono', ''),
    v_departamento.nombre,
    coalesce(nullif(p_datos ->> 'tipo_contrato', ''), 'indefinido'),
    coalesce(nullif(p_datos ->> 'forma_pago', ''), 'transferencia'),
    nullif(p_datos ->> 'banco', ''),
    nullif(p_datos ->> 'tipo_cuenta', ''),
    nullif(p_datos ->> 'numero_cuenta', ''),
    nullif(p_datos ->> 'observacion', '')
  );

  perform public.asignar_departamento_empleado_v34(
    v_empleado_id, p_departamento_id,
    'Asignacion al registrar la persona',
    md5(p_idempotency_key::text || ':departamento')::uuid
  );

  perform public.registrar_afiliacion_v32(
    v_empleado_id,
    v_afiliado,
    case when v_afiliado
      then nullif(p_afiliacion ->> 'empresa_id', '')::uuid end,
    case when v_afiliado
      then nullif(p_afiliacion ->> 'fecha_afiliacion', '')::date end,
    case when v_afiliado
      then nullif(p_afiliacion ->> 'sueldo_declarado', '')::numeric
      else 0 end,
    v_fecha_ingreso,
    'afiliacion_inicial',
    'Registro inicial del personal',
    null,
    md5(p_idempotency_key::text || ':afiliacion')::uuid
  );

  perform public.registrar_compensacion_v32(
    v_empleado_id,
    nullif(p_compensacion ->> 'empresa_pagadora_id', '')::uuid,
    nullif(p_compensacion ->> 'sueldo_real', '')::numeric,
    v_fecha_ingreso,
    'contratacion',
    'Sueldo acordado al ingreso',
    null,
    md5(p_idempotency_key::text || ':compensacion')::uuid
  );

  insert into public.nomina_eventos (
    entidad, entidad_id, empleado_id, tipo, detalle, usuario_id,
    datos, idempotency_key
  ) values (
    'empleado', v_empleado_id, v_empleado_id, 'empleado_alta_completa',
    'Alta atomica con departamento, afiliacion y compensacion', auth.uid(),
    jsonb_build_object(
      'departamento_id', p_departamento_id,
      'afiliado', v_afiliado,
      'empresa_pagadora_id', p_compensacion ->> 'empresa_pagadora_id'
    ),
    p_idempotency_key
  );

  return jsonb_build_object(
    'id', v_empleado_id, 'duplicado', false,
    'mensaje', 'Persona registrada completamente'
  );
end;
$$;

-- ------------------------------------------------------------
-- 4. Lectura operativa
-- ------------------------------------------------------------
create or replace view public.vista_departamentos_nomina_v34
with (security_invoker = true) as
select
  d.id as departamento_id,
  d.grupo_id,
  d.codigo,
  d.nombre,
  d.descripcion,
  d.activo,
  count(e.id)::bigint as empleados_total,
  count(e.id) filter (where e.estado = 'activo')::bigint as empleados_activos,
  d.created_at,
  d.updated_at
from public.departamentos_nomina d
left join public.empleados e on e.departamento_id = d.id
group by d.id;

-- Agrega el identificador normalizado al final para no cambiar las columnas
-- que ya consumen las interfaces v26-v33.
create or replace view public.vista_personal_vigente
with (security_invoker = true) as
select
  e.id as empleado_id,
  e.grupo_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  e.cargo,
  e.area,
  e.tipo_contrato,
  e.estado,
  e.fecha_ingreso_real,
  e.fecha_salida,
  a.afiliado,
  a.empresa_id as empresa_afiliacion_id,
  emp_af.razon_social as empresa_afiliacion,
  a.fecha_afiliacion,
  a.sueldo_declarado,
  c.empresa_pagadora_id,
  emp_pg.razon_social as empresa_pagadora,
  c.sueldo_real,
  coalesce(c.sueldo_real, 0) - coalesce(a.sueldo_declarado, 0) as brecha_sueldo,
  case
    when a.afiliado and a.fecha_afiliacion is not null
      then a.fecha_afiliacion - e.fecha_ingreso_real
  end as dias_entre_ingreso_y_afiliacion,
  (a.afiliado and c.empresa_pagadora_id is distinct from a.empresa_id)
    as paga_otro_ruc,
  e.departamento_id,
  d.codigo as departamento_codigo,
  d.nombre as departamento_nombre
from public.empleados e
left join public.empleado_afiliaciones a
  on a.empleado_id = e.id and a.fecha_hasta is null
left join public.empleado_compensacion c
  on c.empleado_id = e.id and c.fecha_hasta is null
left join public.empresas emp_af on emp_af.id = a.empresa_id
left join public.empresas emp_pg on emp_pg.id = c.empresa_pagadora_id
left join public.departamentos_nomina d on d.id = e.departamento_id;

-- ------------------------------------------------------------
-- 5. RLS, propiedad y privilegios
-- ------------------------------------------------------------
alter table public.departamentos_nomina enable row level security;

drop policy if exists "leer_departamentos_nomina_v34"
  on public.departamentos_nomina;
create policy "leer_departamentos_nomina_v34"
on public.departamentos_nomina for select to authenticated using (
  public.usuario_puede_nomina(false)
);

alter function public.campo_sensible_nomina_v32(text) owner to postgres;
alter function public.crear_vinculo_inicial_empleado_v34() owner to postgres;
alter function public.validar_departamento_empleado_v34() owner to postgres;
alter function public.guardar_departamento_nomina_v34(uuid, uuid, text, text, text, boolean, uuid) owner to postgres;
alter function public.asignar_departamento_empleado_v34(uuid, uuid, text, uuid) owner to postgres;
alter function public.crear_empleado_completo_v34(jsonb, uuid, jsonb, jsonb, uuid) owner to postgres;

revoke all on public.departamentos_nomina from public, anon;
revoke insert, update, delete on public.departamentos_nomina from authenticated;
grant select on public.departamentos_nomina to authenticated;

revoke all on public.vista_departamentos_nomina_v34 from public, anon;
grant select on public.vista_departamentos_nomina_v34 to authenticated;
grant select on public.vista_personal_vigente to authenticated;

revoke execute on function public.validar_departamento_empleado_v34()
  from public, anon, authenticated;
revoke execute on function public.crear_vinculo_inicial_empleado_v34()
  from public, anon, authenticated;
revoke execute on function public.guardar_departamento_nomina_v34(uuid, uuid, text, text, text, boolean, uuid)
  from public, anon;
revoke execute on function public.asignar_departamento_empleado_v34(uuid, uuid, text, uuid)
  from public, anon;
revoke execute on function public.crear_empleado_completo_v34(jsonb, uuid, jsonb, jsonb, uuid)
  from public, anon;
grant execute on function public.guardar_departamento_nomina_v34(uuid, uuid, text, text, text, boolean, uuid)
  to authenticated;
grant execute on function public.asignar_departamento_empleado_v34(uuid, uuid, text, uuid)
  to authenticated;
grant execute on function public.crear_empleado_completo_v34(jsonb, uuid, jsonb, jsonb, uuid)
  to authenticated;

notify pgrst, 'reload schema';
