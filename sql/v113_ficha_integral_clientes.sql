-- ============================================================
-- BOMAN INVENTARIO - v113: ficha integral de clientes
-- Identidad canonica, contactos, direcciones, historial y duplicados.
-- Ejecutar despues de v112.
-- ============================================================
begin;

-- Evita que dos pestañas del editor, otra migracion Boman o una reejecucion
-- accidental creen/alteren estas relaciones al mismo tiempo. Debe ser la
-- primera operacion de la transaccion para esperar sin retener otros locks.
select pg_advisory_xact_lock(1131142026);

-- Todas las consultas comerciales parten de contratos. Tomarlo primero evita
-- el ciclo contratos -> clientes / clientes -> contratos durante una reejecucion.
lock table public.contratos in access exclusive mode;

do $$ begin
 if to_regclass('public.contratos') is null or to_regclass('public.contrato_entregas_v112')is null or to_regclass('public.contrato_abonos_v100')is null or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
  raise exception 'Faltan v35, v79, v100 o v112 antes de v113';
 end if;
end $$;

insert into public.permisos_sistema as p(codigo,modulo,nombre,descripcion,orden,es_boman_especifico)
values
 ('clientes.acceder','Clientes','Consultar clientes','Consulta la ficha integral e historial comercial.',199,true),
 ('clientes.editar','Clientes','Gestionar clientes','Actualiza identificacion, contactos y direcciones.',200,true),
 ('clientes.fusionar','Clientes','Fusionar duplicados','Une fichas duplicadas conservando todo su historial.',201,true)
on conflict(codigo) do update set modulo=excluded.modulo,nombre=excluded.nombre,descripcion=excluded.descripcion,orden=excluded.orden,activo=true,es_boman_especifico=true,updated_at=now();

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,p.codigo,false from unnest(enum_range(null::public.rol_usuario))r(rol)
cross join public.permisos_sistema p where r.rol::text<>'admin' and p.codigo in('clientes.acceder','clientes.editar','clientes.fusionar')
on conflict(rol,permiso_codigo)do nothing;
update public.rol_permisos set permitido=true,updated_at=now() where permiso_codigo='clientes.acceder' and rol::text in('tienda','gerencia','control');
update public.rol_permisos set permitido=true,updated_at=now() where permiso_codigo='clientes.editar' and rol::text in('tienda','control');
update public.rol_permisos set permitido=true,updated_at=now() where permiso_codigo='clientes.fusionar' and rol::text='control';

create or replace function public.normalizar_cliente_v113(p_valor text) returns text
language sql immutable parallel safe set search_path='' as $$
 select regexp_replace(translate(lower(btrim(coalesce(p_valor,''))),'áéíóúüñ','aeiouun'),'[^a-z0-9]+','','g');
$$;

create table if not exists public.clientes_v113(
 id uuid primary key default gen_random_uuid(),
 nombre text not null check(length(btrim(nombre))>=2),
 identificacion text,
 tipo_identificacion text check(tipo_identificacion is null or tipo_identificacion in('cedula','ruc','pasaporte','otro')),
 nombre_normalizado text not null,
 estado text not null default 'activo' check(estado in('activo','fusionado')),
 fusionado_en_id uuid references public.clientes_v113(id) on delete restrict,
 nota text,
 creado_por uuid references public.perfiles(id) on delete set null,
 actualizado_por uuid references public.perfiles(id) on delete set null,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 check((estado='activo' and fusionado_en_id is null)or(estado='fusionado' and fusionado_en_id is not null))
);
create unique index if not exists uq_clientes_v113_identificacion_activa on public.clientes_v113(public.normalizar_cliente_v113(identificacion)) where estado='activo' and nullif(public.normalizar_cliente_v113(identificacion),'')is not null;
create index if not exists idx_clientes_v113_nombre on public.clientes_v113(nombre_normalizado)where estado='activo';

create table if not exists public.cliente_contactos_v113(
 id uuid primary key default gen_random_uuid(),cliente_id uuid not null references public.clientes_v113(id)on delete restrict,
 tipo text not null check(tipo in('telefono','whatsapp','email','otro')),valor text not null check(length(btrim(valor))>=3),
 etiqueta text,principal boolean not null default false,created_at timestamptz not null default now(),unique(cliente_id,tipo,valor)
);
create table if not exists public.cliente_direcciones_v113(
 id uuid primary key default gen_random_uuid(),cliente_id uuid not null references public.clientes_v113(id)on delete restrict,
 direccion text not null check(length(btrim(direccion))>=5),etiqueta text,principal boolean not null default false,created_at timestamptz not null default now(),unique(cliente_id,direccion)
);
create table if not exists public.cliente_eventos_v113(
 id uuid primary key default gen_random_uuid(),cliente_id uuid not null references public.clientes_v113(id)on delete restrict,
 accion text not null,datos jsonb not null default'{}',motivo text not null check(length(btrim(motivo))>=10),
 usuario_id uuid not null references public.perfiles(id)on delete restrict,idempotency_key uuid not null unique,created_at timestamptz not null default now()
);
alter table public.contratos add column if not exists cliente_id_v113 uuid references public.clientes_v113(id)on delete restrict;
create index if not exists idx_contratos_cliente_v113 on public.contratos(cliente_id_v113,fecha_ingreso desc);

insert into public.clientes_v113(nombre,nombre_normalizado)
select min(btrim(c.cliente)),public.normalizar_cliente_v113(c.cliente) from public.contratos c
where nullif(public.normalizar_cliente_v113(c.cliente),'')is not null and not exists(select 1 from public.clientes_v113 cl where cl.estado='activo'and cl.nombre_normalizado=public.normalizar_cliente_v113(c.cliente))group by public.normalizar_cliente_v113(c.cliente);
update public.contratos c set cliente_id_v113=(select cl.id from public.clientes_v113 cl where cl.estado='activo' and cl.nombre_normalizado=public.normalizar_cliente_v113(c.cliente) order by cl.created_at limit 1)where c.cliente_id_v113 is null;
insert into public.cliente_contactos_v113(cliente_id,tipo,valor,principal)
select distinct c.cliente_id_v113,x.tipo,btrim(x.valor),true from public.contratos c cross join lateral(values('telefono',c.telefono),('whatsapp',c.whatsapp),('email',lower(c.email)))x(tipo,valor)
where c.cliente_id_v113 is not null and length(btrim(coalesce(x.valor,'')))>=3 on conflict do nothing;
insert into public.cliente_direcciones_v113(cliente_id,direccion,principal)
select distinct cliente_id_v113,btrim(direccion),true from public.contratos where cliente_id_v113 is not null and length(btrim(coalesce(direccion,'')))>=5 on conflict do nothing;

create or replace function public.asignar_cliente_contrato_v113()returns trigger language plpgsql security definer set search_path='' as $v113$
declare v_id uuid;
begin
 if tg_op='UPDATE'then
  if new.cliente is distinct from old.cliente and new.cliente_id_v113 is not distinct from old.cliente_id_v113 then new.cliente_id_v113:=null;end if;
 end if;
 if new.cliente_id_v113 is not null then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended(public.normalizar_cliente_v113(new.cliente),113));
 select id into v_id from public.clientes_v113 where estado='activo' and nombre_normalizado=public.normalizar_cliente_v113(new.cliente)order by created_at limit 1;
 if v_id is null then insert into public.clientes_v113(nombre,nombre_normalizado,creado_por,actualizado_por)values(btrim(new.cliente),public.normalizar_cliente_v113(new.cliente),new.creado_por,new.actualizado_por)returning id into v_id;end if;
 new.cliente_id_v113:=v_id;return new;
end;$v113$;
drop trigger if exists trg_asignar_cliente_contrato_v113 on public.contratos;
create trigger trg_asignar_cliente_contrato_v113 before insert or update of cliente,cliente_id_v113 on public.contratos for each row execute function public.asignar_cliente_contrato_v113();

create or replace function public.sincronizar_contactos_contrato_v113()returns trigger language plpgsql security definer set search_path='' as $v113$
begin
 if new.cliente_id_v113 is null then return new;end if;
 insert into public.cliente_contactos_v113(cliente_id,tipo,valor,principal)
 select new.cliente_id_v113,x.tipo,btrim(x.valor),true from(values('telefono',new.telefono),('whatsapp',new.whatsapp),('email',lower(new.email)))x(tipo,valor)
 where length(btrim(coalesce(x.valor,'')))>=3 on conflict do nothing;
 if length(btrim(coalesce(new.direccion,'')))>=5 then insert into public.cliente_direcciones_v113(cliente_id,direccion,principal)values(new.cliente_id_v113,btrim(new.direccion),true)on conflict do nothing;end if;
 return new;
end;$v113$;
drop trigger if exists trg_sincronizar_contactos_contrato_v113 on public.contratos;
create trigger trg_sincronizar_contactos_contrato_v113 after insert or update of cliente_id_v113,telefono,whatsapp,email,direccion on public.contratos for each row execute function public.sincronizar_contactos_contrato_v113();

create or replace function public.listar_clientes_v113(p_busqueda text default null,p_solo_duplicados boolean default false,p_pagina integer default 1,p_por_pagina integer default 30)
returns jsonb language plpgsql stable security definer set search_path='' as $v113$
declare v_r jsonb;v_pag integer:=greatest(coalesce(p_pagina,1),1);v_por integer:=least(greatest(coalesce(p_por_pagina,30),1),100);
begin
 if auth.uid()is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('clientes.acceder')then raise exception'No tienes permiso para consultar clientes';end if;
 with base as materialized(select cl.id,cl.nombre,cl.identificacion,cl.tipo_identificacion,cl.updated_at,
  (select count(*)from public.contratos c where c.cliente_id_v113=cl.id)::integer contratos,
  coalesce((select sum(c.presupuesto)from public.contratos c where c.cliente_id_v113=cl.id),0)ventas,
  coalesce((select sum(c.abono)from public.contratos c where c.cliente_id_v113=cl.id),0)pagado,
  coalesce((select sum(greatest(c.presupuesto-c.abono,0))from public.contratos c where c.cliente_id_v113=cl.id),0)saldo,
  exists(select 1 from public.clientes_v113 d where d.estado='activo'and d.id<>cl.id and(d.nombre_normalizado=cl.nombre_normalizado or(nullif(public.normalizar_cliente_v113(d.identificacion),'')is not null and public.normalizar_cliente_v113(d.identificacion)=public.normalizar_cliente_v113(cl.identificacion))))duplicado
 from public.clientes_v113 cl where cl.estado='activo'and(nullif(btrim(coalesce(p_busqueda,'')),'')is null or cl.nombre ilike'%'||btrim(p_busqueda)||'%'or cl.identificacion ilike'%'||btrim(p_busqueda)||'%')),
 filtrados as(select * from base where not coalesce(p_solo_duplicados,false) or duplicado),pag as(select * from filtrados order by saldo desc,nombre offset(v_pag-1)*v_por limit v_por)
 select jsonb_build_object('total',(select count(*)from filtrados),'pagina',v_pag,'por_pagina',v_por,'resumen',jsonb_build_object('clientes',(select count(*)from filtrados),'ventas',coalesce((select sum(ventas)from filtrados),0),'saldo',coalesce((select sum(saldo)from filtrados),0),'duplicados',(select count(*)from filtrados where duplicado)),'filas',coalesce((select jsonb_agg(to_jsonb(pag)order by saldo desc,nombre)from pag),'[]'))into v_r;return v_r;
end;$v113$;

create or replace function public.obtener_cliente_v113(p_cliente_id uuid)returns jsonb language plpgsql stable security definer set search_path='' as $v113$
declare v_r jsonb;
begin
 if auth.uid()is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('clientes.acceder')then raise exception'No tienes permiso para consultar clientes';end if;
 select jsonb_build_object('cliente',to_jsonb(cl),'contactos',coalesce((select jsonb_agg(to_jsonb(x)order by principal desc,tipo,valor)from public.cliente_contactos_v113 x where x.cliente_id=cl.id),'[]'),'direcciones',coalesce((select jsonb_agg(to_jsonb(x)order by principal desc,direccion)from public.cliente_direcciones_v113 x where x.cliente_id=cl.id),'[]'),
 'contratos',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'numero',c.numero,'fecha',c.fecha_ingreso,'entrega',c.fecha_entrega,'estado',c.estado,'reposicion',c.reposicion,'presupuesto',c.presupuesto,'pagado',c.abono,'saldo',greatest(c.presupuesto-c.abono,0))order by c.fecha_ingreso desc)from public.contratos c where c.cliente_id_v113=cl.id),'[]'),
 'pagos',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'contrato_id',c.id,'numero',c.numero,'fecha',a.fecha,'monto',a.monto,'medio',a.medio_pago,'referencia',a.referencia,'estado',a.estado)order by a.fecha desc,a.created_at desc)from public.contrato_abonos_v100 a join public.contratos c on c.id=a.contrato_id where c.cliente_id_v113=cl.id),'[]'),
 'devoluciones',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'contrato_id',c.id,'numero',c.numero,'fecha',e.revertido_en,'motivo',e.motivo_reversion,'prendas',(select sum(l.cantidad)from public.contrato_entrega_lineas_v112 l where l.entrega_id=e.id))order by e.revertido_en desc)from public.contrato_entregas_v112 e join public.contratos c on c.id=e.contrato_id where c.cliente_id_v113=cl.id and e.estado='revertida'),'[]'),
 'duplicados',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'nombre',d.nombre,'identificacion',d.identificacion))from public.clientes_v113 d where d.estado='activo'and d.id<>cl.id and(d.nombre_normalizado=cl.nombre_normalizado or(nullif(public.normalizar_cliente_v113(d.identificacion),'')is not null and public.normalizar_cliente_v113(d.identificacion)=public.normalizar_cliente_v113(cl.identificacion)))),'[]'))into v_r from public.clientes_v113 cl where cl.id=p_cliente_id;
 if v_r is null then raise exception'El cliente no existe';end if;return v_r;
end;$v113$;

create or replace function public.guardar_cliente_v113(p_cliente_id uuid,p_datos jsonb,p_motivo text,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path='' as $v113$
declare v_uid uuid:=auth.uid();v_id uuid;v_res jsonb;v_item jsonb;v_ident text:=nullif(btrim(p_datos->>'identificacion'),'');
begin
 if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('clientes.editar')then raise exception'No tienes permiso para editar clientes';end if;if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;if length(btrim(coalesce(p_motivo,'')))<10 then raise exception'El motivo debe tener al menos 10 caracteres';end if;if length(btrim(coalesce(p_datos->>'nombre','')))<2 then raise exception'Escribe el nombre del cliente';end if;
 select datos into v_res from public.cliente_eventos_v113 where idempotency_key=p_idempotency_key;if found then return v_res;end if;
 if p_cliente_id is null then insert into public.clientes_v113(nombre,identificacion,tipo_identificacion,nombre_normalizado,nota,creado_por,actualizado_por)values(btrim(p_datos->>'nombre'),v_ident,nullif(p_datos->>'tipo_identificacion',''),public.normalizar_cliente_v113(p_datos->>'nombre'),nullif(btrim(p_datos->>'nota'),''),v_uid,v_uid)returning id into v_id;
 else update public.clientes_v113 set nombre=btrim(p_datos->>'nombre'),identificacion=v_ident,tipo_identificacion=nullif(p_datos->>'tipo_identificacion',''),nombre_normalizado=public.normalizar_cliente_v113(p_datos->>'nombre'),nota=nullif(btrim(p_datos->>'nota'),''),actualizado_por=v_uid,updated_at=now()where id=p_cliente_id and estado='activo'returning id into v_id;if v_id is null then raise exception'El cliente no existe o fue fusionado';end if;end if;
 if jsonb_typeof(coalesce(p_datos->'contactos','[]'))='array'then delete from public.cliente_contactos_v113 where cliente_id=v_id;for v_item in select value from jsonb_array_elements(p_datos->'contactos')loop if length(btrim(coalesce(v_item->>'valor','')))>=3 then insert into public.cliente_contactos_v113(cliente_id,tipo,valor,etiqueta,principal)values(v_id,case when v_item->>'tipo'in('telefono','whatsapp','email','otro')then v_item->>'tipo'else'otro'end,btrim(v_item->>'valor'),nullif(btrim(v_item->>'etiqueta'),''),coalesce((v_item->>'principal')::boolean,false))on conflict do nothing;end if;end loop;end if;
 if jsonb_typeof(coalesce(p_datos->'direcciones','[]'))='array'then delete from public.cliente_direcciones_v113 where cliente_id=v_id;for v_item in select value from jsonb_array_elements(p_datos->'direcciones')loop if length(btrim(coalesce(v_item->>'direccion','')))>=5 then insert into public.cliente_direcciones_v113(cliente_id,direccion,etiqueta,principal)values(v_id,btrim(v_item->>'direccion'),nullif(btrim(v_item->>'etiqueta'),''),coalesce((v_item->>'principal')::boolean,false))on conflict do nothing;end if;end loop;end if;
 update public.contratos set cliente=btrim(p_datos->>'nombre')where cliente_id_v113=v_id and cliente is distinct from btrim(p_datos->>'nombre');
 v_res:=jsonb_build_object('cliente_id',v_id);insert into public.cliente_eventos_v113(cliente_id,accion,datos,motivo,usuario_id,idempotency_key)values(v_id,case when p_cliente_id is null then'crear'else'editar'end,v_res,btrim(p_motivo),v_uid,p_idempotency_key);return v_res;
exception when unique_violation then raise exception'Ya existe un cliente activo con esa identificacion';end;$v113$;

create or replace function public.fusionar_clientes_v113(p_conservar_id uuid,p_duplicado_id uuid,p_motivo text,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path='' as $v113$
declare v_uid uuid:=auth.uid();v_res jsonb;
begin
 if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('clientes.fusionar')then raise exception'No tienes permiso para fusionar clientes';end if;if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;select datos into v_res from public.cliente_eventos_v113 where idempotency_key=p_idempotency_key;if found then return v_res;end if;if p_conservar_id=p_duplicado_id then raise exception'Selecciona dos clientes distintos';end if;if length(btrim(coalesce(p_motivo,'')))<10 then raise exception'El motivo debe tener al menos 10 caracteres';end if;
 perform 1 from public.clientes_v113 where id in(p_conservar_id,p_duplicado_id)and estado='activo'for update;if(select count(*)from public.clientes_v113 where id in(p_conservar_id,p_duplicado_id)and estado='activo')<>2 then raise exception'Uno de los clientes no existe o ya fue fusionado';end if;
 update public.contratos set cliente_id_v113=p_conservar_id,cliente=(select nombre from public.clientes_v113 where id=p_conservar_id)where cliente_id_v113=p_duplicado_id;
 insert into public.cliente_contactos_v113(cliente_id,tipo,valor,etiqueta,principal)select p_conservar_id,tipo,valor,etiqueta,principal from public.cliente_contactos_v113 where cliente_id=p_duplicado_id on conflict do nothing;delete from public.cliente_contactos_v113 where cliente_id=p_duplicado_id;
 insert into public.cliente_direcciones_v113(cliente_id,direccion,etiqueta,principal)select p_conservar_id,direccion,etiqueta,principal from public.cliente_direcciones_v113 where cliente_id=p_duplicado_id on conflict do nothing;delete from public.cliente_direcciones_v113 where cliente_id=p_duplicado_id;
 update public.clientes_v113 set estado='fusionado',fusionado_en_id=p_conservar_id,updated_at=now(),actualizado_por=v_uid where id=p_duplicado_id;
 v_res:=jsonb_build_object('cliente_id',p_conservar_id,'fusionado_id',p_duplicado_id);insert into public.cliente_eventos_v113(cliente_id,accion,datos,motivo,usuario_id,idempotency_key)values(p_conservar_id,'fusionar',v_res,btrim(p_motivo),v_uid,p_idempotency_key);return v_res;
end;$v113$;

alter table public.clientes_v113 enable row level security;alter table public.cliente_contactos_v113 enable row level security;alter table public.cliente_direcciones_v113 enable row level security;alter table public.cliente_eventos_v113 enable row level security;
revoke all on public.clientes_v113,public.cliente_contactos_v113,public.cliente_direcciones_v113,public.cliente_eventos_v113 from public,anon,authenticated;
do $p$declare f regprocedure;begin foreach f in array array['public.listar_clientes_v113(text,boolean,integer,integer)'::regprocedure,'public.obtener_cliente_v113(uuid)'::regprocedure,'public.guardar_cliente_v113(uuid,jsonb,text,uuid)'::regprocedure,'public.fusionar_clientes_v113(uuid,uuid,text,uuid)'::regprocedure]loop execute format('alter function %s owner to postgres',f);execute format('revoke all on function %s from public,anon',f);execute format('grant execute on function %s to authenticated',f);end loop;end;$p$;
revoke all on function public.normalizar_cliente_v113(text),public.asignar_cliente_contrato_v113(),public.sincronizar_contactos_contrato_v113()from public,anon,authenticated;
commit;
