-- ============================================================
-- BOMAN INVENTARIO - v158
-- Asignacion de contratos importados a usuarios vendedores y centro de
-- contratos con brief, abonos y despachos. Ejecutar despues de v157.
-- ============================================================

begin;
select pg_advisory_xact_lock(1582026);

do $$begin
 if to_regclass('public.contratos')is null
    or not exists(select 1 from information_schema.columns where table_schema='public'and table_name='contratos'and column_name='vendedor_perfil_id')
    or to_regprocedure('public.obtener_brief_vendedor_v111(uuid)')is null
    or to_regprocedure('public.obtener_despacho_contrato_v112(uuid)')is null
    or to_regclass('public.contrato_abonos_v100')is null then
  raise exception'Faltan v147, v112 o v100 antes de instalar v158';
 end if;
end$$;

insert into public.permisos_sistema as p(codigo,modulo,nombre,descripcion,orden,es_boman_especifico)values
('contratos.asignar_vendedor','Contratos','Asignar contratos a vendedores','Vincula contratos importados o existentes con la cuenta responsable del vendedor.',202,true)
on conflict(codigo)do update set modulo=excluded.modulo,nombre=excluded.nombre,descripcion=excluded.descripcion,orden=excluded.orden,activo=true,es_boman_especifico=true,updated_at=now();

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,'contratos.asignar_vendedor',false from unnest(enum_range(null::public.rol_usuario))r(rol)
where r.rol::text<>'admin' on conflict(rol,permiso_codigo)do nothing;
update public.rol_permisos set permitido=true,updated_at=now()
where permiso_codigo='contratos.asignar_vendedor'and rol::text in('gerencia','control');

create table if not exists public.contrato_asignaciones_v158(
 id uuid primary key default gen_random_uuid(),
 idempotency_key uuid not null unique,
 contrato_id uuid references public.contratos(id)on delete restrict,
 vendedor_texto_origen text,
 vendedor_perfil_id uuid not null references public.perfiles(id)on delete restrict,
 cantidad integer not null check(cantidad>0),
 motivo text not null check(length(btrim(motivo))>=10),
 asignado_por uuid not null references public.perfiles(id)on delete restrict,
 resultado jsonb not null,
 created_at timestamptz not null default now()
);
alter table public.contrato_asignaciones_v158 enable row level security;
revoke all on public.contrato_asignaciones_v158 from public,anon,authenticated;

create or replace function public.catalogo_asignacion_vendedores_v158()returns jsonb
language plpgsql stable security definer set search_path=''as $v158$
declare v_r jsonb;
begin
 if auth.uid()is null or not public.usuario_tiene_permiso_v35('contratos.asignar_vendedor')then raise exception'No tienes permiso para asignar vendedores';end if;
 select jsonb_build_object(
  'vendedores',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nombre',p.nombre_completo,'contratos',(select count(*)from public.contratos c where c.vendedor_perfil_id=p.id))order by p.nombre_completo)from public.perfiles p where p.activo and p.rol::text='vendedor'),'[]'::jsonb),
  'origenes',coalesce((select jsonb_agg(jsonb_build_object('nombre',q.nombre,'cantidad',q.cantidad)order by q.cantidad desc,q.nombre)from(select coalesce(nullif(btrim(c.vendedor),''),'Sin vendedor')nombre,count(*)::integer cantidad from public.contratos c where c.vendedor_perfil_id is null group by coalesce(nullif(btrim(c.vendedor),''),'Sin vendedor'))q),'[]'::jsonb),
  'sin_asignar',(select count(*)from public.contratos where vendedor_perfil_id is null)
 )into v_r;return v_r;
end;$v158$;

create or replace function public.asignar_vendedor_contratos_v158(
 p_contrato_id uuid,p_vendedor_texto text,p_vendedor_perfil_id uuid,
 p_motivo text,p_idempotency_key uuid
)returns jsonb language plpgsql security definer set search_path=''as $v158$
declare v_nombre text;v_cantidad integer;v_r jsonb;
begin
 if auth.uid()is null or not public.usuario_tiene_permiso_v35('contratos.asignar_vendedor')then raise exception'No tienes permiso para asignar vendedores';end if;
 if p_idempotency_key is null then raise exception'La idempotencia es obligatoria';end if;
 select resultado into v_r from public.contrato_asignaciones_v158 where idempotency_key=p_idempotency_key;if found then return v_r;end if;
 if length(btrim(coalesce(p_motivo,'')))<10 then raise exception'Explica la asignacion con al menos 10 caracteres';end if;
 select nombre_completo into v_nombre from public.perfiles where id=p_vendedor_perfil_id and activo and rol::text='vendedor';
 if not found then raise exception'El usuario seleccionado no existe, esta inactivo o no tiene rol Vendedor';end if;
 if p_contrato_id is null and nullif(btrim(coalesce(p_vendedor_texto,'')),'')is null then raise exception'Selecciona el nombre importado que deseas vincular';end if;

 with elegidos as materialized(
  select c.id,c.numero,c.vendedor_perfil_id,c.vendedor from public.contratos c
  where (p_contrato_id is not null and c.id=p_contrato_id)
     or (p_contrato_id is null and c.vendedor_perfil_id is null and
       coalesce(nullif(btrim(c.vendedor),''),'Sin vendedor')=btrim(p_vendedor_texto))
  for update
 ),actualizados as(
  update public.contratos c set vendedor_perfil_id=p_vendedor_perfil_id,
   vendedor=v_nombre,vendedor_responsable=v_nombre,actualizado_por=auth.uid()
  from elegidos e where c.id=e.id
    and(c.vendedor_perfil_id is distinct from p_vendedor_perfil_id or c.vendedor is distinct from v_nombre)
  returning c.id,e.vendedor vendedor_anterior
 )insert into public.contrato_eventos(contrato_id,campo,valor_anterior,valor_nuevo,quien,perfil_id)
 select a.id,'vendedor_asignado',coalesce(nullif(btrim(a.vendedor_anterior),''),'Sin vendedor'),v_nombre,
  coalesce((select nombre_completo from public.perfiles where id=auth.uid()),''),auth.uid()
 from actualizados a;
 get diagnostics v_cantidad=row_count;
 if v_cantidad=0 then raise exception'No se encontraron contratos para asignar';end if;
 v_r:=jsonb_build_object('cantidad',v_cantidad,'vendedor_perfil_id',p_vendedor_perfil_id,'vendedor',v_nombre,'contrato_id',p_contrato_id);
 insert into public.contrato_asignaciones_v158(idempotency_key,contrato_id,vendedor_texto_origen,vendedor_perfil_id,cantidad,motivo,asignado_por,resultado)
 values(p_idempotency_key,p_contrato_id,nullif(btrim(p_vendedor_texto),''),p_vendedor_perfil_id,v_cantidad,btrim(p_motivo),auth.uid(),v_r);
 return v_r;
end;$v158$;

create or replace function public.listar_centro_contratos_v158(
 p_busqueda text default null,p_solo_sin_asignar boolean default false,
 p_pagina integer default 1,p_por_pagina integer default 30
)returns jsonb language plpgsql stable security definer set search_path=''as $v158$
declare v_pag integer:=greatest(coalesce(p_pagina,1),1);v_por integer:=least(greatest(coalesce(p_por_pagina,30),1),100);v_r jsonb;v_es_vendedor boolean:=public.rol_usuario_actual()::text='vendedor';
begin
 if auth.uid()is null or not(public.usuario_tiene_permiso_v35('contratos.acceder')or public.usuario_tiene_permiso_v35('contratos.entregar')or public.usuario_tiene_permiso_v35('contratos.revertir_entrega'))then raise exception'No tienes permiso para consultar contratos';end if;
 with base as materialized(
  select c.id,c.numero,c.cliente,c.vendedor,c.vendedor_perfil_id,p.nombre_completo vendedor_usuario,c.estado,c.prioridad,c.fecha_entrega,c.presupuesto,c.abono,greatest(c.presupuesto-c.abono,0)::numeric(14,2)saldo,
   coalesce((select sum(cp.cantidad)from public.contrato_prendas cp where cp.contrato_id=c.id),c.total_prendas)::integer total_prendas,
   coalesce((select sum(l.cantidad)from public.contrato_entrega_lineas_v112 l join public.contrato_entregas_v112 e on e.id=l.entrega_id where e.contrato_id=c.id and e.estado='aplicada'),0)::integer entregadas,
   (select ca.drive_id from public.contrato_archivos ca where ca.contrato_id=c.id and ca.tipo='mockup'order by ca.orden,ca.id limit 1)mockup_drive_id,
   (select ca.url from public.contrato_archivos ca where ca.contrato_id=c.id and ca.tipo='mockup'order by ca.orden,ca.id limit 1)mockup_url
  from public.contratos c left join public.perfiles p on p.id=c.vendedor_perfil_id
  where (not v_es_vendedor or c.vendedor_perfil_id=auth.uid())
   and(not coalesce(p_solo_sin_asignar,false)or(not v_es_vendedor and c.vendedor_perfil_id is null))
   and(nullif(btrim(coalesce(p_busqueda,'')),'')is null or c.numero ilike'%'||btrim(p_busqueda)||'%'or c.cliente ilike'%'||btrim(p_busqueda)||'%'or c.vendedor ilike'%'||btrim(p_busqueda)||'%')
 ),pag as(select*from base order by greatest(total_prendas-entregadas,0)>0 desc,fecha_entrega nulls last,numero desc offset(v_pag-1)*v_por limit v_por)
 select jsonb_build_object('total',(select count(*)from base),'pagina',v_pag,'por_pagina',v_por,'filas',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('pendientes',greatest(p.total_prendas-p.entregadas,0))order by greatest(p.total_prendas-p.entregadas,0)>0 desc,p.fecha_entrega nulls last,p.numero desc)from pag p),'[]'::jsonb))into v_r;return v_r;
end;$v158$;

create or replace function public.obtener_centro_contrato_v158(p_contrato_id uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $v158$
declare v_r jsonb;v_brief jsonb;v_despacho jsonb;v_es_vendedor boolean:=public.rol_usuario_actual()::text='vendedor';
begin
 if auth.uid()is null or not(public.usuario_tiene_permiso_v35('contratos.acceder')or public.usuario_tiene_permiso_v35('contratos.entregar')or public.usuario_tiene_permiso_v35('contratos.revertir_entrega'))then raise exception'No tienes permiso para consultar contratos';end if;
 if not exists(select 1 from public.contratos c where c.id=p_contrato_id and(not v_es_vendedor or c.vendedor_perfil_id=auth.uid()))then raise exception'El contrato no existe o no esta asignado a tu usuario';end if;
 v_despacho:=public.obtener_despacho_contrato_v112(p_contrato_id);
 select jsonb_build_object('contrato',to_jsonb(c),'prendas',coalesce((select jsonb_agg(to_jsonb(x)order by x.prenda,x.calidad,x.genero,x.talla)from public.contrato_prendas x where x.contrato_id=c.id),'[]'),'jugadores',coalesce((select jsonb_agg(to_jsonb(x)order by x.orden,x.id)from public.contrato_jugadores x where x.contrato_id=c.id),'[]'),'archivos',coalesce((select jsonb_agg(to_jsonb(x)order by x.tipo,x.orden,x.id)from public.contrato_archivos x where x.contrato_id=c.id),'[]'),'especificaciones',coalesce((select jsonb_agg(to_jsonb(x)order by x.orden,x.id)from public.contrato_specs x where x.contrato_id=c.id),'[]'),'facturacion',coalesce((select jsonb_agg(to_jsonb(x)order by x.orden,x.id)from public.contrato_facturacion x where x.contrato_id=c.id),'[]'),'etapas','[]','eventos','[]','enlaces','[]')into v_brief from public.contratos c where c.id=p_contrato_id;
 select v_despacho||jsonb_build_object(
  'brief',v_brief,
  'finanzas',(select jsonb_build_object('presupuesto',c.presupuesto,'abono_inicial',c.abono_inicial_v100,'abonado',c.abono,'saldo',greatest(c.presupuesto-c.abono,0),'vendedor_perfil_id',c.vendedor_perfil_id,'vendedor_usuario',p.nombre_completo)from public.contratos c left join public.perfiles p on p.id=c.vendedor_perfil_id where c.id=p_contrato_id),
  'abonos',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'fecha',a.fecha,'monto',a.monto,'medio_pago',a.medio_pago,'referencia',a.referencia,'nota',a.nota,'estado',a.estado,'created_at',a.created_at,'creado_por',p.nombre_completo)order by a.fecha desc,a.created_at desc)from public.contrato_abonos_v100 a left join public.perfiles p on p.id=a.creado_por where a.contrato_id=p_contrato_id),'[]'::jsonb)
 )into v_r;return v_r;
end;$v158$;

do $p$declare f regprocedure;begin foreach f in array array[
 'public.catalogo_asignacion_vendedores_v158()'::regprocedure,
 'public.asignar_vendedor_contratos_v158(uuid,text,uuid,text,uuid)'::regprocedure,
 'public.listar_centro_contratos_v158(text,boolean,integer,integer)'::regprocedure,
 'public.obtener_centro_contrato_v158(uuid)'::regprocedure
]loop execute format('alter function %s owner to postgres',f);execute format('revoke all on function %s from public,anon',f);execute format('grant execute on function %s to authenticated',f);end loop;end;$p$;

-- Desde v147 el rol vendedor tiene contratos.acceder. Las consultas antiguas
-- de v112 no filtraban por propietario; el centro v158 las reemplaza y evita
-- que una llamada directa permita enumerar contratos de otro vendedor.
revoke execute on function public.listar_despachos_v112(text,integer,integer)from authenticated;
revoke execute on function public.obtener_despacho_contrato_v112(uuid)from authenticated;

insert into public.schema_migrations_boman(id,version,archivo,notas)values
('v158','158','v158_asignacion_vendedores_centro_contratos.sql','Asignacion masiva de contratos importados y centro con brief, abonos y despachos')
on conflict(id)do update set version=excluded.version,archivo=excluded.archivo,notas=excluded.notas,aplicada_at=now();

commit;
notify pgrst,'reload schema';
