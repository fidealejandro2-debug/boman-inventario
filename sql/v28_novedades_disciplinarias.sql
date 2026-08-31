-- ============================================================
-- BOMAN INVENTARIO - Novedades disciplinarias v28
-- Expediente disciplinario con correlativo verificable por RUC, ciclo de
-- notificacion y descargo, evidencias adjuntas y enlace opcional con la
-- suspension registrada en v27 y con el descuento que crea v29.
-- Ejecutar una sola vez DESPUES de v27.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Novedades
-- ------------------------------------------------------------
-- El correlativo es por empresa y anio: es lo que vuelve verificable el
-- documento impreso que se entrega al trabajador. Se asigna al emitir, no
-- al crear, para que los borradores descartados no dejen huecos.
--
-- empresa_id es el RUC bajo el que se emite. Por defecto la afiliadora
-- vigente del empleado; para el personal no afiliado, la pagadora.
create table if not exists public.novedades_empleado (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empleado_id uuid not null references public.empleados(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  anio integer check (anio is null or anio between 2000 and 2100),
  numero integer check (numero is null or numero > 0),
  tipo text not null check (tipo in (
    'llamado_atencion', 'amonestacion_escrita', 'memorando',
    'acta_compromiso', 'felicitacion', 'sancion_economica',
    'solicitud_visto_bueno'
  )),
  fecha_hechos date not null,
  asunto text not null check (btrim(asunto) <> ''),
  hechos text not null check (btrim(hechos) <> ''),
  base_reglamento text,
  base_legal text,
  descargo_empleado text,
  descargo_at timestamptz,
  resolucion text,
  resuelto_por uuid references public.perfiles(id) on delete restrict,
  resuelto_at timestamptz,
  estado text not null default 'borrador' check (estado in (
    'borrador', 'emitida', 'notificada', 'con_descargo', 'archivada', 'anulada'
  )),
  emitido_at timestamptz,
  emitido_por uuid references public.perfiles(id) on delete restrict,
  notificado_at timestamptz,
  notificado_por uuid references public.perfiles(id) on delete restrict,
  forma_notificacion text check (forma_notificacion in (
    'fisica', 'correo', 'testigos', 'negativa_recibir'
  )),
  firma_empleado_doc_id uuid references public.empleado_documentos(id) on delete restrict,
  documento_pdf_id uuid references public.empleado_documentos(id) on delete restrict,
  -- Suspension disciplinaria registrada como ausencia en v27.
  ausencia_id uuid references public.ausencias(id) on delete restrict,
  -- Multa. descuento_id queda SIN clave foranea a proposito: la tabla
  -- descuentos_programados la crea v29 y esa migracion agrega la constraint.
  genera_descuento boolean not null default false,
  monto_descuento numeric(14,2) check (monto_descuento is null or monto_descuento > 0),
  descuento_id uuid,
  motivo_anulacion text,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,
  idempotency_key uuid not null unique,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- El correlativo existe desde que se emite y nunca antes.
  check (
    (estado = 'borrador' and numero is null and anio is null
     and emitido_at is null and emitido_por is null)
    or
    (estado <> 'borrador' and (estado = 'anulada' or numero is not null))
  ),
  check (estado <> 'anulada' or btrim(coalesce(motivo_anulacion, '')) <> ''),
  check (
    (estado in ('notificada', 'con_descargo', 'archivada')
     and notificado_at is not null and forma_notificacion is not null)
    or estado not in ('notificada', 'con_descargo', 'archivada')
  ),
  check (
    (estado = 'con_descargo' and btrim(coalesce(descargo_empleado, '')) <> '')
    or estado <> 'con_descargo'
  ),
  -- Una multa exige monto; sin multa no puede haber monto suelto.
  check (
    (genera_descuento and monto_descuento is not null)
    or (not genera_descuento and monto_descuento is null and descuento_id is null)
  ),
  -- Una felicitacion no descuenta ni suspende.
  check (
    tipo <> 'felicitacion'
    or (not genera_descuento and ausencia_id is null)
  )
);

-- Correlativo unico por RUC y anio.
create unique index if not exists uq_novedades_correlativo_v28
  on public.novedades_empleado(empresa_id, anio, numero)
  where numero is not null;

-- Evidencias del expediente: fotos, actas, informes. El PDF generado y la
-- firma escaneada viajan en sus propias columnas.
create table if not exists public.novedad_documentos (
  novedad_id uuid not null references public.novedades_empleado(id) on delete restrict,
  documento_id uuid not null references public.empleado_documentos(id) on delete restrict,
  descripcion text,
  adjuntado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (novedad_id, documento_id)
);

-- Amplia la auditoria transversal de v26 sin reescribir su historia,
-- igual que hizo v27.
alter table public.nomina_eventos
  drop constraint if exists nomina_eventos_entidad_check;
alter table public.nomina_eventos
  add constraint nomina_eventos_entidad_check check (entidad in (
    'empleado', 'afiliacion', 'compensacion', 'documento', 'parametros',
    'calendario_feriados', 'periodos_vacaciones', 'ausencia', 'novedad'
  ));

create index if not exists idx_novedades_empleado_fecha_v28
  on public.novedades_empleado(empleado_id, fecha_hechos desc, estado);
create index if not exists idx_novedades_empresa_estado_v28
  on public.novedades_empleado(empresa_id, anio, estado);
create index if not exists idx_novedades_reincidencia_v28
  on public.novedades_empleado(empleado_id, tipo, fecha_hechos desc)
  where estado in ('emitida', 'notificada', 'con_descargo', 'archivada');
create index if not exists idx_novedad_documentos_documento_v28
  on public.novedad_documentos(documento_id);

comment on column public.novedades_empleado.numero is
  'Correlativo por empresa y anio. Se asigna al emitir; los borradores no consumen numero.';
comment on column public.novedades_empleado.descuento_id is
  'Descuento generado por la multa. Sin FK hasta que v29 cree descuentos_programados.';
comment on column public.novedades_empleado.fecha_hechos is
  'Cuando ocurrio el hecho, no cuando se redacto el documento.';

-- ------------------------------------------------------------
-- 2. Acceso
-- ------------------------------------------------------------
alter table public.novedades_empleado enable row level security;
alter table public.novedad_documentos enable row level security;

drop policy if exists "leer_novedades_v28" on public.novedades_empleado;
create policy "leer_novedades_v28"
on public.novedades_empleado for select to authenticated using (
  public.usuario_puede_nomina(false)
);

drop policy if exists "leer_novedad_documentos_v28" on public.novedad_documentos;
create policy "leer_novedad_documentos_v28"
on public.novedad_documentos for select to authenticated using (
  public.usuario_puede_nomina(false)
);

-- ------------------------------------------------------------
-- 3. Tope de la multa
-- ------------------------------------------------------------
-- tope_multa_pct se interpreta sobre la remuneracion MENSUAL vigente. Se usa
-- el sueldo real porque es lo que la persona efectivamente percibe; si no
-- hay compensacion vigente se cae al declarado. Solo procede la multa que
-- este prevista en el reglamento interno aprobado por el MDT: el Art. 44
-- lit. b) del Codigo del Trabajo prohibe las que no lo esten, y esa
-- verificacion es humana, no automatica.
--
-- Deliberadamente NO es security definer: asi respeta el RLS de
-- empleado_compensacion. Un usuario sin acceso a nomina obtiene null en vez
-- del tope, que dividido por el porcentaje delataria el sueldo real. Las RPC
-- de este archivo la invocan desde su propio contexto definer y si ven todo.
create or replace function public.tope_multa_empleado_v28(
  p_empleado_id uuid,
  p_fecha date default null
) returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  v_fecha date := coalesce(p_fecha, current_date);
  v_sueldo numeric(14,2);
  v_pct numeric(6,4);
begin
  select c.sueldo_real into v_sueldo
  from public.empleado_compensacion c
  where c.empleado_id = p_empleado_id
    and c.fecha_desde <= v_fecha
    and (c.fecha_hasta is null or c.fecha_hasta >= v_fecha)
  order by c.fecha_desde desc
  limit 1;

  if v_sueldo is null then
    select a.sueldo_declarado into v_sueldo
    from public.empleado_afiliaciones a
    where a.empleado_id = p_empleado_id
      and a.fecha_desde <= v_fecha
      and (a.fecha_hasta is null or a.fecha_hasta >= v_fecha)
    order by a.fecha_desde desc
    limit 1;
  end if;

  if coalesce(v_sueldo, 0) <= 0 then
    return null;
  end if;

  select p.tope_multa_pct into v_pct
  from public.nomina_parametros p
  where p.anio = extract(year from v_fecha)::integer;

  if v_pct is null then
    raise exception 'No hay parametros de nomina cargados para el anio %',
      extract(year from v_fecha)::integer;
  end if;

  return round(v_sueldo * v_pct / 100, 2);
end;
$$;

-- ------------------------------------------------------------
-- 4. Redaccion y emision
-- ------------------------------------------------------------
create or replace function public.guardar_novedad_v28(
  p_novedad_id uuid,
  p_empleado_id uuid,
  p_empresa_id uuid,
  p_tipo text,
  p_fecha_hechos date,
  p_asunto text,
  p_hechos text,
  p_base_reglamento text,
  p_base_legal text,
  p_genera_descuento boolean,
  p_monto_descuento numeric,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_grupo_id uuid;
  v_ingreso date;
  v_estado text;
  v_tope numeric(14,2);
  v_genera boolean := coalesce(p_genera_descuento, false);
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar novedades';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 28)
  );
  if p_novedad_id is null then
    select id into v_id from public.novedades_empleado
    where idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;

  select e.grupo_id, e.fecha_ingreso_real into v_grupo_id, v_ingreso
  from public.empleados e where e.id = p_empleado_id;
  if not found then raise exception 'El empleado no existe'; end if;

  if not exists (
    select 1 from public.empresas
    where id = p_empresa_id and activo and grupo_id = v_grupo_id
  ) then
    raise exception 'La empresa emisora no existe o no pertenece al grupo';
  end if;
  if btrim(coalesce(p_asunto, '')) = '' then
    raise exception 'El asunto de la novedad es obligatorio';
  end if;
  if btrim(coalesce(p_hechos, '')) = '' then
    raise exception 'La descripcion de los hechos es obligatoria';
  end if;
  if p_fecha_hechos is null then
    raise exception 'La fecha de los hechos es obligatoria';
  end if;
  if p_fecha_hechos > current_date then
    raise exception 'La fecha de los hechos no puede ser futura';
  end if;
  if p_fecha_hechos < v_ingreso then
    raise exception 'La fecha de los hechos es anterior al ingreso del empleado';
  end if;

  if v_genera then
    if p_tipo = 'felicitacion' then
      raise exception 'Una felicitacion no puede generar descuento';
    end if;
    if coalesce(p_monto_descuento, 0) <= 0 then
      raise exception 'La multa debe tener un monto mayor a cero';
    end if;
    v_tope := public.tope_multa_empleado_v28(p_empleado_id, p_fecha_hechos);
    if v_tope is null then
      raise exception 'El empleado no tiene sueldo vigente para calcular el tope de multa';
    end if;
    if p_monto_descuento > v_tope then
      raise exception 'La multa de % supera el tope de % permitido por los parametros',
        p_monto_descuento, v_tope;
    end if;
  end if;

  if p_novedad_id is null then
    insert into public.novedades_empleado (
      grupo_id, empleado_id, empresa_id, tipo, fecha_hechos, asunto, hechos,
      base_reglamento, base_legal, genera_descuento, monto_descuento,
      idempotency_key, creado_por, actualizado_por
    ) values (
      v_grupo_id, p_empleado_id, p_empresa_id, p_tipo, p_fecha_hechos,
      btrim(p_asunto), btrim(p_hechos),
      nullif(btrim(p_base_reglamento), ''), nullif(btrim(p_base_legal), ''),
      v_genera, case when v_genera then p_monto_descuento end,
      p_idempotency_key, auth.uid(), auth.uid()
    ) returning id into v_id;
  else
    select estado into v_estado
    from public.novedades_empleado where id = p_novedad_id;
    if not found then raise exception 'La novedad no existe'; end if;
    if v_estado <> 'borrador' then
      raise exception 'Solo se puede editar una novedad en borrador; esta esta %', v_estado;
    end if;

    update public.novedades_empleado
    set empleado_id = p_empleado_id,
        empresa_id = p_empresa_id,
        grupo_id = v_grupo_id,
        tipo = p_tipo,
        fecha_hechos = p_fecha_hechos,
        asunto = btrim(p_asunto),
        hechos = btrim(p_hechos),
        base_reglamento = nullif(btrim(p_base_reglamento), ''),
        base_legal = nullif(btrim(p_base_legal), ''),
        genera_descuento = v_genera,
        monto_descuento = case when v_genera then p_monto_descuento end,
        actualizado_por = auth.uid(),
        updated_at = now()
    where id = p_novedad_id
    returning id into v_id;
  end if;

  perform public.registrar_evento_nomina_v26(
    'novedad', v_id, p_empleado_id,
    case when p_novedad_id is null then 'novedad_creada' else 'novedad_editada' end,
    p_tipo
  );
  return v_id;
end;
$$;

-- Asigna el correlativo y congela el contenido. A partir de aqui la novedad
-- ya no se edita: si estaba mal, se anula y se emite otra.
create or replace function public.emitir_novedad_v28(
  p_novedad_id uuid,
  p_fecha_emision date default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.novedades_empleado%rowtype;
  v_anio integer;
  v_numero integer;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden emitir novedades';
  end if;

  select * into n from public.novedades_empleado where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado <> 'borrador' then
    raise exception 'La novedad ya fue emitida; su estado es %', n.estado;
  end if;

  v_anio := extract(year from coalesce(p_fecha_emision, current_date))::integer;
  if v_anio < extract(year from n.fecha_hechos)::integer then
    raise exception 'La emision no puede ser anterior al anio de los hechos';
  end if;

  -- Serializa la numeracion por RUC y anio para que dos emisiones simultaneas
  -- no reciban el mismo numero.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(n.empresa_id::text || '-' || v_anio::text, 28)
  );
  select coalesce(max(numero), 0) + 1 into v_numero
  from public.novedades_empleado
  where empresa_id = n.empresa_id and anio = v_anio;

  update public.novedades_empleado
  set estado = 'emitida',
      anio = v_anio,
      numero = v_numero,
      emitido_at = now(),
      emitido_por = auth.uid(),
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_novedad_id;

  perform public.registrar_evento_nomina_v26(
    'novedad', p_novedad_id, n.empleado_id, 'novedad_emitida',
    v_anio::text || '-' || lpad(v_numero::text, 4, '0')
  );

  return jsonb_build_object(
    'novedad_id', p_novedad_id, 'anio', v_anio, 'numero', v_numero,
    'referencia', v_anio::text || '-' || lpad(v_numero::text, 4, '0')
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Notificacion, descargo y resolucion
-- ------------------------------------------------------------
-- La negativa a recibir tambien es una forma valida de notificacion: se deja
-- constancia en lugar de dejar el documento sin entregar.
create or replace function public.notificar_novedad_v28(
  p_novedad_id uuid,
  p_forma_notificacion text,
  p_firma_empleado_doc_id uuid default null,
  p_observacion text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.novedades_empleado%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden notificar novedades';
  end if;
  if p_forma_notificacion not in ('fisica', 'correo', 'testigos', 'negativa_recibir') then
    raise exception 'La forma de notificacion no es valida';
  end if;

  select * into n from public.novedades_empleado where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado <> 'emitida' then
    raise exception 'Solo se notifica una novedad emitida; esta esta %', n.estado;
  end if;

  if p_firma_empleado_doc_id is not null and not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_firma_empleado_doc_id and d.empleado_id = n.empleado_id and d.activo
  ) then
    raise exception 'El documento de firma no pertenece al empleado o esta archivado';
  end if;
  if p_forma_notificacion = 'testigos'
     and btrim(coalesce(p_observacion, '')) = '' then
    raise exception 'La notificacion con testigos exige dejar constancia de quienes fueron';
  end if;

  update public.novedades_empleado
  set estado = 'notificada',
      notificado_at = now(),
      notificado_por = auth.uid(),
      forma_notificacion = p_forma_notificacion,
      firma_empleado_doc_id = coalesce(p_firma_empleado_doc_id, firma_empleado_doc_id),
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_novedad_id;

  perform public.registrar_evento_nomina_v26(
    'novedad', p_novedad_id, n.empleado_id, 'novedad_notificada',
    p_forma_notificacion || coalesce(' - ' || btrim(p_observacion), '')
  );
end;
$$;

create or replace function public.registrar_descargo_novedad_v28(
  p_novedad_id uuid,
  p_descargo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.novedades_empleado%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden registrar el descargo';
  end if;
  if btrim(coalesce(p_descargo, '')) = '' then
    raise exception 'El texto del descargo es obligatorio';
  end if;

  select * into n from public.novedades_empleado where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado <> 'notificada' then
    raise exception 'El descargo solo se registra sobre una novedad notificada; esta esta %',
      n.estado;
  end if;

  update public.novedades_empleado
  set estado = 'con_descargo',
      descargo_empleado = btrim(p_descargo),
      descargo_at = now(),
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_novedad_id;

  perform public.registrar_evento_nomina_v26(
    'novedad', p_novedad_id, n.empleado_id, 'descargo_registrado', null
  );
end;
$$;

-- Cierra el caso. Aqui se enlaza la suspension ya registrada en v27 y, si la
-- novedad lleva multa, queda lista para que v29 le cuelgue el descuento.
create or replace function public.resolver_novedad_v28(
  p_novedad_id uuid,
  p_resolucion text,
  p_ausencia_id uuid default null,
  p_documento_pdf_id uuid default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.novedades_empleado%rowtype;
  a public.ausencias%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden resolver novedades';
  end if;
  if btrim(coalesce(p_resolucion, '')) = '' then
    raise exception 'La resolucion es obligatoria';
  end if;

  select * into n from public.novedades_empleado where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado not in ('notificada', 'con_descargo') then
    raise exception 'Solo se resuelve una novedad notificada o con descargo; esta esta %',
      n.estado;
  end if;

  if p_ausencia_id is not null then
    select * into a from public.ausencias where id = p_ausencia_id;
    if not found then raise exception 'La ausencia enlazada no existe'; end if;
    if a.empleado_id <> n.empleado_id then
      raise exception 'La ausencia enlazada pertenece a otro empleado';
    end if;
    if a.tipo <> 'suspension_disciplinaria' then
      raise exception 'Solo se enlaza una ausencia de tipo suspension_disciplinaria';
    end if;
    if a.estado = 'anulada' then
      raise exception 'La ausencia enlazada esta anulada';
    end if;
  end if;

  if p_documento_pdf_id is not null and not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_pdf_id and d.empleado_id = n.empleado_id and d.activo
  ) then
    raise exception 'El PDF de la novedad no pertenece al empleado o esta archivado';
  end if;

  update public.novedades_empleado
  set estado = 'archivada',
      resolucion = btrim(p_resolucion),
      resuelto_por = auth.uid(),
      resuelto_at = now(),
      ausencia_id = coalesce(p_ausencia_id, ausencia_id),
      documento_pdf_id = coalesce(p_documento_pdf_id, documento_pdf_id),
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_novedad_id;

  perform public.registrar_evento_nomina_v26(
    'novedad', p_novedad_id, n.empleado_id, 'novedad_resuelta', btrim(p_resolucion)
  );
end;
$$;

-- No se borra una novedad: se anula con motivo. Si ya tenia correlativo, el
-- numero queda quemado como el de un comprobante anulado; un borrador se
-- anula sin consumir numero.
create or replace function public.anular_novedad_v28(
  p_novedad_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n public.novedades_empleado%rowtype;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede anular una novedad';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo de la anulacion es obligatorio';
  end if;

  select * into n from public.novedades_empleado where id = p_novedad_id for update;
  if not found then raise exception 'La novedad no existe'; end if;
  if n.estado = 'anulada' then
    raise exception 'La novedad ya estaba anulada';
  end if;
  if n.descuento_id is not null then
    raise exception 'La novedad tiene un descuento asociado: reversalo antes de anularla';
  end if;

  update public.novedades_empleado
  set estado = 'anulada',
      motivo_anulacion = btrim(p_motivo),
      anulado_por = auth.uid(),
      anulado_at = now(),
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_novedad_id;

  perform public.registrar_evento_nomina_v26(
    'novedad', p_novedad_id, n.empleado_id, 'novedad_anulada', btrim(p_motivo)
  );
end;
$$;

create or replace function public.adjuntar_documento_novedad_v28(
  p_novedad_id uuid,
  p_documento_id uuid,
  p_descripcion text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empleado_id uuid;
  v_estado text;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden adjuntar evidencias';
  end if;

  select empleado_id, estado into v_empleado_id, v_estado
  from public.novedades_empleado where id = p_novedad_id;
  if not found then raise exception 'La novedad no existe'; end if;
  if v_estado = 'anulada' then
    raise exception 'No se adjuntan evidencias a una novedad anulada';
  end if;
  if not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_id and d.empleado_id = v_empleado_id and d.activo
  ) then
    raise exception 'La evidencia no pertenece al empleado o esta archivada';
  end if;

  insert into public.novedad_documentos (
    novedad_id, documento_id, descripcion, adjuntado_por
  ) values (
    p_novedad_id, p_documento_id, nullif(btrim(p_descripcion), ''), auth.uid()
  ) on conflict (novedad_id, documento_id) do nothing;

  perform public.registrar_evento_nomina_v26(
    'novedad', p_novedad_id, v_empleado_id, 'evidencia_adjuntada', null
  );
end;
$$;

-- ------------------------------------------------------------
-- 6. Reincidencia
-- ------------------------------------------------------------
-- Cuenta las novedades sancionatorias vigentes de un empleado en una ventana
-- movil. Sirve para sustentar un visto bueno (Art. 172 del Codigo del
-- Trabajo), pero la decision es humana: esto informa, no habilita nada.
-- Tampoco es security definer, por la misma razon: sin acceso a nomina
-- devuelve cero en lugar de revelar el historial disciplinario.
create or replace function public.contar_novedades_v28(
  p_empleado_id uuid,
  p_dias integer default 365,
  p_hasta date default null
) returns integer
language sql
stable
set search_path = ''
as $$
  select count(*)::integer
  from public.novedades_empleado n
  where n.empleado_id = p_empleado_id
    and n.estado in ('emitida', 'notificada', 'con_descargo', 'archivada')
    and n.tipo in (
      'llamado_atencion', 'amonestacion_escrita', 'sancion_economica',
      'solicitud_visto_bueno'
    )
    and n.fecha_hechos <= coalesce(p_hasta, current_date)
    and n.fecha_hechos > coalesce(p_hasta, current_date) - coalesce(p_dias, 365);
$$;

-- ------------------------------------------------------------
-- 7. Vistas
-- ------------------------------------------------------------
-- security_invoker obligatorio: sin el, la vista se salta el RLS de las
-- tablas base y cualquier autenticado leeria el expediente disciplinario.
create or replace view public.vista_novedades_v28
with (security_invoker = true) as
select
  n.id as novedad_id,
  n.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  e.cargo,
  e.area,
  n.empresa_id,
  emp.razon_social as empresa,
  emp.ruc,
  n.anio,
  n.numero,
  case when n.numero is not null
    then n.anio::text || '-' || lpad(n.numero::text, 4, '0')
  end as referencia,
  n.tipo,
  n.estado,
  n.fecha_hechos,
  n.asunto,
  n.emitido_at,
  n.notificado_at,
  n.forma_notificacion,
  n.descargo_at is not null as tiene_descargo,
  n.resuelto_at,
  n.genera_descuento,
  n.monto_descuento,
  n.descuento_id is not null as descuento_aplicado,
  n.ausencia_id is not null as genero_suspension
from public.novedades_empleado n
join public.empleados e on e.id = n.empleado_id
join public.empresas emp on emp.id = n.empresa_id;

-- Todo lo que necesita el documento impreso, en una sola fila.
create or replace view public.vista_novedad_impresion_v28
with (security_invoker = true) as
select
  n.id as novedad_id,
  n.anio::text || '-' || lpad(n.numero::text, 4, '0') as referencia,
  n.tipo,
  n.estado,
  n.fecha_hechos,
  n.emitido_at::date as fecha_emision,
  emp.razon_social as empresa,
  emp.ruc,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  e.cargo,
  e.area,
  e.fecha_ingreso_real,
  n.asunto,
  n.hechos,
  n.base_reglamento,
  n.base_legal,
  n.descargo_empleado,
  n.resolucion,
  n.genera_descuento,
  n.monto_descuento,
  firma.storage_path as firma_empleado_path,
  (
    select count(*) from public.novedad_documentos nd where nd.novedad_id = n.id
  ) as evidencias,
  public.contar_novedades_v28(n.empleado_id, 365, n.fecha_hechos) as sanciones_ultimo_anio
from public.novedades_empleado n
join public.empleados e on e.id = n.empleado_id
join public.empresas emp on emp.id = n.empresa_id
left join public.empleado_documentos firma on firma.id = n.firma_empleado_doc_id
where n.numero is not null and n.estado <> 'anulada';

-- Multas emitidas que todavia no tienen descuento. v29 consume esta vista
-- para crear las filas de descuentos_programados.
create or replace view public.vista_multas_pendientes_v28
with (security_invoker = true) as
select
  n.id as novedad_id,
  n.empleado_id,
  n.empresa_id,
  n.anio::text || '-' || lpad(n.numero::text, 4, '0') as referencia,
  n.fecha_hechos,
  n.monto_descuento,
  n.estado
from public.novedades_empleado n
where n.genera_descuento
  and n.descuento_id is null
  and n.estado in ('notificada', 'con_descargo', 'archivada');

-- ------------------------------------------------------------
-- 8. Propiedad y permisos
-- ------------------------------------------------------------
alter function public.tope_multa_empleado_v28(uuid, date) owner to postgres;
alter function public.guardar_novedad_v28(uuid, uuid, uuid, text, date, text, text, text, text, boolean, numeric, uuid) owner to postgres;
alter function public.emitir_novedad_v28(uuid, date) owner to postgres;
alter function public.notificar_novedad_v28(uuid, text, uuid, text) owner to postgres;
alter function public.registrar_descargo_novedad_v28(uuid, text) owner to postgres;
alter function public.resolver_novedad_v28(uuid, text, uuid, uuid) owner to postgres;
alter function public.anular_novedad_v28(uuid, text) owner to postgres;
alter function public.adjuntar_documento_novedad_v28(uuid, uuid, text) owner to postgres;
alter function public.contar_novedades_v28(uuid, integer, date) owner to postgres;

revoke all on public.novedades_empleado from public, anon;
revoke all on public.novedad_documentos from public, anon;
revoke all on public.vista_novedades_v28 from public, anon;
revoke all on public.vista_novedad_impresion_v28 from public, anon;
revoke all on public.vista_multas_pendientes_v28 from public, anon;

grant select on public.novedades_empleado to authenticated;
grant select on public.novedad_documentos to authenticated;
grant select on public.vista_novedades_v28 to authenticated;
grant select on public.vista_novedad_impresion_v28 to authenticated;
grant select on public.vista_multas_pendientes_v28 to authenticated;

revoke execute on function public.tope_multa_empleado_v28(uuid, date) from public, anon;
revoke execute on function public.guardar_novedad_v28(uuid, uuid, uuid, text, date, text, text, text, text, boolean, numeric, uuid) from public, anon;
revoke execute on function public.emitir_novedad_v28(uuid, date) from public, anon;
revoke execute on function public.notificar_novedad_v28(uuid, text, uuid, text) from public, anon;
revoke execute on function public.registrar_descargo_novedad_v28(uuid, text) from public, anon;
revoke execute on function public.resolver_novedad_v28(uuid, text, uuid, uuid) from public, anon;
revoke execute on function public.anular_novedad_v28(uuid, text) from public, anon;
revoke execute on function public.adjuntar_documento_novedad_v28(uuid, uuid, text) from public, anon;
revoke execute on function public.contar_novedades_v28(uuid, integer, date) from public, anon;

grant execute on function public.tope_multa_empleado_v28(uuid, date) to authenticated;
grant execute on function public.guardar_novedad_v28(uuid, uuid, uuid, text, date, text, text, text, text, boolean, numeric, uuid) to authenticated;
grant execute on function public.emitir_novedad_v28(uuid, date) to authenticated;
grant execute on function public.notificar_novedad_v28(uuid, text, uuid, text) to authenticated;
grant execute on function public.registrar_descargo_novedad_v28(uuid, text) to authenticated;
grant execute on function public.resolver_novedad_v28(uuid, text, uuid, uuid) to authenticated;
grant execute on function public.anular_novedad_v28(uuid, text) to authenticated;
grant execute on function public.adjuntar_documento_novedad_v28(uuid, uuid, text) to authenticated;
grant execute on function public.contar_novedades_v28(uuid, integer, date) to authenticated;

notify pgrst, 'reload schema';
