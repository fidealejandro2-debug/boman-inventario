-- ============================================================
-- BOMAN INVENTARIO - v100: presupuesto y abonos de contratos
-- Historial de cobros, saldo, ajustes autorizados y auditoria.
-- Ejecutar despues de v99.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.contratos') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Faltan v35 o v79 antes de v100';
  end if;
end $$;

insert into public.permisos_sistema as p(codigo,modulo,nombre,descripcion,orden)
values
 ('contratos.finanzas.ver','Contratos','Ver presupuesto y cobros','Consulta presupuesto, abonos y saldo de contratos.',193),
 ('contratos.finanzas.editar','Contratos','Gestionar presupuesto y cobros','Registra pagos, anulaciones y ajustes financieros auditados.',194)
on conflict(codigo) do update set modulo=excluded.modulo,nombre=excluded.nombre,
descripcion=excluded.descripcion,orden=excluded.orden,activo=true,updated_at=now();

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,p.codigo,false from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p where r.rol::text<>'admin' and p.activo
on conflict(rol,permiso_codigo) do nothing;
update public.rol_permisos set permitido=true,updated_at=now()
where permiso_codigo='contratos.finanzas.ver' and rol::text in('gerencia','control');
update public.rol_permisos set permitido=true,updated_at=now()
where permiso_codigo='contratos.finanzas.editar' and rol::text='control';

alter table public.contratos add column if not exists abono_inicial_v100 numeric(14,2)
  check(abono_inicial_v100 is null or abono_inicial_v100>=0);
alter table public.contratos add column if not exists finanzas_gestionadas_v100 boolean not null default false;
update public.contratos set abono_inicial_v100=abono where abono_inicial_v100 is null;
alter table public.contratos alter column abono_inicial_v100 set default 0;
alter table public.contratos alter column abono_inicial_v100 set not null;

create table if not exists public.contrato_abonos_v100(
 id uuid primary key default gen_random_uuid(),
 contrato_id uuid not null references public.contratos(id) on delete restrict,
 fecha date not null,
 monto numeric(14,2) not null check(monto>0),
 medio_pago text not null check(medio_pago in('efectivo','transferencia','tarjeta','cheque','otro')),
 referencia text,
 nota text,
 estado text not null default 'aplicado' check(estado in('aplicado','anulado')),
 creado_por uuid not null references public.perfiles(id) on delete restrict,
 anulado_por uuid references public.perfiles(id) on delete restrict,
 created_at timestamptz not null default now(),
 anulado_at timestamptz,
 motivo_anulacion text,
 check(medio_pago not in('transferencia','tarjeta','cheque') or length(btrim(coalesce(referencia,'')))>=3),
 check((estado='aplicado' and anulado_por is null and anulado_at is null and motivo_anulacion is null)
    or (estado='anulado' and anulado_por is not null and anulado_at is not null and length(btrim(motivo_anulacion))>=10))
);

create table if not exists public.contrato_finanzas_eventos_v100(
 id uuid primary key default gen_random_uuid(),
 contrato_id uuid not null references public.contratos(id) on delete restrict,
 abono_id uuid references public.contrato_abonos_v100(id) on delete restrict,
 accion text not null check(accion in('registrar_abono','anular_abono','ajustar_presupuesto','ajustar_abono_inicial')),
 valor_anterior numeric(14,2),
 valor_nuevo numeric(14,2),
 datos_anteriores jsonb,
 datos_nuevos jsonb,
 motivo text not null check(length(btrim(motivo))>=10),
 usuario_id uuid not null references public.perfiles(id) on delete restrict,
 idempotency_key uuid not null unique,
 resultado jsonb not null,
 created_at timestamptz not null default now()
);
create index if not exists idx_contrato_abonos_v100_contrato on public.contrato_abonos_v100(contrato_id,fecha desc) where estado='aplicado';
create index if not exists idx_contrato_finanzas_eventos_v100 on public.contrato_finanzas_eventos_v100(contrato_id,created_at desc);

alter table public.contrato_abonos_v100 enable row level security;
alter table public.contrato_finanzas_eventos_v100 enable row level security;
revoke all on public.contrato_abonos_v100 from public,anon,authenticated;
revoke all on public.contrato_finanzas_eventos_v100 from public,anon,authenticated;

create or replace function public.recalcular_abono_contrato_v100(p_contrato_id uuid)
returns numeric language plpgsql volatile security definer set search_path=''
as $fn$
declare v_total numeric(14,2);
begin
 select round(c.abono_inicial_v100+coalesce(sum(a.monto) filter(where a.estado='aplicado'),0),2)
 into v_total from public.contratos c left join public.contrato_abonos_v100 a on a.contrato_id=c.id
 where c.id=p_contrato_id group by c.id,c.abono_inicial_v100;
 if v_total is null then raise exception 'El contrato no existe'; end if;
 perform set_config('boman.finanzas_v100','autorizado',true);
 update public.contratos set abono=v_total,finanzas_gestionadas_v100=true where id=p_contrato_id;
 return v_total;
end;$fn$;

create or replace function public.registrar_abono_contrato_v100(
 p_contrato_id uuid,p_fecha date,p_monto numeric,p_medio_pago text,
 p_referencia text,p_nota text,p_motivo text,p_idempotency_key uuid
) returns jsonb language plpgsql volatile security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid();v_c public.contratos%rowtype;v_id uuid;v_total numeric;v_resultado jsonb;
begin
 if v_uid is null then raise exception 'Debes iniciar sesion';end if;
 if not public.usuario_tiene_permiso_v35('contratos.finanzas.editar') then raise exception 'No tienes permiso para registrar cobros';end if;
 if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria';end if;
 if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'El motivo debe tener al menos 10 caracteres';end if;
 if p_fecha is null or p_fecha>(now() at time zone 'America/Guayaquil')::date then raise exception 'La fecha del pago no es valida';end if;
 if coalesce(p_monto,0)<=0 then raise exception 'El monto debe ser mayor que cero';end if;
 if p_medio_pago not in('efectivo','transferencia','tarjeta','cheque','otro') then raise exception 'El medio de pago no es valido';end if;
 if p_medio_pago in('transferencia','tarjeta','cheque') and length(btrim(coalesce(p_referencia,'')))<3 then raise exception 'Este medio de pago exige referencia';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,100));
 select resultado into v_resultado from public.contrato_finanzas_eventos_v100 where idempotency_key=p_idempotency_key;
 if found then return v_resultado;end if;
 select * into v_c from public.contratos where id=p_contrato_id for update;
 if not found then raise exception 'El contrato no existe';end if;
 if v_c.abono+p_monto>v_c.presupuesto then raise exception 'El pago supera el saldo pendiente de %',v_c.presupuesto-v_c.abono;end if;
 insert into public.contrato_abonos_v100(contrato_id,fecha,monto,medio_pago,referencia,nota,creado_por)
 values(p_contrato_id,p_fecha,round(p_monto,2),p_medio_pago,nullif(btrim(p_referencia),''),nullif(btrim(p_nota),''),v_uid) returning id into v_id;
 v_total:=public.recalcular_abono_contrato_v100(p_contrato_id);
 v_resultado:=jsonb_build_object('abono_id',v_id,'contrato_id',p_contrato_id,'total_abonado',v_total,'saldo',v_c.presupuesto-v_total);
 insert into public.contrato_finanzas_eventos_v100(contrato_id,abono_id,accion,valor_anterior,valor_nuevo,motivo,usuario_id,idempotency_key,resultado)
 values(p_contrato_id,v_id,'registrar_abono',v_c.abono,v_total,btrim(p_motivo),v_uid,p_idempotency_key,v_resultado);
 return v_resultado;
end;$fn$;

create or replace function public.anular_abono_contrato_v100(p_abono_id uuid,p_motivo text,p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid();v_a public.contrato_abonos_v100%rowtype;v_anterior numeric;v_total numeric;v_resultado jsonb;
begin
 if v_uid is null then raise exception 'Debes iniciar sesion';end if;
 if not public.usuario_tiene_permiso_v35('contratos.finanzas.editar') then raise exception 'No tienes permiso para anular cobros';end if;
 if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria';end if;
 if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'El motivo debe tener al menos 10 caracteres';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,100));
 select resultado into v_resultado from public.contrato_finanzas_eventos_v100 where idempotency_key=p_idempotency_key;if found then return v_resultado;end if;
 select * into v_a from public.contrato_abonos_v100 where id=p_abono_id and estado='aplicado' for update;
 if not found then raise exception 'El abono no existe o ya fue anulado';end if;
 select abono into v_anterior from public.contratos where id=v_a.contrato_id for update;
 update public.contrato_abonos_v100 set estado='anulado',anulado_por=v_uid,anulado_at=now(),motivo_anulacion=btrim(p_motivo) where id=p_abono_id;
 v_total:=public.recalcular_abono_contrato_v100(v_a.contrato_id);
 v_resultado:=jsonb_build_object('abono_id',p_abono_id,'contrato_id',v_a.contrato_id,'total_abonado',v_total);
 insert into public.contrato_finanzas_eventos_v100(contrato_id,abono_id,accion,valor_anterior,valor_nuevo,motivo,usuario_id,idempotency_key,resultado)
 values(v_a.contrato_id,p_abono_id,'anular_abono',v_anterior,v_total,btrim(p_motivo),v_uid,p_idempotency_key,v_resultado);
 return v_resultado;
end;$fn$;

create or replace function public.ajustar_finanzas_contrato_v100(
 p_contrato_id uuid,p_presupuesto numeric,p_abono_inicial numeric,p_motivo text,p_idempotency_key uuid
) returns jsonb language plpgsql volatile security definer set search_path=''
as $fn$
declare v_uid uuid:=auth.uid();v_c public.contratos%rowtype;v_pagos numeric;v_total numeric;v_resultado jsonb;v_accion text;
begin
 if v_uid is null then raise exception 'Debes iniciar sesion';end if;
 if not public.usuario_tiene_permiso_v35('contratos.finanzas.editar') then raise exception 'No tienes permiso para ajustar el contrato';end if;
 if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria';end if;
 if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'El motivo debe tener al menos 10 caracteres';end if;
 if coalesce(p_presupuesto,-1)<0 or coalesce(p_abono_inicial,-1)<0 then raise exception 'Los valores no pueden ser negativos';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,100));
 select resultado into v_resultado from public.contrato_finanzas_eventos_v100 where idempotency_key=p_idempotency_key;if found then return v_resultado;end if;
 select * into v_c from public.contratos where id=p_contrato_id for update;if not found then raise exception 'El contrato no existe';end if;
 select coalesce(sum(monto),0) into v_pagos from public.contrato_abonos_v100 where contrato_id=p_contrato_id and estado='aplicado';
 v_total:=round(p_abono_inicial+v_pagos,2);
 if p_presupuesto<v_total then raise exception 'El presupuesto no puede ser menor que el total abonado (%)',v_total;end if;
 if p_presupuesto=v_c.presupuesto and p_abono_inicial=v_c.abono_inicial_v100 then raise exception 'Los valores no producen cambios';end if;
 perform set_config('boman.finanzas_v100','autorizado',true);
 update public.contratos set presupuesto=round(p_presupuesto,2),abono_inicial_v100=round(p_abono_inicial,2),abono=v_total,finanzas_gestionadas_v100=true,actualizado_por=v_uid where id=p_contrato_id;
 v_accion:=case when p_presupuesto is distinct from v_c.presupuesto and p_abono_inicial is distinct from v_c.abono_inicial_v100 then 'ajustar_presupuesto' when p_presupuesto is distinct from v_c.presupuesto then 'ajustar_presupuesto' else 'ajustar_abono_inicial' end;
 v_resultado:=jsonb_build_object('contrato_id',p_contrato_id,'presupuesto',round(p_presupuesto,2),'abono_inicial',round(p_abono_inicial,2),'total_abonado',v_total,'saldo',round(p_presupuesto-v_total,2));
 insert into public.contrato_finanzas_eventos_v100(contrato_id,accion,valor_anterior,valor_nuevo,datos_anteriores,datos_nuevos,motivo,usuario_id,idempotency_key,resultado)
 values(p_contrato_id,v_accion,case when v_accion='ajustar_presupuesto' then v_c.presupuesto else v_c.abono_inicial_v100 end,case when v_accion='ajustar_presupuesto' then p_presupuesto else p_abono_inicial end,jsonb_build_object('presupuesto',v_c.presupuesto,'abono_inicial',v_c.abono_inicial_v100,'total_abonado',v_c.abono),jsonb_build_object('presupuesto',round(p_presupuesto,2),'abono_inicial',round(p_abono_inicial,2),'total_abonado',v_total),btrim(p_motivo),v_uid,p_idempotency_key,v_resultado);
 return v_resultado;
end;$fn$;

create or replace function public.listar_finanzas_contratos_v100(p_busqueda text default null,p_estado text default null,p_pagina integer default 1,p_por_pagina integer default 40)
returns jsonb language plpgsql stable security definer set search_path=''
as $fn$
declare v_resultado jsonb;v_pag integer:=greatest(coalesce(p_pagina,1),1);v_lim integer:=least(greatest(coalesce(p_por_pagina,40),1),100);
begin
 if auth.uid() is null or not public.usuario_tiene_permiso_v35('contratos.finanzas.ver') then raise exception 'No tienes permiso para consultar cobros';end if;
 with base as materialized(select c.id,c.numero,c.cliente,c.vendedor,c.estado,c.fecha_entrega,c.presupuesto,c.abono_inicial_v100,c.abono,(c.presupuesto-c.abono)::numeric(14,2) saldo,(select count(*) from public.contrato_abonos_v100 a where a.contrato_id=c.id and a.estado='aplicado')::integer pagos from public.contratos c where(nullif(btrim(p_busqueda),'') is null or c.numero ilike '%'||btrim(p_busqueda)||'%' or c.cliente ilike '%'||btrim(p_busqueda)||'%')and(nullif(btrim(p_estado),'') is null or lower(c.estado)=lower(btrim(p_estado)))),pag as(select * from base order by fecha_entrega desc nulls last,numero offset(v_pag-1)*v_lim limit v_lim)
 select jsonb_build_object('total',(select count(*) from base),'pagina',v_pag,'por_pagina',v_lim,'resumen',jsonb_build_object('presupuesto',coalesce((select sum(presupuesto) from base),0),'abonado',coalesce((select sum(abono) from base),0),'saldo',coalesce((select sum(saldo) from base),0),'contratos_con_saldo',(select count(*) from base where saldo>0)),'filas',coalesce((select jsonb_agg(to_jsonb(pag) order by fecha_entrega desc nulls last,numero) from pag),'[]'::jsonb),'estados',coalesce((select jsonb_agg(e order by e) from(select distinct estado e from public.contratos)s),'[]'::jsonb)) into v_resultado;
 return v_resultado;
end;$fn$;

create or replace function public.obtener_finanzas_contrato_v100(p_contrato_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $fn$
declare v_resultado jsonb;
begin
 if auth.uid() is null or not public.usuario_tiene_permiso_v35('contratos.finanzas.ver') then raise exception 'No tienes permiso para consultar cobros';end if;
 select jsonb_build_object('contrato',jsonb_build_object('id',c.id,'numero',c.numero,'cliente',c.cliente,'estado',c.estado,'presupuesto',c.presupuesto,'abono_inicial',c.abono_inicial_v100,'abonado',c.abono,'saldo',c.presupuesto-c.abono),'abonos',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'fecha',a.fecha,'monto',a.monto,'medio_pago',a.medio_pago,'referencia',a.referencia,'nota',a.nota,'estado',a.estado,'created_at',a.created_at,'creado_por',p.nombre_completo,'motivo_anulacion',a.motivo_anulacion) order by a.fecha desc,a.created_at desc)from public.contrato_abonos_v100 a left join public.perfiles p on p.id=a.creado_por where a.contrato_id=c.id),'[]'::jsonb),'eventos',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'accion',e.accion,'valor_anterior',e.valor_anterior,'valor_nuevo',e.valor_nuevo,'motivo',e.motivo,'created_at',e.created_at,'usuario',p.nombre_completo)order by e.created_at desc)from public.contrato_finanzas_eventos_v100 e left join public.perfiles p on p.id=e.usuario_id where e.contrato_id=c.id),'[]'::jsonb)) into v_resultado from public.contratos c where c.id=p_contrato_id;
 if v_resultado is null then raise exception 'El contrato no existe';end if;return v_resultado;
end;$fn$;

alter table public.contrato_abonos_v100 owner to postgres;alter table public.contrato_finanzas_eventos_v100 owner to postgres;
alter function public.recalcular_abono_contrato_v100(uuid) owner to postgres;
alter function public.registrar_abono_contrato_v100(uuid,date,numeric,text,text,text,text,uuid) owner to postgres;
alter function public.anular_abono_contrato_v100(uuid,text,uuid) owner to postgres;
alter function public.ajustar_finanzas_contrato_v100(uuid,numeric,numeric,text,uuid) owner to postgres;
alter function public.listar_finanzas_contratos_v100(text,text,integer,integer) owner to postgres;
alter function public.obtener_finanzas_contrato_v100(uuid) owner to postgres;
revoke all on function public.recalcular_abono_contrato_v100(uuid) from public,anon,authenticated;
revoke all on function public.registrar_abono_contrato_v100(uuid,date,numeric,text,text,text,text,uuid) from public,anon;
revoke all on function public.anular_abono_contrato_v100(uuid,text,uuid) from public,anon;
revoke all on function public.ajustar_finanzas_contrato_v100(uuid,numeric,numeric,text,uuid) from public,anon;
revoke all on function public.listar_finanzas_contratos_v100(text,text,integer,integer) from public,anon;
revoke all on function public.obtener_finanzas_contrato_v100(uuid) from public,anon;
grant execute on function public.registrar_abono_contrato_v100(uuid,date,numeric,text,text,text,text,uuid) to authenticated;
grant execute on function public.anular_abono_contrato_v100(uuid,text,uuid) to authenticated;
grant execute on function public.ajustar_finanzas_contrato_v100(uuid,numeric,numeric,text,uuid) to authenticated;
grant execute on function public.listar_finanzas_contratos_v100(text,text,integer,integer) to authenticated;
grant execute on function public.obtener_finanzas_contrato_v100(uuid) to authenticated;
commit;notify pgrst,'reload schema';
