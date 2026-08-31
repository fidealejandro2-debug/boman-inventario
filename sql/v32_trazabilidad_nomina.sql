-- ============================================================
-- BOMAN INVENTARIO - Trazabilidad de nomina v32
-- Auditoria de campo por trigger sobre personal, afiliaciones,
-- compensacion y parametros: quien cambio que, de que valor a cual, cuando
-- y por que. Tipifica el motivo, exige respaldo documental en los cambios
-- delicados, permite rectificar un error de digitacion y congela los
-- parametros de un anio que ya tiene roles cerrados.
-- Ejecutar una sola vez DESPUES de v31.
--
-- Depende de nomina_periodos y nomina_rol_lineas (v30) para saber que
-- periodos estan cerrados y que compensacion ya se uso en un rol.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Bitacora de cambios a nivel de campo
-- ------------------------------------------------------------
-- La alimenta un trigger, no la aplicacion: un evento que hay que acordarse
-- de registrar se olvida, un trigger no se puede saltar desde el cliente.
create table if not exists public.nomina_cambios (
  id uuid primary key default gen_random_uuid(),
  tabla text not null,
  registro_id uuid not null,
  empleado_id uuid references public.empleados(id) on delete restrict,
  operacion text not null check (operacion in ('alta', 'modificacion')),
  campo text not null,
  valor_anterior text,
  valor_nuevo text,
  sensible boolean not null default false,
  motivo text,
  usuario_id uuid references public.perfiles(id) on delete restrict,
  db_usuario text not null default current_user,
  created_at timestamptz not null default now()
);

create index if not exists idx_nomina_cambios_empleado_v32
  on public.nomina_cambios(empleado_id, created_at desc);
create index if not exists idx_nomina_cambios_registro_v32
  on public.nomina_cambios(tabla, registro_id, created_at desc);
create index if not exists idx_nomina_cambios_sensibles_v32
  on public.nomina_cambios(created_at desc) where sensible;

comment on table public.nomina_cambios is
  'Bitacora de campo alimentada por trigger. Nunca se edita ni se borra.';
comment on column public.nomina_cambios.db_usuario is
  'Rol de base que ejecuto el cambio. Deja rastro incluso si se corre desde el editor SQL y auth.uid() es nulo.';

-- ------------------------------------------------------------
-- 2. Trigger de auditoria
-- ------------------------------------------------------------
-- Campos que cambian solos en cada UPDATE y solo generarian ruido.
create or replace function public.campo_auditable_nomina_v32(p_campo text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_campo not in (
    'id', 'updated_at', 'created_at', 'actualizado_por', 'idempotency_key'
  );
$$;

-- Campos donde un cambio silencioso hace dano real: identidad, dinero,
-- destino del pago y las bases de calculo.
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
    'fecha_ingreso_real', 'fecha_salida', 'estado',
    'salario_basico_unificado', 'pct_aporte_personal', 'pct_aporte_patronal',
    'pct_fondos_reserva', 'tope_multa_pct', 'tope_descuento_total_pct'
  );
$$;

create or replace function public.auditar_cambios_nomina_v32()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when TG_OP = 'UPDATE' then to_jsonb(OLD) else '{}'::jsonb end;
  v_new jsonb := to_jsonb(NEW);
  v_registro_id uuid;
  v_empleado_id uuid;
  v_motivo text;
  v_campo text;
begin
  -- nomina_parametros se identifica por anio, no por uuid: se sintetiza un
  -- identificador estable para poder guardarlo en la misma columna.
  if TG_TABLE_NAME = 'nomina_parametros' then
    v_registro_id := ('00000000-0000-0000-0000-' ||
      lpad((v_new ->> 'anio'), 12, '0'))::uuid;
  else
    v_registro_id := (v_new ->> 'id')::uuid;
  end if;

  v_empleado_id := case
    when TG_TABLE_NAME = 'empleados' then (v_new ->> 'id')::uuid
    else (v_new ->> 'empleado_id')::uuid
  end;

  -- El motivo viene de la propia fila cuando la tabla lo tiene; si no, de
  -- una variable de sesion que el RPC puede fijar antes de escribir.
  v_motivo := coalesce(
    v_new ->> 'motivo',
    nullif(btrim(coalesce(current_setting('nomina.motivo', true), '')), '')
  );

  for v_campo in select jsonb_object_keys(v_new) loop
    if public.campo_auditable_nomina_v32(v_campo)
       and (v_old -> v_campo) is distinct from (v_new -> v_campo)
    then
      insert into public.nomina_cambios (
        tabla, registro_id, empleado_id, operacion, campo,
        valor_anterior, valor_nuevo, sensible, motivo, usuario_id
      ) values (
        TG_TABLE_NAME, v_registro_id, v_empleado_id,
        case when TG_OP = 'INSERT' then 'alta' else 'modificacion' end,
        v_campo,
        v_old ->> v_campo, v_new ->> v_campo,
        public.campo_sensible_nomina_v32(v_campo),
        v_motivo, auth.uid()
      );
    end if;
  end loop;

  return NEW;
end;
$$;

drop trigger if exists trg_auditar_empleados_v32 on public.empleados;
create trigger trg_auditar_empleados_v32
  after insert or update on public.empleados
  for each row execute function public.auditar_cambios_nomina_v32();

drop trigger if exists trg_auditar_compensacion_v32 on public.empleado_compensacion;
create trigger trg_auditar_compensacion_v32
  after insert or update on public.empleado_compensacion
  for each row execute function public.auditar_cambios_nomina_v32();

drop trigger if exists trg_auditar_afiliaciones_v32 on public.empleado_afiliaciones;
create trigger trg_auditar_afiliaciones_v32
  after insert or update on public.empleado_afiliaciones
  for each row execute function public.auditar_cambios_nomina_v32();

drop trigger if exists trg_auditar_parametros_v32 on public.nomina_parametros;
create trigger trg_auditar_parametros_v32
  after insert or update on public.nomina_parametros
  for each row execute function public.auditar_cambios_nomina_v32();

-- ------------------------------------------------------------
-- 3. Motivo tipificado y respaldo documental
-- ------------------------------------------------------------
-- El texto libre no permite responder cuantos aumentos fueron por desempeno
-- y cuantos por ajuste del SBU, que es justo lo que pide un SGC.
alter table public.empleado_compensacion
  add column if not exists motivo_tipo text,
  add column if not exists documento_respaldo_id uuid
    references public.empleado_documentos(id) on delete restrict;

alter table public.empleado_afiliaciones
  add column if not exists motivo_tipo text,
  add column if not exists documento_respaldo_id uuid
    references public.empleado_documentos(id) on delete restrict;

alter table public.empleado_compensacion
  drop constraint if exists empleado_compensacion_motivo_tipo_check;
alter table public.empleado_compensacion
  add constraint empleado_compensacion_motivo_tipo_check check (
    motivo_tipo is null or motivo_tipo in (
      'contratacion', 'aumento_desempeno', 'ajuste_sbu', 'promocion',
      'reestructuracion', 'acuerdo_partes', 'cambio_pagadora',
      'reduccion_acordada', 'correccion_error'
    )
  );

alter table public.empleado_afiliaciones
  drop constraint if exists empleado_afiliaciones_motivo_tipo_check;
alter table public.empleado_afiliaciones
  add constraint empleado_afiliaciones_motivo_tipo_check check (
    motivo_tipo is null or motivo_tipo in (
      'afiliacion_inicial', 'cambio_ruc', 'ajuste_sueldo_declarado',
      'desafiliacion', 'reafiliacion', 'correccion_error'
    )
  );

-- Nulos permitidos solo para las filas que ya existian antes de v32.
comment on column public.empleado_compensacion.motivo_tipo is
  'Obligatorio desde v32 via registrar_compensacion_v32. Nulo solo en el historico previo.';

-- ------------------------------------------------------------
-- 4. Ayudas de control
-- ------------------------------------------------------------
-- Un periodo cerrado ya se pago: tocar hacia atras descuadra el historico
-- contra lo efectivamente desembolsado.
create or replace function public.fecha_en_periodo_cerrado_v32(p_fecha date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.nomina_periodos
    where estado = 'cerrado'
      and p_fecha between fecha_desde and fecha_hasta
  );
$$;

create or replace function public.anio_con_roles_cerrados_v32(p_anio integer)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.nomina_periodos
    where anio = p_anio and estado = 'cerrado'
  );
$$;

-- ------------------------------------------------------------
-- 5. Registro de compensacion con controles
-- ------------------------------------------------------------
-- Reemplaza a registrar_compensacion_v26, que queda revocada al final.
-- Anade: motivo tipificado, respaldo documental, y freno explicito a las
-- tres maniobras que un SGC no puede dejar pasar en silencio -- reducir la
-- remuneracion, escribir sobre un periodo ya pagado y cambiar el RUC que
-- desembolsa sin decirlo.
create or replace function public.registrar_compensacion_v32(
  p_empleado_id uuid,
  p_empresa_pagadora_id uuid,
  p_sueldo_real numeric,
  p_fecha_desde date,
  p_motivo_tipo text,
  p_motivo text,
  p_documento_respaldo_id uuid,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_ingreso date;
  v_vigente public.empleado_compensacion%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar compensaciones';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 32)
  );
  select id into v_id from public.empleado_compensacion
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  if p_motivo_tipo is null then
    raise exception 'Debe indicar el tipo de motivo del cambio de sueldo';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo del cambio de sueldo es obligatorio';
  end if;
  if p_fecha_desde is null then
    raise exception 'La fecha de vigencia es obligatoria';
  end if;
  if coalesce(p_sueldo_real, 0) <= 0 then
    raise exception 'El sueldo real debe ser mayor a cero';
  end if;
  if not exists (
    select 1 from public.empresas where id = p_empresa_pagadora_id and activo
  ) then raise exception 'La empresa pagadora no existe o esta inactiva'; end if;

  select fecha_ingreso_real into v_ingreso
  from public.empleados where id = p_empleado_id and estado <> 'liquidado';
  if not found then
    raise exception 'El empleado no existe o ya esta liquidado';
  end if;
  if p_fecha_desde < v_ingreso then
    raise exception 'La compensacion no puede iniciar antes del ingreso real';
  end if;

  -- Escribir sobre un periodo ya pagado solo se admite como correccion
  -- formal y con documento de respaldo.
  if public.fecha_en_periodo_cerrado_v32(p_fecha_desde) then
    if p_motivo_tipo <> 'correccion_error' or p_documento_respaldo_id is null then
      raise exception
        'El % cae en un periodo de nomina ya cerrado: solo se admite como correccion_error con documento de respaldo',
        p_fecha_desde;
    end if;
  end if;

  select * into v_vigente
  from public.empleado_compensacion
  where empleado_id = p_empleado_id and fecha_hasta is null;

  if found then
    if v_vigente.fecha_desde >= p_fecha_desde then
      raise exception
        'Ya existe una compensacion vigente desde el %. Para corregirla usa rectificar_compensacion_v32',
        v_vigente.fecha_desde;
    end if;

    -- El Art. 39 del Codigo del Trabajo consagra la irrenunciabilidad de los
    -- derechos del trabajador: bajar la remuneracion no puede ser un cambio
    -- mas, necesita causa declarada y respaldo firmado.
    if p_sueldo_real < v_vigente.sueldo_real then
      if p_motivo_tipo not in ('reduccion_acordada', 'correccion_error') then
        raise exception
          'Reducir el sueldo de % a % exige motivo reduccion_acordada o correccion_error',
          v_vigente.sueldo_real, p_sueldo_real;
      end if;
      if p_documento_respaldo_id is null then
        raise exception 'Una reduccion de sueldo exige el documento que la respalda';
      end if;
    end if;

    if p_empresa_pagadora_id <> v_vigente.empresa_pagadora_id
       and p_sueldo_real = v_vigente.sueldo_real
       and p_motivo_tipo <> 'cambio_pagadora' then
      raise exception 'Si solo cambia la empresa que paga, usa el motivo cambio_pagadora';
    end if;

    update public.empleado_compensacion
    set fecha_hasta = p_fecha_desde - 1
    where id = v_vigente.id;
  end if;

  if p_documento_respaldo_id is not null and not exists (
    select 1 from public.empleado_documentos
    where id = p_documento_respaldo_id and empleado_id = p_empleado_id and activo
  ) then
    raise exception 'El documento de respaldo no pertenece al empleado o esta archivado';
  end if;

  insert into public.empleado_compensacion (
    empleado_id, empresa_pagadora_id, sueldo_real, fecha_desde,
    motivo, motivo_tipo, documento_respaldo_id, idempotency_key, registrado_por
  ) values (
    p_empleado_id, p_empresa_pagadora_id, p_sueldo_real, p_fecha_desde,
    btrim(p_motivo), p_motivo_tipo, p_documento_respaldo_id,
    p_idempotency_key, auth.uid()
  ) returning id into v_id;

  perform public.registrar_evento_nomina_v26(
    'compensacion', v_id, p_empleado_id, 'sueldo_registrado',
    p_motivo_tipo || ' - ' || btrim(p_motivo)
  );
  return v_id;
end;
$$;

-- Corrige un error de digitacion sobre la compensacion vigente sin inventar
-- una vigencia falsa. Solo mientras ningun rol la haya usado.
create or replace function public.rectificar_compensacion_v32(
  p_compensacion_id uuid,
  p_sueldo_real numeric,
  p_empresa_pagadora_id uuid,
  p_motivo text,
  p_documento_respaldo_id uuid default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.empleado_compensacion%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden rectificar compensaciones';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo de la rectificacion es obligatorio';
  end if;
  if coalesce(p_sueldo_real, 0) <= 0 then
    raise exception 'El sueldo rectificado debe ser mayor a cero';
  end if;

  select * into c from public.empleado_compensacion
  where id = p_compensacion_id for update;
  if not found then raise exception 'La compensacion no existe'; end if;
  if c.fecha_hasta is not null then
    raise exception 'Solo se rectifica la compensacion vigente';
  end if;

  -- Si ya alimento un rol, corregirla cambiaria un pago hecho: entonces el
  -- camino correcto es una nueva vigencia, no editar la historia.
  if exists (
    select 1 from public.nomina_rol_lineas where compensacion_id = p_compensacion_id
  ) then
    raise exception
      'Esta compensacion ya se uso en un rol: registra una vigencia nueva en vez de rectificar';
  end if;

  if not exists (
    select 1 from public.empresas where id = p_empresa_pagadora_id and activo
  ) then raise exception 'La empresa pagadora no existe o esta inactiva'; end if;

  perform set_config('nomina.motivo', 'Rectificacion: ' || btrim(p_motivo), true);

  update public.empleado_compensacion
  set sueldo_real = p_sueldo_real,
      empresa_pagadora_id = p_empresa_pagadora_id,
      motivo = btrim(c.motivo) || ' | Rectificado: ' || btrim(p_motivo),
      motivo_tipo = 'correccion_error',
      documento_respaldo_id = coalesce(p_documento_respaldo_id, c.documento_respaldo_id)
  where id = p_compensacion_id;

  perform public.registrar_evento_nomina_v26(
    'compensacion', p_compensacion_id, c.empleado_id, 'sueldo_rectificado',
    btrim(p_motivo)
  );
end;
$$;

-- ------------------------------------------------------------
-- 6. Registro de afiliacion con controles
-- ------------------------------------------------------------
-- Reemplaza a registrar_afiliacion_v26. Trata la desafiliacion como lo que
-- es: una decision de otra naturaleza, no un cambio de sueldo mas.
create or replace function public.registrar_afiliacion_v32(
  p_empleado_id uuid,
  p_afiliado boolean,
  p_empresa_id uuid,
  p_fecha_afiliacion date,
  p_sueldo_declarado numeric,
  p_fecha_desde date,
  p_motivo_tipo text,
  p_motivo text,
  p_documento_respaldo_id uuid,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_ingreso date;
  v_vigente public.empleado_afiliaciones%rowtype;
  v_afiliado boolean := coalesce(p_afiliado, true);
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar afiliaciones';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 32)
  );
  select id into v_id from public.empleado_afiliaciones
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  if p_motivo_tipo is null then
    raise exception 'Debe indicar el tipo de motivo del cambio de afiliacion';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo del cambio de afiliacion es obligatorio';
  end if;
  if p_fecha_desde is null then
    raise exception 'La fecha de vigencia es obligatoria';
  end if;

  select fecha_ingreso_real into v_ingreso
  from public.empleados where id = p_empleado_id and estado <> 'liquidado';
  if not found then
    raise exception 'El empleado no existe o ya esta liquidado';
  end if;
  if p_fecha_desde < v_ingreso then
    raise exception 'La afiliacion no puede iniciar antes del ingreso real';
  end if;

  if public.fecha_en_periodo_cerrado_v32(p_fecha_desde)
     and (p_motivo_tipo <> 'correccion_error' or p_documento_respaldo_id is null) then
    raise exception
      'El % cae en un periodo de nomina ya cerrado: solo se admite como correccion_error con respaldo',
      p_fecha_desde;
  end if;

  if v_afiliado then
    if p_empresa_id is null then
      raise exception 'Debe indicar bajo que RUC queda afiliado';
    end if;
    if not exists (
      select 1 from public.empresas where id = p_empresa_id and activo
    ) then raise exception 'La empresa no existe o esta inactiva'; end if;
    if p_fecha_afiliacion is null then
      raise exception 'La fecha de afiliacion al IESS es obligatoria';
    end if;
    if p_fecha_afiliacion < v_ingreso then
      raise exception 'La fecha de afiliacion no puede ser anterior al ingreso real';
    end if;
    if coalesce(p_sueldo_declarado, 0) <= 0 then
      raise exception 'El sueldo declarado debe ser mayor a cero';
    end if;
  end if;

  select * into v_vigente
  from public.empleado_afiliaciones
  where empleado_id = p_empleado_id and fecha_hasta is null;

  if found then
    if v_vigente.fecha_desde >= p_fecha_desde then
      raise exception 'Ya existe una afiliacion vigente desde el %', v_vigente.fecha_desde;
    end if;

    -- Sacar a alguien del IESS deja rastro propio y exige el documento.
    if v_vigente.afiliado and not v_afiliado then
      if p_motivo_tipo <> 'desafiliacion' then
        raise exception 'Dar de baja la afiliacion exige el motivo desafiliacion';
      end if;
      if p_documento_respaldo_id is null then
        raise exception 'La desafiliacion exige el aviso de salida u otro documento de respaldo';
      end if;
    end if;

    if not v_vigente.afiliado and v_afiliado and p_motivo_tipo <> 'reafiliacion'
       and p_motivo_tipo <> 'afiliacion_inicial' then
      raise exception 'Volver a afiliar exige el motivo reafiliacion';
    end if;

    if v_vigente.afiliado and v_afiliado
       and p_sueldo_declarado < v_vigente.sueldo_declarado
       and p_motivo_tipo <> 'correccion_error' then
      raise exception
        'Bajar el sueldo declarado de % a % solo se admite como correccion_error',
        v_vigente.sueldo_declarado, p_sueldo_declarado;
    end if;

    update public.empleado_afiliaciones
    set fecha_hasta = p_fecha_desde - 1
    where id = v_vigente.id;
  end if;

  if p_documento_respaldo_id is not null and not exists (
    select 1 from public.empleado_documentos
    where id = p_documento_respaldo_id and empleado_id = p_empleado_id and activo
  ) then
    raise exception 'El documento de respaldo no pertenece al empleado o esta archivado';
  end if;

  insert into public.empleado_afiliaciones (
    empleado_id, afiliado, empresa_id, fecha_afiliacion, sueldo_declarado,
    fecha_desde, motivo, motivo_tipo, documento_respaldo_id,
    idempotency_key, registrado_por
  ) values (
    p_empleado_id, v_afiliado,
    case when v_afiliado then p_empresa_id end,
    case when v_afiliado then p_fecha_afiliacion end,
    case when v_afiliado then p_sueldo_declarado else 0 end,
    p_fecha_desde, btrim(p_motivo), p_motivo_tipo, p_documento_respaldo_id,
    p_idempotency_key, auth.uid()
  ) returning id into v_id;

  perform public.registrar_evento_nomina_v26(
    'afiliacion', v_id, p_empleado_id,
    case when v_afiliado then 'afiliado' else 'sin_afiliacion' end,
    p_motivo_tipo || ' - ' || btrim(p_motivo)
  );
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 7. Parametros: se congelan al cerrar el primer rol del anio
-- ------------------------------------------------------------
-- Cambiar el SBU de un anio ya liquidado deja cifras que no se pueden
-- reproducir, que para una auditoria es peor que un error.
create or replace function public.guardar_nomina_parametros_v32(
  p_anio integer,
  p_salario_basico_unificado numeric,
  p_pct_aporte_personal numeric default 9.45,
  p_pct_aporte_patronal numeric default 11.15,
  p_pct_fondos_reserva numeric default 8.33,
  p_pct_iece numeric default 0.50,
  p_pct_secap numeric default 0.50,
  p_horas_jornada_semanal numeric default 40,
  p_tope_multa_pct numeric default 10.00,
  p_tope_descuento_total_pct numeric default 50.00,
  p_motivo text default null
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existe boolean;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede cambiar los parametros de nomina';
  end if;
  if coalesce(p_salario_basico_unificado, 0) <= 0 then
    raise exception 'El salario basico unificado debe ser mayor a cero';
  end if;

  select exists (select 1 from public.nomina_parametros where anio = p_anio)
  into v_existe;

  if v_existe and public.anio_con_roles_cerrados_v32(p_anio) then
    raise exception
      'El anio % ya tiene roles cerrados: sus parametros quedan congelados. Corrige el rol, no la base de calculo',
      p_anio;
  end if;

  if v_existe and btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'Cambiar parametros ya cargados exige indicar el motivo';
  end if;

  perform set_config(
    'nomina.motivo',
    coalesce(nullif(btrim(p_motivo), ''), 'Carga inicial del anio'),
    true
  );

  insert into public.nomina_parametros (
    anio, salario_basico_unificado, pct_aporte_personal, pct_aporte_patronal,
    pct_fondos_reserva, pct_iece, pct_secap, horas_jornada_semanal,
    tope_multa_pct, tope_descuento_total_pct, actualizado_por
  ) values (
    p_anio, p_salario_basico_unificado, p_pct_aporte_personal,
    p_pct_aporte_patronal, p_pct_fondos_reserva, p_pct_iece, p_pct_secap,
    p_horas_jornada_semanal, p_tope_multa_pct, p_tope_descuento_total_pct,
    auth.uid()
  )
  on conflict (anio) do update set
    salario_basico_unificado = excluded.salario_basico_unificado,
    pct_aporte_personal = excluded.pct_aporte_personal,
    pct_aporte_patronal = excluded.pct_aporte_patronal,
    pct_fondos_reserva = excluded.pct_fondos_reserva,
    pct_iece = excluded.pct_iece,
    pct_secap = excluded.pct_secap,
    horas_jornada_semanal = excluded.horas_jornada_semanal,
    tope_multa_pct = excluded.tope_multa_pct,
    tope_descuento_total_pct = excluded.tope_descuento_total_pct,
    actualizado_por = auth.uid(),
    updated_at = now();

  perform public.registrar_evento_nomina_v26(
    'parametros', null, null, 'parametros_guardados',
    p_anio::text || coalesce(' - ' || nullif(btrim(p_motivo), ''), '')
  );
  return p_anio;
end;
$$;

-- ------------------------------------------------------------
-- 8. Vistas de auditoria
-- ------------------------------------------------------------
alter table public.nomina_cambios enable row level security;

drop policy if exists "leer_nomina_cambios_v32" on public.nomina_cambios;
create policy "leer_nomina_cambios_v32" on public.nomina_cambios
for select to authenticated using (public.usuario_puede_nomina(false));

create or replace view public.vista_auditoria_nomina_v32
with (security_invoker = true) as
select
  c.id,
  c.created_at,
  c.tabla,
  c.operacion,
  c.campo,
  c.valor_anterior,
  c.valor_nuevo,
  c.sensible,
  c.motivo,
  c.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  p.nombre_completo as usuario,
  c.db_usuario
from public.nomina_cambios c
left join public.empleados e on e.id = c.empleado_id
left join public.perfiles p on p.id = c.usuario_id;

-- Historial completo de sueldo de cada persona, que es lo que pide una
-- auditoria de SGC cuando revisa un aumento.
create or replace view public.vista_historial_sueldo_v32
with (security_invoker = true) as
select
  c.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  c.fecha_desde,
  c.fecha_hasta,
  c.sueldo_real,
  lag(c.sueldo_real) over (partition by c.empleado_id order by c.fecha_desde)
    as sueldo_anterior,
  c.sueldo_real - lag(c.sueldo_real) over (
    partition by c.empleado_id order by c.fecha_desde
  ) as variacion,
  emp.razon_social as empresa_pagadora,
  c.motivo_tipo,
  c.motivo,
  c.documento_respaldo_id is not null as tiene_respaldo,
  d.nombre as documento_respaldo,
  p.nombre_completo as registrado_por,
  c.created_at as registrado_at
from public.empleado_compensacion c
join public.empleados e on e.id = c.empleado_id
left join public.empresas emp on emp.id = c.empresa_pagadora_id
left join public.empleado_documentos d on d.id = c.documento_respaldo_id
left join public.perfiles p on p.id = c.registrado_por;

-- Cambios sensibles sin justificacion registrada: el reporte de excepciones
-- que revisa Control.
create or replace view public.vista_cambios_sin_justificar_v32
with (security_invoker = true) as
select
  c.created_at,
  c.tabla,
  c.campo,
  c.valor_anterior,
  c.valor_nuevo,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  p.nombre_completo as usuario,
  c.db_usuario
from public.nomina_cambios c
left join public.empleados e on e.id = c.empleado_id
left join public.perfiles p on p.id = c.usuario_id
where c.sensible
  and c.operacion = 'modificacion'
  and coalesce(btrim(c.motivo), '') = '';

-- ------------------------------------------------------------
-- 9. Propiedad y permisos
-- ------------------------------------------------------------
alter function public.campo_auditable_nomina_v32(text) owner to postgres;
alter function public.campo_sensible_nomina_v32(text) owner to postgres;
alter function public.auditar_cambios_nomina_v32() owner to postgres;
alter function public.fecha_en_periodo_cerrado_v32(date) owner to postgres;
alter function public.anio_con_roles_cerrados_v32(integer) owner to postgres;
alter function public.registrar_compensacion_v32(uuid, uuid, numeric, date, text, text, uuid, uuid) owner to postgres;
alter function public.rectificar_compensacion_v32(uuid, numeric, uuid, text, uuid) owner to postgres;
alter function public.registrar_afiliacion_v32(uuid, boolean, uuid, date, numeric, date, text, text, uuid, uuid) owner to postgres;
alter function public.guardar_nomina_parametros_v32(integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text) owner to postgres;

revoke all on public.nomina_cambios from public, anon;
revoke all on public.vista_auditoria_nomina_v32 from public, anon;
revoke all on public.vista_historial_sueldo_v32 from public, anon;
revoke all on public.vista_cambios_sin_justificar_v32 from public, anon;

grant select on public.nomina_cambios to authenticated;
grant select on public.vista_auditoria_nomina_v32 to authenticated;
grant select on public.vista_historial_sueldo_v32 to authenticated;
grant select on public.vista_cambios_sin_justificar_v32 to authenticated;

-- La bitacora no se edita ni se borra desde la aplicacion.
revoke insert, update, delete on public.nomina_cambios from authenticated;

-- El trigger es lo unico que escribe en la bitacora.
revoke execute on function public.auditar_cambios_nomina_v32()
  from public, anon, authenticated;

revoke execute on function public.campo_auditable_nomina_v32(text) from public, anon;
revoke execute on function public.campo_sensible_nomina_v32(text) from public, anon;
revoke execute on function public.fecha_en_periodo_cerrado_v32(date) from public, anon;
revoke execute on function public.anio_con_roles_cerrados_v32(integer) from public, anon;
revoke execute on function public.registrar_compensacion_v32(uuid, uuid, numeric, date, text, text, uuid, uuid) from public, anon;
revoke execute on function public.rectificar_compensacion_v32(uuid, numeric, uuid, text, uuid) from public, anon;
revoke execute on function public.registrar_afiliacion_v32(uuid, boolean, uuid, date, numeric, date, text, text, uuid, uuid) from public, anon;
revoke execute on function public.guardar_nomina_parametros_v32(integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text) from public, anon;

grant execute on function public.campo_auditable_nomina_v32(text) to authenticated;
grant execute on function public.campo_sensible_nomina_v32(text) to authenticated;
grant execute on function public.fecha_en_periodo_cerrado_v32(date) to authenticated;
grant execute on function public.anio_con_roles_cerrados_v32(integer) to authenticated;
grant execute on function public.registrar_compensacion_v32(uuid, uuid, numeric, date, text, text, uuid, uuid) to authenticated;
grant execute on function public.rectificar_compensacion_v32(uuid, numeric, uuid, text, uuid) to authenticated;
grant execute on function public.registrar_afiliacion_v32(uuid, boolean, uuid, date, numeric, date, text, text, uuid, uuid) to authenticated;
grant execute on function public.guardar_nomina_parametros_v32(integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text) to authenticated;

-- Las versiones sin controles quedan fuera de servicio: si siguieran
-- disponibles, bastaria llamarlas para saltarse todo lo anterior.
revoke execute on function public.registrar_compensacion_v26(uuid, uuid, numeric, date, text, uuid)
  from public, anon, authenticated;
revoke execute on function public.registrar_afiliacion_v26(uuid, boolean, uuid, date, numeric, date, text, uuid)
  from public, anon, authenticated;
revoke execute on function public.guardar_nomina_parametros_v26(integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
