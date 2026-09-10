-- ============================================================
-- BOMAN INVENTARIO - v115: consolidado comercial
-- Separa nombre de contrato/cliente y consolida vendedor, tienda y canal.
-- Ejecutar despues de v114 y nunca en paralelo con otra migracion.
-- ============================================================
begin;
select pg_advisory_xact_lock(1131142026);
lock table public.contratos in access exclusive mode;
do $$begin if to_regclass('public.contrato_entregas_v112')is null or to_regclass('public.clientes_v113')is null or to_regclass('public.contrato_cartera_v114')is null or to_regprocedure('public.crear_contrato_v108(jsonb,uuid)')is null then raise exception'Faltan v108, v112, v113 o v114 antes de v115';end if;end$$;

insert into public.permisos_sistema as p(codigo,modulo,nombre,descripcion,orden,es_boman_especifico)values
('reportes.comercial.ver','Reportes','Ver consolidado comercial','Ventas, entregas, produccion, cobros y comisiones proyectadas.',204,true),
('reportes.comercial.comisiones','Reportes','Configurar comisiones futuras','Define porcentajes proyectados por vendedor.',205,true)
on conflict(codigo)do update set modulo=excluded.modulo,nombre=excluded.nombre,descripcion=excluded.descripcion,orden=excluded.orden,activo=true,es_boman_especifico=true,updated_at=now();
insert into public.rol_permisos(rol,permiso_codigo,permitido)select r.rol,p.codigo,false from unnest(enum_range(null::public.rol_usuario))r(rol)cross join public.permisos_sistema p where r.rol::text<>'admin'and p.codigo in('reportes.comercial.ver','reportes.comercial.comisiones')on conflict do nothing;
update public.rol_permisos set permitido=true,updated_at=now()where permiso_codigo='reportes.comercial.ver'and rol::text in('gerencia','control');
update public.rol_permisos set permitido=true,updated_at=now()where permiso_codigo='reportes.comercial.comisiones'and rol::text='control';

alter table public.contratos add column if not exists nombre_contrato_v115 text;
alter table public.contratos add column if not exists cliente_confirmado_v115 boolean not null default false;
alter table public.contratos add column if not exists almacen_venta_id_v115 uuid;
do $$begin
 if not exists(
  select 1 from pg_constraint
  where conname='contratos_almacen_venta_v115_fkey'
    and conrelid='public.contratos'::regclass
 )then
  alter table public.contratos add constraint contratos_almacen_venta_v115_fkey
   foreign key(almacen_venta_id_v115)references public.almacenes(id)on delete restrict
   not valid;
 end if;
end$$;
alter table public.contratos validate constraint contratos_almacen_venta_v115_fkey;
update public.contratos set nombre_contrato_v115=cliente where nullif(btrim(nombre_contrato_v115),'')is null;
alter table public.contratos alter column nombre_contrato_v115 set not null;
do $$begin
 if not exists(
  select 1 from pg_constraint
  where conname='contratos_nombre_v115_check'
    and conrelid='public.contratos'::regclass
 )then
  alter table public.contratos add constraint contratos_nombre_v115_check
   check(length(btrim(nombre_contrato_v115))>=2)not valid;
 end if;
end$$;
alter table public.contratos validate constraint contratos_nombre_v115_check;
create index if not exists idx_contratos_nombre_v115 on public.contratos(lower(nombre_contrato_v115));
create index if not exists idx_contratos_almacen_v115 on public.contratos(almacen_venta_id_v115,fecha_ingreso desc);

create table if not exists public.comisiones_vendedores_v115(
 id uuid primary key default gen_random_uuid(),vendedor_normalizado text not null,vendedor text not null,
 porcentaje numeric(7,4)not null check(porcentaje>=0 and porcentaje<=100),base text not null default'cobrado'check(base in('facturado','cobrado')),
 vigente_desde date not null,vigente_hasta date,activo boolean not null default true,nota text,
 creado_por uuid not null references public.perfiles(id)on delete restrict,updated_at timestamptz not null default now(),
 check(vigente_hasta is null or vigente_hasta>=vigente_desde),unique(vendedor_normalizado,vigente_desde)
);
create table if not exists public.comisiones_eventos_v115(
 id uuid primary key default gen_random_uuid(),regla_id uuid not null references public.comisiones_vendedores_v115(id)on delete restrict,
 datos jsonb not null,motivo text not null check(length(btrim(motivo))>=10),usuario_id uuid not null references public.perfiles(id)on delete restrict,
 idempotency_key uuid not null unique,created_at timestamptz not null default now()
);

create or replace function public.catalogo_ingreso_contrato_v115()returns jsonb language plpgsql stable security definer set search_path=''as $fn$
declare v_r jsonb;
begin if auth.uid()is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.editar')then raise exception'No tienes permiso para ingresar contratos';end if;
 select jsonb_build_object('almacenes',coalesce(jsonb_agg(jsonb_build_object('id',a.id,'nombre',a.nombre,'codigo',a.codigo)order by a.nombre)filter(where a.id is not null),'[]'))into v_r from public.almacenes a where a.activo and public.usuario_puede_almacen(a.id,false);return v_r;end;$fn$;

create or replace function public.crear_contrato_v115(p_datos jsonb,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path=''as $fn$
declare v_uid uuid:=auth.uid();v_c jsonb:=coalesce(p_datos->'contrato','{}');v_r jsonb;v_id uuid;v_almacen uuid;v_total_almacenes integer;
begin if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.editar')then raise exception'No tienes permiso para ingresar contratos';end if;
 if length(btrim(coalesce(v_c->>'nombre_contrato_v115','')))<2 then raise exception'Escribe el nombre del contrato';end if;if length(btrim(coalesce(v_c->>'cliente','')))<2 then raise exception'Escribe el nombre del cliente real';end if;
 v_almacen:=nullif(v_c->>'almacen_venta_id_v115','')::uuid;if v_almacen is not null and not public.usuario_puede_almacen(v_almacen,false)then raise exception'No puedes registrar ventas para esa tienda';end if;
 if v_almacen is null then select count(*),min(a.id)into v_total_almacenes,v_almacen from public.almacenes a where a.activo and public.usuario_puede_almacen(a.id,false);if v_total_almacenes>1 then raise exception'Selecciona la tienda o local de la venta';end if;end if;
 v_r:=public.crear_contrato_v108(p_datos,p_idempotency_key);v_id:=(v_r->>'contrato_id')::uuid;
 update public.contratos set nombre_contrato_v115=btrim(v_c->>'nombre_contrato_v115'),cliente_confirmado_v115=true,almacen_venta_id_v115=v_almacen where id=v_id;
 return v_r||jsonb_build_object('nombre_contrato',btrim(v_c->>'nombre_contrato_v115'),'cliente',btrim(v_c->>'cliente'),'almacen_id',v_almacen);
end;$fn$;

create or replace function public.consolidado_comercial_v115(p_desde date,p_hasta date,p_vendedores text[]default null,p_almacenes uuid[]default null,p_canales text[]default null)returns jsonb language plpgsql stable security definer set search_path=''as $fn$
declare v_r jsonb;v_desde date:=coalesce(p_desde,date_trunc('month',(now()at time zone'America/Guayaquil'))::date);v_hasta date:=coalesce(p_hasta,(now()at time zone'America/Guayaquil')::date);
begin if auth.uid()is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('reportes.comercial.ver')then raise exception'No tienes permiso para consultar el consolidado comercial';end if;if v_hasta<v_desde or v_hasta-v_desde>730 then raise exception'El rango debe estar entre 1 y 731 dias';end if;
 with base as materialized(select c.id,c.numero,c.nombre_contrato_v115 nombre_contrato,c.cliente,c.cliente_confirmado_v115,c.vendedor,coalesce(c.canal,'Sin canal')canal,c.almacen_venta_id_v115,coalesce(a.nombre,'Sin tienda asignada')tienda,(c.fecha_ingreso at time zone'America/Guayaquil')::date fecha,c.fecha_entrega,c.total_prendas,c.presupuesto,c.abono,greatest(c.presupuesto-c.abono,0)saldo,
  coalesce(en.entregado,0)::integer entregado,en.fecha_completa,
  case when en.fecha_completa is null then null when c.fecha_entrega is null then true else en.fecha_completa<=c.fecha_entrega end entrega_a_tiempo,
  coalesce(cv.porcentaje,0)comision_pct,coalesce(cv.base,'cobrado')comision_base
 from public.contratos c left join public.almacenes a on a.id=c.almacen_venta_id_v115 left join lateral(select sum(l.cantidad)filter(where e.estado='aplicada')entregado,max((e.fecha_entrega_real at time zone'America/Guayaquil')::date)filter(where e.estado='aplicada'and e.tipo='completa')fecha_completa from public.contrato_entregas_v112 e join public.contrato_entrega_lineas_v112 l on l.entrega_id=e.id where e.contrato_id=c.id)en on true left join lateral(select x.porcentaje,x.base from public.comisiones_vendedores_v115 x where x.activo and x.vendedor_normalizado=public.normalizar_cliente_v113(c.vendedor)and x.vigente_desde<=(c.fecha_ingreso at time zone'America/Guayaquil')::date and(x.vigente_hasta is null or x.vigente_hasta>=(c.fecha_ingreso at time zone'America/Guayaquil')::date)order by x.vigente_desde desc limit 1)cv on true
 where(c.fecha_ingreso at time zone'America/Guayaquil')::date between v_desde and v_hasta and(coalesce(cardinality(p_vendedores),0)=0 or c.vendedor=any(p_vendedores))and(coalesce(cardinality(p_almacenes),0)=0 or c.almacen_venta_id_v115=any(p_almacenes))and(coalesce(cardinality(p_canales),0)=0 or coalesce(c.canal,'Sin canal')=any(p_canales))),
 vendedores as(select vendedor,count(*)contratos,sum(total_prendas)::integer prendas,sum(presupuesto)facturado,sum(abono)cobrado,sum(saldo)saldo,count(*)filter(where fecha_completa is not null)::integer entregados,count(*)filter(where entrega_a_tiempo)::integer a_tiempo,sum((case when comision_base='facturado'then presupuesto else abono end)*comision_pct/100)comision_proyectada from base group by vendedor),
 tiendas as(select almacen_venta_id_v115 id,tienda,count(*)contratos,sum(total_prendas)::integer prendas,sum(presupuesto)facturado,sum(abono)cobrado,sum(saldo)saldo from base group by almacen_venta_id_v115,tienda),
 canales as(select canal,count(*)contratos,sum(total_prendas)::integer prendas,sum(presupuesto)facturado,sum(abono)cobrado,sum(saldo)saldo from base group by canal)
 select jsonb_build_object('desde',v_desde,'hasta',v_hasta,'kpis',jsonb_build_object('contratos',(select count(*)from base),'produccion_vendida',coalesce((select sum(total_prendas)from base),0),'facturado',coalesce((select sum(presupuesto)from base),0),'cobrado',coalesce((select sum(abono)from base),0),'saldo',coalesce((select sum(saldo)from base),0),'entregados',(select count(*)from base where fecha_completa is not null),'a_tiempo',(select count(*)from base where entrega_a_tiempo),'comision_futura',coalesce((select sum((case when comision_base='facturado'then presupuesto else abono end)*comision_pct/100)from base),0),'clientes_por_confirmar',(select count(*)from base where not cliente_confirmado_v115)),
 'vendedores',coalesce((select jsonb_agg(to_jsonb(v)order by facturado desc)from vendedores v),'[]'),'tiendas',coalesce((select jsonb_agg(to_jsonb(t)order by facturado desc)from tiendas t),'[]'),'canales',coalesce((select jsonb_agg(to_jsonb(c)order by facturado desc)from canales c),'[]'),
 'catalogos',jsonb_build_object('vendedores',coalesce((select jsonb_agg(x order by x)from(select distinct vendedor x from public.contratos where nullif(btrim(vendedor),'')is not null)x),'[]'),'almacenes',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nombre',nombre)order by nombre)from public.almacenes where activo),'[]'),'canales',coalesce((select jsonb_agg(x order by x)from(select distinct coalesce(canal,'Sin canal')x from public.contratos)x),'[]')),
 'contratos',coalesce((select jsonb_agg(jsonb_build_object('id',id,'numero',numero,'nombre_contrato',nombre_contrato,'cliente',cliente,'cliente_confirmado',cliente_confirmado_v115,'vendedor',vendedor,'tienda',tienda,'canal',canal,'fecha',fecha,'entrega',fecha_entrega,'prendas',total_prendas,'facturado',presupuesto,'cobrado',abono,'saldo',saldo,'entregado',entregado,'entrega_a_tiempo',entrega_a_tiempo)order by fecha desc,numero desc)from base),'[]'))into v_r;return v_r;end;$fn$;

create or replace function public.guardar_comision_vendedor_v115(p_vendedor text,p_porcentaje numeric,p_base text,p_vigente_desde date,p_vigente_hasta date,p_nota text,p_motivo text,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path=''as $fn$
declare v_uid uuid:=auth.uid();v_id uuid;v_r jsonb;
begin if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('reportes.comercial.comisiones')then raise exception'No tienes permiso para configurar comisiones';end if;if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;select datos into v_r from public.comisiones_eventos_v115 where idempotency_key=p_idempotency_key;if found then return v_r;end if;if length(btrim(coalesce(p_vendedor,'')))<2 then raise exception'Escribe el vendedor';end if;if coalesce(p_porcentaje,-1)<0 or p_porcentaje>100 then raise exception'El porcentaje debe estar entre 0 y 100';end if;if p_base not in('facturado','cobrado')then raise exception'La base de comision no es valida';end if;if p_vigente_desde is null or(p_vigente_hasta is not null and p_vigente_hasta<p_vigente_desde)then raise exception'La vigencia no es valida';end if;if length(btrim(coalesce(p_motivo,'')))<10 then raise exception'El motivo debe tener al menos 10 caracteres';end if;
 insert into public.comisiones_vendedores_v115(vendedor_normalizado,vendedor,porcentaje,base,vigente_desde,vigente_hasta,nota,creado_por)values(public.normalizar_cliente_v113(p_vendedor),btrim(p_vendedor),round(p_porcentaje,4),p_base,p_vigente_desde,p_vigente_hasta,nullif(btrim(p_nota),''),v_uid)on conflict(vendedor_normalizado,vigente_desde)do update set vendedor=excluded.vendedor,porcentaje=excluded.porcentaje,base=excluded.base,vigente_hasta=excluded.vigente_hasta,nota=excluded.nota,activo=true,updated_at=now()returning id into v_id;v_r:=jsonb_build_object('regla_id',v_id,'vendedor',btrim(p_vendedor),'porcentaje',round(p_porcentaje,4),'base',p_base);insert into public.comisiones_eventos_v115(regla_id,datos,motivo,usuario_id,idempotency_key)values(v_id,v_r,btrim(p_motivo),v_uid,p_idempotency_key);return v_r;end;$fn$;

alter table public.comisiones_vendedores_v115 enable row level security;alter table public.comisiones_eventos_v115 enable row level security;revoke all on public.comisiones_vendedores_v115,public.comisiones_eventos_v115 from public,anon,authenticated;
revoke all on function public.crear_contrato_v108(jsonb,uuid)from authenticated;
do $p$declare f regprocedure;begin foreach f in array array['public.catalogo_ingreso_contrato_v115()'::regprocedure,'public.crear_contrato_v115(jsonb,uuid)'::regprocedure,'public.consolidado_comercial_v115(date,date,text[],uuid[],text[])'::regprocedure,'public.guardar_comision_vendedor_v115(text,numeric,text,date,date,text,text,uuid)'::regprocedure]loop execute format('alter function %s owner to postgres',f);execute format('revoke all on function %s from public,anon',f);execute format('grant execute on function %s to authenticated',f);end loop;end;$p$;
commit;
notify pgrst,'reload schema';
