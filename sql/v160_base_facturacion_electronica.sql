-- ============================================================
-- BOMAN INVENTARIO - v160 Base fiscal para comprobantes electronicos SRI
-- Ejecutar despues de v159. Esta migracion NO firma ni transmite XML: deja
-- el modelo, permisos y contratos seguros para un emisor server-side.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v160', 0));

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null
     or to_regclass('public.empresas') is null
     or to_regclass('public.empresa_puntos_emision') is null
     or to_regclass('public.comprobantes_compra') is null
     or to_regclass('public.retenciones_compra') is null
     or to_regclass('public.permisos_sistema') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null
     or to_regprocedure('public.usuario_tiene_capacidad_v68(text)') is null then
    raise exception 'Faltan v19, v35, v68 o v134; instala la base requerida antes de v160';
  end if;
end;
$requisitos$;

-- ------------------------------------------------------------
-- 1. Permisos contables separados
-- ------------------------------------------------------------
insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden, es_boman_especifico)
values
  ('facturacion.preparar','Contabilidad','Preparar comprobantes','Crea y revisa borradores fiscales sin consumir secuencial.',201,false),
  ('facturacion.emitir','Contabilidad','Emitir comprobantes','Consume secuencial y envia el comprobante a la cola SRI.',202,false),
  ('facturacion.reintentar','Contabilidad','Reintentar transmisiones','Reencola comprobantes con error recuperable.',203,false),
  ('facturacion.anular','Contabilidad','Solicitar anulacion','Registra y solicita la anulacion auditada de un comprobante.',204,false),
  ('facturacion.certificados','Contabilidad','Administrar certificados','Registra metadatos y referencias secretas de certificados de firma.',205,false),
  ('facturacion.retenciones_emitir','Contabilidad','Emitir retenciones','Prepara y emite comprobantes electronicos de retencion.',206,false)
on conflict(codigo) do update set modulo=excluded.modulo,nombre=excluded.nombre,
  descripcion=excluded.descripcion,orden=excluded.orden,activo=true,
  es_boman_especifico=false,updated_at=now();

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,p.codigo,false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text<>'admin' and p.codigo like 'facturacion.%'
on conflict(rol,permiso_codigo) do nothing;

update public.rol_permisos set permitido=true,updated_at=now()
where rol::text='control' and permiso_codigo in (
  'facturacion.preparar','facturacion.reintentar','facturacion.anular',
  'facturacion.retenciones_emitir'
);

-- ------------------------------------------------------------
-- 2. Configuracion, certificados y series
-- ------------------------------------------------------------
create table if not exists public.configuracion_tributaria_empresas_v160 (
  empresa_id uuid primary key references public.empresas(id) on delete restrict,
  ambiente smallint not null default 1 check(ambiente in (1,2)),
  tipo_emision smallint not null default 1 check(tipo_emision=1),
  moneda text not null default 'DOLAR' check(btrim(moneda)<>''),
  direccion_matriz text not null check(btrim(direccion_matriz)<>''),
  obligado_contabilidad boolean not null default true,
  contribuyente_especial boolean not null default false,
  resolucion_contribuyente_especial text,
  agente_retencion boolean not null default false,
  resolucion_agente_retencion text,
  ruc_proveedor_software text check(ruc_proveedor_software is null or ruc_proveedor_software ~ '^[0-9]{13}$'),
  email_remitente text,
  activo boolean not null default false,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(not contribuyente_especial or nullif(btrim(resolucion_contribuyente_especial),'') is not null),
  check(not agente_retencion or resolucion_agente_retencion ~ '^[0-9]{1,8}$')
);

comment on column public.configuracion_tributaria_empresas_v160.resolucion_agente_retencion is
  'Numero de resolucion sin ceros a la izquierda; se emite en infoTributaria/agenteRetencion.';

create table if not exists public.certificados_firma_v160 (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  alias text not null check(btrim(alias)<>''),
  archivo_storage_path text not null check(btrim(archivo_storage_path)<>''),
  secreto_password_ref text not null check(btrim(secreto_password_ref)<>''),
  huella_sha256 text not null check(huella_sha256 ~ '^[0-9a-f]{64}$'),
  sujeto text,
  emisor text,
  valido_desde timestamptz not null,
  valido_hasta timestamptz not null,
  activo boolean not null default true,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  desactivado_por uuid references public.perfiles(id) on delete restrict,
  desactivado_at timestamptz,
  created_at timestamptz not null default now(),
  unique(empresa_id,huella_sha256),
  unique(archivo_storage_path),
  check(valido_hasta>valido_desde),
  check(secreto_password_ref !~* '(password|clave|contrasena)\s*[:=]')
);

comment on table public.certificados_firma_v160 is
  'Solo metadatos y referencias opacas. Nunca guarda el PKCS#12 ni su contrasena en columnas consultables.';

create unique index if not exists uq_certificado_activo_empresa_v160
  on public.certificados_firma_v160(empresa_id) where activo;

create table if not exists public.series_comprobantes_v160 (
  id uuid primary key default gen_random_uuid(),
  punto_emision_id uuid not null references public.empresa_puntos_emision(id) on delete restrict,
  ambiente smallint not null check(ambiente in (1,2)),
  codigo_documento text not null check(codigo_documento in ('01','04','05','07')),
  siguiente_secuencial bigint not null default 1 check(siguiente_secuencial between 1 and 999999999),
  ultimo_secuencial bigint not null default 0 check(ultimo_secuencial between 0 and 999999999),
  activo boolean not null default true,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(punto_emision_id,ambiente,codigo_documento),
  check(siguiente_secuencial>ultimo_secuencial)
);

-- ------------------------------------------------------------
-- 3. Facturas: instantanea fiscal, lineas, impuestos y pagos
-- ------------------------------------------------------------
create table if not exists public.facturas_electronicas_v160 (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  punto_emision_id uuid not null references public.empresa_puntos_emision(id) on delete restrict,
  certificado_id uuid references public.certificados_firma_v160(id) on delete restrict,
  origen_tipo text not null check(origen_tipo in ('venta_rapida','contrato','manual')),
  origen_id uuid,
  ambiente smallint not null check(ambiente in (1,2)),
  establecimiento text check(establecimiento is null or establecimiento ~ '^[0-9]{3}$'),
  punto_emision text check(punto_emision is null or punto_emision ~ '^[0-9]{3}$'),
  secuencial text check(secuencial is null or secuencial ~ '^[0-9]{9}$'),
  clave_acceso text check(clave_acceso is null or clave_acceso ~ '^[0-9]{49}$'),
  codigo_numerico text check(codigo_numerico is null or codigo_numerico ~ '^[0-9]{8}$'),
  fecha_emision date not null,
  comprador_tipo_identificacion text not null check(comprador_tipo_identificacion in ('04','05','06','07','08')),
  comprador_identificacion text not null check(btrim(comprador_identificacion)<>''),
  comprador_razon_social text not null check(btrim(comprador_razon_social)<>''),
  comprador_direccion text,
  comprador_email text,
  comprador_telefono text,
  subtotal_sin_impuestos numeric(14,2) not null check(subtotal_sin_impuestos>=0),
  descuento_total numeric(14,2) not null default 0 check(descuento_total>=0),
  propina numeric(14,2) not null default 0 check(propina>=0),
  importe_total numeric(14,2) not null check(importe_total>=0),
  agente_retencion_resolucion text,
  obligado_contabilidad boolean not null,
  informacion_adicional jsonb not null default '{}'::jsonb check(jsonb_typeof(informacion_adicional)='object'),
  estado text not null default 'preparado' check(estado in (
    'preparado','en_cola','enviado','recibido','autorizado','rechazado',
    'error','anulacion_solicitada','anulado','cancelado'
  )),
  numero_autorizacion text,
  autorizado_at timestamptz,
  xml_firmado_path text,
  xml_autorizado_path text,
  ride_path text,
  idempotency_key uuid not null unique,
  preparado_por uuid not null references public.perfiles(id) on delete restrict,
  emitido_por uuid references public.perfiles(id) on delete restrict,
  emitido_at timestamptz,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,
  motivo_anulacion text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((origen_tipo='manual') or origen_id is not null),
  check((clave_acceso is null and secuencial is null) or (clave_acceso is not null and secuencial is not null))
);

create unique index if not exists uq_factura_clave_v160 on public.facturas_electronicas_v160(clave_acceso) where clave_acceso is not null;
create unique index if not exists uq_factura_numero_v160 on public.facturas_electronicas_v160(empresa_id,ambiente,establecimiento,punto_emision,secuencial) where secuencial is not null;
create unique index if not exists uq_factura_origen_v160 on public.facturas_electronicas_v160(empresa_id,origen_tipo,origen_id) where origen_id is not null and estado<>'cancelado';
create index if not exists idx_factura_empresa_fecha_v160 on public.facturas_electronicas_v160(empresa_id,fecha_emision desc,created_at desc);

create table if not exists public.factura_lineas_v160 (
  id uuid primary key default gen_random_uuid(),
  factura_id uuid not null references public.facturas_electronicas_v160(id) on delete restrict,
  numero integer not null check(numero>0),
  producto_id uuid references public.productos(id) on delete restrict,
  codigo_principal text not null check(btrim(codigo_principal)<>''),
  codigo_auxiliar text,
  descripcion text not null check(btrim(descripcion)<>''),
  cantidad numeric(14,4) not null check(cantidad>0),
  precio_unitario numeric(16,6) not null check(precio_unitario>=0),
  descuento numeric(14,2) not null default 0 check(descuento>=0),
  precio_total_sin_impuesto numeric(14,2) not null check(precio_total_sin_impuesto>=0),
  detalles_adicionales jsonb not null default '{}'::jsonb check(jsonb_typeof(detalles_adicionales)='object'),
  unique(factura_id,numero)
);

create table if not exists public.factura_impuestos_v160 (
  id uuid primary key default gen_random_uuid(),
  factura_id uuid not null references public.facturas_electronicas_v160(id) on delete restrict,
  linea_id uuid references public.factura_lineas_v160(id) on delete restrict,
  codigo text not null check(codigo ~ '^[0-9]+$'),
  codigo_porcentaje text not null check(codigo_porcentaje ~ '^[0-9]+$'),
  tarifa numeric(7,4) not null check(tarifa between 0 and 100),
  base_imponible numeric(14,2) not null check(base_imponible>=0),
  valor numeric(14,2) not null check(valor>=0),
  unique(factura_id,linea_id,codigo,codigo_porcentaje),
  check(round(valor,2)=round(base_imponible*tarifa/100,2))
);

create table if not exists public.factura_pagos_v160 (
  id uuid primary key default gen_random_uuid(),
  factura_id uuid not null references public.facturas_electronicas_v160(id) on delete restrict,
  numero integer not null check(numero>0),
  forma_pago_sri text not null check(forma_pago_sri ~ '^[0-9]{2}$'),
  total numeric(14,2) not null check(total>0),
  plazo numeric(12,2),
  unidad_tiempo text,
  unique(factura_id,numero)
);

-- ------------------------------------------------------------
-- 4. Comprobantes electronicos de retencion
-- ------------------------------------------------------------
create table if not exists public.comprobantes_retencion_v160 (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  punto_emision_id uuid not null references public.empresa_puntos_emision(id) on delete restrict,
  certificado_id uuid references public.certificados_firma_v160(id) on delete restrict,
  comprobante_compra_id uuid not null references public.comprobantes_compra(id) on delete restrict,
  ambiente smallint not null check(ambiente in (1,2)),
  establecimiento text check(establecimiento is null or establecimiento ~ '^[0-9]{3}$'),
  punto_emision text check(punto_emision is null or punto_emision ~ '^[0-9]{3}$'),
  secuencial text check(secuencial is null or secuencial ~ '^[0-9]{9}$'),
  clave_acceso text check(clave_acceso is null or clave_acceso ~ '^[0-9]{49}$'),
  codigo_numerico text check(codigo_numerico is null or codigo_numerico ~ '^[0-9]{8}$'),
  fecha_emision date not null,
  periodo_fiscal text not null check(periodo_fiscal ~ '^(0[1-9]|1[0-2])/[0-9]{4}$'),
  sujeto_tipo_identificacion text not null check(sujeto_tipo_identificacion in ('04','05','06')),
  sujeto_identificacion text not null check(btrim(sujeto_identificacion)<>''),
  sujeto_razon_social text not null check(btrim(sujeto_razon_social)<>''),
  total_retenido numeric(14,2) not null check(total_retenido>=0),
  agente_retencion_resolucion text not null check(agente_retencion_resolucion ~ '^[0-9]{1,8}$'),
  estado text not null default 'preparado' check(estado in (
    'preparado','en_cola','enviado','recibido','autorizado','rechazado',
    'error','anulacion_solicitada','anulado','cancelado'
  )),
  numero_autorizacion text,
  autorizado_at timestamptz,
  xml_firmado_path text,
  xml_autorizado_path text,
  ride_path text,
  idempotency_key uuid not null unique,
  preparado_por uuid not null references public.perfiles(id) on delete restrict,
  emitido_por uuid references public.perfiles(id) on delete restrict,
  emitido_at timestamptz,
  anulado_por uuid references public.perfiles(id) on delete restrict,
  anulado_at timestamptz,
  motivo_anulacion text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(empresa_id,comprobante_compra_id),
  check((clave_acceso is null and secuencial is null) or (clave_acceso is not null and secuencial is not null))
);

create unique index if not exists uq_retencion_clave_v160 on public.comprobantes_retencion_v160(clave_acceso) where clave_acceso is not null;
create unique index if not exists uq_retencion_numero_v160 on public.comprobantes_retencion_v160(empresa_id,ambiente,establecimiento,punto_emision,secuencial) where secuencial is not null;

create table if not exists public.retencion_lineas_v160 (
  id uuid primary key default gen_random_uuid(),
  retencion_id uuid not null references public.comprobantes_retencion_v160(id) on delete restrict,
  retencion_compra_id uuid references public.retenciones_compra(id) on delete restrict,
  numero integer not null check(numero>0),
  codigo_impuesto text not null check(codigo_impuesto in ('1','2','6')),
  codigo_retencion text not null check(btrim(codigo_retencion)<>''),
  base_imponible numeric(14,2) not null check(base_imponible>=0),
  porcentaje_retener numeric(7,4) not null check(porcentaje_retener between 0 and 100),
  valor_retenido numeric(14,2) not null check(valor_retenido>=0),
  tipo_documento_sustento text not null check(tipo_documento_sustento ~ '^[0-9]{2}$'),
  numero_documento_sustento text not null check(numero_documento_sustento ~ '^[0-9]{15}$'),
  fecha_emision_documento_sustento date not null,
  unique(retencion_id,numero),
  unique(retencion_compra_id),
  check(round(valor_retenido,2)=round(base_imponible*porcentaje_retener/100,2))
);

-- ------------------------------------------------------------
-- 5. Cola, respuestas y auditoria
-- ------------------------------------------------------------
create table if not exists public.transmisiones_sri_v160 (
  id uuid primary key default gen_random_uuid(),
  factura_id uuid references public.facturas_electronicas_v160(id) on delete restrict,
  retencion_id uuid references public.comprobantes_retencion_v160(id) on delete restrict,
  ambiente smallint not null check(ambiente in (1,2)),
  estado text not null default 'pendiente' check(estado in ('pendiente','procesando','esperando_autorizacion','completada','error','cancelada')),
  intentos integer not null default 0 check(intentos>=0),
  max_intentos integer not null default 12 check(max_intentos between 1 and 100),
  disponible_at timestamptz not null default now(),
  bloqueado_at timestamptz,
  bloqueado_por text,
  ultimo_error_codigo text,
  ultimo_error_mensaje text,
  ultimo_intento_at timestamptz,
  completado_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((factura_id is not null)::integer+(retencion_id is not null)::integer=1),
  unique(factura_id),unique(retencion_id)
);
create index if not exists idx_cola_sri_disponible_v160 on public.transmisiones_sri_v160(estado,disponible_at) where estado in ('pendiente','esperando_autorizacion','error');

create table if not exists public.respuestas_sri_v160 (
  id uuid primary key default gen_random_uuid(),
  transmision_id uuid not null references public.transmisiones_sri_v160(id) on delete restrict,
  etapa text not null check(etapa in ('firma','recepcion','autorizacion','anulacion')),
  estado text,
  codigo text,
  identificador text,
  mensaje text,
  informacion_adicional text,
  numero_autorizacion text,
  fecha_autorizacion timestamptz,
  respuesta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_respuestas_transmision_v160 on public.respuestas_sri_v160(transmision_id,created_at desc);

create table if not exists public.facturacion_eventos_v160 (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  factura_id uuid references public.facturas_electronicas_v160(id) on delete restrict,
  retencion_id uuid references public.comprobantes_retencion_v160(id) on delete restrict,
  tipo text not null check(btrim(tipo)<>''),
  estado_anterior text,
  estado_nuevo text,
  detalle jsonb not null default '{}'::jsonb,
  usuario_id uuid references public.perfiles(id) on delete restrict,
  idempotency_key uuid unique,
  created_at timestamptz not null default now(),
  check((factura_id is not null)::integer+(retencion_id is not null)::integer<=1)
);
create index if not exists idx_eventos_facturacion_v160 on public.facturacion_eventos_v160(empresa_id,created_at desc);

-- ------------------------------------------------------------
-- 6. Integridad: clave de acceso y bloqueo de instantaneas numeradas
-- ------------------------------------------------------------
create or replace function public.digito_modulo11_sri_v160(p_cadena text)
returns integer language plpgsql immutable set search_path='' as $fn$
declare i integer; factor integer:=2; suma integer:=0; resultado integer;
begin
  if p_cadena is null or p_cadena !~ '^[0-9]+$' then raise exception 'La cadena para modulo 11 debe ser numerica'; end if;
  for i in reverse length(p_cadena)..1 loop
    suma:=suma+(substr(p_cadena,i,1)::integer*factor);
    factor:=case when factor=7 then 2 else factor+1 end;
  end loop;
  resultado:=11-(suma%11);
  if resultado=11 then return 0; elsif resultado=10 then return 1; else return resultado; end if;
end;$fn$;

create or replace function public.clave_acceso_sri_v160(p_fecha date,p_codigo_documento text,p_ruc text,p_ambiente smallint,p_serie text,p_secuencial text,p_codigo_numerico text)
returns text language plpgsql immutable set search_path='' as $fn$
declare base text;
begin
  if p_codigo_documento!~'^[0-9]{2}$' or p_ruc!~'^[0-9]{13}$' or p_ambiente not in(1,2)
     or p_serie!~'^[0-9]{6}$' or p_secuencial!~'^[0-9]{9}$' or p_codigo_numerico!~'^[0-9]{8}$' then
    raise exception 'No se puede construir la clave: uno de sus componentes no es valido';
  end if;
  base:=to_char(p_fecha,'DDMMYYYY')||p_codigo_documento||p_ruc||p_ambiente::text||p_serie||p_secuencial||p_codigo_numerico||'1';
  return base||public.digito_modulo11_sri_v160(base)::text;
end;$fn$;

create or replace function public.bloquear_detalle_fiscal_v160() returns trigger
language plpgsql security definer set search_path='' as $fn$
declare v_numerado boolean;v_factura uuid;v_retencion uuid;
begin
  if tg_table_name in ('factura_lineas_v160','factura_impuestos_v160','factura_pagos_v160') then
    if tg_op='DELETE' then v_factura:=old.factura_id;else v_factura:=new.factura_id;end if;
    select f.clave_acceso is not null into v_numerado from public.facturas_electronicas_v160 f where f.id=v_factura;
  else
    if tg_op='DELETE' then v_retencion:=old.retencion_id;else v_retencion:=new.retencion_id;end if;
    select r.clave_acceso is not null into v_numerado from public.comprobantes_retencion_v160 r where r.id=v_retencion;
  end if;
  if coalesce(v_numerado,false) then raise exception 'El detalle fiscal no puede cambiar despues de consumir un secuencial'; end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;$fn$;

drop trigger if exists bloquear_factura_lineas_v160 on public.factura_lineas_v160;
drop trigger if exists bloquear_factura_impuestos_v160 on public.factura_impuestos_v160;
drop trigger if exists bloquear_factura_pagos_v160 on public.factura_pagos_v160;
drop trigger if exists bloquear_retencion_lineas_v160 on public.retencion_lineas_v160;
create trigger bloquear_factura_lineas_v160 before insert or update or delete on public.factura_lineas_v160 for each row execute function public.bloquear_detalle_fiscal_v160();
create trigger bloquear_factura_impuestos_v160 before insert or update or delete on public.factura_impuestos_v160 for each row execute function public.bloquear_detalle_fiscal_v160();
create trigger bloquear_factura_pagos_v160 before insert or update or delete on public.factura_pagos_v160 for each row execute function public.bloquear_detalle_fiscal_v160();
create trigger bloquear_retencion_lineas_v160 before insert or update or delete on public.retencion_lineas_v160 for each row execute function public.bloquear_detalle_fiscal_v160();

-- ------------------------------------------------------------
-- 7. RPC de configuracion
-- ------------------------------------------------------------
create or replace function public.guardar_configuracion_tributaria_v160(p_empresa_id uuid,p_config jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id uuid;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('facturacion.certificados') then raise exception 'No tienes permiso para administrar la configuracion tributaria'; end if;
  if not public.usuario_puede_empresa(p_empresa_id,true) then raise exception 'No tienes acceso de escritura a esta empresa'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('duplicado',true,'empresa_id',p_empresa_id); end if;
  insert into public.configuracion_tributaria_empresas_v160 as c(
    empresa_id,ambiente,tipo_emision,moneda,direccion_matriz,obligado_contabilidad,
    contribuyente_especial,resolucion_contribuyente_especial,agente_retencion,
    resolucion_agente_retencion,ruc_proveedor_software,email_remitente,activo,actualizado_por
  ) values(
    p_empresa_id,coalesce((p_config->>'ambiente')::smallint,1),1,coalesce(nullif(p_config->>'moneda',''),'DOLAR'),
    btrim(p_config->>'direccion_matriz'),coalesce((p_config->>'obligado_contabilidad')::boolean,true),
    coalesce((p_config->>'contribuyente_especial')::boolean,false),nullif(btrim(p_config->>'resolucion_contribuyente_especial'),''),
    coalesce((p_config->>'agente_retencion')::boolean,false),nullif(ltrim(btrim(p_config->>'resolucion_agente_retencion'),'0'),''),
    nullif(btrim(p_config->>'ruc_proveedor_software'),''),nullif(btrim(p_config->>'email_remitente'),''),
    coalesce((p_config->>'activo')::boolean,false),auth.uid()
  ) on conflict(empresa_id) do update set ambiente=excluded.ambiente,moneda=excluded.moneda,
    direccion_matriz=excluded.direccion_matriz,obligado_contabilidad=excluded.obligado_contabilidad,
    contribuyente_especial=excluded.contribuyente_especial,resolucion_contribuyente_especial=excluded.resolucion_contribuyente_especial,
    agente_retencion=excluded.agente_retencion,resolucion_agente_retencion=excluded.resolucion_agente_retencion,
    ruc_proveedor_software=excluded.ruc_proveedor_software,email_remitente=excluded.email_remitente,
    activo=excluded.activo,actualizado_por=auth.uid(),updated_at=now();
  insert into public.facturacion_eventos_v160(id,empresa_id,tipo,detalle,usuario_id,idempotency_key)
  values(gen_random_uuid(),p_empresa_id,'configuracion_actualizada',p_config,auth.uid(),p_idempotency_key);
  return jsonb_build_object('duplicado',false,'empresa_id',p_empresa_id);
end;$fn$;

create or replace function public.registrar_certificado_firma_v160(p_empresa_id uuid,p_datos jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id uuid;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.certificados') then raise exception 'No tienes permiso para administrar certificados'; end if;
  if not public.usuario_puede_empresa(p_empresa_id,true) then raise exception 'No tienes acceso de escritura a esta empresa'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select (detalle->>'certificado_id')::uuid into v_id from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('id',v_id,'duplicado',true); end if;
  update public.certificados_firma_v160 set activo=false,desactivado_por=auth.uid(),desactivado_at=now() where empresa_id=p_empresa_id and activo;
  insert into public.certificados_firma_v160(empresa_id,alias,archivo_storage_path,secreto_password_ref,huella_sha256,sujeto,emisor,valido_desde,valido_hasta,creado_por)
  values(p_empresa_id,btrim(p_datos->>'alias'),btrim(p_datos->>'archivo_storage_path'),btrim(p_datos->>'secreto_password_ref'),lower(btrim(p_datos->>'huella_sha256')),
    nullif(btrim(p_datos->>'sujeto'),''),nullif(btrim(p_datos->>'emisor'),''),(p_datos->>'valido_desde')::timestamptz,(p_datos->>'valido_hasta')::timestamptz,auth.uid()) returning id into v_id;
  insert into public.facturacion_eventos_v160(empresa_id,tipo,detalle,usuario_id,idempotency_key)
  values(p_empresa_id,'certificado_registrado',jsonb_build_object('certificado_id',v_id,'huella_sha256',lower(btrim(p_datos->>'huella_sha256'))),auth.uid(),p_idempotency_key);
  return jsonb_build_object('id',v_id,'duplicado',false);
end;$fn$;

create or replace function public.desactivar_certificado_firma_v160(p_certificado_id uuid,p_motivo text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_empresa uuid;v_event uuid;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.certificados') then raise exception 'No tienes permiso para administrar certificados'; end if;
  if length(btrim(coalesce(p_motivo,'')))<10 or p_idempotency_key is null then raise exception 'Indica un motivo de al menos 10 caracteres y una idempotencia'; end if;
  select id into v_event from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('id',p_certificado_id,'duplicado',true);end if;
  select empresa_id into v_empresa from public.certificados_firma_v160 where id=p_certificado_id and activo for update;
  if v_empresa is null or not public.usuario_puede_empresa(v_empresa,true) then raise exception 'El certificado no existe, ya esta inactivo o no tienes acceso'; end if;
  update public.certificados_firma_v160 set activo=false,desactivado_por=auth.uid(),desactivado_at=now() where id=p_certificado_id;
  insert into public.facturacion_eventos_v160(empresa_id,tipo,detalle,usuario_id,idempotency_key)
  values(v_empresa,'certificado_desactivado',jsonb_build_object('certificado_id',p_certificado_id,'motivo',btrim(p_motivo)),auth.uid(),p_idempotency_key);
  return jsonb_build_object('id',p_certificado_id,'duplicado',false,'activo',false);
end;$fn$;

create or replace function public.configurar_serie_comprobante_v160(p_punto_emision_id uuid,p_ambiente smallint,p_codigo_documento text,p_siguiente bigint,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_empresa uuid;v_id uuid;v_ultimo bigint;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.certificados') then raise exception 'No tienes permiso para administrar secuenciales'; end if;
  select ee.empresa_id into v_empresa from public.empresa_puntos_emision pe join public.empresa_establecimientos ee on ee.id=pe.establecimiento_id where pe.id=p_punto_emision_id and pe.activo and ee.activo;
  if v_empresa is null or not public.usuario_puede_empresa(v_empresa,true) then raise exception 'El punto de emision no existe o no tienes acceso'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select (detalle->>'serie_id')::uuid into v_id from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('id',v_id,'duplicado',true); end if;
  if p_siguiente not between 1 and 999999999 then raise exception 'El siguiente secuencial debe estar entre 1 y 999999999'; end if;
  select id,ultimo_secuencial into v_id,v_ultimo from public.series_comprobantes_v160
  where punto_emision_id=p_punto_emision_id and ambiente=p_ambiente and codigo_documento=p_codigo_documento for update;
  if found then
    if p_siguiente<=v_ultimo then raise exception 'El siguiente secuencial debe ser mayor al ultimo ya consumido (%)',v_ultimo;end if;
    update public.series_comprobantes_v160 set siguiente_secuencial=p_siguiente,activo=true,
      actualizado_por=auth.uid(),updated_at=now() where id=v_id;
  else
    insert into public.series_comprobantes_v160(punto_emision_id,ambiente,codigo_documento,siguiente_secuencial,ultimo_secuencial,actualizado_por)
    values(p_punto_emision_id,p_ambiente,p_codigo_documento,p_siguiente,p_siguiente-1,auth.uid()) returning id into v_id;
  end if;
  insert into public.facturacion_eventos_v160(empresa_id,tipo,detalle,usuario_id,idempotency_key)
  values(v_empresa,'serie_configurada',jsonb_build_object('serie_id',v_id,'siguiente',p_siguiente),auth.uid(),p_idempotency_key);
  return jsonb_build_object('id',v_id,'duplicado',false);
end;$fn$;

-- ------------------------------------------------------------
-- 8. RPC de preparacion y emision de facturas
-- ------------------------------------------------------------
create or replace function public.preparar_factura_electronica_v160(p_cabecera jsonb,p_lineas jsonb,p_impuestos jsonb,p_pagos jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id uuid;v_empresa uuid:=nullif(p_cabecera->>'empresa_id','')::uuid;v_punto uuid:=nullif(p_cabecera->>'punto_emision_id','')::uuid;v_cfg public.configuracion_tributaria_empresas_v160%rowtype;v_base numeric;v_imp numeric;v_pago numeric;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.preparar') then raise exception 'No tienes permiso para preparar comprobantes'; end if;
  if not public.usuario_tiene_capacidad_v68('facturacion.emision') then raise exception 'El plan del grupo no incluye facturacion electronica'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.facturas_electronicas_v160 where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('id',v_id,'duplicado',true); end if;
  if not public.usuario_puede_empresa(v_empresa,true) then raise exception 'No tienes acceso a la empresa emisora'; end if;
  select * into v_cfg from public.configuracion_tributaria_empresas_v160 where empresa_id=v_empresa and activo;
  if not found then raise exception 'La empresa no tiene configuracion tributaria activa'; end if;
  if not exists(select 1 from public.empresa_puntos_emision pe join public.empresa_establecimientos ee on ee.id=pe.establecimiento_id where pe.id=v_punto and ee.empresa_id=v_empresa and pe.activo and ee.activo) then raise exception 'El punto de emision no pertenece a la empresa'; end if;
  if jsonb_typeof(p_lineas)<>'array' or jsonb_array_length(p_lineas)=0 then raise exception 'La factura requiere al menos una linea'; end if;
  if jsonb_typeof(p_impuestos)<>'array' or jsonb_typeof(p_pagos)<>'array' or jsonb_array_length(p_pagos)=0 then raise exception 'Impuestos y pagos deben ser listas; se requiere al menos un pago'; end if;
  if (p_cabecera->>'fecha_emision')::date>current_date then raise exception 'La fecha de emision no puede ser futura'; end if;
  if not (
    (p_cabecera->>'comprador_tipo_identificacion'='04' and btrim(p_cabecera->>'comprador_identificacion')~'^[0-9]{13}$') or
    (p_cabecera->>'comprador_tipo_identificacion'='05' and btrim(p_cabecera->>'comprador_identificacion')~'^[0-9]{10}$') or
    (p_cabecera->>'comprador_tipo_identificacion'='06' and length(btrim(p_cabecera->>'comprador_identificacion')) between 3 and 20) or
    (p_cabecera->>'comprador_tipo_identificacion'='07' and btrim(p_cabecera->>'comprador_identificacion')='9999999999999') or
    (p_cabecera->>'comprador_tipo_identificacion'='08' and length(btrim(p_cabecera->>'comprador_identificacion')) between 3 and 20)
  ) then raise exception 'La identificacion del comprador no coincide con su tipo'; end if;
  select round(coalesce(sum(x.precio_total_sin_impuesto),0),2) into v_base from jsonb_to_recordset(p_lineas)x(precio_total_sin_impuesto numeric);
  select round(coalesce(sum(x.valor),0),2) into v_imp from jsonb_to_recordset(p_impuestos)x(valor numeric);
  select round(coalesce(sum(x.total),0),2) into v_pago from jsonb_to_recordset(p_pagos)x(total numeric);
  if v_base<>round((p_cabecera->>'subtotal_sin_impuestos')::numeric,2) then raise exception 'Las lineas no cuadran con el subtotal sin impuestos'; end if;
  if v_pago<>round((p_cabecera->>'importe_total')::numeric,2) then raise exception 'Las formas de pago no cuadran con el importe total'; end if;
  if round((p_cabecera->>'importe_total')::numeric,2)<>round(v_base+v_imp+coalesce((p_cabecera->>'propina')::numeric,0),2) then raise exception 'El importe total no cuadra con subtotal, impuestos y propina'; end if;
  insert into public.facturas_electronicas_v160(empresa_id,punto_emision_id,origen_tipo,origen_id,ambiente,fecha_emision,
    comprador_tipo_identificacion,comprador_identificacion,comprador_razon_social,comprador_direccion,comprador_email,comprador_telefono,
    subtotal_sin_impuestos,descuento_total,propina,importe_total,agente_retencion_resolucion,obligado_contabilidad,informacion_adicional,idempotency_key,preparado_por)
  values(v_empresa,v_punto,p_cabecera->>'origen_tipo',nullif(p_cabecera->>'origen_id','')::uuid,v_cfg.ambiente,(p_cabecera->>'fecha_emision')::date,
    p_cabecera->>'comprador_tipo_identificacion',btrim(p_cabecera->>'comprador_identificacion'),btrim(p_cabecera->>'comprador_razon_social'),nullif(btrim(p_cabecera->>'comprador_direccion'),''),nullif(btrim(p_cabecera->>'comprador_email'),''),nullif(btrim(p_cabecera->>'comprador_telefono'),''),
    (p_cabecera->>'subtotal_sin_impuestos')::numeric,coalesce((p_cabecera->>'descuento_total')::numeric,0),coalesce((p_cabecera->>'propina')::numeric,0),(p_cabecera->>'importe_total')::numeric,
    case when v_cfg.agente_retencion then v_cfg.resolucion_agente_retencion end,v_cfg.obligado_contabilidad,coalesce(p_cabecera->'informacion_adicional','{}'),p_idempotency_key,auth.uid()) returning id into v_id;
  insert into public.factura_lineas_v160(factura_id,numero,producto_id,codigo_principal,codigo_auxiliar,descripcion,cantidad,precio_unitario,descuento,precio_total_sin_impuesto,detalles_adicionales)
  select v_id,x.numero,x.producto_id,x.codigo_principal,nullif(x.codigo_auxiliar,''),x.descripcion,x.cantidad,x.precio_unitario,coalesce(x.descuento,0),x.precio_total_sin_impuesto,coalesce(x.detalles_adicionales,'{}') from jsonb_to_recordset(p_lineas)x(numero integer,producto_id uuid,codigo_principal text,codigo_auxiliar text,descripcion text,cantidad numeric,precio_unitario numeric,descuento numeric,precio_total_sin_impuesto numeric,detalles_adicionales jsonb);
  if exists(select 1 from jsonb_to_recordset(p_impuestos)x(linea_numero integer) left join public.factura_lineas_v160 l on l.factura_id=v_id and l.numero=x.linea_numero where x.linea_numero is not null and l.id is null) then
    raise exception 'Un impuesto hace referencia a una linea inexistente';
  end if;
  insert into public.factura_impuestos_v160(factura_id,linea_id,codigo,codigo_porcentaje,tarifa,base_imponible,valor)
  select v_id,l.id,x.codigo,x.codigo_porcentaje,x.tarifa,x.base_imponible,x.valor
  from jsonb_to_recordset(p_impuestos)x(linea_numero integer,codigo text,codigo_porcentaje text,tarifa numeric,base_imponible numeric,valor numeric)
  left join public.factura_lineas_v160 l on l.factura_id=v_id and l.numero=x.linea_numero;
  insert into public.factura_pagos_v160(factura_id,numero,forma_pago_sri,total,plazo,unidad_tiempo)
  select v_id,x.numero,x.forma_pago_sri,x.total,x.plazo,nullif(x.unidad_tiempo,'') from jsonb_to_recordset(p_pagos)x(numero integer,forma_pago_sri text,total numeric,plazo numeric,unidad_tiempo text);
  insert into public.facturacion_eventos_v160(empresa_id,factura_id,tipo,estado_nuevo,usuario_id) values(v_empresa,v_id,'factura_preparada','preparado',auth.uid());
  return jsonb_build_object('id',v_id,'duplicado',false,'estado','preparado');
end;$fn$;

create or replace function public.emitir_factura_electronica_v160(p_factura_id uuid,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare f public.facturas_electronicas_v160%rowtype;s public.series_comprobantes_v160%rowtype;v_ruc text;v_est text;v_pe text;v_seq text;v_num text;v_clave text;v_cert uuid;v_event uuid;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.emitir') then raise exception 'No tienes permiso para emitir comprobantes'; end if;
  if not public.usuario_tiene_capacidad_v68('facturacion.emision') then raise exception 'El plan del grupo no incluye facturacion electronica'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_event from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;
  if found then select * into f from public.facturas_electronicas_v160 where id=p_factura_id;return jsonb_build_object('id',f.id,'duplicado',true,'estado',f.estado,'clave_acceso',f.clave_acceso);end if;
  select * into f from public.facturas_electronicas_v160 where id=p_factura_id for update;
  if not found then raise exception 'La factura no existe'; end if;
  if f.estado<>'preparado' then raise exception 'Solo una factura preparada puede emitirse'; end if;
  if not public.usuario_puede_empresa(f.empresa_id,true) then raise exception 'No tienes acceso a la empresa emisora'; end if;
  select e.ruc,ee.codigo,pe.codigo into v_ruc,v_est,v_pe from public.empresas e join public.empresa_establecimientos ee on ee.empresa_id=e.id join public.empresa_puntos_emision pe on pe.establecimiento_id=ee.id where e.id=f.empresa_id and pe.id=f.punto_emision_id and ee.activo and pe.activo;
  select id into v_cert from public.certificados_firma_v160 where empresa_id=f.empresa_id and activo and now() between valido_desde and valido_hasta;
  if v_cert is null then raise exception 'No existe un certificado activo y vigente para la empresa'; end if;
  select * into s from public.series_comprobantes_v160 where punto_emision_id=f.punto_emision_id and ambiente=f.ambiente and codigo_documento='01' and activo for update;
  if not found then raise exception 'No existe una serie activa para facturas en este punto y ambiente'; end if;
  v_seq:=lpad(s.siguiente_secuencial::text,9,'0');v_num:=lpad((((('x'||substr(md5(f.id::text),1,8))::bit(32)::bigint)%100000000))::text,8,'0');
  v_clave:=public.clave_acceso_sri_v160(f.fecha_emision,'01',v_ruc,f.ambiente,v_est||v_pe,v_seq,v_num);
  update public.series_comprobantes_v160 set ultimo_secuencial=s.siguiente_secuencial,siguiente_secuencial=s.siguiente_secuencial+1,updated_at=now(),actualizado_por=auth.uid() where id=s.id;
  update public.facturas_electronicas_v160 set certificado_id=v_cert,establecimiento=v_est,punto_emision=v_pe,secuencial=v_seq,codigo_numerico=v_num,clave_acceso=v_clave,estado='en_cola',emitido_por=auth.uid(),emitido_at=now(),updated_at=now() where id=f.id;
  insert into public.transmisiones_sri_v160(factura_id,ambiente) values(f.id,f.ambiente);
  insert into public.facturacion_eventos_v160(empresa_id,factura_id,tipo,estado_anterior,estado_nuevo,detalle,usuario_id,idempotency_key)
  values(f.empresa_id,f.id,'factura_encolada','preparado','en_cola',jsonb_build_object('clave_acceso',v_clave),auth.uid(),p_idempotency_key);
  return jsonb_build_object('id',f.id,'duplicado',false,'estado','en_cola','clave_acceso',v_clave,'numero',v_est||'-'||v_pe||'-'||v_seq);
end;$fn$;

-- ------------------------------------------------------------
-- 9. RPC de retenciones, reintentos, anulacion y consulta
-- ------------------------------------------------------------
create or replace function public.preparar_retencion_electronica_v160(p_cabecera jsonb,p_lineas jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_id uuid;v_empresa uuid:=nullif(p_cabecera->>'empresa_id','')::uuid;v_punto uuid:=nullif(p_cabecera->>'punto_emision_id','')::uuid;v_compra uuid:=nullif(p_cabecera->>'comprobante_compra_id','')::uuid;v_cfg public.configuracion_tributaria_empresas_v160%rowtype;v_total numeric;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.retenciones_emitir') then raise exception 'No tienes permiso para preparar retenciones'; end if;
  if not public.usuario_tiene_capacidad_v68('facturacion.emision') then raise exception 'El plan no incluye comprobantes electronicos'; end if;
  select id into v_id from public.comprobantes_retencion_v160 where idempotency_key=p_idempotency_key;if found then return jsonb_build_object('id',v_id,'duplicado',true);end if;
  if p_idempotency_key is null or not public.usuario_puede_empresa(v_empresa,true) then raise exception 'Idempotencia o acceso a empresa invalidos'; end if;
  select * into v_cfg from public.configuracion_tributaria_empresas_v160 where empresa_id=v_empresa and activo and agente_retencion;
  if not found then raise exception 'La empresa no esta configurada como agente de retencion activo'; end if;
  if not exists(select 1 from public.empresa_puntos_emision pe join public.empresa_establecimientos ee on ee.id=pe.establecimiento_id where pe.id=v_punto and ee.empresa_id=v_empresa and pe.activo and ee.activo) then raise exception 'El punto de emision no pertenece a la empresa'; end if;
  if not exists(select 1 from public.comprobantes_compra c join public.proveedores p on p.id=c.proveedor_id where c.id=v_compra and c.empresa_id=v_empresa and c.estado='registrado' and p.identificacion=btrim(p_cabecera->>'sujeto_identificacion') and p.razon_social=btrim(p_cabecera->>'sujeto_razon_social')) then
    raise exception 'La compra no pertenece a la empresa, esta anulada o no coincide con el proveedor indicado';
  end if;
  if jsonb_typeof(p_lineas)<>'array' or jsonb_array_length(p_lineas)=0 then raise exception 'La retencion requiere al menos una linea'; end if;
  if exists(
    select 1 from jsonb_to_recordset(p_lineas)x(retencion_compra_id uuid,codigo_impuesto text,codigo_retencion text,base_imponible numeric,porcentaje_retener numeric,valor_retenido numeric)
    left join public.retenciones_compra rc on rc.id=x.retencion_compra_id and rc.comprobante_id=v_compra
    left join public.retencion_conceptos c on c.codigo=rc.concepto_codigo
    where rc.id is null or x.codigo_retencion<>rc.concepto_codigo
      or x.codigo_impuesto<>case when c.clase='renta' then '1' else '2' end
      or round(x.base_imponible,2)<>round(rc.base_imponible,2)
      or x.porcentaje_retener<>rc.porcentaje or round(x.valor_retenido,2)<>round(rc.valor,2)
  ) then raise exception 'Las lineas no coinciden con las retenciones calculadas en la compra'; end if;
  select round(coalesce(sum(x.valor_retenido),0),2) into v_total from jsonb_to_recordset(p_lineas)x(valor_retenido numeric);
  insert into public.comprobantes_retencion_v160(empresa_id,punto_emision_id,comprobante_compra_id,ambiente,fecha_emision,periodo_fiscal,sujeto_tipo_identificacion,sujeto_identificacion,sujeto_razon_social,total_retenido,agente_retencion_resolucion,idempotency_key,preparado_por)
  values(v_empresa,v_punto,v_compra,v_cfg.ambiente,(p_cabecera->>'fecha_emision')::date,p_cabecera->>'periodo_fiscal',p_cabecera->>'sujeto_tipo_identificacion',btrim(p_cabecera->>'sujeto_identificacion'),btrim(p_cabecera->>'sujeto_razon_social'),v_total,v_cfg.resolucion_agente_retencion,p_idempotency_key,auth.uid()) returning id into v_id;
  insert into public.retencion_lineas_v160(retencion_id,retencion_compra_id,numero,codigo_impuesto,codigo_retencion,base_imponible,porcentaje_retener,valor_retenido,tipo_documento_sustento,numero_documento_sustento,fecha_emision_documento_sustento)
  select v_id,x.retencion_compra_id,x.numero,x.codigo_impuesto,x.codigo_retencion,x.base_imponible,x.porcentaje_retener,x.valor_retenido,x.tipo_documento_sustento,replace(x.numero_documento_sustento,'-',''),x.fecha_emision_documento_sustento from jsonb_to_recordset(p_lineas)x(retencion_compra_id uuid,numero integer,codigo_impuesto text,codigo_retencion text,base_imponible numeric,porcentaje_retener numeric,valor_retenido numeric,tipo_documento_sustento text,numero_documento_sustento text,fecha_emision_documento_sustento date);
  insert into public.facturacion_eventos_v160(empresa_id,retencion_id,tipo,estado_nuevo,usuario_id) values(v_empresa,v_id,'retencion_preparada','preparado',auth.uid());
  return jsonb_build_object('id',v_id,'duplicado',false,'total_retenido',v_total);
end;$fn$;

create or replace function public.emitir_retencion_electronica_v160(p_retencion_id uuid,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r public.comprobantes_retencion_v160%rowtype;s public.series_comprobantes_v160%rowtype;v_ruc text;v_est text;v_pe text;v_seq text;v_num text;v_clave text;v_cert uuid;v_event uuid;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.retenciones_emitir') then raise exception 'No tienes permiso para emitir retenciones'; end if;
  if not public.usuario_tiene_capacidad_v68('facturacion.emision') then raise exception 'El plan no incluye comprobantes electronicos'; end if;
  select id into v_event from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;
  if found then select * into r from public.comprobantes_retencion_v160 where id=p_retencion_id;return jsonb_build_object('id',r.id,'duplicado',true,'estado',r.estado,'clave_acceso',r.clave_acceso);end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select * into r from public.comprobantes_retencion_v160 where id=p_retencion_id for update;
  if not found or r.estado<>'preparado' then raise exception 'La retencion no existe o ya fue emitida'; end if;
  if not public.usuario_puede_empresa(r.empresa_id,true) then raise exception 'No tienes acceso a la empresa emisora'; end if;
  select e.ruc,ee.codigo,pe.codigo into v_ruc,v_est,v_pe from public.empresas e join public.empresa_establecimientos ee on ee.empresa_id=e.id join public.empresa_puntos_emision pe on pe.establecimiento_id=ee.id where e.id=r.empresa_id and pe.id=r.punto_emision_id and ee.activo and pe.activo;
  select id into v_cert from public.certificados_firma_v160 where empresa_id=r.empresa_id and activo and now() between valido_desde and valido_hasta;
  if v_cert is null then raise exception 'No existe un certificado activo y vigente'; end if;
  select * into s from public.series_comprobantes_v160 where punto_emision_id=r.punto_emision_id and ambiente=r.ambiente and codigo_documento='07' and activo for update;
  if not found then raise exception 'No existe una serie activa para retenciones'; end if;
  v_seq:=lpad(s.siguiente_secuencial::text,9,'0');v_num:=lpad((((('x'||substr(md5(r.id::text),1,8))::bit(32)::bigint)%100000000))::text,8,'0');
  v_clave:=public.clave_acceso_sri_v160(r.fecha_emision,'07',v_ruc,r.ambiente,v_est||v_pe,v_seq,v_num);
  update public.series_comprobantes_v160 set ultimo_secuencial=s.siguiente_secuencial,siguiente_secuencial=s.siguiente_secuencial+1,updated_at=now(),actualizado_por=auth.uid() where id=s.id;
  update public.comprobantes_retencion_v160 set certificado_id=v_cert,establecimiento=v_est,punto_emision=v_pe,secuencial=v_seq,codigo_numerico=v_num,clave_acceso=v_clave,estado='en_cola',emitido_por=auth.uid(),emitido_at=now(),updated_at=now() where id=r.id;
  insert into public.transmisiones_sri_v160(retencion_id,ambiente) values(r.id,r.ambiente);
  insert into public.facturacion_eventos_v160(empresa_id,retencion_id,tipo,estado_anterior,estado_nuevo,detalle,usuario_id,idempotency_key)
  values(r.empresa_id,r.id,'retencion_encolada','preparado','en_cola',jsonb_build_object('clave_acceso',v_clave),auth.uid(),p_idempotency_key);
  return jsonb_build_object('id',r.id,'duplicado',false,'estado','en_cola','clave_acceso',v_clave,'numero',v_est||'-'||v_pe||'-'||v_seq);
end;$fn$;

create or replace function public.reintentar_transmision_sri_v160(p_transmision_id uuid,p_motivo text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare t public.transmisiones_sri_v160%rowtype;v_empresa uuid;v_event uuid;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.reintentar') then raise exception 'No tienes permiso para reintentar transmisiones'; end if;
  if length(btrim(coalesce(p_motivo,'')))<10 or p_idempotency_key is null then raise exception 'Indica un motivo de al menos 10 caracteres y una idempotencia'; end if;
  select id into v_event from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;if found then return jsonb_build_object('id',p_transmision_id,'duplicado',true);end if;
  select * into t from public.transmisiones_sri_v160 where id=p_transmision_id for update;
  if not found or t.estado not in('error','esperando_autorizacion') then raise exception 'La transmision no existe o no admite reintento manual'; end if;
  select empresa_id into v_empresa from public.facturas_electronicas_v160 where id=t.factura_id;
  if v_empresa is null then select empresa_id into v_empresa from public.comprobantes_retencion_v160 where id=t.retencion_id;end if;
  if not public.usuario_puede_empresa(v_empresa,true) then raise exception 'No tienes acceso a la empresa'; end if;
  update public.transmisiones_sri_v160 set estado='pendiente',disponible_at=now(),bloqueado_at=null,bloqueado_por=null,ultimo_error_codigo=null,ultimo_error_mensaje=null,updated_at=now() where id=t.id;
  insert into public.facturacion_eventos_v160(empresa_id,factura_id,retencion_id,tipo,detalle,usuario_id,idempotency_key) values(v_empresa,t.factura_id,t.retencion_id,'transmision_reintentada',jsonb_build_object('motivo',btrim(p_motivo)),auth.uid(),p_idempotency_key);
  return jsonb_build_object('id',t.id,'duplicado',false,'estado','pendiente');
end;$fn$;

create or replace function public.solicitar_anulacion_comprobante_v160(p_tipo text,p_comprobante_id uuid,p_motivo text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_empresa uuid;v_estado text;v_event uuid;
begin
  if not public.usuario_tiene_permiso_v35('facturacion.anular') then raise exception 'No tienes permiso para solicitar anulaciones'; end if;
  if p_tipo not in('factura','retencion') or length(btrim(coalesce(p_motivo,'')))<10 or p_idempotency_key is null then raise exception 'Tipo, motivo de 10 caracteres e idempotencia son obligatorios'; end if;
  select id into v_event from public.facturacion_eventos_v160 where idempotency_key=p_idempotency_key;if found then return jsonb_build_object('id',p_comprobante_id,'duplicado',true);end if;
  if p_tipo='factura' then select empresa_id,estado into v_empresa,v_estado from public.facturas_electronicas_v160 where id=p_comprobante_id for update;
  else select empresa_id,estado into v_empresa,v_estado from public.comprobantes_retencion_v160 where id=p_comprobante_id for update;end if;
  if v_empresa is null or not public.usuario_puede_empresa(v_empresa,true) then raise exception 'El comprobante no existe o no tienes acceso'; end if;
  if v_estado not in('preparado','rechazado','error','autorizado') then raise exception 'El estado actual no permite solicitar anulacion'; end if;
  if p_tipo='factura' then update public.facturas_electronicas_v160 set estado=case when v_estado='autorizado' then 'anulacion_solicitada' else 'cancelado' end,motivo_anulacion=btrim(p_motivo),anulado_por=auth.uid(),anulado_at=now(),updated_at=now() where id=p_comprobante_id;
  else update public.comprobantes_retencion_v160 set estado=case when v_estado='autorizado' then 'anulacion_solicitada' else 'cancelado' end,motivo_anulacion=btrim(p_motivo),anulado_por=auth.uid(),anulado_at=now(),updated_at=now() where id=p_comprobante_id;end if;
  insert into public.facturacion_eventos_v160(empresa_id,factura_id,retencion_id,tipo,estado_anterior,estado_nuevo,detalle,usuario_id,idempotency_key)
  values(v_empresa,case when p_tipo='factura' then p_comprobante_id end,case when p_tipo='retencion' then p_comprobante_id end,'anulacion_solicitada',v_estado,case when v_estado='autorizado' then 'anulacion_solicitada' else 'cancelado' end,jsonb_build_object('motivo',btrim(p_motivo)),auth.uid(),p_idempotency_key);
  return jsonb_build_object('id',p_comprobante_id,'duplicado',false,'estado',case when v_estado='autorizado' then 'anulacion_solicitada' else 'cancelado' end);
end;$fn$;

create or replace function public.listar_comprobantes_electronicos_v160(p_empresa_id uuid,p_tipo text default null,p_estado text default null,p_desde date default current_date-30,p_hasta date default current_date)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_result jsonb;
begin
  if not public.usuario_puede_empresa(p_empresa_id,false) then raise exception 'No tienes acceso a esta empresa'; end if;
  if p_desde>p_hasta or p_hasta-p_desde>366 then raise exception 'El rango de consulta no es valido (maximo 367 dias)'; end if;
  select coalesce(jsonb_agg(x.d order by x.fecha_emision desc,x.created_at desc),'[]'::jsonb) into v_result from(
    select jsonb_build_object('tipo','factura','id',f.id,'fecha_emision',f.fecha_emision,'numero',concat_ws('-',f.establecimiento,f.punto_emision,f.secuencial),'cliente',f.comprador_razon_social,'total',f.importe_total,'estado',f.estado,'clave_acceso',f.clave_acceso,'created_at',f.created_at) d,f.fecha_emision,f.created_at from public.facturas_electronicas_v160 f where f.empresa_id=p_empresa_id and f.fecha_emision between p_desde and p_hasta and (p_tipo is null or p_tipo='factura') and (p_estado is null or f.estado=p_estado)
    union all
    select jsonb_build_object('tipo','retencion','id',r.id,'fecha_emision',r.fecha_emision,'numero',concat_ws('-',r.establecimiento,r.punto_emision,r.secuencial),'cliente',r.sujeto_razon_social,'total',r.total_retenido,'estado',r.estado,'clave_acceso',r.clave_acceso,'created_at',r.created_at),r.fecha_emision,r.created_at from public.comprobantes_retencion_v160 r where r.empresa_id=p_empresa_id and r.fecha_emision between p_desde and p_hasta and (p_tipo is null or p_tipo='retencion') and (p_estado is null or r.estado=p_estado)
  )x;
  return v_result;
end;$fn$;

create or replace function public.obtener_comprobante_electronico_v160(p_tipo text,p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_empresa uuid;v_result jsonb;
begin
  if p_tipo='factura' then
    select empresa_id,jsonb_build_object('tipo','factura','cabecera',to_jsonb(f),'lineas',(select coalesce(jsonb_agg(to_jsonb(l) order by l.numero),'[]') from public.factura_lineas_v160 l where l.factura_id=f.id),'impuestos',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.factura_impuestos_v160 i where i.factura_id=f.id),'pagos',(select coalesce(jsonb_agg(to_jsonb(p) order by p.numero),'[]') from public.factura_pagos_v160 p where p.factura_id=f.id),'transmision',(select to_jsonb(t) from public.transmisiones_sri_v160 t where t.factura_id=f.id),'respuestas',(select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at),'[]') from public.respuestas_sri_v160 s join public.transmisiones_sri_v160 t on t.id=s.transmision_id where t.factura_id=f.id)) into v_empresa,v_result from public.facturas_electronicas_v160 f where f.id=p_id;
  elsif p_tipo='retencion' then
    select empresa_id,jsonb_build_object('tipo','retencion','cabecera',to_jsonb(r),'lineas',(select coalesce(jsonb_agg(to_jsonb(l) order by l.numero),'[]') from public.retencion_lineas_v160 l where l.retencion_id=r.id),'transmision',(select to_jsonb(t) from public.transmisiones_sri_v160 t where t.retencion_id=r.id),'respuestas',(select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at),'[]') from public.respuestas_sri_v160 s join public.transmisiones_sri_v160 t on t.id=s.transmision_id where t.retencion_id=r.id)) into v_empresa,v_result from public.comprobantes_retencion_v160 r where r.id=p_id;
  else raise exception 'Tipo de comprobante no valido';end if;
  if v_empresa is null or not public.usuario_puede_empresa(v_empresa,false) then raise exception 'El comprobante no existe o no tienes acceso'; end if;
  return v_result;
end;$fn$;

-- ------------------------------------------------------------
-- 10. RPC privadas del worker (solo service_role/postgres)
-- ------------------------------------------------------------
create or replace function public.reclamar_transmisiones_sri_v160(p_worker text,p_limite integer default 10)
returns setof public.transmisiones_sri_v160 language plpgsql security definer set search_path='' as $fn$
begin
  return query with candidatas as(
    select id from public.transmisiones_sri_v160 where estado in('pendiente','esperando_autorizacion') and disponible_at<=now() and intentos<max_intentos order by disponible_at,id for update skip locked limit least(greatest(coalesce(p_limite,10),1),50)
  ) update public.transmisiones_sri_v160 t set estado='procesando',intentos=t.intentos+1,bloqueado_at=now(),bloqueado_por=left(p_worker,100),ultimo_intento_at=now(),updated_at=now() from candidatas c where t.id=c.id returning t.*;
end;$fn$;

create or replace function public.registrar_resultado_transmision_sri_v160(p_transmision_id uuid,p_etapa text,p_estado text,p_respuesta jsonb,p_reintentar_en_segundos integer default null)
returns void language plpgsql security definer set search_path='' as $fn$
declare t public.transmisiones_sri_v160%rowtype;v_doc_estado text;v_empresa uuid;v_aut text:=nullif(p_respuesta->>'numero_autorizacion','');
begin
  select * into t from public.transmisiones_sri_v160 where id=p_transmision_id for update;if not found then raise exception 'La transmision no existe';end if;
  insert into public.respuestas_sri_v160(transmision_id,etapa,estado,codigo,identificador,mensaje,informacion_adicional,numero_autorizacion,fecha_autorizacion,respuesta)
  values(t.id,p_etapa,p_estado,nullif(p_respuesta->>'codigo',''),nullif(p_respuesta->>'identificador',''),nullif(p_respuesta->>'mensaje',''),nullif(p_respuesta->>'informacion_adicional',''),v_aut,nullif(p_respuesta->>'fecha_autorizacion','')::timestamptz,coalesce(p_respuesta,'{}'));
  v_doc_estado:=case when p_estado='AUTORIZADO' then 'autorizado' when p_estado in('DEVUELTA','NO AUTORIZADO','RECHAZADO') then 'rechazado' when p_estado='RECIBIDA' then 'recibido' when p_reintentar_en_segundos is not null then 'enviado' else 'error' end;
  update public.transmisiones_sri_v160 set estado=case when p_estado='AUTORIZADO' then 'completada' when p_reintentar_en_segundos is not null then 'esperando_autorizacion' else 'error' end,disponible_at=case when p_reintentar_en_segundos is not null then now()+make_interval(secs=>p_reintentar_en_segundos) else disponible_at end,bloqueado_at=null,bloqueado_por=null,ultimo_error_codigo=case when v_doc_estado in('error','rechazado') then p_respuesta->>'codigo' end,ultimo_error_mensaje=case when v_doc_estado in('error','rechazado') then p_respuesta->>'mensaje' end,completado_at=case when p_estado='AUTORIZADO' then now() end,updated_at=now() where id=t.id;
  if t.factura_id is not null then update public.facturas_electronicas_v160 set estado=v_doc_estado,numero_autorizacion=coalesce(v_aut,numero_autorizacion),autorizado_at=case when p_estado='AUTORIZADO' then coalesce(nullif(p_respuesta->>'fecha_autorizacion','')::timestamptz,now()) else autorizado_at end,xml_firmado_path=coalesce(nullif(p_respuesta->>'xml_firmado_path',''),xml_firmado_path),xml_autorizado_path=coalesce(nullif(p_respuesta->>'xml_autorizado_path',''),xml_autorizado_path),ride_path=coalesce(nullif(p_respuesta->>'ride_path',''),ride_path),updated_at=now() where id=t.factura_id returning empresa_id into v_empresa;
  else update public.comprobantes_retencion_v160 set estado=v_doc_estado,numero_autorizacion=coalesce(v_aut,numero_autorizacion),autorizado_at=case when p_estado='AUTORIZADO' then coalesce(nullif(p_respuesta->>'fecha_autorizacion','')::timestamptz,now()) else autorizado_at end,xml_firmado_path=coalesce(nullif(p_respuesta->>'xml_firmado_path',''),xml_firmado_path),xml_autorizado_path=coalesce(nullif(p_respuesta->>'xml_autorizado_path',''),xml_autorizado_path),ride_path=coalesce(nullif(p_respuesta->>'ride_path',''),ride_path),updated_at=now() where id=t.retencion_id returning empresa_id into v_empresa;end if;
  insert into public.facturacion_eventos_v160(empresa_id,factura_id,retencion_id,tipo,estado_nuevo,detalle) values(v_empresa,t.factura_id,t.retencion_id,'respuesta_sri',v_doc_estado,jsonb_build_object('etapa',p_etapa,'estado_sri',p_estado));
end;$fn$;

-- ------------------------------------------------------------
-- 11. RLS y privilegios: lectura por empresa, toda escritura por RPC
-- ------------------------------------------------------------
do $rls$
declare n text;
begin
  foreach n in array array['configuracion_tributaria_empresas_v160','certificados_firma_v160','series_comprobantes_v160','facturas_electronicas_v160','factura_lineas_v160','factura_impuestos_v160','factura_pagos_v160','comprobantes_retencion_v160','retencion_lineas_v160','transmisiones_sri_v160','respuestas_sri_v160','facturacion_eventos_v160'] loop
    execute format('alter table public.%I enable row level security',n);
    execute format('revoke all on public.%I from public, anon',n);
    execute format('revoke insert,update,delete on public.%I from authenticated',n);
  end loop;
end;$rls$;

create policy leer_config_tributaria_v160 on public.configuracion_tributaria_empresas_v160 for select to authenticated using(public.usuario_puede_empresa(empresa_id,false));
create policy leer_certificados_v160 on public.certificados_firma_v160 for select to authenticated using(public.usuario_tiene_permiso_v35('facturacion.certificados') and public.usuario_puede_empresa(empresa_id,false));
create policy leer_series_v160 on public.series_comprobantes_v160 for select to authenticated using(exists(select 1 from public.empresa_puntos_emision pe join public.empresa_establecimientos ee on ee.id=pe.establecimiento_id where pe.id=punto_emision_id and public.usuario_puede_empresa(ee.empresa_id,false)));
create policy leer_facturas_v160 on public.facturas_electronicas_v160 for select to authenticated using(public.usuario_puede_empresa(empresa_id,false));
create policy leer_factura_lineas_v160 on public.factura_lineas_v160 for select to authenticated using(exists(select 1 from public.facturas_electronicas_v160 f where f.id=factura_id));
create policy leer_factura_impuestos_v160 on public.factura_impuestos_v160 for select to authenticated using(exists(select 1 from public.facturas_electronicas_v160 f where f.id=factura_id));
create policy leer_factura_pagos_v160 on public.factura_pagos_v160 for select to authenticated using(exists(select 1 from public.facturas_electronicas_v160 f where f.id=factura_id));
create policy leer_retenciones_v160 on public.comprobantes_retencion_v160 for select to authenticated using(public.usuario_puede_empresa(empresa_id,false));
create policy leer_retencion_lineas_v160 on public.retencion_lineas_v160 for select to authenticated using(exists(select 1 from public.comprobantes_retencion_v160 r where r.id=retencion_id));
create policy leer_transmisiones_v160 on public.transmisiones_sri_v160 for select to authenticated using(exists(select 1 from public.facturas_electronicas_v160 f where f.id=factura_id) or exists(select 1 from public.comprobantes_retencion_v160 r where r.id=retencion_id));
create policy leer_respuestas_v160 on public.respuestas_sri_v160 for select to authenticated using(exists(select 1 from public.transmisiones_sri_v160 t where t.id=transmision_id));
create policy leer_eventos_v160 on public.facturacion_eventos_v160 for select to authenticated using(public.usuario_puede_empresa(empresa_id,false));

grant select on public.configuracion_tributaria_empresas_v160,public.series_comprobantes_v160,public.facturas_electronicas_v160,public.factura_lineas_v160,public.factura_impuestos_v160,public.factura_pagos_v160,public.comprobantes_retencion_v160,public.retencion_lineas_v160,public.transmisiones_sri_v160,public.respuestas_sri_v160,public.facturacion_eventos_v160 to authenticated;
grant select on public.certificados_firma_v160 to authenticated;

do $funciones$
declare f regprocedure;
begin
  foreach f in array array[
    'public.guardar_configuracion_tributaria_v160(uuid,jsonb,uuid)'::regprocedure,
    'public.registrar_certificado_firma_v160(uuid,jsonb,uuid)'::regprocedure,
    'public.desactivar_certificado_firma_v160(uuid,text,uuid)'::regprocedure,
    'public.configurar_serie_comprobante_v160(uuid,smallint,text,bigint,uuid)'::regprocedure,
    'public.preparar_factura_electronica_v160(jsonb,jsonb,jsonb,jsonb,uuid)'::regprocedure,
    'public.emitir_factura_electronica_v160(uuid,uuid)'::regprocedure,
    'public.preparar_retencion_electronica_v160(jsonb,jsonb,uuid)'::regprocedure,
    'public.emitir_retencion_electronica_v160(uuid,uuid)'::regprocedure,
    'public.reintentar_transmision_sri_v160(uuid,text,uuid)'::regprocedure,
    'public.solicitar_anulacion_comprobante_v160(text,uuid,text,uuid)'::regprocedure,
    'public.listar_comprobantes_electronicos_v160(uuid,text,text,date,date)'::regprocedure,
    'public.obtener_comprobante_electronico_v160(text,uuid)'::regprocedure
  ] loop
    execute format('alter function %s owner to postgres',f);
    execute format('revoke all on function %s from public,anon',f);
    execute format('grant execute on function %s to authenticated',f);
  end loop;
end;$funciones$;

alter function public.reclamar_transmisiones_sri_v160(text,integer) owner to postgres;
alter function public.registrar_resultado_transmision_sri_v160(uuid,text,text,jsonb,integer) owner to postgres;
revoke all on function public.reclamar_transmisiones_sri_v160(text,integer) from public,anon,authenticated;
revoke all on function public.registrar_resultado_transmision_sri_v160(uuid,text,text,jsonb,integer) from public,anon,authenticated;
grant execute on function public.reclamar_transmisiones_sri_v160(text,integer) to service_role;
grant execute on function public.registrar_resultado_transmision_sri_v160(uuid,text,text,jsonb,integer) to service_role;

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v160',160,'v160_base_facturacion_electronica.sql','Base fiscal SRI: configuracion por empresa, certificados por referencia secreta, series atomicas, facturas, retenciones, cola, respuestas, auditoria, permisos y RPC.')
on conflict(id) do update set version=excluded.version,archivo=excluded.archivo,notas=excluded.notas,aplicada_at=now();

notify pgrst,'reload schema';
commit;
