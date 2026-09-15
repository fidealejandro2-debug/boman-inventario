-- ============================================================
-- BOMAN INVENTARIO - v143
-- Servicios en Caja BomanSport: catalogo separado, venta mixta y cero stock.
-- ============================================================
begin;
select pg_advisory_xact_lock(14309142026);

do $req$ begin
 if to_regclass('public.schema_migrations_boman') is null
    or to_regprocedure('public.registrar_venta_franquicia_v81(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid)') is null then
  raise exception 'Falta instalar la operacion de franquicias hasta v81';
 end if;
end $req$;

create table if not exists public.servicios_franquicia_v143(
 id uuid primary key default gen_random_uuid(),
 franquicia_id uuid not null references public.franquicias(id) on delete restrict,
 codigo text not null,
 nombre text not null check(btrim(nombre)<>''),
 precio numeric(14,2) not null check(precio>=0),
 activo boolean not null default true,
 creado_por uuid not null references public.perfiles(id) on delete restrict,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(franquicia_id,codigo), unique(franquicia_id,nombre)
);

alter table public.venta_franquicia_lineas alter column producto_id drop not null;
alter table public.venta_franquicia_lineas
 add column if not exists servicio_id uuid references public.servicios_franquicia_v143(id) on delete restrict,
 add column if not exists tipo_item text not null default 'producto',
 add column if not exists descripcion text;
update public.venta_franquicia_lineas l set descripcion=p.nombre
from public.productos p where p.id=l.producto_id and l.descripcion is null;
alter table public.venta_franquicia_lineas drop constraint if exists venta_linea_tipo_v143;
alter table public.venta_franquicia_lineas add constraint venta_linea_tipo_v143 check(
 (tipo_item='producto' and producto_id is not null and servicio_id is null)
 or (tipo_item='servicio' and producto_id is null and servicio_id is not null)
);
create unique index if not exists uq_venta_servicio_v143
 on public.venta_franquicia_lineas(venta_id,servicio_id) where servicio_id is not null;

alter table public.servicios_franquicia_v143 enable row level security;
drop policy if exists leer_servicios_v143 on public.servicios_franquicia_v143;
create policy leer_servicios_v143 on public.servicios_franquicia_v143 for select to authenticated
 using(public.usuario_puede_franquicia_v42(franquicia_id,false,false));
revoke all on public.servicios_franquicia_v143 from public,anon;
revoke insert,update,delete on public.servicios_franquicia_v143 from authenticated;
grant select on public.servicios_franquicia_v143 to authenticated;

create or replace function public.guardar_servicio_franquicia_v143(p_id uuid,p_nombre text,p_precio numeric)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare f uuid; r public.servicios_franquicia_v143%rowtype; n integer;
begin
 if public.rol_usuario_actual() not in ('franquiciado','vendedor_franquicia')
    or not public.usuario_tiene_permiso_v35('franquicia.ventas') then
  raise exception 'No tienes permiso para gestionar servicios de Caja';
 end if;
 f:=public.franquicia_usuario_actual_v42();
 if f is null or btrim(coalesce(p_nombre,''))='' or coalesce(p_precio,-1)<0 then
  raise exception 'Nombre y precio del servicio son obligatorios';
 end if;
 if p_id is null then
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(f::text,143));
  select coalesce(max(nullif(regexp_replace(codigo,'\D','','g'),'' )::integer),0)+1 into n
  from public.servicios_franquicia_v143 where franquicia_id=f;
  insert into public.servicios_franquicia_v143(franquicia_id,codigo,nombre,precio,creado_por)
  values(f,'SRV-'||lpad(n::text,4,'0'),btrim(p_nombre),round(p_precio,2),auth.uid()) returning * into r;
 else
  update public.servicios_franquicia_v143 set nombre=btrim(p_nombre),precio=round(p_precio,2),updated_at=now()
  where id=p_id and franquicia_id=f returning * into r;
  if not found then raise exception 'El servicio no existe en este local'; end if;
 end if;
 return jsonb_build_object('id',r.id,'codigo',r.codigo,'nombre',r.nombre,'precio',r.precio,'activo',r.activo);
exception when unique_violation then raise exception 'Ya existe un servicio con ese nombre';
end $fn$;

create or replace function public.registrar_venta_franquicia_v143(
 p_fecha date,p_items jsonb,p_pagos jsonb,p_descuento numeric,p_referencia text,p_nota text,
 p_cliente_id uuid,p_fecha_vencimiento date,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
 f public.franquicias%rowtype; venta uuid; numero integer; subtotal numeric(14,2); descuento numeric(14,2):=round(coalesce(p_descuento,0),2);
 total numeric(14,2); medio text; it record; pg record; pago uuid; credito numeric; puede_precio boolean; puede_descuento boolean;
begin
 if public.rol_usuario_actual() not in ('franquiciado','vendedor_franquicia') or not public.usuario_tiene_permiso_v35('franquicia.ventas') then raise exception 'No tienes permiso para registrar ventas'; end if;
 if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
 select * into f from public.franquicias where id=public.franquicia_usuario_actual_v42() and activo;
 if not found then raise exception 'No tienes una franquicia activa asignada'; end if;
 if p_fecha is null or p_fecha>(now() at time zone 'America/Guayaquil')::date then raise exception 'La fecha de venta no es valida'; end if;
 if jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Agrega al menos un producto o servicio'; end if;
 if exists(select 1 from jsonb_to_recordset(p_items)x(tipo text,producto_id uuid,servicio_id uuid,cantidad integer,precio_unitario numeric,descuento numeric)
   left join public.productos p on x.tipo='producto' and p.id=x.producto_id and p.activo
   left join public.servicios_franquicia_v143 s on x.tipo='servicio' and s.id=x.servicio_id and s.franquicia_id=f.id and s.activo
   where x.tipo not in ('producto','servicio') or (x.tipo='producto' and p.id is null) or (x.tipo='servicio' and s.id is null)
    or coalesce(x.cantidad,0)<=0 or coalesce(x.precio_unitario,-1)<0 or coalesce(x.descuento,0)<0 or coalesce(x.descuento,0)>x.cantidad*x.precio_unitario)
 then raise exception 'La venta contiene productos, servicios, cantidades o valores invalidos'; end if;
 if exists(select tipo,coalesce(producto_id,servicio_id) from jsonb_to_recordset(p_items)x(tipo text,producto_id uuid,servicio_id uuid)
   group by tipo,coalesce(producto_id,servicio_id) having count(*)>1) then raise exception 'La venta contiene items repetidos'; end if;

 puede_precio:=public.usuario_tiene_permiso_v35('franquicia.precio_libre'); puede_descuento:=public.usuario_tiene_permiso_v35('franquicia.descuento');
 if not puede_descuento and (descuento<>0 or exists(select 1 from jsonb_to_recordset(p_items)x(descuento numeric)where coalesce(x.descuento,0)<>0)) then raise exception 'No tienes permiso para aplicar descuentos'; end if;
 if not puede_precio and exists(
   select 1 from jsonb_to_recordset(p_items)x(tipo text,producto_id uuid,servicio_id uuid,precio_unitario numeric)
   left join public.productos p on p.id=x.producto_id left join public.servicios_franquicia_v143 s on s.id=x.servicio_id
   where round(x.precio_unitario,2)<>round(case when x.tipo='producto' then p.precio else s.precio end,2)
      or case when x.tipo='producto' then p.precio else s.precio end is null
 ) then raise exception 'No tienes permiso para cambiar el precio de catalogo'; end if;

 select id into venta from public.ventas_franquicia where idempotency_key=p_idempotency_key and franquicia_id=f.id;
 if found then return jsonb_build_object('id',venta,'duplicado',true); end if;
 select round(sum(x.cantidad*x.precio_unitario-coalesce(x.descuento,0)),2) into subtotal
 from jsonb_to_recordset(p_items)x(cantidad integer,precio_unitario numeric,descuento numeric);
 if descuento<0 or descuento>subtotal then raise exception 'El descuento general no es valido'; end if; total:=subtotal-descuento;
 if jsonb_typeof(coalesce(p_pagos,'[]'::jsonb))<>'array' then raise exception 'El desglose de pagos no es valido'; end if;
 if total>0 and (jsonb_array_length(p_pagos)=0 or exists(select 1 from jsonb_to_recordset(p_pagos)x(medio_pago text,monto numeric)where x.medio_pago not in ('efectivo','transferencia','tarjeta','otro','credito')or round(coalesce(x.monto,0),2)<=0)) then raise exception 'Distribuye el total entre medios de pago validos'; end if;
 if exists(select medio_pago from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb))x(medio_pago text)group by medio_pago having count(*)>1) then raise exception 'Agrupa cada medio de pago en una sola linea'; end if;
 if total>0 and (select round(sum(x.monto),2)from jsonb_to_recordset(p_pagos)x(monto numeric))<>total then raise exception 'La suma de pagos debe ser exactamente igual al total'; end if;
 select coalesce(sum(x.monto),0)into credito from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb))x(medio_pago text,monto numeric)where x.medio_pago='credito';
 if exists(select 1 from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb))x(medio_pago text,referencia text)where x.medio_pago in('transferencia','tarjeta')and btrim(coalesce(x.referencia,''))='')then raise exception 'Transferencia y tarjeta requieren numero de referencia';end if;
 if credito>0 then
  if not public.usuario_tiene_permiso_v35('franquicia.cobros')then raise exception 'No tienes permiso para vender a credito';end if;
  perform 1 from public.clientes_franquicia where id=p_cliente_id and franquicia_id=f.id and activo;
  if not found or p_fecha_vencimiento is null or p_fecha_vencimiento<p_fecha then raise exception 'La venta a credito exige cliente activo y vencimiento valido';end if;
 end if;
 perform set_config('franquicia.cliente_id',coalesce(p_cliente_id::text,''),true);perform set_config('franquicia.fecha_vencimiento',coalesce(p_fecha_vencimiento::text,''),true);
 select case when count(*)=1 then min(x.medio_pago)else'mixto'end into medio from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb))x(medio_pago text);medio:=coalesce(medio,'otro');
 perform pg_advisory_xact_lock(pg_catalog.hashtextextended(f.id::text,143));select coalesce(max(v.numero),0)+1 into numero from public.ventas_franquicia v where v.franquicia_id=f.id;
 insert into public.ventas_franquicia(franquicia_id,numero,fecha,medio_pago,subtotal,descuento,total,referencia,nota,idempotency_key,creada_por)
 values(f.id,numero,p_fecha,medio,subtotal,descuento,total,nullif(btrim(p_referencia),''),nullif(btrim(p_nota),''),p_idempotency_key,auth.uid())returning id into venta;
 insert into public.venta_franquicia_lineas(venta_id,producto_id,servicio_id,tipo_item,descripcion,cantidad,precio_unitario,descuento,total)
 select venta,x.producto_id,x.servicio_id,x.tipo,case when x.tipo='producto'then p.nombre else s.nombre end,x.cantidad,round(x.precio_unitario,2),round(coalesce(x.descuento,0),2),round(x.cantidad*x.precio_unitario-coalesce(x.descuento,0),2)
 from jsonb_to_recordset(p_items)x(tipo text,producto_id uuid,servicio_id uuid,cantidad integer,precio_unitario numeric,descuento numeric)
 left join public.productos p on p.id=x.producto_id left join public.servicios_franquicia_v143 s on s.id=x.servicio_id;
 for it in select * from public.venta_franquicia_lineas where venta_id=venta and producto_id is not null order by producto_id loop
  perform public.aplicar_movimiento_stock_v20(it.producto_id,f.almacen_id,f.empresa_id,'salida'::public.tipo_movimiento,-it.cantidad,venta,'venta_franquicia','Venta franquicia #'||numero,null,null,gen_random_uuid());
 end loop;
 for pg in select a.numero::integer,x.* from jsonb_array_elements(coalesce(p_pagos,'[]'::jsonb))with ordinality a(valor,numero)cross join lateral jsonb_to_record(a.valor)as x(medio_pago text,monto numeric,referencia text)loop
  insert into public.venta_franquicia_pagos(venta_id,numero,medio_pago,monto,referencia)values(venta,pg.numero,pg.medio_pago,round(pg.monto,2),nullif(btrim(pg.referencia),''))returning id into pago;
  insert into public.franquicia_caja_movimientos(franquicia_id,fecha,tipo,categoria,concepto,monto,medio_pago,referencia,venta_id,venta_pago_id,idempotency_key,creado_por)
  values(f.id,p_fecha,'ingreso','venta','Venta #'||numero,round(pg.monto,2),pg.medio_pago,nullif(btrim(pg.referencia),''),venta,pago,md5(venta::text||':'||pago::text)::uuid,auth.uid());
 end loop;
 return jsonb_build_object('id',venta,'numero',numero,'total',total,'duplicado',false);
end $fn$;

-- Al anular, los servicios revierten caja pero nunca generan stock.
do $ajuste$ declare o oid;d text;n text;begin
 select p.oid into o from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='public'and p.proname='anular_venta_franquicia_v47'limit 1;
 d:=pg_get_functiondef(o);if position('where venta_id = v.id and producto_id is not null' in d)=0 then
  n:=replace(d,'where venta_id = v.id order by producto_id','where venta_id = v.id and producto_id is not null order by producto_id');
  if n=d then raise exception 'No se pudo proteger la anulacion de servicios';end if;execute n;
 end if;
end $ajuste$;

-- Una devolucion parcial de servicio devuelve dinero, pero no existencias.
do $ajuste_devolucion$ declare o oid;d text;n text;viejo text;nuevo text;begin
 select p.oid into o from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
 where ns.nspname='public'and p.proname='registrar_devolucion_franquicia_v81'limit 1;
 d:=pg_get_functiondef(o);
 if position('if it.producto_id is not null then' in d)=0 then
  viejo:=$old$  perform public.aplicar_movimiento_stock_v20(it.producto_id,f.almacen_id,f.empresa_id,'devolucion_venta'::public.tipo_movimiento,it.cantidad,d,'devolucion_franquicia','Devolucion parcial venta #'||v.numero,null,null,gen_random_uuid());$old$;
  nuevo:=$new$  if it.producto_id is not null then
   perform public.aplicar_movimiento_stock_v20(it.producto_id,f.almacen_id,f.empresa_id,'devolucion_venta'::public.tipo_movimiento,it.cantidad,d,'devolucion_franquicia','Devolucion parcial venta #'||v.numero,null,null,gen_random_uuid());
  end if;$new$;
  n:=replace(d,viejo,nuevo);if n=d then raise exception 'No se pudo proteger la devolucion parcial de servicios';end if;execute n;
 end if;
end $ajuste_devolucion$;

alter function public.guardar_servicio_franquicia_v143(uuid,text,numeric) owner to postgres;
alter function public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid) owner to postgres;
revoke all on function public.guardar_servicio_franquicia_v143(uuid,text,numeric),public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid) from public,anon;
grant execute on function public.guardar_servicio_franquicia_v143(uuid,text,numeric),public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid) to authenticated;
insert into public.schema_migrations_boman(id,version,archivo,notas)values('v143','143','v143_servicios_caja_bomansport.sql','Servicios separados de productos en Caja BomanSport')on conflict(id)do update set version=excluded.version,archivo=excluded.archivo,notas=excluded.notas,aplicada_at=now();
commit;notify pgrst,'reload schema';
