-- ============================================================
-- v149 - Comprobante obligatorio en transferencias también para el flujo
-- de venta de FRANQUICIA (el pedido no distinguió tienda de franquicia).
--
-- Reusa el bucket ventas-comprobantes y las RPC de comprobante de v148
-- (ya quedaron almacen-scoped, y una franquicia tiene almacen_id igual que
-- una tienda) -no se duplica bucket ni tabla de staging.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v149', 0));

do $requisitos$
begin
  if to_regprocedure('public.preparar_comprobante_venta_v148(uuid,text,text,bigint,uuid)') is null then
    raise exception 'Falta v148: instala primero venta rapida y comprobantes de venta';
  end if;
  if to_regprocedure('public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid)') is null then
    raise exception 'Falta v143: instala primero registrar_venta_franquicia_v143';
  end if;
end;
$requisitos$;

alter table public.venta_franquicia_pagos
  add column if not exists comprobante_storage_path text,
  add column if not exists comprobante_nombre text,
  add column if not exists comprobante_mime_type text,
  add column if not exists comprobante_tamano_bytes bigint;

create unique index if not exists uq_venta_franquicia_pago_comprobante_path_v149
  on public.venta_franquicia_pagos(comprobante_storage_path)
  where comprobante_storage_path is not null;

-- create or replace: la firma NO cambia (p_pagos ya es jsonb; cada linea
-- ahora puede traer un campo extra "comprobante_id" que las llamadas
-- existentes simplemente no mandan -jsonb_to_recordset lo deja null). No
-- hace falta el drop+create que otros cambios de firma sí necesitaron.
create or replace function public.registrar_venta_franquicia_v143(
 p_fecha date,p_items jsonb,p_pagos jsonb,p_descuento numeric,p_referencia text,p_nota text,
 p_cliente_id uuid,p_fecha_vencimiento date,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
 f public.franquicias%rowtype; venta uuid; numero integer; subtotal numeric(14,2); descuento numeric(14,2):=round(coalesce(p_descuento,0),2);
 total numeric(14,2); medio text; it record; pg record; pago uuid; credito numeric; puede_precio boolean; puede_descuento boolean;
 v_comprobante public.venta_comprobantes_pendientes_v148%rowtype;
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
 -- v149: la transferencia ademas exige comprobante adjunto (no solo referencia de texto).
 if exists(select 1 from jsonb_to_recordset(coalesce(p_pagos,'[]'::jsonb))x(medio_pago text,comprobante_id uuid)where x.medio_pago='transferencia' and x.comprobante_id is null)then raise exception 'Las ventas con transferencia requieren comprobante adjunto';end if;
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
 for pg in select a.numero::integer,x.* from jsonb_array_elements(coalesce(p_pagos,'[]'::jsonb))with ordinality a(valor,numero)cross join lateral jsonb_to_record(a.valor)as x(medio_pago text,monto numeric,referencia text,comprobante_id uuid)loop
  v_comprobante := null;
  if pg.comprobante_id is not null then
    select * into v_comprobante
    from public.venta_comprobantes_pendientes_v148
    where id = pg.comprobante_id and almacen_id = f.almacen_id and creado_por = auth.uid()
      and usado_en is null and vence_en > now()
    for update;
    if not found then raise exception 'El comprobante no fue preparado o ya fue utilizado'; end if;
    if not exists (
      select 1 from storage.objects o
      where o.bucket_id = 'ventas-comprobantes' and o.name = v_comprobante.storage_path
    ) then
      raise exception 'El comprobante no termino de cargarse';
    end if;
  end if;
  insert into public.venta_franquicia_pagos(
    venta_id,numero,medio_pago,monto,referencia,
    comprobante_storage_path,comprobante_nombre,comprobante_mime_type,comprobante_tamano_bytes
  )values(
    venta,pg.numero,pg.medio_pago,round(pg.monto,2),nullif(btrim(pg.referencia),''),
    case when v_comprobante.id is null then null else v_comprobante.storage_path end,
    case when v_comprobante.id is null then null else v_comprobante.nombre_archivo end,
    case when v_comprobante.id is null then null else v_comprobante.mime_type end,
    case when v_comprobante.id is null then null else v_comprobante.tamano_bytes end
  )returning id into pago;
  if v_comprobante.id is not null then
    update public.venta_comprobantes_pendientes_v148 set usado_en = pago where id = v_comprobante.id;
  end if;
  insert into public.franquicia_caja_movimientos(franquicia_id,almacen_id,fecha,tipo,categoria,concepto,monto,medio_pago,referencia,venta_id,venta_pago_id,idempotency_key,creado_por)
  values(f.id,f.almacen_id,p_fecha,'ingreso','venta','Venta #'||numero,round(pg.monto,2),pg.medio_pago,nullif(btrim(pg.referencia),''),venta,pago,md5(venta::text||':'||pago::text)::uuid,auth.uid());
 end loop;
 return jsonb_build_object('id',venta,'numero',numero,'total',total,'duplicado',false);
end $fn$;

alter function public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid) owner to postgres;
revoke all on function public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid) from public,anon;
grant execute on function public.registrar_venta_franquicia_v143(date,jsonb,jsonb,numeric,text,text,uuid,date,uuid) to authenticated;

insert into public.schema_migrations_boman(id,version,archivo,notas)values('v149','149','v149_comprobante_transferencia_franquicia.sql','Comprobante obligatorio en transferencias del flujo de venta de franquicia, reusando el bucket/RPC de comprobantes de v148')
on conflict(id)do update set version=excluded.version,archivo=excluded.archivo,notas=excluded.notas,aplicada_at=now();

notify pgrst,'reload schema';
commit;
