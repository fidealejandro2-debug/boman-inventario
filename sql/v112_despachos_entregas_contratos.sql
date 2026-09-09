-- ============================================================
-- BOMAN INVENTARIO - v112: despachos y entregas de contratos
-- Ejecutar despues de v111 y sin migraciones en paralelo.
-- ============================================================
begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.contrato_prendas') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta instalar contratos y permisos antes de v112';
  end if;
end;
$requisitos$;

insert into public.permisos_sistema(
  codigo, modulo, nombre, descripcion, orden, activo, es_boman_especifico
) values
  ('contratos.entregar','contratos','Registrar entregas','Registra entregas completas o parciales con evidencia.',176,true,true),
  ('contratos.revertir_entrega','contratos','Revertir entregas','Revierte una entrega con motivo e idempotencia.',177,true,true)
on conflict(codigo) do update set modulo=excluded.modulo,nombre=excluded.nombre,
  descripcion=excluded.descripcion,orden=excluded.orden,activo=true,
  es_boman_especifico=true,updated_at=now();

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,p.codigo,false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text<>'admin' and p.codigo in('contratos.entregar','contratos.revertir_entrega')
on conflict(rol,permiso_codigo) do nothing;

update public.rol_permisos set permitido=true,updated_at=now()
where permiso_codigo='contratos.entregar' and rol::text in('tienda','logistica','control','gerencia');
update public.rol_permisos set permitido=true,updated_at=now()
where permiso_codigo='contratos.revertir_entrega' and rol::text in('control','gerencia');

alter table public.contratos
  add column if not exists estado_antes_entregas_v112 text;

create table if not exists public.contrato_entregas_v112(
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  secuencia integer not null check(secuencia>0),
  tipo text not null check(tipo in('parcial','completa')),
  estado text not null default 'aplicada' check(estado in('aplicada','revertida')),
  fecha_entrega_real timestamptz not null,
  responsable text not null check(btrim(responsable)<>''),
  observacion text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  revertido_por uuid references public.perfiles(id) on delete restrict,
  revertido_en timestamptz,
  motivo_reversion text,
  reversion_idempotency_key uuid unique,
  created_at timestamptz not null default now(),
  unique(contrato_id,secuencia),
  check((estado='aplicada' and revertido_por is null and revertido_en is null and motivo_reversion is null)
     or (estado='revertida' and revertido_por is not null and revertido_en is not null and length(btrim(motivo_reversion))>=10))
);

create table if not exists public.contrato_entrega_lineas_v112(
  id uuid primary key default gen_random_uuid(),
  entrega_id uuid not null references public.contrato_entregas_v112(id) on delete restrict,
  contrato_prenda_id uuid not null references public.contrato_prendas(id) on delete restrict,
  cantidad integer not null check(cantidad>0),
  unique(entrega_id,contrato_prenda_id)
);

create table if not exists public.contrato_entrega_archivos_pendientes_v112(
  id uuid primary key,
  creado_por uuid not null references public.perfiles(id) on delete cascade,
  storage_path text not null unique,
  nombre_archivo text not null,
  mime_type text not null check(mime_type in('image/jpeg','image/png','image/webp','application/pdf')),
  tamano_bytes bigint not null check(tamano_bytes between 1 and 12582912),
  usado_en uuid references public.contrato_entregas_v112(id) on delete set null,
  vence_en timestamptz not null default now()+interval '24 hours',
  created_at timestamptz not null default now()
);

create table if not exists public.contrato_entrega_archivos_v112(
  id uuid primary key default gen_random_uuid(),
  entrega_id uuid not null references public.contrato_entregas_v112(id) on delete restrict,
  tipo text not null check(tipo in('foto','firma','comprobante')),
  storage_path text not null unique,
  nombre_archivo text not null,
  mime_type text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_entregas_contrato_v112 on public.contrato_entregas_v112(contrato_id,created_at desc);
create index if not exists idx_entrega_lineas_prenda_v112 on public.contrato_entrega_lineas_v112(contrato_prenda_id);
create index if not exists idx_entrega_archivos_entrega_v112 on public.contrato_entrega_archivos_v112(entrega_id);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('contratos-entregas','contratos-entregas',false,12582912,
  array['image/jpeg','image/png','image/webp','application/pdf']::text[])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.preparar_evidencia_entrega_v112(
  p_nombre_archivo text,p_mime_type text,p_tamano_bytes bigint,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_uid uuid:=auth.uid();v_ext text;v_path text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion';end if;
  if not public.usuario_tiene_permiso_v35('contratos.entregar') then raise exception 'No tienes permiso para registrar entregas';end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria';end if;
  if lower(coalesce(p_mime_type,'')) not in('image/jpeg','image/png','image/webp','application/pdf') then raise exception 'Usa archivos JPG, PNG, WebP o PDF';end if;
  if p_tamano_bytes is null or p_tamano_bytes not between 1 and 12582912 then raise exception 'Cada evidencia debe pesar entre 1 byte y 12 MB';end if;
  v_ext:=case lower(p_mime_type) when'image/png'then'png' when'image/webp'then'webp' when'application/pdf'then'pdf' else'jpg'end;
  v_path:=v_uid::text||'/'||p_idempotency_key::text||'.'||v_ext;
  insert into public.contrato_entrega_archivos_pendientes_v112(id,creado_por,storage_path,nombre_archivo,mime_type,tamano_bytes)
  values(p_idempotency_key,v_uid,v_path,left(btrim(coalesce(p_nombre_archivo,'evidencia')),255),lower(p_mime_type),p_tamano_bytes)
  on conflict(id) do nothing;
  select storage_path into v_path from public.contrato_entrega_archivos_pendientes_v112 where id=p_idempotency_key and creado_por=v_uid;
  if v_path is null then raise exception 'La clave de evidencia ya fue utilizada';end if;
  return jsonb_build_object('id',p_idempotency_key,'path',v_path);
end;$fn$;

create or replace function public.puede_subir_evidencia_entrega_v112(p_path text)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.contrato_entrega_archivos_pendientes_v112 p
  where p.storage_path=p_path and p.creado_por=auth.uid() and p.usado_en is null and p.vence_en>now());
$$;

create or replace function public.puede_leer_evidencia_entrega_v112(p_path text)
returns boolean language sql stable security definer set search_path='' as $$
 select public.usuario_tiene_permiso_v35('contratos.entregar')
     or public.usuario_tiene_permiso_v35('contratos.revertir_entrega')
     or public.usuario_tiene_permiso_v35('contratos.acceder');
$$;

drop policy if exists "subir_evidencia_entrega_v112" on storage.objects;
create policy "subir_evidencia_entrega_v112" on storage.objects for insert to authenticated
with check(bucket_id='contratos-entregas' and public.puede_subir_evidencia_entrega_v112(name));
drop policy if exists "leer_evidencia_entrega_v112" on storage.objects;
create policy "leer_evidencia_entrega_v112" on storage.objects for select to authenticated
using(bucket_id='contratos-entregas' and public.puede_leer_evidencia_entrega_v112(name));

create or replace function public.listar_despachos_v112(p_busqueda text default null,p_pagina integer default 1,p_por_pagina integer default 30)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_pag integer:=greatest(coalesce(p_pagina,1),1);v_por integer:=least(greatest(coalesce(p_por_pagina,30),1),100);v_r jsonb;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesion';end if;
 if not(public.usuario_tiene_permiso_v35('contratos.entregar') or public.usuario_tiene_permiso_v35('contratos.revertir_entrega') or public.usuario_tiene_permiso_v35('contratos.acceder')) then raise exception 'No tienes permiso para consultar entregas';end if;
 with base as materialized(
  select c.id,c.numero,c.cliente,c.vendedor,c.estado,c.prioridad,c.fecha_entrega,
   coalesce((select sum(cp.cantidad) from public.contrato_prendas cp where cp.contrato_id=c.id),c.total_prendas)::integer total_prendas,
   coalesce((select sum(l.cantidad) from public.contrato_entrega_lineas_v112 l join public.contrato_entregas_v112 e on e.id=l.entrega_id where e.contrato_id=c.id and e.estado='aplicada'),0)::integer entregadas,
   (select ca.drive_id from public.contrato_archivos ca where ca.contrato_id=c.id and ca.tipo='mockup' order by ca.orden,ca.id limit 1) mockup_drive_id,
   (select ca.url from public.contrato_archivos ca where ca.contrato_id=c.id and ca.tipo='mockup' order by ca.orden,ca.id limit 1) mockup_url
  from public.contratos c where nullif(btrim(coalesce(p_busqueda,'')),'') is null or c.numero ilike'%'||btrim(p_busqueda)||'%' or c.cliente ilike'%'||btrim(p_busqueda)||'%' or c.vendedor ilike'%'||btrim(p_busqueda)||'%'
 ),pag as(select * from base order by greatest(total_prendas-entregadas,0)>0 desc,fecha_entrega nulls last,numero offset(v_pag-1)*v_por limit v_por)
 select jsonb_build_object('total',(select count(*)from base),'pagina',v_pag,'por_pagina',v_por,
  'filas',coalesce((select jsonb_agg(jsonb_build_object('id',id,'numero',numero,'cliente',cliente,'vendedor',vendedor,'estado',estado,'prioridad',prioridad,'fecha_entrega',fecha_entrega,'total_prendas',total_prendas,'entregadas',entregadas,'pendientes',greatest(total_prendas-entregadas,0),'mockup_drive_id',mockup_drive_id,'mockup_url',mockup_url)order by greatest(total_prendas-entregadas,0)>0 desc,fecha_entrega nulls last,numero)from pag),'[]'::jsonb))into v_r;
 return v_r;
end;$fn$;

create or replace function public.obtener_despacho_contrato_v112(p_contrato_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_r jsonb;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesion';end if;
 if not(public.usuario_tiene_permiso_v35('contratos.entregar') or public.usuario_tiene_permiso_v35('contratos.revertir_entrega') or public.usuario_tiene_permiso_v35('contratos.acceder')) then raise exception 'No tienes permiso para consultar entregas';end if;
 select jsonb_build_object('contrato',jsonb_build_object('id',c.id,'numero',c.numero,'cliente',c.cliente,'vendedor',c.vendedor,'estado',c.estado,'fecha_entrega',c.fecha_entrega,'total_prendas',c.total_prendas),
  'lineas',coalesce((select jsonb_agg(jsonb_build_object('id',cp.id,'prenda',cp.prenda,'calidad',cp.calidad,'detalle',cp.detalle,'genero',cp.genero,'talla',cp.talla,'ordenadas',cp.cantidad,'entregadas',coalesce(x.entregadas,0),'pendientes',greatest(cp.cantidad-coalesce(x.entregadas,0),0))order by cp.prenda,cp.calidad,cp.genero,cp.talla)from public.contrato_prendas cp left join lateral(select sum(l.cantidad)::integer entregadas from public.contrato_entrega_lineas_v112 l join public.contrato_entregas_v112 e on e.id=l.entrega_id where l.contrato_prenda_id=cp.id and e.estado='aplicada')x on true where cp.contrato_id=c.id),'[]'::jsonb),
  'entregas',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'secuencia',e.secuencia,'tipo',e.tipo,'estado',e.estado,'fecha_entrega_real',e.fecha_entrega_real,'responsable',e.responsable,'observacion',e.observacion,'creado_por',pc.nombre_completo,'created_at',e.created_at,'revertido_por',pr.nombre_completo,'revertido_en',e.revertido_en,'motivo_reversion',e.motivo_reversion,'total',(select coalesce(sum(l.cantidad),0)from public.contrato_entrega_lineas_v112 l where l.entrega_id=e.id),'archivos',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'tipo',a.tipo,'storage_path',a.storage_path,'nombre_archivo',a.nombre_archivo,'mime_type',a.mime_type)order by a.created_at)from public.contrato_entrega_archivos_v112 a where a.entrega_id=e.id),'[]'::jsonb))order by e.secuencia desc)from public.contrato_entregas_v112 e join public.perfiles pc on pc.id=e.creado_por left join public.perfiles pr on pr.id=e.revertido_por where e.contrato_id=c.id),'[]'::jsonb))into v_r from public.contratos c where c.id=p_contrato_id;
 if v_r is null then raise exception 'El contrato no existe';end if;return v_r;
end;$fn$;

create or replace function public.registrar_entrega_contrato_v112(p_contrato_id uuid,p_lineas jsonb,p_archivos jsonb,p_fecha_entrega_real timestamptz,p_responsable text,p_observacion text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_uid uuid:=auth.uid();v_entrega uuid;v_item jsonb;v_cp public.contrato_prendas%rowtype;v_pend integer;v_cant integer;v_total integer:=0;v_secuencia integer;v_tipo text;v_restante integer;v_arch public.contrato_entrega_archivos_pendientes_v112%rowtype;v_result jsonb;v_quien text;v_estado_actual text;v_entregas_activas integer;
begin
 if v_uid is null then raise exception 'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.entregar')then raise exception 'No tienes permiso para registrar entregas';end if;
 if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria';end if;
 select jsonb_build_object('id',id,'tipo',tipo,'secuencia',secuencia)into v_result from public.contrato_entregas_v112 where idempotency_key=p_idempotency_key;if found then return v_result;end if;
 if jsonb_typeof(p_lineas)<>'array'or jsonb_array_length(p_lineas)=0 then raise exception 'Selecciona al menos una prenda para entregar';end if;
 if (select count(*) from jsonb_array_elements(p_lineas))<>(select count(distinct value->>'contrato_prenda_id')from jsonb_array_elements(p_lineas))then raise exception 'Una prenda esta repetida en la entrega';end if;
 if length(btrim(coalesce(p_responsable,'')))<3 then raise exception 'Escribe el responsable de la entrega';end if;if p_fecha_entrega_real is null or p_fecha_entrega_real>now()+interval'5 minutes'then raise exception 'La fecha real de entrega no es valida';end if;
 select estado into v_estado_actual from public.contratos where id=p_contrato_id for update;if not found then raise exception 'El contrato no existe';end if;
 select count(*) into v_entregas_activas from public.contrato_entregas_v112 where contrato_id=p_contrato_id and estado='aplicada';
 if v_entregas_activas=0 and lower(btrim(v_estado_actual)) in('entregado','entrega parcial')then raise exception 'El contrato ya figura como %. Revisa o migra su entrega anterior antes de registrar otra',v_estado_actual;end if;
 for v_item in select value from jsonb_array_elements(p_lineas)loop
  v_cant:=coalesce((v_item->>'cantidad')::integer,0);if v_cant<=0 then continue;end if;
  select * into v_cp from public.contrato_prendas where id=(v_item->>'contrato_prenda_id')::uuid and contrato_id=p_contrato_id for update;if not found then raise exception 'Una prenda no pertenece al contrato';end if;
  select v_cp.cantidad-coalesce(sum(l.cantidad),0)into v_pend from public.contrato_entrega_lineas_v112 l join public.contrato_entregas_v112 e on e.id=l.entrega_id where l.contrato_prenda_id=v_cp.id and e.estado='aplicada';
  if v_cant>v_pend then raise exception 'La entrega de % % supera el saldo pendiente de %',v_cp.prenda,v_cp.talla,v_pend;end if;v_total:=v_total+v_cant;
 end loop;
 if v_total<=0 then raise exception 'Ingresa una cantidad mayor a cero';end if;
 select coalesce(max(secuencia),0)+1 into v_secuencia from public.contrato_entregas_v112 where contrato_id=p_contrato_id;
 select sum(cp.cantidad)-coalesce((select sum(l.cantidad)from public.contrato_entrega_lineas_v112 l join public.contrato_entregas_v112 e on e.id=l.entrega_id where e.contrato_id=p_contrato_id and e.estado='aplicada'),0)-v_total into v_restante from public.contrato_prendas cp where cp.contrato_id=p_contrato_id;
 v_tipo:=case when v_restante=0 then'completa'else'parcial'end;
 update public.contratos set estado_antes_entregas_v112=case when estado not in('Entrega parcial','Entregado')then estado else estado_antes_entregas_v112 end,estado=case when v_tipo='completa'then'Entregado'else'Entrega parcial'end,actualizado_por=v_uid where id=p_contrato_id;
 insert into public.contrato_entregas_v112(contrato_id,secuencia,tipo,fecha_entrega_real,responsable,observacion,creado_por,idempotency_key)values(p_contrato_id,v_secuencia,v_tipo,p_fecha_entrega_real,btrim(p_responsable),nullif(btrim(coalesce(p_observacion,'')),''),v_uid,p_idempotency_key)returning id into v_entrega;
 for v_item in select value from jsonb_array_elements(p_lineas)loop v_cant:=coalesce((v_item->>'cantidad')::integer,0);if v_cant>0 then insert into public.contrato_entrega_lineas_v112(entrega_id,contrato_prenda_id,cantidad)values(v_entrega,(v_item->>'contrato_prenda_id')::uuid,v_cant);end if;end loop;
 if coalesce(jsonb_typeof(p_archivos),'null')='array'then for v_item in select value from jsonb_array_elements(p_archivos)loop
  select * into v_arch from public.contrato_entrega_archivos_pendientes_v112 where id=(v_item->>'id')::uuid and creado_por=v_uid and usado_en is null and vence_en>now()for update;if not found then raise exception 'Una evidencia no fue preparada o ya fue utilizada';end if;
  if not exists(select 1 from storage.objects where bucket_id='contratos-entregas'and name=v_arch.storage_path)then raise exception 'Una evidencia no termino de cargarse';end if;
  insert into public.contrato_entrega_archivos_v112(entrega_id,tipo,storage_path,nombre_archivo,mime_type)values(v_entrega,case when v_item->>'tipo'in('foto','firma','comprobante')then v_item->>'tipo'else'foto'end,v_arch.storage_path,v_arch.nombre_archivo,v_arch.mime_type);update public.contrato_entrega_archivos_pendientes_v112 set usado_en=v_entrega where id=v_arch.id;
 end loop;end if;
 select nombre_completo into v_quien from public.perfiles where id=v_uid;insert into public.contrato_eventos(contrato_id,campo,valor_nuevo,quien,perfil_id)values(p_contrato_id,'entrega',v_tipo||' · '||v_total||' prenda(s) · #'||v_secuencia,coalesce(v_quien,p_responsable),v_uid);
 return jsonb_build_object('id',v_entrega,'tipo',v_tipo,'secuencia',v_secuencia,'total',v_total,'pendientes',v_restante);
end;$fn$;

create or replace function public.revertir_entrega_contrato_v112(p_entrega_id uuid,p_motivo text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_uid uuid:=auth.uid();v_e public.contrato_entregas_v112%rowtype;v_activas integer;v_pend integer;v_quien text;
begin
 if v_uid is null then raise exception 'Debes iniciar sesion';end if;if not public.usuario_tiene_permiso_v35('contratos.revertir_entrega')then raise exception 'No tienes permiso para revertir entregas';end if;
 if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria';end if;if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'El motivo debe tener al menos 10 caracteres';end if;
 select * into v_e from public.contrato_entregas_v112 where id=p_entrega_id for update;if not found then raise exception 'La entrega no existe';end if;
 if v_e.estado='revertida'then if v_e.reversion_idempotency_key=p_idempotency_key then return jsonb_build_object('id',v_e.id,'estado','revertida');end if;raise exception 'La entrega ya fue revertida';end if;
 perform 1 from public.contratos where id=v_e.contrato_id for update;
 update public.contrato_entregas_v112 set estado='revertida',revertido_por=v_uid,revertido_en=now(),motivo_reversion=btrim(p_motivo),reversion_idempotency_key=p_idempotency_key where id=v_e.id;
 select count(*)into v_activas from public.contrato_entregas_v112 where contrato_id=v_e.contrato_id and estado='aplicada';
 select sum(cp.cantidad)-coalesce((select sum(l.cantidad)from public.contrato_entrega_lineas_v112 l join public.contrato_entregas_v112 e on e.id=l.entrega_id where e.contrato_id=v_e.contrato_id and e.estado='aplicada'),0)into v_pend from public.contrato_prendas cp where cp.contrato_id=v_e.contrato_id;
 update public.contratos set estado=case when v_activas=0 then coalesce(estado_antes_entregas_v112,'Ingresado')when v_pend=0 then'Entregado'else'Entrega parcial'end,estado_antes_entregas_v112=case when v_activas=0 then null else estado_antes_entregas_v112 end,actualizado_por=v_uid where id=v_e.contrato_id;
 select nombre_completo into v_quien from public.perfiles where id=v_uid;insert into public.contrato_eventos(contrato_id,campo,valor_anterior,valor_nuevo,quien,perfil_id)values(v_e.contrato_id,'entrega_revertida','#'||v_e.secuencia,p_motivo,coalesce(v_quien,''),v_uid);
 return jsonb_build_object('id',v_e.id,'estado','revertida','pendientes',v_pend);
end;$fn$;

alter table public.contrato_entregas_v112 enable row level security;alter table public.contrato_entrega_lineas_v112 enable row level security;alter table public.contrato_entrega_archivos_pendientes_v112 enable row level security;alter table public.contrato_entrega_archivos_v112 enable row level security;
revoke all on public.contrato_entregas_v112,public.contrato_entrega_lineas_v112,public.contrato_entrega_archivos_pendientes_v112,public.contrato_entrega_archivos_v112 from public,anon,authenticated;

do $privilegios$ declare f regprocedure;begin foreach f in array array[
 'public.preparar_evidencia_entrega_v112(text,text,bigint,uuid)'::regprocedure,'public.puede_subir_evidencia_entrega_v112(text)'::regprocedure,'public.puede_leer_evidencia_entrega_v112(text)'::regprocedure,'public.listar_despachos_v112(text,integer,integer)'::regprocedure,'public.obtener_despacho_contrato_v112(uuid)'::regprocedure,'public.registrar_entrega_contrato_v112(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure,'public.revertir_entrega_contrato_v112(uuid,text,uuid)'::regprocedure
 ]loop execute format('alter function %s owner to postgres',f);execute format('revoke all on function %s from public,anon',f);execute format('grant execute on function %s to authenticated',f);end loop;end;$privilegios$;
commit;
