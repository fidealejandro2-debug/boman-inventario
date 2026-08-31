-- ============================================================
-- BOMAN INVENTARIO - Nomina: personal y expediente v26
-- Registro unico de personal para los tres RUC del grupo. La persona no
-- cuelga de una empresa: su afiliacion al IESS y su compensacion real son
-- series historizadas aparte, y la empresa que paga puede diferir de la que
-- afilia. Incluye expediente digital y parametros anuales de nomina.
-- Ejecutar una sola vez DESPUES de v25.
--
-- PASO 1 - EJECUTAR SOLO ESTA LINEA Y CONFIRMAR ANTES DEL RESTO.
-- Postgres no permite usar un valor de enum en la misma transaccion en que
-- se agrega, igual que ocurrio en v21 con tipo_movimiento.
--
--   alter type public.rol_usuario add value if not exists 'nomina';
--
-- PASO 2 - ejecutar el resto de este archivo.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Personal
-- ------------------------------------------------------------
-- Sin empresa_id a proposito: la persona existe una sola vez en el grupo.
-- fecha_ingreso_real es el inicio efectivo de la relacion laboral y manda
-- para vacaciones, decimos, antiguedad y finiquito. La fecha de afiliacion
-- vive en empleado_afiliaciones y solo manda para fondos de reserva e
-- historia IESS. No son intercambiables.
create table if not exists public.empleados (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  tipo_identificacion text not null default 'cedula'
    check (tipo_identificacion in ('cedula', 'pasaporte')),
  identificacion text not null check (btrim(identificacion) <> ''),
  nombres text not null check (btrim(nombres) <> ''),
  apellidos text not null check (btrim(apellidos) <> ''),
  fecha_nacimiento date,
  estado_civil text check (estado_civil in (
    'soltero', 'casado', 'divorciado', 'viudo', 'union_hecho'
  )),
  direccion text,
  telefono text,
  email text,
  contacto_emergencia_nombre text,
  contacto_emergencia_telefono text,
  fecha_ingreso_real date not null,
  fecha_salida date,
  cargo text not null check (btrim(cargo) <> ''),
  area text,
  tipo_contrato text not null default 'indefinido' check (tipo_contrato in (
    'indefinido', 'eventual', 'ocasional', 'servicios_profesionales', 'aprendizaje'
  )),
  estado text not null default 'activo'
    check (estado in ('activo', 'inactivo', 'liquidado')),
  forma_pago text not null default 'transferencia'
    check (forma_pago in ('transferencia', 'efectivo', 'cheque')),
  banco text,
  tipo_cuenta text check (tipo_cuenta in ('ahorros', 'corriente')),
  numero_cuenta text,
  observacion text,
  creado_por uuid references public.perfiles(id),
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, identificacion),
  check (fecha_salida is null or fecha_salida >= fecha_ingreso_real),
  check (estado <> 'liquidado' or fecha_salida is not null)
);

-- ------------------------------------------------------------
-- 2. Afiliacion al IESS - historizada
-- ------------------------------------------------------------
-- empresa_id null y afiliado false describen al personal no afiliado, que
-- igual recibe rol de pago (solo el real) pero no entra en planilla IESS.
create table if not exists public.empleado_afiliaciones (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  afiliado boolean not null default true,
  empresa_id uuid references public.empresas(id) on delete restrict,
  fecha_afiliacion date,
  sueldo_declarado numeric(14,2) not null default 0 check (sueldo_declarado >= 0),
  fecha_desde date not null,
  fecha_hasta date,
  motivo text not null check (btrim(motivo) <> ''),
  idempotency_key uuid not null unique,
  registrado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (fecha_hasta is null or fecha_hasta >= fecha_desde),
  check (
    (afiliado and empresa_id is not null and fecha_afiliacion is not null
     and sueldo_declarado > 0)
    or
    (not afiliado and empresa_id is null and fecha_afiliacion is null
     and sueldo_declarado = 0)
  )
);

-- Una sola afiliacion vigente por empleado.
create unique index if not exists uq_empleado_afiliacion_vigente
  on public.empleado_afiliaciones(empleado_id)
  where fecha_hasta is null;

-- ------------------------------------------------------------
-- 3. Compensacion real - historizada
-- ------------------------------------------------------------
-- empresa_pagadora_id es el default de quien desembolsa. Hoy casi todo sale
-- de una persona natural, pero el rol permite sobrescribirlo por periodo,
-- y esta empresa puede ser distinta de la que afilia.
create table if not exists public.empleado_compensacion (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  empresa_pagadora_id uuid not null references public.empresas(id) on delete restrict,
  sueldo_real numeric(14,2) not null check (sueldo_real > 0),
  fecha_desde date not null,
  fecha_hasta date,
  motivo text not null check (btrim(motivo) <> ''),
  idempotency_key uuid not null unique,
  registrado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (fecha_hasta is null or fecha_hasta >= fecha_desde)
);

create unique index if not exists uq_empleado_compensacion_vigente
  on public.empleado_compensacion(empleado_id)
  where fecha_hasta is null;

-- ------------------------------------------------------------
-- 4. Expediente digital
-- ------------------------------------------------------------
-- El archivo vive en el bucket privado 'expedientes'. Aqui solo la metadata.
-- tipo 'firma' guarda el PNG recortado que se estampa en roles y llamados.
-- fecha_caducidad alimenta alertas de examenes medicos, licencias y
-- contratos eventuales por vencer.
create table if not exists public.empleado_documentos (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  tipo text not null check (tipo in (
    'hoja_vida', 'cedula', 'papeleta_votacion', 'contrato', 'adendum',
    'titulo', 'certificado_laboral', 'certificado_medico', 'antecedentes',
    'firma', 'foto', 'aviso_entrada_iess', 'acta_finiquito', 'otro'
  )),
  nombre text not null check (btrim(nombre) <> ''),
  storage_path text not null unique check (btrim(storage_path) <> ''),
  mime text,
  tamano_bytes bigint check (tamano_bytes is null or tamano_bytes > 0),
  fecha_emision date,
  fecha_caducidad date,
  activo boolean not null default true,
  motivo_baja text,
  subido_por uuid not null references public.perfiles(id) on delete restrict,
  dado_de_baja_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (fecha_caducidad is null or fecha_emision is null
         or fecha_caducidad >= fecha_emision),
  check (activo or btrim(coalesce(motivo_baja, '')) <> '')
);

-- Una sola firma y una sola foto vigentes por empleado.
create unique index if not exists uq_empleado_documento_unico_vigente
  on public.empleado_documentos(empleado_id, tipo)
  where activo and tipo in ('firma', 'foto');

-- ------------------------------------------------------------
-- 5. Parametros anuales
-- ------------------------------------------------------------
-- Los porcentajes cambian por normativa: nunca se escriben en el codigo.
-- No se siembra ningun anio a proposito. Un SBU equivocado corrompe todos
-- los decimos cuartos del ejercicio; lo carga Fidel con el valor vigente.
create table if not exists public.nomina_parametros (
  anio integer primary key check (anio between 2000 and 2100),
  salario_basico_unificado numeric(14,2) not null check (salario_basico_unificado > 0),
  pct_aporte_personal numeric(6,4) not null default 9.4500
    check (pct_aporte_personal >= 0 and pct_aporte_personal < 100),
  pct_aporte_patronal numeric(6,4) not null default 11.1500
    check (pct_aporte_patronal >= 0 and pct_aporte_patronal < 100),
  pct_fondos_reserva numeric(6,4) not null default 8.3300
    check (pct_fondos_reserva >= 0 and pct_fondos_reserva < 100),
  pct_iece numeric(6,4) not null default 0.5000
    check (pct_iece >= 0 and pct_iece < 100),
  pct_secap numeric(6,4) not null default 0.5000
    check (pct_secap >= 0 and pct_secap < 100),
  horas_jornada_semanal numeric(6,2) not null default 40
    check (horas_jornada_semanal > 0 and horas_jornada_semanal <= 60),
  tope_multa_pct numeric(6,4) not null default 10.0000
    check (tope_multa_pct >= 0 and tope_multa_pct <= 100),
  tope_descuento_total_pct numeric(6,4) not null default 50.0000
    check (tope_descuento_total_pct > 0 and tope_descuento_total_pct <= 100),
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 6. Auditoria del modulo
-- ------------------------------------------------------------
create table if not exists public.nomina_eventos (
  id uuid primary key default gen_random_uuid(),
  entidad text not null check (entidad in (
    'empleado', 'afiliacion', 'compensacion', 'documento', 'parametros'
  )),
  entidad_id uuid,
  empleado_id uuid references public.empleados(id) on delete restrict,
  tipo text not null check (btrim(tipo) <> ''),
  detalle text,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_empleados_grupo_estado
  on public.empleados(grupo_id, estado, apellidos, nombres);
create index if not exists idx_empleados_identificacion
  on public.empleados(identificacion);
create index if not exists idx_empleado_afiliaciones_empleado
  on public.empleado_afiliaciones(empleado_id, fecha_desde desc);
create index if not exists idx_empleado_afiliaciones_empresa
  on public.empleado_afiliaciones(empresa_id, fecha_desde desc);
create index if not exists idx_empleado_compensacion_empleado
  on public.empleado_compensacion(empleado_id, fecha_desde desc);
create index if not exists idx_empleado_compensacion_empresa
  on public.empleado_compensacion(empresa_pagadora_id, fecha_desde desc);
create index if not exists idx_empleado_documentos_empleado
  on public.empleado_documentos(empleado_id, tipo, created_at desc);
create index if not exists idx_empleado_documentos_caducidad
  on public.empleado_documentos(fecha_caducidad)
  where activo and fecha_caducidad is not null;
create index if not exists idx_nomina_eventos_empleado
  on public.nomina_eventos(empleado_id, created_at desc);

-- ------------------------------------------------------------
-- 7. Control de acceso
-- ------------------------------------------------------------
-- Cedulas, sueldos reales y la brecha por persona son el dato mas sensible
-- del sistema. Solo admin, gerencia y nomina entran; gerencia solo lee.
-- Se compara rol::text para no depender de que el valor del enum ya exista.
create or replace function public.usuario_puede_nomina(
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text in ('admin', 'nomina')
        or (not p_escritura and p.rol::text = 'gerencia')
      )
  );
$$;

-- Digito verificador de cedula ecuatoriana (modulo 10). Se valida en el RPC,
-- no como CHECK, para no bloquear la carga inicial ni a extranjeros con
-- pasaporte.
create or replace function public.es_cedula_ecuatoriana(p_cedula text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_cedula text := btrim(coalesce(p_cedula, ''));
  v_provincia integer;
  v_suma integer := 0;
  v_digito integer;
  v_verificador integer;
  i integer;
begin
  if v_cedula !~ '^[0-9]{10}$' then return false; end if;
  v_provincia := substr(v_cedula, 1, 2)::integer;
  if v_provincia < 1 or (v_provincia > 24 and v_provincia <> 30) then
    return false;
  end if;
  if substr(v_cedula, 3, 1)::integer > 5 then return false; end if;

  for i in 1..9 loop
    v_digito := substr(v_cedula, i, 1)::integer;
    if i % 2 = 1 then
      v_digito := v_digito * 2;
      if v_digito > 9 then v_digito := v_digito - 9; end if;
    end if;
    v_suma := v_suma + v_digito;
  end loop;

  v_verificador := (10 - (v_suma % 10)) % 10;
  return v_verificador = substr(v_cedula, 10, 1)::integer;
end;
$$;

alter table public.empleados enable row level security;
alter table public.empleado_afiliaciones enable row level security;
alter table public.empleado_compensacion enable row level security;
alter table public.empleado_documentos enable row level security;
alter table public.nomina_parametros enable row level security;
alter table public.nomina_eventos enable row level security;

-- Solo lectura via policy. Toda escritura pasa por los RPC de abajo.
drop policy if exists "leer_empleados_v26" on public.empleados;
create policy "leer_empleados_v26" on public.empleados
for select to authenticated using (public.usuario_puede_nomina(false));

drop policy if exists "leer_empleado_afiliaciones_v26" on public.empleado_afiliaciones;
create policy "leer_empleado_afiliaciones_v26" on public.empleado_afiliaciones
for select to authenticated using (public.usuario_puede_nomina(false));

drop policy if exists "leer_empleado_compensacion_v26" on public.empleado_compensacion;
create policy "leer_empleado_compensacion_v26" on public.empleado_compensacion
for select to authenticated using (public.usuario_puede_nomina(false));

drop policy if exists "leer_empleado_documentos_v26" on public.empleado_documentos;
create policy "leer_empleado_documentos_v26" on public.empleado_documentos
for select to authenticated using (public.usuario_puede_nomina(false));

drop policy if exists "leer_nomina_parametros_v26" on public.nomina_parametros;
create policy "leer_nomina_parametros_v26" on public.nomina_parametros
for select to authenticated using (public.usuario_puede_nomina(false));

drop policy if exists "leer_nomina_eventos_v26" on public.nomina_eventos;
create policy "leer_nomina_eventos_v26" on public.nomina_eventos
for select to authenticated using (public.usuario_puede_nomina(false));

-- ------------------------------------------------------------
-- 8. Registro de personal
-- ------------------------------------------------------------
create or replace function public.registrar_evento_nomina_v26(
  p_entidad text,
  p_entidad_id uuid,
  p_empleado_id uuid,
  p_tipo text,
  p_detalle text default null
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.nomina_eventos (
    entidad, entidad_id, empleado_id, tipo, detalle, usuario_id
  ) values (
    p_entidad, p_entidad_id, p_empleado_id, p_tipo,
    nullif(btrim(p_detalle), ''), auth.uid()
  );
$$;

create or replace function public.guardar_empleado_v26(
  p_empleado_id uuid,
  p_grupo_id uuid,
  p_tipo_identificacion text,
  p_identificacion text,
  p_nombres text,
  p_apellidos text,
  p_fecha_ingreso_real date,
  p_cargo text,
  p_fecha_nacimiento date default null,
  p_estado_civil text default null,
  p_direccion text default null,
  p_telefono text default null,
  p_email text default null,
  p_contacto_emergencia_nombre text default null,
  p_contacto_emergencia_telefono text default null,
  p_area text default null,
  p_tipo_contrato text default 'indefinido',
  p_forma_pago text default 'transferencia',
  p_banco text default null,
  p_tipo_cuenta text default null,
  p_numero_cuenta text default null,
  p_observacion text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_identificacion text := upper(btrim(coalesce(p_identificacion, '')));
  v_es_nuevo boolean := p_empleado_id is null;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden gestionar personal';
  end if;
  if not exists (
    select 1 from public.grupos_economicos where id = p_grupo_id and activo
  ) then raise exception 'El grupo economico no existe o esta inactivo'; end if;

  if p_tipo_identificacion not in ('cedula', 'pasaporte') then
    raise exception 'El tipo de identificacion no es valido';
  end if;
  if p_tipo_identificacion = 'cedula'
     and not public.es_cedula_ecuatoriana(v_identificacion) then
    raise exception 'La cedula % no es valida', v_identificacion;
  end if;
  if p_tipo_identificacion = 'pasaporte'
     and length(v_identificacion) not between 5 and 30 then
    raise exception 'El pasaporte debe tener entre 5 y 30 caracteres';
  end if;
  if btrim(coalesce(p_nombres, '')) = '' or btrim(coalesce(p_apellidos, '')) = '' then
    raise exception 'Nombres y apellidos son obligatorios';
  end if;
  if p_fecha_ingreso_real is null then
    raise exception 'La fecha de ingreso real es obligatoria';
  end if;
  if p_fecha_ingreso_real > current_date then
    raise exception 'La fecha de ingreso real no puede ser futura';
  end if;
  if p_fecha_nacimiento is not null
     and p_fecha_nacimiento > p_fecha_ingreso_real - interval '15 years' then
    raise exception 'La fecha de nacimiento no es coherente con la de ingreso';
  end if;
  if btrim(coalesce(p_cargo, '')) = '' then
    raise exception 'El cargo es obligatorio';
  end if;
  if p_forma_pago = 'transferencia'
     and (btrim(coalesce(p_banco, '')) = '' or btrim(coalesce(p_numero_cuenta, '')) = '') then
    raise exception 'El pago por transferencia exige banco y numero de cuenta';
  end if;

  if v_es_nuevo then
    insert into public.empleados (
      grupo_id, tipo_identificacion, identificacion, nombres, apellidos,
      fecha_nacimiento, estado_civil, direccion, telefono, email,
      contacto_emergencia_nombre, contacto_emergencia_telefono,
      fecha_ingreso_real, cargo, area, tipo_contrato, forma_pago,
      banco, tipo_cuenta, numero_cuenta, observacion,
      creado_por, actualizado_por
    ) values (
      p_grupo_id, p_tipo_identificacion, v_identificacion,
      btrim(p_nombres), btrim(p_apellidos),
      p_fecha_nacimiento, p_estado_civil, nullif(btrim(p_direccion), ''),
      nullif(btrim(p_telefono), ''), nullif(btrim(p_email), ''),
      nullif(btrim(p_contacto_emergencia_nombre), ''),
      nullif(btrim(p_contacto_emergencia_telefono), ''),
      p_fecha_ingreso_real, btrim(p_cargo), nullif(btrim(p_area), ''),
      coalesce(p_tipo_contrato, 'indefinido'),
      coalesce(p_forma_pago, 'transferencia'),
      nullif(btrim(p_banco), ''), p_tipo_cuenta, nullif(btrim(p_numero_cuenta), ''),
      nullif(btrim(p_observacion), ''),
      auth.uid(), auth.uid()
    ) returning id into v_id;
  else
    update public.empleados
    set tipo_identificacion = p_tipo_identificacion,
        identificacion = v_identificacion,
        nombres = btrim(p_nombres),
        apellidos = btrim(p_apellidos),
        fecha_nacimiento = p_fecha_nacimiento,
        estado_civil = p_estado_civil,
        direccion = nullif(btrim(p_direccion), ''),
        telefono = nullif(btrim(p_telefono), ''),
        email = nullif(btrim(p_email), ''),
        contacto_emergencia_nombre = nullif(btrim(p_contacto_emergencia_nombre), ''),
        contacto_emergencia_telefono = nullif(btrim(p_contacto_emergencia_telefono), ''),
        fecha_ingreso_real = p_fecha_ingreso_real,
        cargo = btrim(p_cargo),
        area = nullif(btrim(p_area), ''),
        tipo_contrato = coalesce(p_tipo_contrato, 'indefinido'),
        forma_pago = coalesce(p_forma_pago, 'transferencia'),
        banco = nullif(btrim(p_banco), ''),
        tipo_cuenta = p_tipo_cuenta,
        numero_cuenta = nullif(btrim(p_numero_cuenta), ''),
        observacion = nullif(btrim(p_observacion), ''),
        actualizado_por = auth.uid(),
        updated_at = now()
    where id = p_empleado_id
    returning id into v_id;
    if not found then raise exception 'El empleado no existe'; end if;
  end if;

  perform public.registrar_evento_nomina_v26(
    'empleado', v_id, v_id,
    case when v_es_nuevo then 'creado' else 'actualizado' end,
    null
  );
  return v_id;
end;
$$;

-- Da de baja al empleado sin borrarlo: el expediente y el historial de roles
-- deben sobrevivir a la salida.
create or replace function public.dar_baja_empleado_v26(
  p_empleado_id uuid,
  p_fecha_salida date,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ingreso date;
  v_estado text;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden dar de baja personal';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo de la salida es obligatorio';
  end if;

  select fecha_ingreso_real, estado into v_ingreso, v_estado
  from public.empleados where id = p_empleado_id;
  if not found then raise exception 'El empleado no existe'; end if;
  if v_estado = 'liquidado' then
    raise exception 'El empleado ya fue liquidado';
  end if;
  if p_fecha_salida is null or p_fecha_salida < v_ingreso then
    raise exception 'La fecha de salida no puede ser anterior al ingreso';
  end if;

  update public.empleados
  set estado = 'liquidado', fecha_salida = p_fecha_salida,
      actualizado_por = auth.uid(), updated_at = now()
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

  perform public.registrar_evento_nomina_v26(
    'empleado', p_empleado_id, p_empleado_id, 'baja', btrim(p_motivo)
  );
end;
$$;

-- ------------------------------------------------------------
-- 9. Afiliacion y compensacion
-- ------------------------------------------------------------
-- Ambas cierran la vigente el dia anterior y abren la nueva. Llevan clave de
-- idempotencia porque duplicar una fila corrompe el historial, no solo la
-- pantalla.
create or replace function public.registrar_afiliacion_v26(
  p_empleado_id uuid,
  p_afiliado boolean,
  p_empresa_id uuid,
  p_fecha_afiliacion date,
  p_sueldo_declarado numeric,
  p_fecha_desde date,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_ingreso date;
  v_vigente_desde date;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar afiliaciones';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 26)
  );
  select id into v_id from public.empleado_afiliaciones
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

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

  if coalesce(p_afiliado, true) then
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

  -- Cierra la vigente el dia anterior al inicio de la nueva.
  select fecha_desde into v_vigente_desde
  from public.empleado_afiliaciones
  where empleado_id = p_empleado_id and fecha_hasta is null;
  if found then
    if v_vigente_desde >= p_fecha_desde then
      raise exception 'Ya existe una afiliacion vigente desde el %', v_vigente_desde;
    end if;
    update public.empleado_afiliaciones
    set fecha_hasta = p_fecha_desde - 1
    where empleado_id = p_empleado_id and fecha_hasta is null;
  end if;

  insert into public.empleado_afiliaciones (
    empleado_id, afiliado, empresa_id, fecha_afiliacion, sueldo_declarado,
    fecha_desde, motivo, idempotency_key, registrado_por
  ) values (
    p_empleado_id, coalesce(p_afiliado, true),
    case when coalesce(p_afiliado, true) then p_empresa_id end,
    case when coalesce(p_afiliado, true) then p_fecha_afiliacion end,
    case when coalesce(p_afiliado, true) then p_sueldo_declarado else 0 end,
    p_fecha_desde, btrim(p_motivo), p_idempotency_key, auth.uid()
  ) returning id into v_id;

  perform public.registrar_evento_nomina_v26(
    'afiliacion', v_id, p_empleado_id,
    case when coalesce(p_afiliado, true) then 'afiliado' else 'sin_afiliacion' end,
    btrim(p_motivo)
  );
  return v_id;
end;
$$;

create or replace function public.registrar_compensacion_v26(
  p_empleado_id uuid,
  p_empresa_pagadora_id uuid,
  p_sueldo_real numeric,
  p_fecha_desde date,
  p_motivo text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_ingreso date;
  v_vigente_desde date;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar compensaciones';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 26)
  );
  select id into v_id from public.empleado_compensacion
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

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

  select fecha_desde into v_vigente_desde
  from public.empleado_compensacion
  where empleado_id = p_empleado_id and fecha_hasta is null;
  if found then
    if v_vigente_desde >= p_fecha_desde then
      raise exception 'Ya existe una compensacion vigente desde el %', v_vigente_desde;
    end if;
    update public.empleado_compensacion
    set fecha_hasta = p_fecha_desde - 1
    where empleado_id = p_empleado_id and fecha_hasta is null;
  end if;

  insert into public.empleado_compensacion (
    empleado_id, empresa_pagadora_id, sueldo_real, fecha_desde,
    motivo, idempotency_key, registrado_por
  ) values (
    p_empleado_id, p_empresa_pagadora_id, p_sueldo_real, p_fecha_desde,
    btrim(p_motivo), p_idempotency_key, auth.uid()
  ) returning id into v_id;

  perform public.registrar_evento_nomina_v26(
    'compensacion', v_id, p_empleado_id, 'sueldo_registrado', btrim(p_motivo)
  );
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 10. Expediente
-- ------------------------------------------------------------
create or replace function public.registrar_documento_empleado_v26(
  p_empleado_id uuid,
  p_tipo text,
  p_nombre text,
  p_storage_path text,
  p_mime text default null,
  p_tamano_bytes bigint default null,
  p_fecha_emision date default null,
  p_fecha_caducidad date default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_path text := btrim(coalesce(p_storage_path, ''));
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden cargar documentos';
  end if;
  if not exists (select 1 from public.empleados where id = p_empleado_id) then
    raise exception 'El empleado no existe';
  end if;
  if btrim(coalesce(p_nombre, '')) = '' then
    raise exception 'El nombre del documento es obligatorio';
  end if;
  -- El path debe apuntar a la carpeta del propio empleado.
  if v_path <> 'empleados/' || p_empleado_id::text || '/'
       || split_part(v_path, '/', 3)
     or split_part(v_path, '/', 3) = '' then
    raise exception 'La ruta del documento debe ser empleados/<id_empleado>/<archivo>';
  end if;

  -- Firma y foto son unicas vigentes: la anterior se archiva sola.
  if p_tipo in ('firma', 'foto') then
    update public.empleado_documentos
    set activo = false,
        motivo_baja = 'Reemplazado por una version mas reciente',
        dado_de_baja_por = auth.uid()
    where empleado_id = p_empleado_id and tipo = p_tipo and activo;
  end if;

  insert into public.empleado_documentos (
    empleado_id, tipo, nombre, storage_path, mime, tamano_bytes,
    fecha_emision, fecha_caducidad, subido_por
  ) values (
    p_empleado_id, p_tipo, btrim(p_nombre), v_path,
    nullif(btrim(p_mime), ''), p_tamano_bytes,
    p_fecha_emision, p_fecha_caducidad, auth.uid()
  ) returning id into v_id;

  perform public.registrar_evento_nomina_v26(
    'documento', v_id, p_empleado_id, 'documento_cargado', p_tipo
  );
  return v_id;
end;
$$;

-- No se borra nada del expediente: se archiva con motivo.
create or replace function public.archivar_documento_empleado_v26(
  p_documento_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empleado_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden archivar documentos';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo para archivar el documento es obligatorio';
  end if;

  update public.empleado_documentos
  set activo = false, motivo_baja = btrim(p_motivo),
      dado_de_baja_por = auth.uid()
  where id = p_documento_id and activo
  returning empleado_id into v_empleado_id;
  if not found then
    raise exception 'El documento no existe o ya estaba archivado';
  end if;

  perform public.registrar_evento_nomina_v26(
    'documento', p_documento_id, v_empleado_id, 'documento_archivado', btrim(p_motivo)
  );
end;
$$;

-- Deja rastro de quien abre un expediente completo. La UI la llama al entrar
-- a la ficha; las lecturas de lista no se registran.
-- ponytail: auditoria de lectura solo en el expediente, no en cada select.
create or replace function public.registrar_consulta_expediente_v26(
  p_empleado_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.usuario_puede_nomina(false) then
    raise exception 'No tiene acceso al expediente';
  end if;
  perform public.registrar_evento_nomina_v26(
    'empleado', p_empleado_id, p_empleado_id, 'expediente_consultado', null
  );
end;
$$;

-- ------------------------------------------------------------
-- 11. Parametros anuales
-- ------------------------------------------------------------
create or replace function public.guardar_nomina_parametros_v26(
  p_anio integer,
  p_salario_basico_unificado numeric,
  p_pct_aporte_personal numeric default 9.45,
  p_pct_aporte_patronal numeric default 11.15,
  p_pct_fondos_reserva numeric default 8.33,
  p_pct_iece numeric default 0.50,
  p_pct_secap numeric default 0.50,
  p_horas_jornada_semanal numeric default 40,
  p_tope_multa_pct numeric default 10.00,
  p_tope_descuento_total_pct numeric default 50.00
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede cambiar los parametros de nomina';
  end if;
  if coalesce(p_salario_basico_unificado, 0) <= 0 then
    raise exception 'El salario basico unificado debe ser mayor a cero';
  end if;

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
    'parametros', null, null, 'parametros_guardados', p_anio::text
  );
  return p_anio;
end;
$$;

-- ------------------------------------------------------------
-- 12. Vista operativa
-- ------------------------------------------------------------
-- Estado actual de cada persona: afiliacion vigente, compensacion vigente y
-- la brecha entre lo real y lo declarado. Base de la pantalla de personal.
-- security_invoker obligatorio: sin el, la vista se saltaria el RLS de las
-- tablas base y cualquier usuario autenticado leeria sueldos reales.
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
    as paga_otro_ruc
from public.empleados e
left join public.empleado_afiliaciones a
  on a.empleado_id = e.id and a.fecha_hasta is null
left join public.empleado_compensacion c
  on c.empleado_id = e.id and c.fecha_hasta is null
left join public.empresas emp_af on emp_af.id = a.empresa_id
left join public.empresas emp_pg on emp_pg.id = c.empresa_pagadora_id;

-- Documentos por vencer dentro de 60 dias, para las alertas del expediente.
create or replace view public.vista_documentos_por_vencer
with (security_invoker = true) as
select
  d.id as documento_id,
  d.empleado_id,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  d.tipo,
  d.nombre,
  d.fecha_caducidad,
  d.fecha_caducidad - current_date as dias_restantes
from public.empleado_documentos d
join public.empleados e on e.id = d.empleado_id
where d.activo
  and d.fecha_caducidad is not null
  and d.fecha_caducidad <= current_date + 60
  and e.estado = 'activo';

-- ------------------------------------------------------------
-- 13. Bucket privado del expediente
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('expedientes', 'expedientes', false)
on conflict (id) do update set public = false;

drop policy if exists "leer_expedientes_v26" on storage.objects;
create policy "leer_expedientes_v26" on storage.objects
for select to authenticated
using (bucket_id = 'expedientes' and public.usuario_puede_nomina(false));

drop policy if exists "cargar_expedientes_v26" on storage.objects;
create policy "cargar_expedientes_v26" on storage.objects
for insert to authenticated
with check (bucket_id = 'expedientes' and public.usuario_puede_nomina(true));

drop policy if exists "actualizar_expedientes_v26" on storage.objects;
create policy "actualizar_expedientes_v26" on storage.objects
for update to authenticated
using (bucket_id = 'expedientes' and public.usuario_puede_nomina(true))
with check (bucket_id = 'expedientes' and public.usuario_puede_nomina(true));

-- No se entrega delete: el expediente se archiva, no se borra.

-- ------------------------------------------------------------
-- 14. Propiedad y permisos
-- ------------------------------------------------------------
alter function public.usuario_puede_nomina(boolean) owner to postgres;
alter function public.es_cedula_ecuatoriana(text) owner to postgres;
alter function public.registrar_evento_nomina_v26(text, uuid, uuid, text, text) owner to postgres;
alter function public.guardar_empleado_v26(uuid, uuid, text, text, text, text, date, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text) owner to postgres;
alter function public.dar_baja_empleado_v26(uuid, date, text) owner to postgres;
alter function public.registrar_afiliacion_v26(uuid, boolean, uuid, date, numeric, date, text, uuid) owner to postgres;
alter function public.registrar_compensacion_v26(uuid, uuid, numeric, date, text, uuid) owner to postgres;
alter function public.registrar_documento_empleado_v26(uuid, text, text, text, text, bigint, date, date) owner to postgres;
alter function public.archivar_documento_empleado_v26(uuid, text) owner to postgres;
alter function public.registrar_consulta_expediente_v26(uuid) owner to postgres;
alter function public.guardar_nomina_parametros_v26(integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) owner to postgres;

revoke all on public.empleados from public, anon;
revoke all on public.empleado_afiliaciones from public, anon;
revoke all on public.empleado_compensacion from public, anon;
revoke all on public.empleado_documentos from public, anon;
revoke all on public.nomina_parametros from public, anon;
revoke all on public.nomina_eventos from public, anon;
revoke all on public.vista_personal_vigente from public, anon;
revoke all on public.vista_documentos_por_vencer from public, anon;

grant select on public.empleados to authenticated;
grant select on public.empleado_afiliaciones to authenticated;
grant select on public.empleado_compensacion to authenticated;
grant select on public.empleado_documentos to authenticated;
grant select on public.nomina_parametros to authenticated;
grant select on public.nomina_eventos to authenticated;
grant select on public.vista_personal_vigente to authenticated;
grant select on public.vista_documentos_por_vencer to authenticated;

-- El registro de eventos solo se invoca desde los RPC de este archivo.
revoke execute on function public.registrar_evento_nomina_v26(text, uuid, uuid, text, text)
  from public, anon, authenticated;

revoke execute on function public.usuario_puede_nomina(boolean) from public, anon;
revoke execute on function public.es_cedula_ecuatoriana(text) from public, anon;
revoke execute on function public.guardar_empleado_v26(uuid, uuid, text, text, text, text, date, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text) from public, anon;
revoke execute on function public.dar_baja_empleado_v26(uuid, date, text) from public, anon;
revoke execute on function public.registrar_afiliacion_v26(uuid, boolean, uuid, date, numeric, date, text, uuid) from public, anon;
revoke execute on function public.registrar_compensacion_v26(uuid, uuid, numeric, date, text, uuid) from public, anon;
revoke execute on function public.registrar_documento_empleado_v26(uuid, text, text, text, text, bigint, date, date) from public, anon;
revoke execute on function public.archivar_documento_empleado_v26(uuid, text) from public, anon;
revoke execute on function public.registrar_consulta_expediente_v26(uuid) from public, anon;
revoke execute on function public.guardar_nomina_parametros_v26(integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) from public, anon;

grant execute on function public.usuario_puede_nomina(boolean) to authenticated;
grant execute on function public.es_cedula_ecuatoriana(text) to authenticated;
grant execute on function public.guardar_empleado_v26(uuid, uuid, text, text, text, text, date, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text) to authenticated;
grant execute on function public.dar_baja_empleado_v26(uuid, date, text) to authenticated;
grant execute on function public.registrar_afiliacion_v26(uuid, boolean, uuid, date, numeric, date, text, uuid) to authenticated;
grant execute on function public.registrar_compensacion_v26(uuid, uuid, numeric, date, text, uuid) to authenticated;
grant execute on function public.registrar_documento_empleado_v26(uuid, text, text, text, text, bigint, date, date) to authenticated;
grant execute on function public.archivar_documento_empleado_v26(uuid, text) to authenticated;
grant execute on function public.registrar_consulta_expediente_v26(uuid) to authenticated;
grant execute on function public.guardar_nomina_parametros_v26(integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) to authenticated;

notify pgrst, 'reload schema';
