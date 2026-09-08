-- ============================================================
-- BOMAN INVENTARIO - v101: costos y rentabilidad por contrato
-- Hoja de costo manual, ordenes vinculadas y panel consolidado.
-- Ejecutar despues de v99. v100 puede instalarse antes o despues.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.ordenes_produccion') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Faltan v24, v35 o v79 antes de v101';
  end if;
end $$;

-- Los costos y margenes son informacion sensible y tienen permisos propios.
insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('produccion.costos.ver', 'Produccion', 'Ver costos y rentabilidad',
   'Consulta hojas de costo, margenes y el consolidado de rentabilidad.', 195),
  ('produccion.costos.editar', 'Produccion', 'Gestionar costos de contratos',
   'Registra costos manuales y vincula ordenes de produccion a contratos.', 196)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.activo
on conflict (rol, permiso_codigo) do nothing;

update public.rol_permisos set permitido = true, updated_at = now()
where permiso_codigo = 'produccion.costos.ver'
  and rol::text in ('gerencia', 'control');
update public.rol_permisos set permitido = true, updated_at = now()
where permiso_codigo = 'produccion.costos.editar'
  and rol::text = 'control';

create table if not exists public.contrato_costos_lineas_v101 (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  naturaleza text not null check (naturaleza in ('estimado', 'real')),
  categoria text not null check (categoria in (
    'materiales', 'mano_obra', 'maquila', 'indirectos', 'transporte', 'otros'
  )),
  concepto text not null check (length(btrim(concepto)) >= 3),
  cantidad numeric(18,4) not null default 1 check (cantidad > 0),
  costo_unitario numeric(18,6) not null check (costo_unitario >= 0),
  total numeric(18,2) generated always as
    (round(cantidad * costo_unitario, 2)) stored,
  activo boolean not null default true,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  actualizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.contrato_ordenes_produccion_v101 (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  orden_id uuid not null unique references public.ordenes_produccion(id) on delete restrict,
  vinculada_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (contrato_id, orden_id)
);

create table if not exists public.contrato_costos_eventos_v101 (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  linea_id uuid references public.contrato_costos_lineas_v101(id) on delete restrict,
  orden_id uuid references public.ordenes_produccion(id) on delete restrict,
  accion text not null check (accion in (
    'crear_linea', 'editar_linea', 'anular_linea', 'vincular_orden', 'desvincular_orden'
  )),
  datos_anteriores jsonb,
  datos_nuevos jsonb,
  motivo text not null check (length(btrim(motivo)) >= 10),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  resultado jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_costos_lineas_v101_contrato
  on public.contrato_costos_lineas_v101(contrato_id, activo, naturaleza);
create index if not exists idx_contrato_ordenes_v101_contrato
  on public.contrato_ordenes_produccion_v101(contrato_id);
create index if not exists idx_costos_eventos_v101_contrato
  on public.contrato_costos_eventos_v101(contrato_id, created_at desc);

alter table public.contrato_costos_lineas_v101 enable row level security;
alter table public.contrato_ordenes_produccion_v101 enable row level security;
alter table public.contrato_costos_eventos_v101 enable row level security;
revoke all on public.contrato_costos_lineas_v101 from public, anon, authenticated;
revoke all on public.contrato_ordenes_produccion_v101 from public, anon, authenticated;
revoke all on public.contrato_costos_eventos_v101 from public, anon, authenticated;

create or replace function public.guardar_costo_contrato_v101(
  p_contrato_id uuid,
  p_linea_id uuid,
  p_naturaleza text,
  p_categoria text,
  p_concepto text,
  p_cantidad numeric,
  p_costo_unitario numeric,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_linea public.contrato_costos_lineas_v101%rowtype;
  v_antes jsonb;
  v_resultado jsonb;
  v_accion text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('produccion.costos.editar') then
    raise exception 'No tienes permiso para gestionar costos';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El motivo debe tener al menos 10 caracteres';
  end if;
  if p_naturaleza not in ('estimado', 'real') then raise exception 'La naturaleza no es valida'; end if;
  if p_categoria not in ('materiales','mano_obra','maquila','indirectos','transporte','otros') then
    raise exception 'La categoria no es valida';
  end if;
  if length(btrim(coalesce(p_concepto, ''))) < 3 then raise exception 'Escribe el concepto'; end if;
  if coalesce(p_cantidad, 0) <= 0 or coalesce(p_costo_unitario, -1) < 0 then
    raise exception 'Cantidad y costo no son validos';
  end if;
  if not exists (select 1 from public.contratos where id = p_contrato_id) then
    raise exception 'El contrato no existe';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 101));
  select resultado into v_resultado from public.contrato_costos_eventos_v101
  where idempotency_key = p_idempotency_key;
  if found then return v_resultado; end if;

  if p_linea_id is null then
    insert into public.contrato_costos_lineas_v101(
      contrato_id, naturaleza, categoria, concepto, cantidad, costo_unitario,
      creado_por, actualizado_por
    ) values (
      p_contrato_id, p_naturaleza, p_categoria, btrim(p_concepto),
      p_cantidad, p_costo_unitario, v_uid, v_uid
    ) returning * into v_linea;
    v_accion := 'crear_linea';
  else
    select l.* into v_linea
    from public.contrato_costos_lineas_v101 l
    where l.id = p_linea_id and l.contrato_id = p_contrato_id and l.activo
    for update;
    if not found then raise exception 'La linea de costo no existe o esta anulada'; end if;
    v_antes := to_jsonb(v_linea);
    update public.contrato_costos_lineas_v101 set
      naturaleza = p_naturaleza, categoria = p_categoria,
      concepto = btrim(p_concepto), cantidad = p_cantidad,
      costo_unitario = p_costo_unitario, actualizado_por = v_uid,
      updated_at = now()
    where id = p_linea_id returning * into v_linea;
    v_accion := 'editar_linea';
  end if;

  v_resultado := jsonb_build_object(
    'linea_id', v_linea.id, 'contrato_id', p_contrato_id,
    'accion', v_accion, 'total', v_linea.total
  );
  insert into public.contrato_costos_eventos_v101(
    contrato_id, linea_id, accion, datos_anteriores, datos_nuevos,
    motivo, usuario_id, idempotency_key, resultado
  ) values (
    p_contrato_id, v_linea.id, v_accion, v_antes, to_jsonb(v_linea),
    btrim(p_motivo), v_uid, p_idempotency_key, v_resultado
  );
  return v_resultado;
end;
$fn$;

create or replace function public.anular_costo_contrato_v101(
  p_linea_id uuid, p_motivo text, p_idempotency_key uuid
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid(); v_linea public.contrato_costos_lineas_v101%rowtype;
  v_antes jsonb; v_resultado jsonb;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('produccion.costos.editar') then raise exception 'No tienes permiso para gestionar costos'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo,''))) < 10 then raise exception 'El motivo debe tener al menos 10 caracteres'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 101));
  select resultado into v_resultado from public.contrato_costos_eventos_v101 where idempotency_key=p_idempotency_key;
  if found then return v_resultado; end if;
  select l.* into v_linea from public.contrato_costos_lineas_v101 l
  where l.id=p_linea_id and l.activo for update;
  if not found then raise exception 'La linea no existe o ya fue anulada'; end if;
  v_antes := to_jsonb(v_linea);
  update public.contrato_costos_lineas_v101 set activo=false, actualizado_por=v_uid, updated_at=now() where id=p_linea_id;
  v_resultado:=jsonb_build_object('linea_id',p_linea_id,'contrato_id',v_linea.contrato_id,'accion','anular_linea');
  insert into public.contrato_costos_eventos_v101(contrato_id,linea_id,accion,datos_anteriores,datos_nuevos,motivo,usuario_id,idempotency_key,resultado)
  values(v_linea.contrato_id,p_linea_id,'anular_linea',v_antes,jsonb_build_object('activo',false),btrim(p_motivo),v_uid,p_idempotency_key,v_resultado);
  return v_resultado;
end;
$fn$;

create or replace function public.vincular_orden_costo_v101(
  p_contrato_id uuid, p_orden_id uuid, p_vincular boolean,
  p_motivo text, p_idempotency_key uuid
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $fn$
declare
  v_uid uuid:=auth.uid(); v_resultado jsonb; v_accion text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('produccion.costos.editar') then raise exception 'No tienes permiso para gestionar costos'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'El motivo debe tener al menos 10 caracteres'; end if;
  if not exists(select 1 from public.contratos where id=p_contrato_id) then raise exception 'El contrato no existe'; end if;
  if not exists(select 1 from public.ordenes_produccion where id=p_orden_id) then raise exception 'La orden no existe'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,101));
  select resultado into v_resultado from public.contrato_costos_eventos_v101 where idempotency_key=p_idempotency_key;
  if found then return v_resultado; end if;
  if p_vincular then
    insert into public.contrato_ordenes_produccion_v101(contrato_id,orden_id,vinculada_por)
    values(p_contrato_id,p_orden_id,v_uid);
    v_accion:='vincular_orden';
  else
    delete from public.contrato_ordenes_produccion_v101 where contrato_id=p_contrato_id and orden_id=p_orden_id;
    if not found then raise exception 'La orden no esta vinculada a este contrato'; end if;
    v_accion:='desvincular_orden';
  end if;
  v_resultado:=jsonb_build_object('contrato_id',p_contrato_id,'orden_id',p_orden_id,'accion',v_accion);
  insert into public.contrato_costos_eventos_v101(contrato_id,orden_id,accion,datos_nuevos,motivo,usuario_id,idempotency_key,resultado)
  values(p_contrato_id,p_orden_id,v_accion,jsonb_build_object('vinculada',p_vincular),btrim(p_motivo),v_uid,p_idempotency_key,v_resultado);
  return v_resultado;
exception when unique_violation then
  raise exception 'La orden ya esta vinculada a un contrato';
end;
$fn$;

create or replace function public.obtener_hoja_costo_v101(p_contrato_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $fn$
declare v_resultado jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.costos.ver') then
    raise exception 'No tienes permiso para consultar costos';
  end if;
  if not exists(select 1 from public.contratos where id=p_contrato_id) then raise exception 'El contrato no existe'; end if;
  with manual as (
    select coalesce(sum(total) filter(where naturaleza='estimado'),0)::numeric(18,2) estimado,
           coalesce(sum(total) filter(where naturaleza='real'),0)::numeric(18,2) real
    from public.contrato_costos_lineas_v101 where contrato_id=p_contrato_id and activo
  ), ordenes as (
    select coalesce(sum(o.costo_total_estimado),0)::numeric(18,2) estimado,
           coalesce(sum(o.costo_total_real),0)::numeric(18,2) real,
           count(*) filter(where o.costo_total_real is null)::integer pendientes
    from public.contrato_ordenes_produccion_v101 co
    join public.ordenes_produccion o on o.id=co.orden_id where co.contrato_id=p_contrato_id
  )
  select jsonb_build_object(
    'contrato',jsonb_build_object('id',c.id,'numero',c.numero,'cliente',c.cliente,'estado',c.estado,'fecha_entrega',c.fecha_entrega,'presupuesto',c.presupuesto,'total_prendas',c.total_prendas),
    'resumen',jsonb_build_object(
      'manual_estimado',m.estimado,'ordenes_estimado',o.estimado,'costo_estimado',m.estimado+o.estimado,
      'manual_real',m.real,'ordenes_real',o.real,'costo_real',m.real+o.real,
      'margen_estimado',c.presupuesto-m.estimado-o.estimado,'margen_real',c.presupuesto-m.real-o.real,
      'margen_estimado_pct',case when c.presupuesto>0 then round((c.presupuesto-m.estimado-o.estimado)*100/c.presupuesto,2) end,
      'margen_real_pct',case when c.presupuesto>0 then round((c.presupuesto-m.real-o.real)*100/c.presupuesto,2) end,
      'ordenes_sin_costo_real',o.pendientes
    ),
    'lineas',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'naturaleza',l.naturaleza,'categoria',l.categoria,'concepto',l.concepto,'cantidad',l.cantidad,'costo_unitario',l.costo_unitario,'total',l.total,'updated_at',l.updated_at,'usuario',p.nombre_completo) order by l.naturaleza,l.categoria,l.created_at) from public.contrato_costos_lineas_v101 l left join public.perfiles p on p.id=l.actualizado_por where l.contrato_id=c.id and l.activo),'[]'::jsonb),
    'ordenes',coalesce((select jsonb_agg(jsonb_build_object('id',op.id,'numero',op.numero,'estado',op.estado,'resultado',pr.sku||' - '||pr.nombre,'cantidad',op.cantidad_planificada,'estimado',op.costo_total_estimado,'real',op.costo_total_real) order by op.created_at) from public.contrato_ordenes_produccion_v101 co join public.ordenes_produccion op on op.id=co.orden_id join public.productos pr on pr.id=op.producto_resultado_id where co.contrato_id=c.id),'[]'::jsonb),
    'ordenes_disponibles',coalesce((select jsonb_agg(x order by x.created_at desc) from (select op.id,op.numero,op.estado,op.cantidad_planificada,op.costo_total_estimado,op.created_at,pr.sku,pr.nombre producto from public.ordenes_produccion op join public.productos pr on pr.id=op.producto_resultado_id left join public.contrato_ordenes_produccion_v101 co on co.orden_id=op.id where co.id is null and op.estado not in ('rechazada','cancelada') order by op.created_at desc limit 150)x),'[]'::jsonb)
  ) into v_resultado
  from public.contratos c cross join manual m cross join ordenes o where c.id=p_contrato_id;
  return v_resultado;
end;
$fn$;

create or replace function public.dashboard_rentabilidad_v101(
  p_desde date, p_hasta date, p_estado text default null,
  p_busqueda text default null, p_pagina integer default 1,
  p_por_pagina integer default 40
) returns jsonb language plpgsql stable security definer set search_path = ''
as $fn$
declare v_resultado jsonb; v_pagina integer:=greatest(coalesce(p_pagina,1),1); v_limite integer:=least(greatest(coalesce(p_por_pagina,40),1),100);
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.costos.ver') then raise exception 'No tienes permiso para consultar rentabilidad'; end if;
  if p_desde is null or p_hasta is null or p_hasta<p_desde or p_hasta-p_desde>366 then raise exception 'El rango debe tener entre 1 y 367 dias'; end if;
  with costos_manual as (
    select contrato_id,coalesce(sum(total) filter(where naturaleza='estimado' and activo),0) estimado,coalesce(sum(total) filter(where naturaleza='real' and activo),0) real
    from public.contrato_costos_lineas_v101 group by contrato_id
  ), costos_orden as (
    select co.contrato_id,coalesce(sum(o.costo_total_estimado),0) estimado,coalesce(sum(o.costo_total_real),0) real,count(*) filter(where o.costo_total_real is null) pendientes
    from public.contrato_ordenes_produccion_v101 co join public.ordenes_produccion o on o.id=co.orden_id group by co.contrato_id
  ), base as materialized (
    select c.id,c.numero,c.cliente,c.vendedor,c.estado,c.fecha_entrega,c.total_prendas,c.presupuesto,
      round(coalesce(cm.estimado,0)+coalesce(cop.estimado,0),2) costo_estimado,
      round(coalesce(cm.real,0)+coalesce(cop.real,0),2) costo_real,
      coalesce(cop.pendientes,0)::integer ordenes_pendientes
    from public.contratos c left join costos_manual cm on cm.contrato_id=c.id left join costos_orden cop on cop.contrato_id=c.id
    where coalesce(c.fecha_entrega,c.fecha_ingreso::date) between p_desde and p_hasta
      and (nullif(btrim(p_estado),'') is null or lower(c.estado)=lower(btrim(p_estado)))
      and (nullif(btrim(p_busqueda),'') is null or c.numero ilike '%'||btrim(p_busqueda)||'%' or c.cliente ilike '%'||btrim(p_busqueda)||'%')
  ), paginada as (
    select *,presupuesto-costo_estimado margen_estimado,presupuesto-costo_real margen_real,
      case when presupuesto>0 then round((presupuesto-costo_real)*100/presupuesto,2) end margen_real_pct
    from base order by fecha_entrega desc nulls last,numero offset (v_pagina-1)*v_limite limit v_limite
  )
  select jsonb_build_object(
    'total',(select count(*) from base),'pagina',v_pagina,'por_pagina',v_limite,
    'kpis',jsonb_build_object('ingresos',coalesce((select sum(presupuesto) from base),0),'costo_estimado',coalesce((select sum(costo_estimado) from base),0),'costo_real',coalesce((select sum(costo_real) from base),0),'margen_estimado',coalesce((select sum(presupuesto-costo_estimado) from base),0),'margen_real',coalesce((select sum(presupuesto-costo_real) from base),0),'contratos_sin_costos',(select count(*) from base where costo_estimado=0 and costo_real=0),'ordenes_sin_costo_real',coalesce((select sum(ordenes_pendientes) from base),0)),
    'filas',coalesce((select jsonb_agg(to_jsonb(paginada) order by fecha_entrega desc nulls last,numero) from paginada),'[]'::jsonb),
    'estados',coalesce((select jsonb_agg(e order by e) from(select distinct estado e from public.contratos where btrim(estado)<>'')s),'[]'::jsonb)
  ) into v_resultado;
  return v_resultado;
end;
$fn$;

alter table public.contrato_costos_lineas_v101 owner to postgres;
alter table public.contrato_ordenes_produccion_v101 owner to postgres;
alter table public.contrato_costos_eventos_v101 owner to postgres;
alter function public.guardar_costo_contrato_v101(uuid,uuid,text,text,text,numeric,numeric,text,uuid) owner to postgres;
alter function public.anular_costo_contrato_v101(uuid,text,uuid) owner to postgres;
alter function public.vincular_orden_costo_v101(uuid,uuid,boolean,text,uuid) owner to postgres;
alter function public.obtener_hoja_costo_v101(uuid) owner to postgres;
alter function public.dashboard_rentabilidad_v101(date,date,text,text,integer,integer) owner to postgres;

revoke all on function public.guardar_costo_contrato_v101(uuid,uuid,text,text,text,numeric,numeric,text,uuid) from public,anon;
revoke all on function public.anular_costo_contrato_v101(uuid,text,uuid) from public,anon;
revoke all on function public.vincular_orden_costo_v101(uuid,uuid,boolean,text,uuid) from public,anon;
revoke all on function public.obtener_hoja_costo_v101(uuid) from public,anon;
revoke all on function public.dashboard_rentabilidad_v101(date,date,text,text,integer,integer) from public,anon;
grant execute on function public.guardar_costo_contrato_v101(uuid,uuid,text,text,text,numeric,numeric,text,uuid) to authenticated;
grant execute on function public.anular_costo_contrato_v101(uuid,text,uuid) to authenticated;
grant execute on function public.vincular_orden_costo_v101(uuid,uuid,boolean,text,uuid) to authenticated;
grant execute on function public.obtener_hoja_costo_v101(uuid) to authenticated;
grant execute on function public.dashboard_rentabilidad_v101(date,date,text,text,integer,integer) to authenticated;

commit;
notify pgrst, 'reload schema';
