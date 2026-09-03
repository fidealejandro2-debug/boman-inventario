-- ============================================================
-- BOMAN INVENTARIO - v74: novedades de calidad en produccion
--
-- Registra errores, reclamos y reprocesos vinculados a orden, etapa, lote,
-- producto o pedido. La solicitud de descuento nunca descuenta por si sola:
-- Nomina debe generar y tramitar la novedad disciplinaria formal de v28; el
-- descuento posterior conserva los topes y prioridades del motor v29.
-- Ejecutar despues de v73 y antes de verificacion_v74.sql.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.ordenes_produccion') is null
     or to_regclass('public.orden_produccion_etapas') is null
     or to_regclass('public.novedades_empleado') is null
     or to_regclass('public.descuentos_programados') is null
     or to_regclass('public.notificaciones_comunicados') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Faltan v25, v28, v29 o v35. Instalalas antes de v74';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Permisos configurables
-- ------------------------------------------------------------
-- v35 solo admitia codigos de dos segmentos (modulo.accion). Los permisos de
-- calidad son de tres (produccion.calidad.accion) porque son un submodulo de
-- produccion, asi que hay que ampliar el patron antes de insertarlos o el
-- insert se cae con permisos_sistema_codigo_check. Se admiten 2 o 3 segmentos;
-- no mas, para que el codigo siga siendo legible y predecible.
alter table public.permisos_sistema
  drop constraint if exists permisos_sistema_codigo_check;
alter table public.permisos_sistema
  add constraint permisos_sistema_codigo_check
  check (codigo ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,2}$');

insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('produccion.calidad.registrar', 'Produccion', 'Registrar novedades de calidad',
   'Reporta errores, reclamos, reprocesos y evidencia de produccion.', 180),
  ('produccion.calidad.resolver', 'Produccion', 'Resolver novedades de calidad',
   'Analiza causa raiz, define acciones y cierra novedades de calidad.', 181),
  ('produccion.calidad.descuento', 'Produccion', 'Derivar descuentos a Nomina',
   'Convierte una solicitud aprobada de calidad en novedad disciplinaria formal.', 182)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.activo
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos set permitido = true, updated_at = now()
where permiso_codigo = 'produccion.calidad.registrar'
  and rol::text in ('bodega', 'logistica', 'control');
update public.rol_permisos set permitido = true, updated_at = now()
where permiso_codigo = 'produccion.calidad.resolver'
  and rol::text in ('control', 'gerencia');
update public.rol_permisos set permitido = true, updated_at = now()
where permiso_codigo = 'produccion.calidad.descuento'
  and rol::text = 'nomina';

create or replace view public.vista_matriz_permisos_v35
with (security_invoker = true) as
select
  r.rol::text as rol, ps.codigo as permiso_codigo, ps.modulo,
  ps.nombre, ps.descripcion, ps.orden,
  case when r.rol::text = 'admin' then true else coalesce(rp.permitido, false) end
    as permitido,
  r.rol::text <> 'admin' as configurable,
  rp.updated_at
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema ps
left join public.rol_permisos rp
  on rp.rol = r.rol and rp.permiso_codigo = ps.codigo
where ps.activo;

-- ------------------------------------------------------------
-- 2. Novedad, evidencias y eventos
-- ------------------------------------------------------------
create table if not exists public.novedades_calidad_produccion (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  anio integer not null check (anio between 2000 and 2200),
  numero integer not null check (numero > 0),
  codigo text generated always as (
    'NC-' || anio::text || '-' || lpad(numero::text, 6, '0')
  ) stored,
  orden_id uuid references public.ordenes_produccion(id) on delete restrict,
  etapa_id uuid references public.orden_produccion_etapas(id) on delete restrict,
  lote_id uuid references public.lotes_produccion(id) on delete restrict,
  producto_id uuid references public.productos(id) on delete restrict,
  pedido_referencia text,
  formato text not null default 'no_aplica' check (formato in (
    'anterior', 'nuevo', 'no_aplica'
  )),
  origen text not null check (origen in (
    'produccion_interna', 'maquila_externa', 'devolucion_cliente',
    'bodega', 'control_calidad', 'otro'
  )),
  prioridad text not null default 'normal' check (prioridad in ('normal', 'urgente')),
  tipo text not null check (tipo in (
    'error_corte', 'error_costura', 'error_estampado_sublimacion',
    'error_diseno', 'error_sello_tpu_dtf', 'reclamo_cliente',
    'falla_maquila_externa', 'error_ingreso_contrato', 'material_defectuoso',
    'falla_maquinaria', 'otro'
  )),
  fecha_hora timestamptz not null,
  descripcion text not null check (length(btrim(descripcion)) >= 10),
  cantidad_afectada integer not null default 1 check (cantidad_afectada > 0),
  accion_inmediata text,
  responsable_perfil_id uuid references public.perfiles(id) on delete restrict,
  responsable_proveedor_id uuid references public.proveedores(id) on delete restrict,
  empleado_responsable_id uuid references public.empleados(id) on delete restrict,
  estado text not null default 'abierta' check (estado in (
    'abierta', 'en_analisis', 'accion_correctiva', 'cerrada', 'anulada'
  )),
  causa_raiz text,
  accion_correctiva text,
  disposicion text check (disposicion is null or disposicion in (
    'reproceso', 'reemplazo', 'desecho', 'devolucion_proveedor',
    'aceptado_concesion', 'sin_afectacion'
  )),
  costo_estimado numeric(14,2) not null default 0 check (costo_estimado >= 0),
  costo_real numeric(14,2) check (costo_real is null or costo_real >= 0),
  solicita_descuento boolean not null default false,
  monto_descuento_solicitado numeric(14,2),
  motivo_descuento text,
  novedad_empleado_id uuid unique
    references public.novedades_empleado(id) on delete restrict,
  idempotency_key uuid not null unique,
  registrado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  cerrado_por uuid references public.perfiles(id) on delete restrict,
  cerrado_at timestamptz,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,
  motivo_anulacion text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (grupo_id, anio, numero),
  check (etapa_id is null or orden_id is not null),
  check (responsable_perfil_id is null or responsable_proveedor_id is null),
  check (
    (solicita_descuento and empleado_responsable_id is not null
      and monto_descuento_solicitado > 0
      and length(btrim(coalesce(motivo_descuento, ''))) >= 10)
    or (not solicita_descuento and monto_descuento_solicitado is null
      and motivo_descuento is null and novedad_empleado_id is null)
  ),
  check (
    estado <> 'cerrada' or (
      length(btrim(coalesce(causa_raiz, ''))) >= 10
      and length(btrim(coalesce(accion_correctiva, ''))) >= 10
      and disposicion is not null and costo_real is not null
      and cerrado_por is not null and cerrado_at is not null
    )
  ),
  check (
    estado <> 'anulada' or (
      length(btrim(coalesce(motivo_anulacion, ''))) >= 10
      and anulado_por is not null and anulado_at is not null
    )
  )
);

create table if not exists public.novedad_calidad_evidencias (
  id uuid primary key default gen_random_uuid(),
  novedad_id uuid not null
    references public.novedades_calidad_produccion(id) on delete restrict,
  nombre text not null check (length(btrim(nombre)) >= 3),
  referencia text not null check (length(btrim(referencia)) >= 5),
  descripcion text,
  idempotency_key uuid not null unique,
  adjuntado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.novedad_calidad_eventos (
  id uuid primary key default gen_random_uuid(),
  novedad_id uuid not null
    references public.novedades_calidad_produccion(id) on delete restrict,
  tipo text not null check (btrim(tipo) <> ''),
  estado_anterior text,
  estado_nuevo text,
  detalle text not null check (length(btrim(detalle)) >= 5),
  datos jsonb not null default '{}'::jsonb,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_novedades_calidad_estado_v74
  on public.novedades_calidad_produccion(grupo_id, estado, fecha_hora desc);
create index if not exists idx_novedades_calidad_orden_v74
  on public.novedades_calidad_produccion(orden_id, fecha_hora desc)
  where orden_id is not null;
create index if not exists idx_novedades_calidad_empleado_v74
  on public.novedades_calidad_produccion(empleado_responsable_id, fecha_hora desc)
  where empleado_responsable_id is not null;
create index if not exists idx_evidencias_calidad_novedad_v74
  on public.novedad_calidad_evidencias(novedad_id, created_at);

-- ------------------------------------------------------------
-- 3. Acceso y lista laboral limitada a identificacion/nombre
-- ------------------------------------------------------------
create or replace function public.usuario_puede_calidad_v74(
  p_grupo_id uuid,
  p_accion text default 'ver'
) returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select p_grupo_id is not null
    and exists (
      select 1 from public.perfiles p
      where p.id = auth.uid() and p.activo and p.grupo_id = p_grupo_id
    )
    and case p_accion
      when 'ver' then public.usuario_tiene_permiso_v35('produccion.acceder')
        or public.usuario_puede_nomina(false)
      when 'registrar' then public.usuario_tiene_permiso_v35('produccion.calidad.registrar')
      when 'resolver' then public.usuario_tiene_permiso_v35('produccion.calidad.resolver')
      when 'descuento' then public.usuario_tiene_permiso_v35('produccion.calidad.descuento')
        and public.usuario_puede_nomina(true)
      else false
    end;
$fn$;

create or replace function public.listar_empleados_calidad_v74()
returns table (id uuid, identificacion text, nombre_completo text)
language sql
stable
security definer
set search_path = ''
as $fn$
  select e.id, e.identificacion, btrim(e.nombres || ' ' || e.apellidos)
  from public.empleados e
  join public.perfiles p on p.id = auth.uid() and p.activo
  where e.grupo_id = p.grupo_id and e.estado = 'activo'
    and public.usuario_puede_calidad_v74(e.grupo_id, 'ver')
  order by e.apellidos, e.nombres;
$fn$;

-- ------------------------------------------------------------
-- 4. Registro de la novedad
-- ------------------------------------------------------------
create or replace function public.registrar_novedad_calidad_v74(
  p_datos jsonb,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
  v_grupo_id uuid;
  v_empresa_id uuid := nullif(p_datos->>'empresa_id', '')::uuid;
  v_orden_id uuid := nullif(p_datos->>'orden_id', '')::uuid;
  v_etapa_id uuid := nullif(p_datos->>'etapa_id', '')::uuid;
  v_lote_id uuid := nullif(p_datos->>'lote_id', '')::uuid;
  v_producto_id uuid := nullif(p_datos->>'producto_id', '')::uuid;
  v_responsable_perfil uuid := nullif(p_datos->>'responsable_perfil_id', '')::uuid;
  v_responsable_proveedor uuid := nullif(p_datos->>'responsable_proveedor_id', '')::uuid;
  v_empleado uuid := nullif(p_datos->>'empleado_responsable_id', '')::uuid;
  v_fecha timestamptz := nullif(p_datos->>'fecha_hora', '')::timestamptz;
  v_anio integer;
  v_numero integer;
  v_solicita boolean := coalesce((p_datos->>'solicita_descuento')::boolean, false);
  v_monto numeric := nullif(p_datos->>'monto_descuento_solicitado', '')::numeric;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.novedades_calidad_produccion
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then
    raise exception 'Los datos de la novedad son obligatorios';
  end if;
  select e.grupo_id into v_grupo_id from public.empresas e
  where e.id = v_empresa_id and e.activo;
  if not found or not public.usuario_puede_calidad_v74(v_grupo_id, 'registrar') then
    raise exception 'No tienes permiso para registrar calidad en esta empresa';
  end if;
  if coalesce(p_datos->>'origen', '') not in (
    'produccion_interna', 'maquila_externa', 'devolucion_cliente',
    'bodega', 'control_calidad', 'otro'
  ) then raise exception 'El origen de la novedad no es valido'; end if;
  if coalesce(p_datos->>'tipo', '') not in (
    'error_corte', 'error_costura', 'error_estampado_sublimacion',
    'error_diseno', 'error_sello_tpu_dtf', 'reclamo_cliente',
    'falla_maquila_externa', 'error_ingreso_contrato', 'material_defectuoso',
    'falla_maquinaria', 'otro'
  ) then raise exception 'El tipo de novedad no es valido'; end if;
  if coalesce(p_datos->>'prioridad', 'normal') not in ('normal', 'urgente') then
    raise exception 'La prioridad no es valida';
  end if;
  if v_fecha is null or v_fecha > now() + interval '5 minutes' then
    raise exception 'La fecha del hecho es obligatoria y no puede ser futura';
  end if;
  if length(btrim(coalesce(p_datos->>'descripcion', ''))) < 10 then
    raise exception 'Describe el error con al menos 10 caracteres';
  end if;
  if coalesce(nullif(p_datos->>'cantidad_afectada', '')::integer, 0) <= 0 then
    raise exception 'La cantidad afectada debe ser mayor que cero';
  end if;
  if coalesce(nullif(p_datos->>'costo_estimado', '')::numeric, 0) < 0 then
    raise exception 'El costo estimado no puede ser negativo';
  end if;
  if coalesce(p_datos->>'formato', 'no_aplica') not in (
    'anterior', 'nuevo', 'no_aplica'
  ) then raise exception 'El formato de la prenda no es valido'; end if;

  if v_orden_id is not null then
    select o.producto_resultado_id into v_producto_id
    from public.ordenes_produccion o
    where o.id = v_orden_id and o.grupo_id = v_grupo_id
      and o.empresa_id = v_empresa_id;
    if not found then raise exception 'La orden no pertenece a la empresa seleccionada'; end if;
  end if;
  if v_etapa_id is not null and not exists (
    select 1 from public.orden_produccion_etapas e
    where e.id = v_etapa_id and e.orden_id = v_orden_id
  ) then raise exception 'La etapa no pertenece a la orden'; end if;
  if v_lote_id is not null and not exists (
    select 1 from public.lotes_produccion l
    where l.id = v_lote_id and l.orden_id = v_orden_id
  ) then raise exception 'El lote no pertenece a la orden'; end if;
  if v_orden_id is null and v_producto_id is null
     and btrim(coalesce(p_datos->>'pedido_referencia', '')) = '' then
    raise exception 'Relaciona la novedad con una orden, producto o pedido';
  end if;
  if v_producto_id is not null and not exists (
    select 1 from public.productos p where p.id = v_producto_id and p.activo
  ) then raise exception 'El producto no existe o esta inactivo'; end if;
  if v_responsable_perfil is not null and not exists (
    select 1 from public.perfiles p
    where p.id = v_responsable_perfil and p.grupo_id = v_grupo_id and p.activo
  ) then raise exception 'El responsable interno no pertenece al grupo'; end if;
  if v_responsable_proveedor is not null and not exists (
    select 1 from public.proveedor_empresas pe
    where pe.proveedor_id = v_responsable_proveedor
      and pe.empresa_id = v_empresa_id and pe.activo
  ) then raise exception 'El proveedor no esta habilitado para la empresa'; end if;
  if v_responsable_perfil is not null and v_responsable_proveedor is not null then
    raise exception 'Selecciona responsable interno o proveedor, no ambos';
  end if;
  if v_empleado is not null and not exists (
    select 1 from public.empleados e
    where e.id = v_empleado and e.grupo_id = v_grupo_id and e.estado = 'activo'
  ) then raise exception 'El empleado responsable no pertenece al grupo o no esta activo'; end if;
  if v_solicita and (
    v_empleado is null or coalesce(v_monto, 0) <= 0
    or length(btrim(coalesce(p_datos->>'motivo_descuento', ''))) < 10
  ) then raise exception 'La solicitud de descuento exige empleado, monto y justificacion'; end if;

  v_anio := extract(year from v_fecha at time zone 'America/Guayaquil')::integer;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_grupo_id::text || '-' || v_anio::text, 74)
  );
  select coalesce(max(numero), 0) + 1 into v_numero
  from public.novedades_calidad_produccion
  where grupo_id = v_grupo_id and anio = v_anio;

  insert into public.novedades_calidad_produccion (
    grupo_id, empresa_id, anio, numero, orden_id, etapa_id, lote_id,
    producto_id, pedido_referencia, formato, origen, prioridad, tipo, fecha_hora,
    descripcion, cantidad_afectada, accion_inmediata,
    responsable_perfil_id, responsable_proveedor_id, empleado_responsable_id,
    costo_estimado, solicita_descuento, monto_descuento_solicitado,
    motivo_descuento, idempotency_key, registrado_por, actualizado_por
  ) values (
    v_grupo_id, v_empresa_id, v_anio, v_numero, v_orden_id, v_etapa_id,
    v_lote_id, v_producto_id, nullif(btrim(p_datos->>'pedido_referencia'), ''),
    coalesce(p_datos->>'formato', 'no_aplica'),
    p_datos->>'origen', coalesce(p_datos->>'prioridad', 'normal'),
    p_datos->>'tipo', v_fecha, btrim(p_datos->>'descripcion'),
    (p_datos->>'cantidad_afectada')::integer,
    nullif(btrim(p_datos->>'accion_inmediata'), ''),
    v_responsable_perfil, v_responsable_proveedor, v_empleado,
    coalesce(nullif(p_datos->>'costo_estimado', '')::numeric, 0),
    v_solicita, case when v_solicita then round(v_monto, 2) end,
    case when v_solicita then btrim(p_datos->>'motivo_descuento') end,
    p_idempotency_key, auth.uid(), auth.uid()
  ) returning id into v_id;

  insert into public.novedad_calidad_eventos (
    novedad_id, tipo, estado_nuevo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_id, 'registrada', 'abierta', 'Novedad de calidad registrada',
    jsonb_build_object('tipo', p_datos->>'tipo', 'origen', p_datos->>'origen',
      'cantidad_afectada', p_datos->>'cantidad_afectada'),
    auth.uid(), p_idempotency_key
  );
  insert into public.notificaciones_comunicados (
    origen_clave, origen_tipo, grupo_id, empresa_id, permiso_requerido,
    modulo, nivel, titulo, mensaje, href, creado_por
  ) values (
    'calidad:resolver:' || v_id::text, 'calidad_novedad', v_grupo_id,
    v_empresa_id, 'produccion.calidad.resolver', 'Produccion',
    case when coalesce(p_datos->>'prioridad', 'normal') = 'urgente'
      then 'critica' else 'accion' end,
    case when coalesce(p_datos->>'prioridad', 'normal') = 'urgente'
      then 'Novedad urgente de calidad' else 'Nueva novedad de calidad' end,
    'El caso ' || ('NC-' || v_anio::text || '-' || lpad(v_numero::text, 6, '0'))
      || ' requiere analisis y accion correctiva.',
    '/produccion/calidad', auth.uid()
  ) on conflict (origen_clave) do update set
    activo = true, nivel = excluded.nivel, titulo = excluded.titulo,
    mensaje = excluded.mensaje, updated_at = now();
  return v_id;
end;
$fn$;

-- ------------------------------------------------------------
-- 5. Analisis, evidencia, cierre y anulacion
-- ------------------------------------------------------------
create or replace function public.resolver_novedad_calidad_v74(
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
  v_estado text := coalesce(p_datos->>'estado', '');
  v_empleado uuid := nullif(p_datos->>'empleado_responsable_id', '')::uuid;
  v_solicita boolean := coalesce((p_datos->>'solicita_descuento')::boolean, false);
  v_monto numeric := nullif(p_datos->>'monto_descuento_solicitado', '')::numeric;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if exists (select 1 from public.novedad_calidad_eventos where idempotency_key = p_idempotency_key) then return; end if;
  select * into n from public.novedades_calidad_produccion
  where id = p_novedad_id for update;
  if not found then raise exception 'La novedad de calidad no existe'; end if;
  if not public.usuario_puede_calidad_v74(n.grupo_id, 'resolver') then
    raise exception 'No tienes permiso para resolver esta novedad';
  end if;
  if n.estado in ('cerrada', 'anulada') then raise exception 'La novedad ya esta cerrada'; end if;
  if v_estado not in ('en_analisis', 'accion_correctiva', 'cerrada') then
    raise exception 'El nuevo estado no es valido';
  end if;
  -- Los CASE van entre parentesis a proposito: PL/pgSQL lee la condicion de un
  -- IF hasta el primer THEN contando solo parentesis, no CASE/END. Sin ellos,
  -- el "then" de "when 'abierta' then 1" corta la condicion y la funcion ni
  -- siquiera compila ("syntax error at end of input").
  if (case n.estado when 'abierta' then 1 when 'en_analisis' then 2 else 3 end)
     > (case v_estado when 'en_analisis' then 2 when 'accion_correctiva' then 3 else 4 end) then
    raise exception 'No se puede retroceder el flujo de calidad';
  end if;
  if v_empleado is not null and not exists (
    select 1 from public.empleados e
    where e.id = v_empleado and e.grupo_id = n.grupo_id and e.estado = 'activo'
  ) then raise exception 'El empleado responsable no pertenece al grupo o no esta activo'; end if;
  if n.novedad_empleado_id is not null and (
    v_solicita <> n.solicita_descuento
    or v_empleado is distinct from n.empleado_responsable_id
    or round(coalesce(v_monto, 0), 2) <> round(coalesce(n.monto_descuento_solicitado, 0), 2)
  ) then raise exception 'La solicitud laboral ya fue generada y no puede alterarse'; end if;
  if v_solicita and (
    v_empleado is null or coalesce(v_monto, 0) <= 0
    or length(btrim(coalesce(p_datos->>'motivo_descuento', ''))) < 10
  ) then raise exception 'La solicitud de descuento exige empleado, monto y justificacion'; end if;
  if nullif(p_datos->>'costo_real', '')::numeric < 0 then
    raise exception 'El costo real no puede ser negativo';
  end if;
  if v_estado = 'cerrada' and (
    length(btrim(coalesce(p_datos->>'causa_raiz', ''))) < 10
    or length(btrim(coalesce(p_datos->>'accion_correctiva', ''))) < 10
    or coalesce(p_datos->>'disposicion', '') not in (
      'reproceso', 'reemplazo', 'desecho', 'devolucion_proveedor',
      'aceptado_concesion', 'sin_afectacion'
    ) or nullif(p_datos->>'costo_real', '')::numeric is null
  ) then raise exception 'Para cerrar registra causa, accion, disposicion y costo real'; end if;

  update public.novedades_calidad_produccion set
    estado = v_estado,
    causa_raiz = nullif(btrim(p_datos->>'causa_raiz'), ''),
    accion_correctiva = nullif(btrim(p_datos->>'accion_correctiva'), ''),
    disposicion = nullif(p_datos->>'disposicion', ''),
    costo_real = nullif(p_datos->>'costo_real', '')::numeric,
    empleado_responsable_id = v_empleado,
    solicita_descuento = v_solicita,
    monto_descuento_solicitado = case when v_solicita then round(v_monto, 2) end,
    motivo_descuento = case when v_solicita then btrim(p_datos->>'motivo_descuento') end,
    actualizado_por = auth.uid(), updated_at = now(),
    cerrado_por = case when v_estado = 'cerrada' then auth.uid() else cerrado_por end,
    cerrado_at = case when v_estado = 'cerrada' then now() else cerrado_at end
  where id = n.id;

  insert into public.novedad_calidad_eventos (
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle,
    datos, usuario_id, idempotency_key
  ) values (
    n.id, case when v_estado = 'cerrada' then 'cerrada' else 'analizada' end,
    n.estado, v_estado, coalesce(nullif(btrim(p_datos->>'detalle'), ''),
      'Analisis de calidad actualizado'),
    jsonb_build_object('disposicion', nullif(p_datos->>'disposicion', ''),
      'costo_real', nullif(p_datos->>'costo_real', ''),
      'solicita_descuento', v_solicita),
    auth.uid(), p_idempotency_key
  );
  if v_estado = 'cerrada' then
    update public.notificaciones_comunicados set activo = false, updated_at = now()
    where origen_clave = 'calidad:resolver:' || n.id::text;
    if v_solicita then
      insert into public.notificaciones_comunicados (
        origen_clave, origen_tipo, grupo_id, empresa_id, permiso_requerido,
        modulo, nivel, titulo, mensaje, href, creado_por
      ) values (
        'calidad:descuento:' || n.id::text, 'calidad_descuento', n.grupo_id,
        n.empresa_id, 'produccion.calidad.descuento', 'Produccion', 'accion',
        'Descuento de calidad por revisar',
        'El caso ' || n.codigo || ' fue cerrado y solicita revisar un descuento por '
          || to_char(round(v_monto, 2), 'FM999999990D00') || ' USD.',
        '/produccion/calidad', auth.uid()
      ) on conflict (origen_clave) do update set
        activo = true, mensaje = excluded.mensaje, updated_at = now();
    end if;
  end if;
end;
$fn$;

create or replace function public.agregar_evidencia_calidad_v74(
  p_novedad_id uuid,
  p_nombre text,
  p_referencia text,
  p_descripcion text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  n public.novedades_calidad_produccion%rowtype;
  v_id uuid;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_id from public.novedad_calidad_evidencias
  where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  select * into n from public.novedades_calidad_produccion where id = p_novedad_id;
  if not found then raise exception 'La novedad de calidad no existe'; end if;
  if not public.usuario_puede_calidad_v74(n.grupo_id, 'registrar')
     and not public.usuario_puede_calidad_v74(n.grupo_id, 'resolver') then
    raise exception 'No tienes permiso para adjuntar evidencia';
  end if;
  if n.estado = 'anulada' then raise exception 'No se adjunta evidencia a una novedad anulada'; end if;
  if length(btrim(coalesce(p_nombre, ''))) < 3
     or length(btrim(coalesce(p_referencia, ''))) < 5 then
    raise exception 'Indica nombre y referencia verificable de la evidencia';
  end if;
  insert into public.novedad_calidad_evidencias (
    novedad_id, nombre, referencia, descripcion,
    idempotency_key, adjuntado_por
  ) values (
    n.id, btrim(p_nombre), btrim(p_referencia), nullif(btrim(p_descripcion), ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;
  insert into public.novedad_calidad_eventos (
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle,
    datos, usuario_id, idempotency_key
  ) values (
    n.id, 'evidencia_adjuntada', n.estado, n.estado,
    'Evidencia adjuntada: ' || btrim(p_nombre),
    jsonb_build_object('evidencia_id', v_id, 'referencia', btrim(p_referencia)),
    auth.uid(), p_idempotency_key
  );
  return v_id;
end;
$fn$;

create or replace function public.anular_novedad_calidad_v74(
  p_novedad_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare n public.novedades_calidad_produccion%rowtype;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if exists (select 1 from public.novedad_calidad_eventos where idempotency_key = p_idempotency_key) then return; end if;
  select * into n from public.novedades_calidad_produccion
  where id = p_novedad_id for update;
  if not found then raise exception 'La novedad de calidad no existe'; end if;
  if not public.usuario_puede_calidad_v74(n.grupo_id, 'resolver') then
    raise exception 'No tienes permiso para anular esta novedad';
  end if;
  if n.estado = 'anulada' then return; end if;
  if n.novedad_empleado_id is not null then
    raise exception 'La novedad ya fue derivada a Nomina; resuelve primero el expediente laboral';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Indica un motivo de anulacion de al menos 10 caracteres';
  end if;
  update public.novedades_calidad_produccion set
    estado = 'anulada', motivo_anulacion = btrim(p_motivo),
    anulado_por = auth.uid(), anulado_at = now(),
    actualizado_por = auth.uid(), updated_at = now()
  where id = n.id;
  update public.notificaciones_comunicados set activo = false, updated_at = now()
  where origen_clave in (
    'calidad:resolver:' || n.id::text,
    'calidad:descuento:' || n.id::text
  );
  insert into public.novedad_calidad_eventos (
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle,
    usuario_id, idempotency_key
  ) values (
    n.id, 'anulada', n.estado, 'anulada', btrim(p_motivo),
    auth.uid(), p_idempotency_key
  );
end;
$fn$;

-- ------------------------------------------------------------
-- 6. Derivacion laboral: crea borrador formal, no aplica el descuento
-- ------------------------------------------------------------
create or replace function public.generar_novedad_laboral_calidad_v74(
  p_novedad_id uuid,
  p_empresa_emisora_id uuid,
  p_base_reglamento text,
  p_base_legal text,
  p_idempotency_key uuid
) returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  n public.novedades_calidad_produccion%rowtype;
  v_novedad_empleado_id uuid;
  v_hechos text;
begin
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select * into n from public.novedades_calidad_produccion
  where id = p_novedad_id for update;
  if not found then raise exception 'La novedad de calidad no existe'; end if;
  if not public.usuario_puede_calidad_v74(n.grupo_id, 'descuento') then
    raise exception 'Solo Administracion o Nomina pueden iniciar el tramite de descuento';
  end if;
  if n.novedad_empleado_id is not null then return n.novedad_empleado_id; end if;
  if n.estado <> 'cerrada' then
    raise exception 'Cierra primero el analisis de calidad antes de derivarlo a Nomina';
  end if;
  if not n.solicita_descuento or n.empleado_responsable_id is null
     or coalesce(n.monto_descuento_solicitado, 0) <= 0 then
    raise exception 'La novedad no contiene una solicitud de descuento completa';
  end if;
  if length(btrim(coalesce(p_base_reglamento, ''))) < 5 then
    raise exception 'Indica la disposicion del reglamento interno aplicable';
  end if;
  v_hechos := concat_ws(E'\n',
    'Referencia de calidad: ' || n.codigo,
    'Descripcion: ' || n.descripcion,
    'Causa raiz: ' || n.causa_raiz,
    'Accion correctiva: ' || n.accion_correctiva,
    'Justificacion solicitada: ' || n.motivo_descuento
  );
  v_novedad_empleado_id := public.guardar_novedad_v28(
    null, n.empleado_responsable_id, p_empresa_emisora_id,
    'sancion_economica', (n.fecha_hora at time zone 'America/Guayaquil')::date,
    'Novedad de calidad ' || n.codigo, v_hechos,
    btrim(p_base_reglamento), nullif(btrim(p_base_legal), ''),
    true, n.monto_descuento_solicitado, p_idempotency_key
  );
  update public.novedades_calidad_produccion set
    novedad_empleado_id = v_novedad_empleado_id,
    actualizado_por = auth.uid(), updated_at = now()
  where id = n.id;
  update public.notificaciones_comunicados set activo = false, updated_at = now()
  where origen_clave = 'calidad:descuento:' || n.id::text;
  insert into public.novedad_calidad_eventos (
    novedad_id, tipo, estado_anterior, estado_nuevo, detalle,
    datos, usuario_id, idempotency_key
  ) values (
    n.id, 'derivada_nomina', n.estado, n.estado,
    'Solicitud derivada al expediente laboral',
    jsonb_build_object('novedad_empleado_id', v_novedad_empleado_id,
      'monto_solicitado', n.monto_descuento_solicitado),
    auth.uid(), p_idempotency_key
  );
  return v_novedad_empleado_id;
end;
$fn$;

-- ------------------------------------------------------------
-- 7. Vista operativa
-- ------------------------------------------------------------
create or replace view public.vista_novedades_calidad_v74
with (security_invoker = true) as
select
  n.id, n.grupo_id, n.empresa_id, n.anio, n.numero, n.codigo,
  n.orden_id, o.numero as orden_numero,
  n.etapa_id, oe.secuencia as etapa_secuencia, oe.nombre as etapa_nombre,
  n.lote_id, l.codigo as lote_codigo,
  n.producto_id, p.sku, p.nombre as producto,
  n.pedido_referencia, n.formato, n.origen, n.prioridad, n.tipo,
  n.fecha_hora, n.descripcion, n.cantidad_afectada, n.accion_inmediata,
  n.responsable_perfil_id, rp.nombre_completo as responsable_interno,
  n.responsable_proveedor_id,
  coalesce(pr.nombre_comercial, pr.razon_social) as responsable_externo,
  n.empleado_responsable_id, n.estado, n.causa_raiz,
  n.accion_correctiva, n.disposicion, n.costo_estimado, n.costo_real,
  n.solicita_descuento, n.monto_descuento_solicitado, n.motivo_descuento,
  n.novedad_empleado_id, ne.estado as novedad_laboral_estado,
  ne.anio as novedad_laboral_anio, ne.numero as novedad_laboral_numero,
  ne.descuento_id, dp.estado as descuento_estado, dp.saldo as descuento_saldo,
  (select count(*)::integer from public.novedad_calidad_evidencias ev
    where ev.novedad_id = n.id) as evidencias,
  e.codigo as empresa_codigo, e.razon_social as empresa,
  reg.nombre_completo as registrado_por_nombre,
  n.cerrado_at, n.motivo_anulacion, n.created_at, n.updated_at
from public.novedades_calidad_produccion n
join public.empresas e on e.id = n.empresa_id
left join public.ordenes_produccion o on o.id = n.orden_id
left join public.orden_produccion_etapas oe on oe.id = n.etapa_id
left join public.lotes_produccion l on l.id = n.lote_id
left join public.productos p on p.id = n.producto_id
left join public.perfiles rp on rp.id = n.responsable_perfil_id
left join public.proveedores pr on pr.id = n.responsable_proveedor_id
left join public.perfiles reg on reg.id = n.registrado_por
left join public.novedades_empleado ne on ne.id = n.novedad_empleado_id
left join public.descuentos_programados dp on dp.id = ne.descuento_id;

-- ------------------------------------------------------------
-- 8. RLS y privilegios
-- ------------------------------------------------------------
alter table public.novedades_calidad_produccion enable row level security;
alter table public.novedad_calidad_evidencias enable row level security;
alter table public.novedad_calidad_eventos enable row level security;

drop policy if exists "leer_novedades_calidad_v74" on public.novedades_calidad_produccion;
create policy "leer_novedades_calidad_v74" on public.novedades_calidad_produccion
for select to authenticated using (public.usuario_puede_calidad_v74(grupo_id, 'ver'));
drop policy if exists "leer_evidencias_calidad_v74" on public.novedad_calidad_evidencias;
create policy "leer_evidencias_calidad_v74" on public.novedad_calidad_evidencias
for select to authenticated using (
  exists (select 1 from public.novedades_calidad_produccion n where n.id = novedad_id)
);
drop policy if exists "leer_eventos_calidad_v74" on public.novedad_calidad_eventos;
create policy "leer_eventos_calidad_v74" on public.novedad_calidad_eventos
for select to authenticated using (
  exists (select 1 from public.novedades_calidad_produccion n where n.id = novedad_id)
);

revoke all on public.novedades_calidad_produccion from public, anon;
revoke all on public.novedad_calidad_evidencias from public, anon;
revoke all on public.novedad_calidad_eventos from public, anon;
revoke insert, update, delete on public.novedades_calidad_produccion from authenticated;
revoke insert, update, delete on public.novedad_calidad_evidencias from authenticated;
revoke insert, update, delete on public.novedad_calidad_eventos from authenticated;
grant select on public.novedades_calidad_produccion to authenticated;
grant select on public.novedad_calidad_evidencias to authenticated;
grant select on public.novedad_calidad_eventos to authenticated;
revoke all on public.vista_novedades_calidad_v74 from public, anon;
grant select on public.vista_novedades_calidad_v74 to authenticated;

alter function public.usuario_puede_calidad_v74(uuid,text) owner to postgres;
alter function public.listar_empleados_calidad_v74() owner to postgres;
alter function public.registrar_novedad_calidad_v74(jsonb,uuid) owner to postgres;
alter function public.resolver_novedad_calidad_v74(uuid,jsonb,uuid) owner to postgres;
alter function public.agregar_evidencia_calidad_v74(uuid,text,text,text,uuid) owner to postgres;
alter function public.anular_novedad_calidad_v74(uuid,text,uuid) owner to postgres;
alter function public.generar_novedad_laboral_calidad_v74(uuid,uuid,text,text,uuid) owner to postgres;

revoke all on function public.usuario_puede_calidad_v74(uuid,text) from public, anon;
revoke all on function public.listar_empleados_calidad_v74() from public, anon;
revoke all on function public.registrar_novedad_calidad_v74(jsonb,uuid) from public, anon;
revoke all on function public.resolver_novedad_calidad_v74(uuid,jsonb,uuid) from public, anon;
revoke all on function public.agregar_evidencia_calidad_v74(uuid,text,text,text,uuid) from public, anon;
revoke all on function public.anular_novedad_calidad_v74(uuid,text,uuid) from public, anon;
revoke all on function public.generar_novedad_laboral_calidad_v74(uuid,uuid,text,text,uuid) from public, anon;
grant execute on function public.usuario_puede_calidad_v74(uuid,text) to authenticated;
grant execute on function public.listar_empleados_calidad_v74() to authenticated;
grant execute on function public.registrar_novedad_calidad_v74(jsonb,uuid) to authenticated;
grant execute on function public.resolver_novedad_calidad_v74(uuid,jsonb,uuid) to authenticated;
grant execute on function public.agregar_evidencia_calidad_v74(uuid,text,text,text,uuid) to authenticated;
grant execute on function public.anular_novedad_calidad_v74(uuid,text,uuid) to authenticated;
grant execute on function public.generar_novedad_laboral_calidad_v74(uuid,uuid,text,text,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
