-- ============================================================
-- BOMAN INVENTARIO - v147 paso 2
-- Vendedor propietario del contrato y abonos conciliados con Caja.
-- Ejecutar despues de v147_paso1_rol_vendedor.sql.
-- ============================================================
begin;
select pg_advisory_xact_lock(1472026);

do $$begin
 if not exists(select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='rol_usuario' and e.enumlabel='vendedor')then
  raise exception 'Ejecuta primero v147_paso1_rol_vendedor.sql';
 end if;
 if to_regprocedure('public.crear_contrato_v115(jsonb,uuid)')is null
    or to_regclass('public.contrato_abonos_v100')is null
    or to_regclass('public.franquicia_caja_movimientos')is null then
  raise exception 'Faltan v115, v100 o Caja antes de v147';
 end if;
end$$;

insert into public.permisos_sistema as p(codigo,modulo,nombre,descripcion,orden,es_boman_especifico)values
('contratos.abonos.registrar','Contratos','Registrar abonos propios','Registra cobros de contratos autorizados y su movimiento en Caja.',201,true)
on conflict(codigo)do update set modulo=excluded.modulo,nombre=excluded.nombre,descripcion=excluded.descripcion,orden=excluded.orden,activo=true,es_boman_especifico=true,updated_at=now();

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,p.codigo,false from unnest(enum_range(null::public.rol_usuario))r(rol)
cross join public.permisos_sistema p where r.rol::text<>'admin' and p.codigo='contratos.abonos.registrar'
on conflict(rol,permiso_codigo)do nothing;

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select 'vendedor'::public.rol_usuario,p.codigo,false from public.permisos_sistema p where p.activo
on conflict(rol,permiso_codigo)do nothing;

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select 'vendedor'::public.rol_usuario,p.codigo,true
from public.permisos_sistema p
where p.codigo in('contratos.acceder','contratos.editar','contratos.abonos.registrar','clientes.acceder','notificaciones.acceder')
on conflict(rol,permiso_codigo)do update set permitido=excluded.permitido,updated_at=now();

update public.rol_permisos set permitido=true,updated_at=now()
where permiso_codigo='contratos.abonos.registrar' and rol::text in('control','gerencia');

alter table public.contratos add column if not exists vendedor_perfil_id uuid;
do $$begin
 if not exists(select 1 from pg_constraint where conname='contratos_vendedor_perfil_v147_fkey' and conrelid='public.contratos'::regclass)then
  alter table public.contratos add constraint contratos_vendedor_perfil_v147_fkey
   foreign key(vendedor_perfil_id)references public.perfiles(id)on delete restrict not valid;
 end if;
end$$;
alter table public.contratos validate constraint contratos_vendedor_perfil_v147_fkey;
create index if not exists idx_contratos_vendedor_perfil_v147 on public.contratos(vendedor_perfil_id,fecha_ingreso desc);

-- Backfill conservador: vincula solo cuando el nombre identifica a un unico
-- usuario vendedor. Los contratos ambiguos permanecen visibles a gerencia.
with candidatos as(
 select c.id,min(p.id::text)::uuid perfil_id
 from public.contratos c join public.perfiles p
  on p.rol::text='vendedor' and p.activo
 and public.normalizar_cliente_v113(p.nombre_completo)=public.normalizar_cliente_v113(c.vendedor)
 where c.vendedor_perfil_id is null
 group by c.id having count(*)=1
)
update public.contratos c set vendedor_perfil_id=x.perfil_id from candidatos x where c.id=x.id;

alter table public.franquicia_caja_movimientos add column if not exists contrato_abono_id uuid;
do $$begin
 if not exists(select 1 from pg_constraint where conname='caja_contrato_abono_v147_fkey' and conrelid='public.franquicia_caja_movimientos'::regclass)then
  alter table public.franquicia_caja_movimientos add constraint caja_contrato_abono_v147_fkey
   foreign key(contrato_abono_id)references public.contrato_abonos_v100(id)on delete restrict not valid;
 end if;
end$$;
alter table public.franquicia_caja_movimientos validate constraint caja_contrato_abono_v147_fkey;
create unique index if not exists uq_caja_contrato_abono_v147
 on public.franquicia_caja_movimientos(contrato_abono_id)where contrato_abono_id is not null;

create or replace function public.catalogo_ingreso_contrato_v147()returns jsonb
language plpgsql stable security definer set search_path=''as $v147$
declare v_r jsonb;v_es_vendedor boolean:=public.rol_usuario_actual()::text='vendedor';
begin
 if auth.uid()is null or not public.usuario_tiene_permiso_v35('contratos.editar')then raise exception'No tienes permiso para ingresar contratos';end if;
 select jsonb_build_object(
  'almacenes',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nombre',a.nombre,'codigo',a.codigo)order by a.nombre)from public.almacenes a where a.activo and public.usuario_puede_almacen(a.id,false)),'[]'::jsonb),
  'vendedores',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nombre',p.nombre_completo)order by p.nombre_completo)from public.perfiles p where p.activo and p.rol::text='vendedor'and(not v_es_vendedor or p.id=auth.uid())),'[]'::jsonb),
  'vendedor_bloqueado',v_es_vendedor
 )into v_r;return v_r;
end;$v147$;

create or replace function public.crear_contrato_v147(p_datos jsonb,p_idempotency_key uuid)returns jsonb
language plpgsql security definer set search_path=''as $v147$
declare v_uid uuid:=auth.uid();v_c jsonb:=coalesce(p_datos->'contrato','{}');v_vendedor_id uuid;v_nombre text;v_datos jsonb;v_r jsonb;v_id uuid;
begin
 if v_uid is null or not public.usuario_tiene_permiso_v35('contratos.editar')then raise exception'No tienes permiso para ingresar contratos';end if;
 v_vendedor_id:=case when public.rol_usuario_actual()::text='vendedor'then v_uid else nullif(v_c->>'vendedor_perfil_id','')::uuid end;
 if v_vendedor_id is null then raise exception'Selecciona el usuario vendedor responsable';end if;
 select nombre_completo into v_nombre from public.perfiles where id=v_vendedor_id and activo and rol::text='vendedor';
 if not found then raise exception'El vendedor seleccionado no existe, esta inactivo o no tiene rol Vendedor';end if;
 -- El abono inicial historico no tiene fecha ni trazabilidad. Los nuevos
 -- contratos nacen en cero y cada cobro entra por registrar_abono_contrato_v147.
 v_c:=v_c||jsonb_build_object('vendedor',v_nombre,'vendedor_responsable',v_nombre,'abono',0);
 v_datos:=jsonb_set(p_datos,'{contrato}',v_c,true);
 v_r:=public.crear_contrato_v115(v_datos,p_idempotency_key);
 v_id:=(v_r->>'contrato_id')::uuid;
 update public.contratos set vendedor_perfil_id=v_vendedor_id,vendedor=v_nombre,vendedor_responsable=v_nombre where id=v_id;
 return v_r||jsonb_build_object('vendedor_perfil_id',v_vendedor_id,'vendedor',v_nombre);
end;$v147$;

create or replace function public.registrar_abono_contrato_v147(
 p_contrato_id uuid,p_fecha date,p_monto numeric,p_medio_pago text,
 p_referencia text,p_nota text,p_motivo text,p_idempotency_key uuid
)returns jsonb language plpgsql security definer set search_path=''as $v147$
declare v_uid uuid:=auth.uid();v_c public.contratos%rowtype;v_abono_id uuid;v_mov_id uuid;v_total numeric;v_r jsonb;v_franquicia uuid;v_es_vendedor boolean:=public.rol_usuario_actual()::text='vendedor';
begin
 if v_uid is null then raise exception'Debes iniciar sesion';end if;
 if not(public.usuario_tiene_permiso_v35('contratos.abonos.registrar')or public.usuario_tiene_permiso_v35('contratos.finanzas.editar')or public.usuario_tiene_permiso_v35('contratos.cartera.editar'))then raise exception'No tienes permiso para registrar abonos';end if;
 if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;
 if length(btrim(coalesce(p_motivo,'')))<10 then raise exception'El motivo debe tener al menos 10 caracteres';end if;
 if p_fecha is null or p_fecha>(now()at time zone'America/Guayaquil')::date then raise exception'La fecha real del pago no es valida';end if;
 if coalesce(p_monto,0)<=0 then raise exception'El monto debe ser mayor que cero';end if;
 if p_medio_pago not in('efectivo','transferencia','tarjeta','cheque','otro')then raise exception'El medio de pago no es valido';end if;
 if p_medio_pago in('transferencia','tarjeta','cheque')and length(btrim(coalesce(p_referencia,'')))<3 then raise exception'Este medio exige numero o referencia del comprobante';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,147));
 select resultado into v_r from public.contrato_finanzas_eventos_v100 where idempotency_key=p_idempotency_key;if found then return v_r;end if;
 select*into v_c from public.contratos where id=p_contrato_id for update;if not found then raise exception'El contrato no existe';end if;
 if v_es_vendedor and v_c.vendedor_perfil_id is distinct from v_uid then raise exception'Solo puedes registrar cobros de tus contratos';end if;
 if v_c.almacen_venta_id_v115 is null then raise exception'Asigna una tienda o local al contrato antes de registrar el cobro';end if;
 if v_es_vendedor and not public.usuario_puede_almacen(v_c.almacen_venta_id_v115,false)then raise exception'No tienes acceso al local de venta de este contrato';end if;
 if v_c.abono+p_monto>v_c.presupuesto then raise exception'El pago supera el saldo pendiente de %',v_c.presupuesto-v_c.abono;end if;
 select id into v_franquicia from public.franquicias where almacen_id=v_c.almacen_venta_id_v115 and activo order by created_at limit 1;
 insert into public.contrato_abonos_v100(contrato_id,fecha,monto,medio_pago,referencia,nota,creado_por)
 values(p_contrato_id,p_fecha,round(p_monto,2),p_medio_pago,nullif(btrim(p_referencia),''),nullif(btrim(p_nota),''),v_uid)returning id into v_abono_id;
 insert into public.franquicia_caja_movimientos(franquicia_id,almacen_id,fecha,tipo,categoria,concepto,monto,medio_pago,referencia,idempotency_key,creado_por,contrato_abono_id)
 values(v_franquicia,v_c.almacen_venta_id_v115,p_fecha,'ingreso','abono_contrato','Abono '||v_c.numero||' - '||v_c.cliente,round(p_monto,2),case when p_medio_pago='cheque'then'otro'else p_medio_pago end,nullif(btrim(p_referencia),''),p_idempotency_key,v_uid,v_abono_id)returning id into v_mov_id;
 v_total:=public.recalcular_abono_contrato_v100(p_contrato_id);
 v_r:=jsonb_build_object('abono_id',v_abono_id,'movimiento_caja_id',v_mov_id,'contrato_id',p_contrato_id,'fecha_pago',p_fecha,'registrado_at',now(),'total_abonado',v_total,'saldo',v_c.presupuesto-v_total);
 insert into public.contrato_finanzas_eventos_v100(contrato_id,abono_id,accion,valor_anterior,valor_nuevo,motivo,usuario_id,idempotency_key,resultado)
 values(p_contrato_id,v_abono_id,'registrar_abono',v_c.abono,v_total,btrim(p_motivo),v_uid,p_idempotency_key,v_r);
 update public.contrato_promesas_pago_v114 set estado='cumplida',resuelto_at=now(),motivo_resolucion='Saldo cancelado'where contrato_id=p_contrato_id and estado='vigente'and v_total>=v_c.presupuesto;
 return v_r;
end;$v147$;

create or replace function public.anular_abono_contrato_v147(p_abono_id uuid,p_motivo text,p_idempotency_key uuid)returns jsonb
language plpgsql security definer set search_path=''as $v147$
declare v_uid uuid:=auth.uid();v_a public.contrato_abonos_v100%rowtype;v_m public.franquicia_caja_movimientos%rowtype;v_anterior numeric;v_total numeric;v_r jsonb;
begin
 if v_uid is null or not(public.usuario_tiene_permiso_v35('contratos.finanzas.editar')or public.usuario_tiene_permiso_v35('contratos.cartera.editar'))then raise exception'No tienes permiso para anular cobros';end if;
 if p_idempotency_key is null or length(btrim(coalesce(p_motivo,'')))<10 then raise exception'La idempotencia y un motivo de al menos 10 caracteres son obligatorios';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,147));select resultado into v_r from public.contrato_finanzas_eventos_v100 where idempotency_key=p_idempotency_key;if found then return v_r;end if;
 select*into v_a from public.contrato_abonos_v100 where id=p_abono_id and estado='aplicado'for update;if not found then raise exception'El abono no existe o ya fue anulado';end if;
 select*into v_m from public.franquicia_caja_movimientos where contrato_abono_id=p_abono_id and estado='vigente'for update;
 select abono into v_anterior from public.contratos where id=v_a.contrato_id for update;
 update public.contrato_abonos_v100 set estado='anulado',anulado_por=v_uid,anulado_at=now(),motivo_anulacion=btrim(p_motivo)where id=p_abono_id;
 if v_m.id is not null then
  update public.franquicia_caja_movimientos set estado='revertido',motivo_reversa=btrim(p_motivo)where id=v_m.id;
  insert into public.franquicia_caja_movimientos(franquicia_id,almacen_id,fecha,tipo,categoria,concepto,monto,medio_pago,referencia,estado,reversa_de_id,motivo_reversa,idempotency_key,creado_por)
  values(v_m.franquicia_id,v_m.almacen_id,v_m.fecha,'egreso','reversa_abono_contrato','Reversa: '||v_m.concepto,v_m.monto,v_m.medio_pago,v_m.referencia,'vigente',v_m.id,btrim(p_motivo),p_idempotency_key,v_uid);
 end if;
 v_total:=public.recalcular_abono_contrato_v100(v_a.contrato_id);v_r:=jsonb_build_object('abono_id',p_abono_id,'contrato_id',v_a.contrato_id,'total_abonado',v_total,'movimiento_revertido',v_m.id,'legado_sin_caja',v_m.id is null);
 insert into public.contrato_finanzas_eventos_v100(contrato_id,abono_id,accion,valor_anterior,valor_nuevo,motivo,usuario_id,idempotency_key,resultado)values(v_a.contrato_id,p_abono_id,'anular_abono',v_anterior,v_total,btrim(p_motivo),v_uid,p_idempotency_key,v_r);return v_r;
end;$v147$;

-- Sustituye el panel v111 manteniendo su firma para no romper enlaces.
create or replace function public.panel_vendedores_v111(p_vendedores text[]default null,p_desde date default null,p_hasta date default null,p_estados text[]default null,p_prioridades text[]default null,p_cliente text default null,p_pagina integer default 1,p_por_pagina integer default 30)returns jsonb
language plpgsql stable security definer set search_path=''as $v147$
declare v_hoy date:=(now()at time zone'America/Guayaquil')::date;v_desde date:=coalesce(p_desde,v_hoy);v_hasta date:=coalesce(p_hasta,v_hoy+14);v_pag integer:=greatest(coalesce(p_pagina,1),1);v_por integer:=least(greatest(coalesce(p_por_pagina,30),1),100);v_r jsonb;v_es_vendedor boolean:=public.rol_usuario_actual()::text='vendedor';
begin
 if auth.uid()is null or not public.usuario_tiene_permiso_v35('contratos.acceder')then raise exception'No tienes permiso para consultar contratos';end if;
 if v_desde>v_hasta or v_hasta-v_desde>3660 then raise exception'El rango de fechas no es valido';end if;
 with f as materialized(select c.*,c.fecha_entrega is not null and c.fecha_entrega<v_hoy and lower(btrim(c.estado))not in('entregado','anulado')atrasado,case when c.fecha_entrega is null then null else c.fecha_entrega-v_hoy end dias_para_entrega from public.contratos c where c.fecha_entrega between v_desde and v_hasta and(not v_es_vendedor or c.vendedor_perfil_id=auth.uid())and(coalesce(cardinality(p_vendedores),0)=0 or c.vendedor=any(p_vendedores))and(coalesce(cardinality(p_estados),0)=0 or c.estado=any(p_estados))and(coalesce(cardinality(p_prioridades),0)=0 or c.prioridad=any(p_prioridades))and(nullif(btrim(coalesce(p_cliente,'')),'')is null or c.cliente ilike'%'||btrim(p_cliente)||'%'or c.numero ilike'%'||btrim(p_cliente)||'%')),
 pg as(select*from f order by atrasado desc,fecha_entrega,prioridad desc,numero offset(v_pag-1)*v_por limit v_por),
 e as(select p.id,p.numero,p.cliente,p.vendedor,p.estado,p.prioridad,p.tipo_contrato,p.fecha_ingreso,p.fecha_inicio_produccion,p.fecha_entrega,p.total_prendas,p.presupuesto,p.abono,greatest(p.presupuesto-p.abono,0)::numeric(14,2)saldo,p.atrasado,p.dias_para_entrega,a.drive_id mockup_drive_id,a.url mockup_url,coalesce(pr.detalle,'[]'::jsonb)prendas from pg p left join lateral(select ca.drive_id,ca.url from public.contrato_archivos ca where ca.contrato_id=p.id and ca.tipo='mockup'order by ca.orden,ca.id limit 1)a on true left join lateral(select jsonb_agg(jsonb_build_object('prenda',q.prenda,'calidad',q.calidad,'cantidad',q.cantidad)order by q.cantidad desc,q.prenda,q.calidad)detalle from(select cp.prenda,nullif(btrim(cp.calidad),'')calidad,sum(cp.cantidad)::integer cantidad from public.contrato_prendas cp where cp.contrato_id=p.id group by cp.prenda,nullif(btrim(cp.calidad),''))q)pr on true)
 select jsonb_build_object('hoy',v_hoy,'filtros',jsonb_build_object('desde',v_desde,'hasta',v_hasta),'catalogos',jsonb_build_object('vendedores',coalesce((select jsonb_agg(x order by x)from(select distinct vendedor x from f where nullif(btrim(vendedor),'')is not null)x),'[]'),'estados',coalesce((select jsonb_agg(x order by x)from(select distinct estado x from f)x),'[]'),'prioridades',coalesce((select jsonb_agg(x order by x)from(select distinct prioridad x from f)x),'[]')),'kpis',jsonb_build_object('contratos',(select count(*)from f),'prendas',coalesce((select sum(total_prendas)from f),0),'presupuesto',coalesce((select sum(presupuesto)from f),0),'abono',coalesce((select sum(abono)from f),0),'saldo',coalesce((select sum(greatest(presupuesto-abono,0))from f),0),'atrasados',(select count(*)from f where atrasado)),'total',(select count(*)from f),'pagina',v_pag,'por_pagina',v_por,'filas',coalesce((select jsonb_agg(to_jsonb(e)order by atrasado desc,fecha_entrega,prioridad desc,numero)from e),'[]'))into v_r;return v_r;
end;$v147$;

create or replace function public.obtener_brief_vendedor_v111(p_contrato_id uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $v147$
declare v_r jsonb;
begin
 if auth.uid()is null or not public.usuario_tiene_permiso_v35('contratos.acceder')then raise exception'No tienes permiso para consultar contratos';end if;
 if public.rol_usuario_actual()::text='vendedor'and not exists(select 1 from public.contratos where id=p_contrato_id and vendedor_perfil_id=auth.uid())then raise exception'Solo puedes abrir tus contratos';end if;
 select jsonb_build_object('contrato',to_jsonb(c),'prendas',coalesce((select jsonb_agg(to_jsonb(x)order by x.prenda,x.calidad,x.genero,x.talla)from public.contrato_prendas x where x.contrato_id=c.id),'[]'),'jugadores',coalesce((select jsonb_agg(to_jsonb(x)order by x.orden,x.id)from public.contrato_jugadores x where x.contrato_id=c.id),'[]'),'archivos',coalesce((select jsonb_agg(to_jsonb(x)order by x.tipo,x.orden,x.id)from public.contrato_archivos x where x.contrato_id=c.id),'[]'),'especificaciones',coalesce((select jsonb_agg(to_jsonb(x)order by x.orden,x.id)from public.contrato_specs x where x.contrato_id=c.id),'[]'),'facturacion',coalesce((select jsonb_agg(to_jsonb(x)order by x.orden,x.id)from public.contrato_facturacion x where x.contrato_id=c.id),'[]'),'etapas','[]','eventos','[]','enlaces','[]')into v_r from public.contratos c where c.id=p_contrato_id;
 if v_r is null then raise exception'El contrato no existe';end if;return v_r;
end;$v147$;

create or replace function public.buscar_contratos_reposicion_v108(p_busqueda text)returns jsonb
language plpgsql stable security definer set search_path=''as $v147$
declare v_r jsonb;v_es_vendedor boolean:=public.rol_usuario_actual()::text='vendedor';
begin
 if auth.uid()is null or not public.usuario_tiene_permiso_v35('contratos.editar')then raise exception'No tienes permiso para consultar contratos';end if;
 select coalesce(jsonb_agg(to_jsonb(q)order by q.fecha_ingreso desc),'[]')into v_r from(
  select c.id,c.numero,c.cliente,c.vendedor,c.fecha_ingreso,c.fecha_entrega,c.total_prendas from public.contratos c
  where length(btrim(coalesce(p_busqueda,'')))>=2 and(not v_es_vendedor or c.vendedor_perfil_id=auth.uid())
   and(c.numero ilike'%'||btrim(p_busqueda)||'%'or c.cliente ilike'%'||btrim(p_busqueda)||'%')
  order by c.fecha_ingreso desc limit 12
 )q;return v_r;
end;$v147$;

create or replace function public.obtener_plantilla_contrato_v108(p_contrato_id uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $v147$
declare v_r jsonb;
begin
 if auth.uid()is null or not public.usuario_tiene_permiso_v35('contratos.editar')then raise exception'No tienes permiso para consultar contratos';end if;
 if public.rol_usuario_actual()::text='vendedor'and not exists(select 1 from public.contratos where id=p_contrato_id and vendedor_perfil_id=auth.uid())then raise exception'Solo puedes reutilizar tus contratos';end if;
 select jsonb_build_object('contrato',to_jsonb(c),'prendas',coalesce((select jsonb_agg(to_jsonb(x)-'id'-'contrato_id')from public.contrato_prendas x where x.contrato_id=c.id),'[]'),'jugadores',coalesce((select jsonb_agg(to_jsonb(x)-'id'-'contrato_id'order by x.orden)from public.contrato_jugadores x where x.contrato_id=c.id),'[]'),'archivos',coalesce((select jsonb_agg(to_jsonb(x)-'id'-'contrato_id'order by x.tipo,x.orden)from public.contrato_archivos x where x.contrato_id=c.id),'[]'),'especificaciones',coalesce((select jsonb_agg(to_jsonb(x)-'id'-'contrato_id'order by x.orden)from public.contrato_specs x where x.contrato_id=c.id),'[]'),'facturacion',coalesce((select jsonb_agg(to_jsonb(x)-'id'-'contrato_id'order by x.orden)from public.contrato_facturacion x where x.contrato_id=c.id),'[]'))into v_r from public.contratos c where c.id=p_contrato_id;
 if v_r is null then raise exception'No se encontro el contrato';end if;return v_r;
end;$v147$;

revoke all on function public.crear_contrato_v115(jsonb,uuid),public.registrar_abono_contrato_v100(uuid,date,numeric,text,text,text,text,uuid),public.registrar_abono_cartera_v114(uuid,date,numeric,text,text,text,text,uuid),public.anular_abono_contrato_v100(uuid,text,uuid)from authenticated;
do $p$declare f regprocedure;begin foreach f in array array['public.catalogo_ingreso_contrato_v147()'::regprocedure,'public.crear_contrato_v147(jsonb,uuid)'::regprocedure,'public.registrar_abono_contrato_v147(uuid,date,numeric,text,text,text,text,uuid)'::regprocedure,'public.anular_abono_contrato_v147(uuid,text,uuid)'::regprocedure,'public.panel_vendedores_v111(text[],date,date,text[],text[],text,integer,integer)'::regprocedure,'public.obtener_brief_vendedor_v111(uuid)'::regprocedure,'public.buscar_contratos_reposicion_v108(text)'::regprocedure,'public.obtener_plantilla_contrato_v108(uuid)'::regprocedure]loop execute format('alter function %s owner to postgres',f);execute format('revoke all on function %s from public,anon',f);execute format('grant execute on function %s to authenticated',f);end loop;end;$p$;

insert into public.schema_migrations_boman(id,version,archivo,notas)values('v147','147','v147_paso2_contratos_vendedor_caja.sql','Usuarios vendedores, contratos propios y abonos conciliados con Caja')on conflict(id)do update set version=excluded.version,archivo=excluded.archivo,notas=excluded.notas,aplicada_at=now();
commit;
notify pgrst,'reload schema';
