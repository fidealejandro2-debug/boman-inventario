-- ============================================================
-- BOMAN INVENTARIO - v114: cuentas por cobrar de contratos
-- Cartera, promesas, abonos y seguimiento de cobro.
-- Ejecutar despues de v113.
-- ============================================================
begin;
-- Comparte el candado de migracion con v113: nunca se instalan en paralelo.
select pg_advisory_xact_lock(1131142026);
lock table public.contratos in access exclusive mode;
do $$begin if to_regclass('public.clientes_v113')is null or to_regclass('public.contrato_abonos_v100')is null then raise exception'Faltan v100 o v113 antes de v114';end if;end$$;

insert into public.permisos_sistema as p(codigo,modulo,nombre,descripcion,orden,es_boman_especifico)values
('contratos.cartera.ver','Contratos','Consultar cuentas por cobrar','Consulta saldos, vencimientos, promesas y recordatorios.',202,true),
('contratos.cartera.editar','Contratos','Gestionar cuentas por cobrar','Registra promesas, abonos y gestiones de cobranza.',203,true)
on conflict(codigo)do update set modulo=excluded.modulo,nombre=excluded.nombre,descripcion=excluded.descripcion,orden=excluded.orden,activo=true,es_boman_especifico=true,updated_at=now();
insert into public.rol_permisos(rol,permiso_codigo,permitido)select r.rol,p.codigo,false from unnest(enum_range(null::public.rol_usuario))r(rol)cross join public.permisos_sistema p where r.rol::text<>'admin'and p.codigo in('contratos.cartera.ver','contratos.cartera.editar')on conflict do nothing;
update public.rol_permisos set permitido=true,updated_at=now()where permiso_codigo='contratos.cartera.ver'and rol::text in('gerencia','control');
update public.rol_permisos set permitido=true,updated_at=now()where permiso_codigo='contratos.cartera.editar'and rol::text='control';

create table if not exists public.contrato_cartera_v114(
 contrato_id uuid primary key references public.contratos(id)on delete restrict,
 fecha_vencimiento_base date not null,nota text,actualizado_por uuid references public.perfiles(id)on delete set null,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.contrato_promesas_pago_v114(
 id uuid primary key default gen_random_uuid(),contrato_id uuid not null references public.contratos(id)on delete restrict,
 fecha_prometida date not null,monto_prometido numeric(14,2)not null check(monto_prometido>0),nota text,
 estado text not null default'vigente'check(estado in('vigente','cumplida','incumplida','anulada')),
 creado_por uuid not null references public.perfiles(id)on delete restrict,created_at timestamptz not null default now(),
 resuelto_at timestamptz,motivo_resolucion text,idempotency_key uuid not null unique
);
create unique index if not exists uq_promesa_vigente_v114 on public.contrato_promesas_pago_v114(contrato_id)where estado='vigente';
create index if not exists idx_promesas_fecha_v114 on public.contrato_promesas_pago_v114(fecha_prometida)where estado='vigente';
create table if not exists public.contrato_recordatorios_cobro_v114(
 id uuid primary key default gen_random_uuid(),contrato_id uuid not null references public.contratos(id)on delete restrict,
 fecha_gestion timestamptz not null default now(),canal text not null check(canal in('llamada','whatsapp','email','visita','otro')),
 resultado text not null check(length(btrim(resultado))>=5),proximo_recordatorio date,
 usuario_id uuid not null references public.perfiles(id)on delete restrict,idempotency_key uuid not null unique,created_at timestamptz not null default now()
);
create index if not exists idx_recordatorios_proximo_v114 on public.contrato_recordatorios_cobro_v114(proximo_recordatorio)where proximo_recordatorio is not null;
insert into public.contrato_cartera_v114(contrato_id,fecha_vencimiento_base)
select id,coalesce(fecha_entrega,(fecha_ingreso at time zone'America/Guayaquil')::date)from public.contratos on conflict(contrato_id)do nothing;

create or replace function public.sincronizar_cartera_contrato_v114()returns trigger language plpgsql security definer set search_path=''as $v114$
begin insert into public.contrato_cartera_v114(contrato_id,fecha_vencimiento_base,actualizado_por)values(new.id,coalesce(new.fecha_entrega,(new.fecha_ingreso at time zone'America/Guayaquil')::date),new.actualizado_por)on conflict(contrato_id)do nothing;return new;end;$v114$;
drop trigger if exists trg_sincronizar_cartera_contrato_v114 on public.contratos;
create trigger trg_sincronizar_cartera_contrato_v114 after insert on public.contratos for each row execute function public.sincronizar_cartera_contrato_v114();

create or replace function public.listar_cartera_contratos_v114(p_busqueda text default null,p_estado text default null,p_desde date default null,p_hasta date default null,p_pagina integer default 1,p_por_pagina integer default 40)
returns jsonb language plpgsql stable security definer set search_path=''as $v114$
declare v_r jsonb;v_hoy date:=(now()at time zone'America/Guayaquil')::date;v_pag integer:=greatest(coalesce(p_pagina,1),1);v_por integer:=least(greatest(coalesce(p_por_pagina,40),1),100);
begin
 if auth.uid()is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.cartera.ver')then raise exception'No tienes permiso para consultar cartera';end if;
 with base as materialized(select c.id,c.numero,c.cliente_id_v113 cliente_id,coalesce(cl.nombre,c.cliente)cliente,c.vendedor,c.estado contrato_estado,c.fecha_entrega,c.presupuesto,c.abono,greatest(c.presupuesto-c.abono,0)::numeric(14,2)saldo,
  coalesce(pr.fecha_prometida,cc.fecha_vencimiento_base)fecha_compromiso,pr.id promesa_id,pr.monto_prometido,
  case when c.presupuesto-c.abono<=0 then'pagada'when coalesce(pr.fecha_prometida,cc.fecha_vencimiento_base)<v_hoy then'vencida'when pr.fecha_prometida=v_hoy then'promesa_hoy'else'pendiente'end estado,
  (select max(r.proximo_recordatorio)from public.contrato_recordatorios_cobro_v114 r where r.contrato_id=c.id and r.proximo_recordatorio>=v_hoy)proximo_recordatorio
 from public.contratos c join public.contrato_cartera_v114 cc on cc.contrato_id=c.id left join public.clientes_v113 cl on cl.id=c.cliente_id_v113 left join public.contrato_promesas_pago_v114 pr on pr.contrato_id=c.id and pr.estado='vigente'),
 filtrados as(select * from base where(nullif(btrim(coalesce(p_busqueda,'')),'')is null or numero ilike'%'||btrim(p_busqueda)||'%'or cliente ilike'%'||btrim(p_busqueda)||'%'or vendedor ilike'%'||btrim(p_busqueda)||'%')and(nullif(p_estado,'')is null or estado=p_estado)and(p_desde is null or fecha_compromiso>=p_desde)and(p_hasta is null or fecha_compromiso<=p_hasta)),pag as(select * from filtrados order by case estado when'vencida'then 0 when'promesa_hoy'then 1 when'pendiente'then 2 else 3 end,fecha_compromiso,numero offset(v_pag-1)*v_por limit v_por)
 select jsonb_build_object('total',(select count(*)from filtrados),'pagina',v_pag,'por_pagina',v_por,'resumen',jsonb_build_object('saldo',coalesce((select sum(saldo)from filtrados),0),'vencido',coalesce((select sum(saldo)from filtrados where estado='vencida'),0),'por_vencer',coalesce((select sum(saldo)from filtrados where estado in('pendiente','promesa_hoy')),0),'contratos_vencidos',(select count(*)from filtrados where estado='vencida')),'filas',coalesce((select jsonb_agg(to_jsonb(pag)order by case estado when'vencida'then 0 when'promesa_hoy'then 1 when'pendiente'then 2 else 3 end,fecha_compromiso,numero)from pag),'[]'))into v_r;return v_r;
end;$v114$;

create or replace function public.obtener_cartera_contrato_v114(p_contrato_id uuid)returns jsonb language plpgsql stable security definer set search_path=''as $v114$
declare v_r jsonb;
begin if auth.uid()is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.cartera.ver')then raise exception'No tienes permiso para consultar cartera';end if;
 select jsonb_build_object('contrato',jsonb_build_object('id',c.id,'numero',c.numero,'cliente',coalesce(cl.nombre,c.cliente),'cliente_id',c.cliente_id_v113,'vendedor',c.vendedor,'presupuesto',c.presupuesto,'pagado',c.abono,'saldo',greatest(c.presupuesto-c.abono,0),'vencimiento_base',cc.fecha_vencimiento_base,'nota',cc.nota),
 'promesas',coalesce((select jsonb_agg(to_jsonb(p)-'idempotency_key'order by p.created_at desc)from public.contrato_promesas_pago_v114 p where p.contrato_id=c.id),'[]'),
 'abonos',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'fecha',a.fecha,'monto',a.monto,'medio',a.medio_pago,'referencia',a.referencia,'nota',a.nota,'estado',a.estado,'creado_por',pf.nombre_completo)order by a.fecha desc,a.created_at desc)from public.contrato_abonos_v100 a left join public.perfiles pf on pf.id=a.creado_por where a.contrato_id=c.id),'[]'),
 'recordatorios',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'fecha_gestion',r.fecha_gestion,'canal',r.canal,'resultado',r.resultado,'proximo_recordatorio',r.proximo_recordatorio,'usuario',pf.nombre_completo)order by r.fecha_gestion desc)from public.contrato_recordatorios_cobro_v114 r join public.perfiles pf on pf.id=r.usuario_id where r.contrato_id=c.id),'[]'))into v_r from public.contratos c join public.contrato_cartera_v114 cc on cc.contrato_id=c.id left join public.clientes_v113 cl on cl.id=c.cliente_id_v113 where c.id=p_contrato_id;
 if v_r is null then raise exception'El contrato no existe';end if;return v_r;end;$v114$;

create or replace function public.configurar_cartera_contrato_v114(p_contrato_id uuid,p_fecha_vencimiento date,p_nota text,p_motivo text,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path=''as $v114$
declare v_uid uuid:=auth.uid();v_r jsonb;
begin if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.cartera.editar')then raise exception'No tienes permiso para gestionar cartera';end if;if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;select datos into v_r from public.cliente_eventos_v113 where idempotency_key=p_idempotency_key;if found then return v_r;end if;if p_fecha_vencimiento is null then raise exception'Elige una fecha de vencimiento';end if;if length(btrim(coalesce(p_motivo,'')))<10 then raise exception'El motivo debe tener al menos 10 caracteres';end if;
 update public.contrato_cartera_v114 set fecha_vencimiento_base=p_fecha_vencimiento,nota=nullif(btrim(p_nota),''),actualizado_por=v_uid,updated_at=now()where contrato_id=p_contrato_id;if not found then raise exception'El contrato no existe';end if;
 v_r:=jsonb_build_object('contrato_id',p_contrato_id,'fecha_vencimiento',p_fecha_vencimiento);insert into public.cliente_eventos_v113(cliente_id,accion,datos,motivo,usuario_id,idempotency_key)select cliente_id_v113,'configurar_cartera',v_r,btrim(p_motivo),v_uid,p_idempotency_key from public.contratos where id=p_contrato_id;return v_r;end;$v114$;

create or replace function public.registrar_promesa_pago_v114(p_contrato_id uuid,p_fecha_prometida date,p_monto numeric,p_nota text,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path=''as $v114$
declare v_uid uuid:=auth.uid();v_saldo numeric;v_id uuid;v_r jsonb;v_hoy date:=(now()at time zone'America/Guayaquil')::date;
begin if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.cartera.editar')then raise exception'No tienes permiso para registrar promesas';end if;if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;select jsonb_build_object('id',id,'contrato_id',contrato_id,'fecha_prometida',fecha_prometida,'monto',monto_prometido)into v_r from public.contrato_promesas_pago_v114 where idempotency_key=p_idempotency_key;if found then return v_r;end if;if p_fecha_prometida is null or p_fecha_prometida<v_hoy then raise exception'La fecha prometida no puede estar vencida';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_contrato_id::text,114));
 select greatest(presupuesto-abono,0)into v_saldo from public.contratos where id=p_contrato_id for update;if not found then raise exception'El contrato no existe';end if;if v_saldo<=0 then raise exception'El contrato no tiene saldo pendiente';end if;if coalesce(p_monto,0)<=0 or p_monto>v_saldo then raise exception'El monto prometido debe estar entre 0,01 y el saldo pendiente';end if;
 update public.contrato_promesas_pago_v114 set estado=case when fecha_prometida<v_hoy then'incumplida'else'anulada'end,resuelto_at=now(),motivo_resolucion=case when fecha_prometida<v_hoy then'Promesa vencida sin pago completo'else'Reemplazada por una nueva promesa'end where contrato_id=p_contrato_id and estado='vigente';
 insert into public.contrato_promesas_pago_v114(contrato_id,fecha_prometida,monto_prometido,nota,creado_por,idempotency_key)values(p_contrato_id,p_fecha_prometida,round(p_monto,2),nullif(btrim(p_nota),''),v_uid,p_idempotency_key)returning id into v_id;
 v_r:=jsonb_build_object('id',v_id,'contrato_id',p_contrato_id,'fecha_prometida',p_fecha_prometida,'monto',round(p_monto,2));return v_r;exception when unique_violation then select jsonb_build_object('id',id,'contrato_id',contrato_id,'fecha_prometida',fecha_prometida,'monto',monto_prometido)into v_r from public.contrato_promesas_pago_v114 where idempotency_key=p_idempotency_key;return v_r;end;$v114$;

create or replace function public.registrar_abono_cartera_v114(p_contrato_id uuid,p_fecha date,p_monto numeric,p_medio_pago text,p_referencia text,p_nota text,p_motivo text,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path=''as $v114$
declare v_uid uuid:=auth.uid();v_c public.contratos%rowtype;v_id uuid;v_total numeric;v_r jsonb;
begin if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.cartera.editar')then raise exception'No tienes permiso para registrar abonos';end if;if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;if length(btrim(coalesce(p_motivo,'')))<10 then raise exception'El motivo debe tener al menos 10 caracteres';end if;if p_fecha is null or p_fecha>(now()at time zone'America/Guayaquil')::date then raise exception'La fecha del abono no es valida';end if;if coalesce(p_monto,0)<=0 then raise exception'El monto debe ser mayor que cero';end if;if p_medio_pago not in('efectivo','transferencia','tarjeta','cheque','otro')then raise exception'El medio de pago no es valido';end if;if p_medio_pago in('transferencia','tarjeta','cheque')and length(btrim(coalesce(p_referencia,'')))<3 then raise exception'Este medio de pago exige referencia';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,114));select resultado into v_r from public.contrato_finanzas_eventos_v100 where idempotency_key=p_idempotency_key;if found then return v_r;end if;select*into v_c from public.contratos where id=p_contrato_id for update;if not found then raise exception'El contrato no existe';end if;if v_c.abono+p_monto>v_c.presupuesto then raise exception'El abono supera el saldo pendiente de %',v_c.presupuesto-v_c.abono;end if;
 insert into public.contrato_abonos_v100(contrato_id,fecha,monto,medio_pago,referencia,nota,creado_por)values(p_contrato_id,p_fecha,round(p_monto,2),p_medio_pago,nullif(btrim(p_referencia),''),nullif(btrim(p_nota),''),v_uid)returning id into v_id;v_total:=public.recalcular_abono_contrato_v100(p_contrato_id);v_r:=jsonb_build_object('abono_id',v_id,'contrato_id',p_contrato_id,'total_abonado',v_total,'saldo',v_c.presupuesto-v_total);
 insert into public.contrato_finanzas_eventos_v100(contrato_id,abono_id,accion,valor_anterior,valor_nuevo,motivo,usuario_id,idempotency_key,resultado)values(p_contrato_id,v_id,'registrar_abono',v_c.abono,v_total,btrim(p_motivo),v_uid,p_idempotency_key,v_r);if v_total>=v_c.presupuesto then update public.contrato_promesas_pago_v114 set estado='cumplida',resuelto_at=now(),motivo_resolucion='Saldo cancelado'where contrato_id=p_contrato_id and estado='vigente';end if;return v_r;end;$v114$;

create or replace function public.registrar_recordatorio_cobro_v114(p_contrato_id uuid,p_canal text,p_resultado text,p_proximo_recordatorio date,p_idempotency_key uuid)returns jsonb language plpgsql security definer set search_path=''as $v114$
declare v_uid uuid:=auth.uid();v_id uuid;v_r jsonb;
begin if v_uid is null then raise exception'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.cartera.editar')then raise exception'No tienes permiso para registrar gestiones';end if;if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;select jsonb_build_object('id',id,'contrato_id',contrato_id)into v_r from public.contrato_recordatorios_cobro_v114 where idempotency_key=p_idempotency_key;if found then return v_r;end if;if not exists(select 1 from public.contratos where id=p_contrato_id)then raise exception'El contrato no existe';end if;if p_canal not in('llamada','whatsapp','email','visita','otro')then raise exception'El canal no es valido';end if;if length(btrim(coalesce(p_resultado,'')))<5 then raise exception'Escribe el resultado de la gestion';end if;if p_proximo_recordatorio is not null and p_proximo_recordatorio<(now()at time zone'America/Guayaquil')::date then raise exception'El proximo recordatorio no puede estar vencido';end if;
 insert into public.contrato_recordatorios_cobro_v114(contrato_id,canal,resultado,proximo_recordatorio,usuario_id,idempotency_key)values(p_contrato_id,p_canal,btrim(p_resultado),p_proximo_recordatorio,v_uid,p_idempotency_key)returning id into v_id;v_r:=jsonb_build_object('id',v_id,'contrato_id',p_contrato_id);return v_r;exception when unique_violation then select jsonb_build_object('id',id,'contrato_id',contrato_id)into v_r from public.contrato_recordatorios_cobro_v114 where idempotency_key=p_idempotency_key;return v_r;end;$v114$;

alter table public.contrato_cartera_v114 enable row level security;alter table public.contrato_promesas_pago_v114 enable row level security;alter table public.contrato_recordatorios_cobro_v114 enable row level security;
revoke all on public.contrato_cartera_v114,public.contrato_promesas_pago_v114,public.contrato_recordatorios_cobro_v114 from public,anon,authenticated;
do $p$declare f regprocedure;begin foreach f in array array['public.listar_cartera_contratos_v114(text,text,date,date,integer,integer)'::regprocedure,'public.obtener_cartera_contrato_v114(uuid)'::regprocedure,'public.configurar_cartera_contrato_v114(uuid,date,text,text,uuid)'::regprocedure,'public.registrar_promesa_pago_v114(uuid,date,numeric,text,uuid)'::regprocedure,'public.registrar_abono_cartera_v114(uuid,date,numeric,text,text,text,text,uuid)'::regprocedure,'public.registrar_recordatorio_cobro_v114(uuid,text,text,date,uuid)'::regprocedure]loop execute format('alter function %s owner to postgres',f);execute format('revoke all on function %s from public,anon',f);execute format('grant execute on function %s to authenticated',f);end loop;end;$p$;
revoke all on function public.sincronizar_cartera_contrato_v114()from public,anon,authenticated;
commit;
