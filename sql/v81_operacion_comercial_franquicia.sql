-- ============================================================
-- BOMAN INVENTARIO - v81: operacion comercial completa de franquicia
-- Turnos/cajas, credito y cartera, devoluciones parciales y referencias.
-- La seleccion masiva de XML se implementa en la interfaz de esta version.
-- Ejecutar una sola vez DESPUES de v80.
-- ============================================================
begin;

-- 1. Permisos -------------------------------------------------------------
insert into public.permisos_sistema as p (codigo, modulo, nombre, descripcion, orden) values
 ('franquicia.turnos', 'Franquicias', 'Operar turnos de caja', 'Abre y cierra la caja fisica del vendedor.', 127),
 ('franquicia.cobros', 'Franquicias', 'Gestionar cuentas por cobrar', 'Crea clientes y registra abonos de ventas a credito.', 128),
 ('franquicia.devoluciones', 'Franquicias', 'Registrar cambios y devoluciones', 'Devuelve parcialmente productos y dinero con trazabilidad.', 129)
on conflict (codigo) do update set nombre=excluded.nombre, descripcion=excluded.descripcion,
  modulo=excluded.modulo, orden=excluded.orden, activo=true, updated_at=now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p where r.rol::text <> 'admin' and p.activo
on conflict (rol, permiso_codigo) do nothing;
update public.rol_permisos set permitido=true, updated_at=now()
where (rol::text='franquiciado' and permiso_codigo in ('franquicia.turnos','franquicia.cobros','franquicia.devoluciones'))
   or (rol::text='vendedor_franquicia' and permiso_codigo='franquicia.turnos');

-- 2. Referencias obligatorias --------------------------------------------
update public.venta_franquicia_pagos set referencia='LEGADO-SIN-REFERENCIA'
where medio_pago in ('transferencia','tarjeta') and btrim(coalesce(referencia,''))='';
update public.franquicia_caja_movimientos set referencia='LEGADO-SIN-REFERENCIA'
where medio_pago in ('transferencia','tarjeta') and btrim(coalesce(referencia,''))='';
alter table public.venta_franquicia_pagos drop constraint if exists venta_pago_referencia_v81;
alter table public.venta_franquicia_pagos add constraint venta_pago_referencia_v81 check (
  medio_pago not in ('transferencia','tarjeta') or btrim(coalesce(referencia,'')) <> '');
alter table public.franquicia_caja_movimientos drop constraint if exists caja_referencia_v81;
alter table public.franquicia_caja_movimientos add constraint caja_referencia_v81 check (
  medio_pago not in ('transferencia','tarjeta') or btrim(coalesce(referencia,'')) <> '');

-- 3. Caja fisica y turno por operador ------------------------------------
create table if not exists public.franquicia_caja_turnos (
 id uuid primary key default gen_random_uuid(),
 franquicia_id uuid not null references public.franquicias(id) on delete restrict,
 almacen_id uuid not null references public.almacenes(id) on delete restrict,
 caja_codigo text not null check (btrim(caja_codigo)<>''),
 turno text not null check (btrim(turno)<>''),
 estado text not null default 'abierto' check (estado in ('abierto','cerrado','reabierto')),
 saldo_inicial numeric(14,2) not null check (saldo_inicial>=0),
 ingresos_efectivo numeric(14,2), egresos_efectivo numeric(14,2),
 efectivo_esperado numeric(14,2), efectivo_contado numeric(14,2), diferencia numeric(14,2),
 ingresos_total numeric(14,2), egresos_total numeric(14,2),
 abierto_por uuid not null references public.perfiles(id) on delete restrict,
 abierto_at timestamptz not null default now(), cerrado_por uuid references public.perfiles(id),
 cerrado_at timestamptz, nota_cierre text, motivo_reapertura text,
 idempotency_apertura uuid not null unique, idempotency_cierre uuid unique
);
create unique index if not exists uq_turno_caja_abierto_v81
 on public.franquicia_caja_turnos(almacen_id,caja_codigo) where estado in ('abierto','reabierto');
create unique index if not exists uq_turno_operador_abierto_v81
 on public.franquicia_caja_turnos(abierto_por) where estado in ('abierto','reabierto');
create index if not exists idx_turnos_franquicia_fecha_v81
 on public.franquicia_caja_turnos(franquicia_id,abierto_at desc);
alter table public.franquicia_caja_movimientos add column if not exists turno_caja_id uuid
 references public.franquicia_caja_turnos(id) on delete restrict;
alter table public.ventas_franquicia add column if not exists turno_caja_id uuid
 references public.franquicia_caja_turnos(id) on delete restrict;

create or replace function public.asignar_turno_caja_movimiento_v81() returns trigger
language plpgsql security definer set search_path='' as $fn$
begin
 if new.almacen_id is null and new.franquicia_id is not null then
   select f.almacen_id into new.almacen_id from public.franquicias f where f.id=new.franquicia_id;
 end if;
 if new.turno_caja_id is null and new.reversa_de_id is not null then
   select turno_caja_id into new.turno_caja_id from public.franquicia_caja_movimientos where id=new.reversa_de_id;
 end if;
 if new.turno_caja_id is null and auth.uid() is not null
    and public.rol_usuario_actual() in ('franquiciado','vendedor_franquicia') then
   select t.id into new.turno_caja_id from public.franquicia_caja_turnos t
   where t.almacen_id=new.almacen_id and t.abierto_por=auth.uid()
     and t.estado in ('abierto','reabierto') order by t.abierto_at desc limit 1;
   if new.turno_caja_id is null then raise exception 'Abre tu turno de caja antes de registrar la operacion'; end if;
 end if;
 if new.turno_caja_id is not null and not exists(
   select 1 from public.franquicia_caja_turnos t where t.id=new.turno_caja_id and t.estado in ('abierto','reabierto')
 ) then raise exception 'El turno asociado ya esta cerrado; registra la correccion en un turno abierto'; end if;
 return new;
end;$fn$;
drop trigger if exists trg_asignar_turno_caja_v81 on public.franquicia_caja_movimientos;
create trigger trg_asignar_turno_caja_v81 before insert on public.franquicia_caja_movimientos
for each row execute function public.asignar_turno_caja_movimiento_v81();

create or replace function public.abrir_turno_caja_v81(p_caja_codigo text,p_turno text,p_saldo numeric,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare f public.franquicias%rowtype; t public.franquicia_caja_turnos%rowtype;
begin
 if not public.usuario_tiene_permiso_v35('franquicia.turnos') then raise exception 'No tienes permiso para operar turnos'; end if;
 if p_idempotency_key is null or btrim(coalesce(p_caja_codigo,''))='' or btrim(coalesce(p_turno,''))='' or coalesce(p_saldo,-1)<0 then raise exception 'Caja, turno, saldo e idempotencia son obligatorios'; end if;
 select * into f from public.franquicias where id=public.franquicia_usuario_actual_v42() and activo;
 if not found then raise exception 'No tienes una franquicia activa'; end if;
 select * into t from public.franquicia_caja_turnos where idempotency_apertura=p_idempotency_key;
 if found then return to_jsonb(t); end if;
 insert into public.franquicia_caja_turnos(franquicia_id,almacen_id,caja_codigo,turno,saldo_inicial,abierto_por,idempotency_apertura)
 values(f.id,f.almacen_id,upper(btrim(p_caja_codigo)),btrim(p_turno),round(p_saldo,2),auth.uid(),p_idempotency_key) returning * into t;
 return to_jsonb(t);
end;$fn$;

create or replace function public.cerrar_turno_caja_v81(p_turno_id uuid,p_efectivo_contado numeric,p_nota text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare t public.franquicia_caja_turnos%rowtype; vi numeric; ve numeric; ti numeric; te numeric;
begin
 select * into t from public.franquicia_caja_turnos where id=p_turno_id for update;
 if not found or (t.abierto_por<>auth.uid() and public.rol_usuario_actual()<>'admin') then raise exception 'Turno no encontrado o sin permiso'; end if;
 if t.estado='cerrado' then return to_jsonb(t); end if;
 if coalesce(p_efectivo_contado,-1)<0 or p_idempotency_key is null then raise exception 'Indica el efectivo contado'; end if;
 select coalesce(sum(monto) filter(where tipo='ingreso' and medio_pago='efectivo'),0),coalesce(sum(monto) filter(where tipo='egreso' and medio_pago='efectivo'),0),coalesce(sum(monto) filter(where tipo='ingreso'),0),coalesce(sum(monto) filter(where tipo='egreso'),0)
 into vi,ve,ti,te from public.franquicia_caja_movimientos where turno_caja_id=t.id and estado='vigente' and reversa_de_id is null;
 update public.franquicia_caja_turnos set estado='cerrado',ingresos_efectivo=vi,egresos_efectivo=ve,
 efectivo_esperado=round(saldo_inicial+vi-ve,2),efectivo_contado=round(p_efectivo_contado,2),
 diferencia=round(p_efectivo_contado-(saldo_inicial+vi-ve),2),ingresos_total=ti,egresos_total=te,
 cerrado_por=auth.uid(),cerrado_at=now(),nota_cierre=nullif(btrim(coalesce(p_nota,'')),''),idempotency_cierre=p_idempotency_key
 where id=t.id returning * into t; return to_jsonb(t);
end;$fn$;

-- 4. Clientes y cartera ---------------------------------------------------
create table if not exists public.clientes_franquicia (
 id uuid primary key default gen_random_uuid(), franquicia_id uuid not null references public.franquicias(id),
 identificacion text, nombre text not null check(btrim(nombre)<>''), telefono text, email text, activo boolean not null default true,
 creado_por uuid not null references public.perfiles(id), created_at timestamptz not null default now(),
 unique(franquicia_id,identificacion)
);
create table if not exists public.cuentas_cobrar_franquicia (
 id uuid primary key default gen_random_uuid(), franquicia_id uuid not null references public.franquicias(id),
 venta_id uuid references public.ventas_franquicia(id), documento_xml_id uuid references public.documentos_venta_xml(id),
 cliente_id uuid not null references public.clientes_franquicia(id), fecha date not null, fecha_vencimiento date not null,
 monto_original numeric(14,2) not null check(monto_original>0), saldo numeric(14,2) not null check(saldo>=0),
 estado text not null default 'pendiente' check(estado in ('pendiente','pagada','anulada')),
 created_at timestamptz not null default now(), check((venta_id is null)<>(documento_xml_id is null))
);
alter table public.cuentas_cobrar_franquicia add column if not exists monto_ajustado numeric(14,2) not null default 0 check(monto_ajustado>=0);
alter table public.cuentas_cobrar_franquicia drop constraint if exists cxc_fechas_v81;
alter table public.cuentas_cobrar_franquicia add constraint cxc_fechas_v81 check(fecha_vencimiento>=fecha);
create unique index if not exists uq_cxc_venta_v81 on public.cuentas_cobrar_franquicia(venta_id) where venta_id is not null;
create unique index if not exists uq_cxc_xml_v81 on public.cuentas_cobrar_franquicia(documento_xml_id) where documento_xml_id is not null;
create index if not exists idx_cxc_franquicia_estado_v81
 on public.cuentas_cobrar_franquicia(franquicia_id,estado,fecha_vencimiento);
create table if not exists public.cobros_franquicia (
 id uuid primary key default gen_random_uuid(), cuenta_id uuid not null references public.cuentas_cobrar_franquicia(id),
 fecha date not null, monto numeric(14,2) not null check(monto>0), medio_pago text not null check(medio_pago in ('efectivo','transferencia','tarjeta')),
 referencia text, idempotency_key uuid not null unique, creado_por uuid not null references public.perfiles(id), created_at timestamptz not null default now(),
 check(medio_pago='efectivo' or btrim(coalesce(referencia,''))<>'')
);
alter table public.ventas_franquicia add column if not exists cliente_id uuid references public.clientes_franquicia(id);
alter table public.ventas_franquicia add column if not exists fecha_vencimiento date;
alter table public.venta_franquicia_pagos drop constraint if exists venta_franquicia_pagos_medio_pago_check;
alter table public.venta_franquicia_pagos add constraint venta_franquicia_pagos_medio_pago_check check(medio_pago in ('efectivo','transferencia','tarjeta','mixto','otro','credito'));
alter table public.ventas_franquicia drop constraint if exists ventas_franquicia_medio_pago_check;
alter table public.ventas_franquicia add constraint ventas_franquicia_medio_pago_check check(medio_pago in ('efectivo','transferencia','tarjeta','mixto','otro','credito'));

-- Las RPC v47 validaban una lista literal. Se amplia sin duplicar sus motores.
do $migra$ declare n text; o oid; d text; nuevo text; begin
 foreach n in array array['registrar_venta_franquicia_v47','aplicar_factura_venta_franquicia_v47'] loop
  select p.oid into o from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='public' and p.proname=n limit 1;
  d:=pg_get_functiondef(o); nuevo:=replace(d,
    $old$('efectivo', 'transferencia', 'tarjeta', 'otro')$old$,
    $new$('efectivo', 'transferencia', 'tarjeta', 'otro', 'credito')$new$);
  if nuevo=d then raise exception 'No se pudo habilitar credito en %',n; end if; execute nuevo;
 end loop;
end;$migra$;

-- Una porcion a credito cuadra la venta, pero no es ingreso de caja.
create or replace function public.omitir_credito_en_caja_v81() returns trigger language plpgsql as $$
begin if new.medio_pago='credito' then return null; end if; return new; end;$$;
drop trigger if exists trg_00_omitir_credito_caja_v81 on public.franquicia_caja_movimientos;
create trigger trg_00_omitir_credito_caja_v81 before insert on public.franquicia_caja_movimientos
for each row execute function public.omitir_credito_en_caja_v81();

create or replace function public.preparar_credito_venta_v81() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is not null and public.rol_usuario_actual() in ('franquiciado','vendedor_franquicia') then
  select t.id into new.turno_caja_id from public.franquicia_caja_turnos t
  where t.franquicia_id=new.franquicia_id and t.abierto_por=auth.uid()
    and t.estado in ('abierto','reabierto') order by t.abierto_at desc limit 1;
  if new.turno_caja_id is null then raise exception 'Abre tu turno de caja antes de registrar la venta'; end if;
 end if;
 if nullif(current_setting('franquicia.cliente_id',true),'') is not null then new.cliente_id=current_setting('franquicia.cliente_id',true)::uuid; end if;
 if nullif(current_setting('franquicia.fecha_vencimiento',true),'') is not null then new.fecha_vencimiento=current_setting('franquicia.fecha_vencimiento',true)::date; end if;
 return new;
end;$$;
drop trigger if exists trg_preparar_credito_venta_v81 on public.ventas_franquicia;
create trigger trg_preparar_credito_venta_v81 before insert on public.ventas_franquicia for each row execute function public.preparar_credito_venta_v81();

create or replace function public.crear_cxc_pago_credito_v81() returns trigger language plpgsql security definer set search_path='' as $fn$
declare v public.ventas_franquicia%rowtype;
begin
 if new.medio_pago<>'credito' then return new; end if;
 select * into v from public.ventas_franquicia where id=new.venta_id;
 if v.cliente_id is null or v.fecha_vencimiento is null then raise exception 'El credito exige cliente y vencimiento'; end if;
 insert into public.cuentas_cobrar_franquicia(franquicia_id,venta_id,cliente_id,fecha,fecha_vencimiento,monto_original,saldo)
 values(v.franquicia_id,v.id,v.cliente_id,v.fecha,v.fecha_vencimiento,new.monto,new.monto);
 return new;
end;$fn$;
drop trigger if exists trg_crear_cxc_pago_v81 on public.venta_franquicia_pagos;
create trigger trg_crear_cxc_pago_v81 after insert on public.venta_franquicia_pagos for each row execute function public.crear_cxc_pago_credito_v81();

create or replace function public.registrar_venta_franquicia_v81(p_fecha date,p_items jsonb,p_pagos jsonb,p_descuento numeric,p_referencia text,p_nota text,p_cliente_id uuid,p_fecha_vencimiento date,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare f uuid; credito numeric;
begin
 select coalesce(sum(x.monto),0) into credito from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb)) x(medio_pago text,monto numeric) where x.medio_pago='credito';
 if exists(select 1 from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb)) x(medio_pago text,referencia text)
   where x.medio_pago in ('transferencia','tarjeta') and btrim(coalesce(x.referencia,''))='') then
  raise exception 'Transferencia y tarjeta requieren numero de referencia';
 end if;
 if credito>0 then
  if not public.usuario_tiene_permiso_v35('franquicia.cobros') then raise exception 'No tienes permiso para vender a credito'; end if;
  select id into f from public.clientes_franquicia where id=p_cliente_id and franquicia_id=public.franquicia_usuario_actual_v42() and activo;
  if not found or p_fecha_vencimiento is null or p_fecha_vencimiento<p_fecha then raise exception 'La venta a credito exige cliente activo y vencimiento valido'; end if;
 end if;
 perform set_config('franquicia.cliente_id',coalesce(p_cliente_id::text,''),true);
 perform set_config('franquicia.fecha_vencimiento',coalesce(p_fecha_vencimiento::text,''),true);
 return public.registrar_venta_franquicia_v50(p_fecha,p_items,p_pagos,p_descuento,p_referencia,p_nota,p_idempotency_key);
end;$fn$;

-- La factura XML comparte las mismas reglas de turno, cliente y cartera.
create or replace function public.aplicar_factura_venta_franquicia_v81(p_documento jsonb,p_asignaciones jsonb,p_pagos jsonb,p_nota text,p_cliente_id uuid,p_fecha_vencimiento date)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare f public.franquicias%rowtype; r jsonb; credito numeric; doc uuid; fecha_doc date;
begin
 select * into f from public.franquicias where id=public.franquicia_usuario_actual_v42() and activo;
 if not found then raise exception 'No tienes una franquicia activa asignada'; end if;
 if not exists(select 1 from public.franquicia_caja_turnos t where t.franquicia_id=f.id and t.abierto_por=auth.uid() and t.estado in ('abierto','reabierto')) then
  raise exception 'Abre tu turno de caja antes de registrar la factura';
 end if;
 select coalesce(sum(x.monto),0) into credito from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb)) x(medio_pago text,monto numeric) where x.medio_pago='credito';
 if exists(select 1 from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb)) x(medio_pago text,referencia text)
   where x.medio_pago in ('transferencia','tarjeta') and btrim(coalesce(x.referencia,''))='') then
  raise exception 'Transferencia y tarjeta requieren numero de referencia';
 end if;
 fecha_doc:=coalesce((p_documento->>'fecha_emision')::date,(now() at time zone 'America/Guayaquil')::date);
 if credito>0 then
  if not public.usuario_tiene_permiso_v35('franquicia.cobros') then raise exception 'No tienes permiso para vender a credito'; end if;
  perform 1 from public.clientes_franquicia where id=p_cliente_id and franquicia_id=f.id and activo;
  if not found or p_fecha_vencimiento is null or p_fecha_vencimiento<fecha_doc then raise exception 'La venta a credito exige cliente activo y vencimiento valido'; end if;
 end if;
 r:=public.aplicar_factura_venta_franquicia_v47(p_documento,p_asignaciones,p_pagos,p_nota);
 if credito>0 and not coalesce((r->>'duplicado')::boolean,false) then
  doc:=nullif(r->>'id','')::uuid;
  insert into public.cuentas_cobrar_franquicia(franquicia_id,documento_xml_id,cliente_id,fecha,fecha_vencimiento,monto_original,saldo)
  values(f.id,doc,p_cliente_id,fecha_doc,p_fecha_vencimiento,round(credito,2),round(credito,2));
 end if;
 return r;
end;$fn$;

create or replace function public.guardar_cliente_franquicia_v81(p_id uuid,p_identificacion text,p_nombre text,p_telefono text,p_email text)
returns uuid language plpgsql security definer set search_path='' as $fn$ declare f uuid; r uuid; begin
 if not public.usuario_tiene_permiso_v35('franquicia.cobros') then raise exception 'No tienes permiso para gestionar clientes'; end if;
 f:=public.franquicia_usuario_actual_v42(); if f is null or btrim(coalesce(p_nombre,''))='' then raise exception 'Nombre y franquicia son obligatorios'; end if;
 insert into public.clientes_franquicia(id,franquicia_id,identificacion,nombre,telefono,email,creado_por)
 values(coalesce(p_id,gen_random_uuid()),f,nullif(btrim(coalesce(p_identificacion,'')),''),btrim(p_nombre),nullif(btrim(coalesce(p_telefono,'')),''),nullif(btrim(coalesce(p_email,'')),''),auth.uid())
 on conflict(id) do update set identificacion=excluded.identificacion,nombre=excluded.nombre,telefono=excluded.telefono,email=excluded.email
 where clientes_franquicia.franquicia_id=f returning id into r; return r; end;$fn$;

create or replace function public.registrar_cobro_franquicia_v81(p_cuenta_id uuid,p_fecha date,p_monto numeric,p_medio text,p_referencia text,p_idempotency_key uuid)
returns uuid language plpgsql security definer set search_path='' as $fn$
declare c public.cuentas_cobrar_franquicia%rowtype; f public.franquicias%rowtype; r uuid;
begin
 if not public.usuario_tiene_permiso_v35('franquicia.cobros') then raise exception 'No tienes permiso para registrar cobros'; end if;
 select id into r from public.cobros_franquicia where idempotency_key=p_idempotency_key;
 if found then return r; end if;
 select * into c from public.cuentas_cobrar_franquicia where id=p_cuenta_id for update;
 if not found or c.franquicia_id<>public.franquicia_usuario_actual_v42() or c.estado<>'pendiente' then raise exception 'Cuenta no disponible'; end if;
 if coalesce(p_monto,0)<=0 or p_monto>c.saldo then raise exception 'Monto de cobro invalido'; end if;
 if p_fecha is null or p_fecha<c.fecha or p_fecha>(now() at time zone 'America/Guayaquil')::date then raise exception 'Fecha de cobro invalida'; end if;
 if p_medio not in ('efectivo','transferencia','tarjeta') or (p_medio<>'efectivo' and btrim(coalesce(p_referencia,''))='') then raise exception 'Medio o referencia invalido'; end if;
 insert into public.cobros_franquicia(cuenta_id,fecha,monto,medio_pago,referencia,idempotency_key,creado_por)
 values(c.id,p_fecha,round(p_monto,2),p_medio,nullif(btrim(coalesce(p_referencia,'')),''),p_idempotency_key,auth.uid()) returning id into r;
 update public.cuentas_cobrar_franquicia set saldo=saldo-round(p_monto,2),estado=case when saldo-round(p_monto,2)=0 then 'pagada' else 'pendiente' end where id=c.id;
 select * into f from public.franquicias where id=c.franquicia_id;
 insert into public.franquicia_caja_movimientos(franquicia_id,almacen_id,fecha,tipo,categoria,concepto,monto,medio_pago,referencia,idempotency_key,creado_por)
 values(f.id,f.almacen_id,p_fecha,'ingreso','cobro_credito','Cobro de venta a credito',round(p_monto,2),p_medio,nullif(btrim(coalesce(p_referencia,'')),''),p_idempotency_key,auth.uid()); return r;
end;$fn$;

-- 5. Devolucion parcial ---------------------------------------------------
create table if not exists public.devoluciones_franquicia(
 id uuid primary key default gen_random_uuid(),venta_id uuid not null references public.ventas_franquicia(id),numero integer not null,
 fecha date not null,monto numeric(14,2) not null check(monto>=0),motivo text not null check(length(btrim(motivo))>=10),
 idempotency_key uuid not null unique,creado_por uuid not null references public.perfiles(id),created_at timestamptz not null default now(),unique(venta_id,numero));
create table if not exists public.devolucion_franquicia_lineas(id uuid primary key default gen_random_uuid(),devolucion_id uuid not null references public.devoluciones_franquicia(id),venta_linea_id uuid not null references public.venta_franquicia_lineas(id),cantidad integer not null check(cantidad>0),monto numeric(14,2) not null check(monto>=0),unique(devolucion_id,venta_linea_id));
create index if not exists idx_devolucion_linea_venta_v81 on public.devolucion_franquicia_lineas(venta_linea_id);

create or replace function public.registrar_devolucion_franquicia_v81(p_venta_id uuid,p_fecha date,p_items jsonb,p_reembolsos jsonb,p_motivo text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v public.ventas_franquicia%rowtype; f public.franquicias%rowtype; d uuid; n integer; total numeric; factor numeric; it record; pg record; cxc uuid;
begin
 if not public.usuario_tiene_permiso_v35('franquicia.devoluciones') then raise exception 'No tienes permiso para registrar devoluciones'; end if;
 select id into d from public.devoluciones_franquicia where idempotency_key=p_idempotency_key;
 if found then select numero,monto into n,total from public.devoluciones_franquicia where id=d; return jsonb_build_object('id',d,'numero',n,'monto',total,'duplicado',true); end if;
 if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'Explica el motivo con al menos 10 caracteres'; end if;
 if p_idempotency_key is null or jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)=0
    or jsonb_typeof(coalesce(p_reembolsos,'null'::jsonb))<>'array' or jsonb_array_length(p_reembolsos)=0 then
  raise exception 'Productos, reembolso e idempotencia son obligatorios';
 end if;
 select * into v from public.ventas_franquicia where id=p_venta_id and estado='registrada' for update;
 if not found or v.franquicia_id<>public.franquicia_usuario_actual_v42() then raise exception 'Venta no disponible'; end if;
 if p_fecha is null or p_fecha<v.fecha or p_fecha>(now() at time zone 'America/Guayaquil')::date then raise exception 'Fecha de devolucion invalida'; end if;
 if exists(select 1 from jsonb_to_recordset(p_items)x(linea_id uuid,cantidad integer) left join public.venta_franquicia_lineas l on l.id=x.linea_id and l.venta_id=v.id where l.id is null or x.cantidad<=0 or x.cantidad>l.cantidad-coalesce((select sum(dl.cantidad) from public.devolucion_franquicia_lineas dl join public.devoluciones_franquicia dd on dd.id=dl.devolucion_id where dl.venta_linea_id=l.id),0)) then raise exception 'Cantidad de devolucion invalida'; end if;
 factor:=case when v.subtotal>0 then v.total/v.subtotal else 1 end;
 select round(sum(x.cantidad*(l.total/l.cantidad)*factor),2) into total from jsonb_to_recordset(p_items)x(linea_id uuid,cantidad integer) join public.venta_franquicia_lineas l on l.id=x.linea_id;
 if exists(select 1 from jsonb_to_recordset(p_reembolsos)x(medio_pago text,monto numeric,referencia text) where coalesce(x.monto,0)<=0) then raise exception 'Los montos de reembolso deben ser mayores a cero'; end if;
 if total<>(select round(coalesce(sum(x.monto),0),2) from jsonb_to_recordset(p_reembolsos)x(medio_pago text,monto numeric,referencia text)) then raise exception 'El reembolso debe coincidir con el valor devuelto'; end if;
 select coalesce(max(numero),0)+1 into n from public.devoluciones_franquicia where venta_id=v.id;
 insert into public.devoluciones_franquicia(venta_id,numero,fecha,monto,motivo,idempotency_key,creado_por) values(v.id,n,p_fecha,total,btrim(p_motivo),p_idempotency_key,auth.uid()) returning id into d;
 select * into f from public.franquicias where id=v.franquicia_id;
 for it in select x.linea_id,x.cantidad,l.producto_id,round(x.cantidad*(l.total/l.cantidad)*factor,2) monto from jsonb_to_recordset(p_items)x(linea_id uuid,cantidad integer) join public.venta_franquicia_lineas l on l.id=x.linea_id loop
  insert into public.devolucion_franquicia_lineas(devolucion_id,venta_linea_id,cantidad,monto) values(d,it.linea_id,it.cantidad,it.monto);
  perform public.aplicar_movimiento_stock_v20(it.producto_id,f.almacen_id,f.empresa_id,'devolucion_venta'::public.tipo_movimiento,it.cantidad,d,'devolucion_franquicia','Devolucion parcial venta #'||v.numero,null,null,gen_random_uuid());
 end loop;
 for pg in select a.n::integer,x.* from jsonb_array_elements(p_reembolsos) with ordinality a(j,n) cross join lateral jsonb_to_record(a.j)x(medio_pago text,monto numeric,referencia text) loop
  if pg.medio_pago not in ('efectivo','transferencia','tarjeta','credito')
     or (pg.medio_pago in ('transferencia','tarjeta') and btrim(coalesce(pg.referencia,''))='') then raise exception 'Reembolso o referencia invalida'; end if;
  if pg.medio_pago='credito' then
   cxc:=null;
   update public.cuentas_cobrar_franquicia set saldo=saldo-pg.monto,monto_ajustado=monto_ajustado+pg.monto,
     estado=case when saldo-pg.monto=0 then 'pagada' else 'pendiente' end
   where venta_id=v.id and estado='pendiente' and saldo>=pg.monto returning id into cxc;
   if cxc is null then raise exception 'El ajuste supera el saldo pendiente de la venta'; end if;
  else
   insert into public.franquicia_caja_movimientos(franquicia_id,almacen_id,fecha,tipo,categoria,concepto,monto,medio_pago,referencia,idempotency_key,creado_por)
   values(f.id,f.almacen_id,p_fecha,'egreso','devolucion','Devolucion venta #'||v.numero,pg.monto,pg.medio_pago,nullif(btrim(coalesce(pg.referencia,'')),''),md5(p_idempotency_key::text||':'||pg.n)::uuid,auth.uid());
  end if;
 end loop; return jsonb_build_object('id',d,'numero',n,'monto',total);
end;$fn$;

-- Una anulacion total despues de una devolucion parcial duplicaria el retorno
-- de stock. Una venta a credito cobrada tampoco puede anularse silenciosamente.
create or replace function public.validar_anulacion_venta_v81() returns trigger
language plpgsql security definer set search_path='' as $fn$
begin
 if new.estado='anulada' and old.estado<>'anulada' then
  if exists(select 1 from public.devoluciones_franquicia d where d.venta_id=old.id) then
   raise exception 'La venta ya tiene devoluciones parciales y no admite anulacion total';
  end if;
  if exists(select 1 from public.cuentas_cobrar_franquicia c join public.cobros_franquicia x on x.cuenta_id=c.id where c.venta_id=old.id) then
   raise exception 'La venta a credito ya tiene cobros y no admite anulacion total';
  end if;
  update public.cuentas_cobrar_franquicia set estado='anulada',saldo=0 where venta_id=old.id and estado='pendiente';
 end if;
 return new;
end;$fn$;
drop trigger if exists trg_validar_anulacion_venta_v81 on public.ventas_franquicia;
create trigger trg_validar_anulacion_venta_v81 before update of estado on public.ventas_franquicia
for each row execute function public.validar_anulacion_venta_v81();

-- 6. Lectura segura -------------------------------------------------------
create or replace view public.vista_turnos_caja_franquicia_v81 with(security_invoker=true) as
select t.*,p.nombre_completo operador
from public.franquicia_caja_turnos t join public.perfiles p on p.id=t.abierto_por;

create or replace view public.vista_cartera_franquicia_v81 with(security_invoker=true) as
select c.*,cl.nombre cliente,cl.identificacion,cl.telefono,v.numero venta_numero,
 case when c.estado='pendiente' and c.fecha_vencimiento<(now() at time zone 'America/Guayaquil')::date then true else false end vencida
from public.cuentas_cobrar_franquicia c join public.clientes_franquicia cl on cl.id=c.cliente_id
left join public.ventas_franquicia v on v.id=c.venta_id;

alter table public.franquicia_caja_turnos enable row level security; alter table public.clientes_franquicia enable row level security;
alter table public.cuentas_cobrar_franquicia enable row level security; alter table public.cobros_franquicia enable row level security;
alter table public.devoluciones_franquicia enable row level security; alter table public.devolucion_franquicia_lineas enable row level security;
drop policy if exists leer_turnos_v81 on public.franquicia_caja_turnos;
create policy leer_turnos_v81 on public.franquicia_caja_turnos for select to authenticated using(public.usuario_puede_franquicia_v42(franquicia_id,false,false));
drop policy if exists leer_clientes_v81 on public.clientes_franquicia;
create policy leer_clientes_v81 on public.clientes_franquicia for select to authenticated using(public.usuario_puede_franquicia_v42(franquicia_id,false,false) and public.usuario_tiene_permiso_v35('franquicia.cobros'));
drop policy if exists leer_cxc_v81 on public.cuentas_cobrar_franquicia;
create policy leer_cxc_v81 on public.cuentas_cobrar_franquicia for select to authenticated using(public.usuario_puede_franquicia_v42(franquicia_id,false,false) and public.usuario_tiene_permiso_v35('franquicia.cobros'));
drop policy if exists leer_cobros_v81 on public.cobros_franquicia;
create policy leer_cobros_v81 on public.cobros_franquicia for select to authenticated using(public.usuario_tiene_permiso_v35('franquicia.cobros') and exists(select 1 from public.cuentas_cobrar_franquicia c where c.id=cuenta_id and public.usuario_puede_franquicia_v42(c.franquicia_id,false,false)));
drop policy if exists leer_devoluciones_v81 on public.devoluciones_franquicia;
create policy leer_devoluciones_v81 on public.devoluciones_franquicia for select to authenticated using(public.usuario_tiene_permiso_v35('franquicia.devoluciones') and exists(select 1 from public.ventas_franquicia v where v.id=venta_id and public.usuario_puede_franquicia_v42(v.franquicia_id,false,false)));
drop policy if exists leer_devolucion_lineas_v81 on public.devolucion_franquicia_lineas;
create policy leer_devolucion_lineas_v81 on public.devolucion_franquicia_lineas for select to authenticated using(public.usuario_tiene_permiso_v35('franquicia.devoluciones') and exists(select 1 from public.devoluciones_franquicia d join public.ventas_franquicia v on v.id=d.venta_id where d.id=devolucion_id and public.usuario_puede_franquicia_v42(v.franquicia_id,false,false)));

revoke all on public.franquicia_caja_turnos,public.clientes_franquicia,public.cuentas_cobrar_franquicia,public.cobros_franquicia,public.devoluciones_franquicia,public.devolucion_franquicia_lineas from public,anon;
revoke insert,update,delete on public.franquicia_caja_turnos,public.clientes_franquicia,public.cuentas_cobrar_franquicia,public.cobros_franquicia,public.devoluciones_franquicia,public.devolucion_franquicia_lineas from authenticated;
grant select on public.franquicia_caja_turnos,public.clientes_franquicia,public.cuentas_cobrar_franquicia,public.cobros_franquicia,public.devoluciones_franquicia,public.devolucion_franquicia_lineas,public.vista_turnos_caja_franquicia_v81,public.vista_cartera_franquicia_v81 to authenticated;
revoke all on function public.abrir_turno_caja_v81(text,text,numeric,uuid),public.cerrar_turno_caja_v81(uuid,numeric,text,uuid),public.registrar_venta_franquicia_v81(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid),public.aplicar_factura_venta_franquicia_v81(jsonb,jsonb,jsonb,text,uuid,date),public.guardar_cliente_franquicia_v81(uuid,text,text,text,text),public.registrar_cobro_franquicia_v81(uuid,date,numeric,text,text,uuid),public.registrar_devolucion_franquicia_v81(uuid,date,jsonb,jsonb,text,uuid) from public,anon;
grant execute on function public.abrir_turno_caja_v81(text,text,numeric,uuid),public.cerrar_turno_caja_v81(uuid,numeric,text,uuid),public.registrar_venta_franquicia_v81(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid),public.aplicar_factura_venta_franquicia_v81(jsonb,jsonb,jsonb,text,uuid,date),public.guardar_cliente_franquicia_v81(uuid,text,text,text,text),public.registrar_cobro_franquicia_v81(uuid,date,numeric,text,text,uuid),public.registrar_devolucion_franquicia_v81(uuid,date,jsonb,jsonb,text,uuid) to authenticated;
revoke execute on function public.registrar_venta_franquicia_v50(date,jsonb,jsonb,numeric,text,text,uuid),public.aplicar_factura_venta_franquicia_v47(jsonb,jsonb,jsonb,text) from authenticated;
commit;
