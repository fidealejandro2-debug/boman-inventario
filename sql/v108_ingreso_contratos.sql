-- ============================================================
-- BOMAN INVENTARIO - v108: ingreso nativo de contratos
-- Ejecutar despues de v107.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.contrato_prendas') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta instalar el esquema de contratos (v79+) antes de v108';
  end if;
end;
$requisitos$;

alter table public.contratos
  add column if not exists contrato_origen_reposicion_id uuid
    references public.contratos(id) on delete set null;

create table if not exists public.contrato_ingresos_v108 (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid references public.contratos(id) on delete restrict,
  datos jsonb not null check (jsonb_typeof(datos) = 'object'),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  resultado jsonb,
  respaldo_sheets_estado text not null default 'pendiente'
    check (respaldo_sheets_estado in ('pendiente','sincronizado','error')),
  respaldo_sheets_intentos integer not null default 0,
  respaldo_sheets_error text,
  respaldado_sheets_at timestamptz,
  created_at timestamptz not null default now()
);

-- Conserva la migracion reejecutable si una primera corrida fue interrumpida.
alter table public.contrato_ingresos_v108
  add column if not exists respaldo_sheets_estado text not null default 'pendiente',
  add column if not exists respaldo_sheets_intentos integer not null default 0,
  add column if not exists respaldo_sheets_error text,
  add column if not exists respaldado_sheets_at timestamptz;

create table if not exists public.contrato_archivos_pendientes_v108 (
  id uuid primary key default gen_random_uuid(),
  creado_por uuid not null references public.perfiles(id) on delete cascade,
  storage_path text not null unique,
  nombre_archivo text not null,
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  tamano_bytes bigint not null check (tamano_bytes between 1 and 12582912),
  usado_en uuid references public.contratos(id) on delete set null,
  vence_en timestamptz not null default (now() + interval '24 hours'),
  created_at timestamptz not null default now()
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'contratos-archivos', 'contratos-archivos', true, 12582912,
  array['image/jpeg','image/png','image/webp','application/pdf']::text[]
)
on conflict (id) do update set public = true,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.preparar_archivo_contrato_v108(
  p_nombre_archivo text,
  p_mime_type text,
  p_tamano_bytes bigint,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_ext text;
  v_path text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar') then
    raise exception 'No tienes permiso para ingresar contratos';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if lower(coalesce(p_mime_type,'')) not in ('image/jpeg','image/png','image/webp','application/pdf') then
    raise exception 'Archivo no permitido. Usa JPG, PNG, WebP o PDF';
  end if;
  if p_tamano_bytes is null or p_tamano_bytes not between 1 and 12582912 then
    raise exception 'Cada archivo debe pesar como maximo 12 MB';
  end if;

  select id, storage_path into v_id, v_path
  from public.contrato_archivos_pendientes_v108
  where id = p_idempotency_key and creado_por = v_uid;
  if found then return jsonb_build_object('id',v_id,'path',v_path); end if;

  v_id := p_idempotency_key;
  v_ext := case lower(p_mime_type) when 'image/png' then 'png'
    when 'image/webp' then 'webp' when 'application/pdf' then 'pdf' else 'jpg' end;
  v_path := v_uid::text || '/' || v_id::text || '.' || v_ext;
  insert into public.contrato_archivos_pendientes_v108(
    id, creado_por, storage_path, nombre_archivo, mime_type, tamano_bytes
  ) values (
    v_id, v_uid, v_path, left(btrim(coalesce(p_nombre_archivo,'archivo')),255),
    lower(p_mime_type), p_tamano_bytes
  );
  return jsonb_build_object('id',v_id,'path',v_path);
end;
$fn$;

create or replace function public.puede_subir_archivo_contrato_v108(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.contrato_archivos_pendientes_v108 a
    where a.storage_path = p_path and a.creado_por = auth.uid()
      and a.usado_en is null and a.vence_en > now()
  );
$$;

drop policy if exists "subir_archivo_contrato_v108" on storage.objects;
create policy "subir_archivo_contrato_v108" on storage.objects
for insert to authenticated with check (
  bucket_id = 'contratos-archivos'
  and public.puede_subir_archivo_contrato_v108(name)
);

create or replace function public.buscar_contratos_reposicion_v108(p_busqueda text)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_r jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('contratos.editar') then
    raise exception 'No tienes permiso para consultar contratos';
  end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.fecha_ingreso desc),'[]'::jsonb)
  into v_r from (
    select c.id,c.numero,c.cliente,c.vendedor,c.fecha_ingreso,c.fecha_entrega,c.total_prendas
    from public.contratos c
    where length(btrim(coalesce(p_busqueda,''))) >= 2
      and (c.numero ilike '%'||btrim(p_busqueda)||'%'
        or c.cliente ilike '%'||btrim(p_busqueda)||'%')
    order by c.fecha_ingreso desc limit 12
  ) q;
  return v_r;
end;
$fn$;

-- Listado compatible con archivos de Drive y con los cargados en Vercel.
create or replace function public.listar_contratos_v108(
  p_busqueda text default null, p_estado text default null,
  p_pagina integer default 1, p_por_pagina integer default 40
) returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_pag integer:=greatest(coalesce(p_pagina,1),1);v_lim integer:=least(greatest(coalesce(p_por_pagina,40),1),100);v_r jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('contratos.acceder') then raise exception 'No tienes permiso para consultar contratos';end if;
  with f as materialized(
    select c.* from public.contratos c where
      (nullif(btrim(p_busqueda),'') is null or c.numero ilike '%'||btrim(p_busqueda)||'%' or c.cliente ilike '%'||btrim(p_busqueda)||'%' or c.vendedor ilike '%'||btrim(p_busqueda)||'%' or coalesce(c.disenador,'') ilike '%'||btrim(p_busqueda)||'%')
      and(nullif(btrim(p_estado),'') is null or lower(c.estado)=lower(btrim(p_estado)))
  ),p as(
    select f.*,(select ca.drive_id from public.contrato_archivos ca where ca.contrato_id=f.id and ca.tipo='mockup' order by ca.orden,ca.id limit 1) mockup_drive_id,
      (select ca.url from public.contrato_archivos ca where ca.contrato_id=f.id and ca.tipo='mockup' order by ca.orden,ca.id limit 1) mockup_url
    from f order by f.fecha_entrega desc nulls last,f.numero desc limit v_lim offset(v_pag-1)*v_lim
  ) select jsonb_build_object('total',(select count(*)from f),'pagina',v_pag,'por_pagina',v_lim,
    'estados',coalesce((select jsonb_agg(e order by e)from(select distinct estado e from public.contratos where btrim(estado)<>'')q),'[]'::jsonb),
    'filas',coalesce((select jsonb_agg(jsonb_build_object('id',id,'numero',numero,'cliente',cliente,'vendedor',vendedor,'disenador',disenador,'estado',estado,'prioridad',prioridad,'fecha_ingreso',fecha_ingreso,'fecha_inicio',fecha_inicio_produccion,'fecha_entrega',fecha_entrega,'total_prendas',total_prendas,'presupuesto',presupuesto,'abono',abono,'saldo',greatest(presupuesto-abono,0),'mockup_drive_id',mockup_drive_id,'mockup_url',mockup_url,'updated_at',updated_at)order by fecha_entrega desc nulls last,numero desc)from p),'[]'::jsonb)
  into v_r;return v_r;
end;$fn$;

create or replace function public.obtener_plantilla_contrato_v108(p_contrato_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_r jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('contratos.editar') then
    raise exception 'No tienes permiso para consultar contratos';
  end if;
  select jsonb_build_object(
    'contrato',to_jsonb(c),
    'prendas',coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id') from public.contrato_prendas x where x.contrato_id=c.id),'[]'::jsonb),
    'jugadores',coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id' order by x.orden) from public.contrato_jugadores x where x.contrato_id=c.id),'[]'::jsonb),
    'archivos',coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id' order by x.tipo,x.orden) from public.contrato_archivos x where x.contrato_id=c.id),'[]'::jsonb),
    'especificaciones',coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id' order by x.orden) from public.contrato_specs x where x.contrato_id=c.id),'[]'::jsonb),
    'facturacion',coalesce((select jsonb_agg(to_jsonb(x) - 'id' - 'contrato_id' order by x.orden) from public.contrato_facturacion x where x.contrato_id=c.id),'[]'::jsonb)
  ) into v_r from public.contratos c where c.id=p_contrato_id;
  if v_r is null then raise exception 'No se encontro el contrato'; end if;
  return v_r;
end;
$fn$;

create or replace function public.crear_contrato_v108(
  p_datos jsonb,
  p_idempotency_key uuid
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_c jsonb := coalesce(p_datos->'contrato','{}'::jsonb);
  v_id uuid;
  v_numero text;
  v_anio integer;
  v_sig integer;
  v_item jsonb;
  v_total integer := 0;
  v_archivo public.contrato_archivos_pendientes_v108%rowtype;
  v_url text;
  v_resultado jsonb;
  v_quien text;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion para ingresar contratos'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar') then
    raise exception 'No tienes permiso para ingresar contratos';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if jsonb_typeof(coalesce(p_datos,'null'::jsonb)) <> 'object'
     or jsonb_typeof(v_c) <> 'object' then raise exception 'Los datos del contrato no son validos'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,108));
  select resultado into v_resultado from public.contrato_ingresos_v108
  where idempotency_key=p_idempotency_key;
  if found and v_resultado is not null then return v_resultado || jsonb_build_object('duplicado',true); end if;

  if length(btrim(coalesce(v_c->>'cliente',''))) < 2 then raise exception 'Escribe el cliente o equipo'; end if;
  if length(btrim(coalesce(v_c->>'vendedor',''))) < 2 then raise exception 'Escribe el vendedor'; end if;
  if length(btrim(coalesce(v_c->>'vendedor_responsable',''))) < 2 then raise exception 'Confirma el vendedor responsable'; end if;
  if coalesce(v_c->>'tipo_contrato','') not in ('Normal','Equipo Profesional',U&'Mercader\00EDa','Emergente') then raise exception 'Selecciona un tipo de contrato valido'; end if;
  if coalesce(v_c->>'prioridad','') not in ('Normal','Urgente') then raise exception 'Selecciona la prioridad'; end if;
  if nullif(v_c->>'fecha_entrega','') is null then raise exception 'Selecciona la fecha deseada de entrega'; end if;
  if coalesce((v_c->>'presupuesto')::numeric,0) < 0 or coalesce((v_c->>'abono')::numeric,0) < 0
     or coalesce((v_c->>'abono')::numeric,0) > coalesce((v_c->>'presupuesto')::numeric,0) then
    raise exception 'El abono no puede superar el presupuesto';
  end if;
  if coalesce((v_c->>'autorizado')::boolean,false) is not true then
    raise exception 'Confirma que revisaste los datos y autorizas el envio a produccion';
  end if;
  if jsonb_typeof(coalesce(p_datos->'prendas','null'::jsonb)) <> 'array'
     or jsonb_array_length(p_datos->'prendas') = 0 then raise exception 'Agrega al menos una prenda con talla y cantidad'; end if;

  for v_item in select value from jsonb_array_elements(p_datos->'prendas') loop
    if length(btrim(coalesce(v_item->>'prenda',''))) = 0
       or coalesce(v_item->>'genero','') not in ('H','M','N')
       or length(btrim(coalesce(v_item->>'talla',''))) = 0
       or coalesce((v_item->>'cantidad')::integer,0) <= 0 then
      raise exception 'Hay una linea de prenda incompleta';
    end if;
    v_total := v_total + (v_item->>'cantidad')::integer;
  end loop;

  v_anio := extract(year from current_date)::integer;
  perform pg_advisory_xact_lock(108000000 + v_anio);
  select coalesce(max(substring(numero from '^BOM-[0-9]{4}-([0-9]+)$')::integer),0)+1
  into v_sig from public.contratos where numero like 'BOM-'||v_anio::text||'-%';
  v_numero := 'BOM-'||v_anio::text||'-'||lpad(v_sig::text,4,'0');

  insert into public.contratos(
    numero,fecha_inicio_produccion,fecha_entrega,vendedor,vendedor_responsable,canal,
    cliente,telefono,whatsapp,email,prioridad,tipo_contrato,reposicion,
    contrato_origen_reposicion_id,prendas_txt,total_prendas,arqueros,estado,
    estado_mockup,aprobo_mockup,presupuesto,abono,forma_entrega,direccion,instrucciones,
    nombre_tecnica,numero_tecnica,sellos_tpu,ubicacion_tpu,bordado,colores_generales,
    adicionales,email_ingresante,creado_por,actualizado_por
  ) values (
    v_numero,nullif(v_c->>'fecha_inicio_produccion','')::date,(v_c->>'fecha_entrega')::date,
    btrim(v_c->>'vendedor'),btrim(v_c->>'vendedor_responsable'),nullif(btrim(v_c->>'canal'),''),
    btrim(v_c->>'cliente'),nullif(btrim(v_c->>'telefono'),''),nullif(btrim(v_c->>'whatsapp'),''),nullif(btrim(v_c->>'email'),''),
    v_c->>'prioridad',v_c->>'tipo_contrato',coalesce((v_c->>'reposicion')::boolean,false),
    nullif(v_c->>'contrato_origen_reposicion_id','')::uuid,nullif(btrim(v_c->>'prendas_txt'),''),v_total,
    coalesce((v_c->>'arqueros')::integer,0),'Ingresado','Mockup aprobado por cliente',true,
    coalesce((v_c->>'presupuesto')::numeric,0),coalesce((v_c->>'abono')::numeric,0),
    nullif(btrim(v_c->>'forma_entrega'),''),nullif(btrim(v_c->>'direccion'),''),nullif(btrim(v_c->>'instrucciones'),''),
    nullif(btrim(v_c->>'nombre_tecnica'),''),nullif(btrim(v_c->>'numero_tecnica'),''),nullif(btrim(v_c->>'sellos_tpu'),''),
    nullif(btrim(v_c->>'ubicacion_tpu'),''),nullif(btrim(v_c->>'bordado'),''),coalesce(v_c->'colores_generales','[]'::jsonb),
    coalesce(v_c->'adicionales','{}'::jsonb),nullif(btrim(v_c->>'email_ingresante'),''),v_uid,v_uid
  ) returning id into v_id;

  insert into public.contrato_prendas(contrato_id,prenda,calidad,detalle,genero,talla,cantidad)
  select v_id,btrim(x.prenda),btrim(coalesce(x.calidad,'')),btrim(coalesce(x.detalle,'')),x.genero,btrim(x.talla),x.cantidad
  from jsonb_to_recordset(p_datos->'prendas') as x(prenda text,calidad text,detalle text,genero text,talla text,cantidad integer);

  insert into public.contrato_jugadores(contrato_id,orden,nombre,numero,categoria,talla_superior,talla_inferior,manga,calidad,modelo_arquero,tipo_uniforme,detalle,mockup)
  select v_id,coalesce(x.orden,0),coalesce(x.nombre,''),x.numero,coalesce(x.categoria,'Hombre'),x.talla_superior,x.talla_inferior,
    nullif(x.manga,''),x.calidad,x.modelo_arquero,x.tipo_uniforme,x.detalle,x.mockup
  from jsonb_to_recordset(coalesce(p_datos->'jugadores','[]'::jsonb)) as x(orden integer,nombre text,numero text,categoria text,talla_superior text,talla_inferior text,manga text,calidad text,modelo_arquero text,tipo_uniforme text,detalle text,mockup text);

  insert into public.contrato_specs(contrato_id,prenda_clave,orden,variante_mockup,variante_calidad,variante_otro,spec)
  select v_id,btrim(x.prenda_clave),coalesce(x.orden,0),x.variante_mockup,x.variante_calidad,x.variante_otro,coalesce(x.spec,'{}'::jsonb)
  from jsonb_to_recordset(coalesce(p_datos->'especificaciones','[]'::jsonb)) as x(prenda_clave text,orden integer,variante_mockup text,variante_calidad text,variante_otro text,spec jsonb)
  where btrim(coalesce(x.prenda_clave,''))<>'';

  insert into public.contrato_facturacion(contrato_id,orden,concepto,calidad,cantidad,obsequio)
  select v_id,coalesce(x.orden,0),btrim(x.concepto),x.calidad,x.cantidad,coalesce(x.obsequio,false)
  from jsonb_to_recordset(coalesce(p_datos->'facturacion','[]'::jsonb)) as x(orden integer,concepto text,calidad text,cantidad integer,obsequio boolean)
  where btrim(coalesce(x.concepto,''))<>'' and x.cantidad>0;

  for v_item in select value from jsonb_array_elements(coalesce(p_datos->'archivos','[]'::jsonb)) loop
    if nullif(v_item->>'pendiente_id','') is not null then
      select * into v_archivo from public.contrato_archivos_pendientes_v108
      where id=(v_item->>'pendiente_id')::uuid and creado_por=v_uid and usado_en is null for update;
      if not found then raise exception 'Uno de los archivos no fue preparado o ya fue utilizado'; end if;
      if not exists(select 1 from storage.objects o where o.bucket_id='contratos-archivos' and o.name=v_archivo.storage_path) then
        raise exception 'Uno de los archivos no termino de subir';
      end if;
      v_url := coalesce(nullif(v_item->>'url',''),'/storage/v1/object/public/contratos-archivos/'||v_archivo.storage_path);
      update public.contrato_archivos_pendientes_v108 set usado_en=v_id where id=v_archivo.id;
    else
      v_url := coalesce(v_item->>'url','');
    end if;
    insert into public.contrato_archivos(contrato_id,tipo,orden,descripcion,url,drive_id,color,prenda,posicion,tecnica,calidad_aplicable,observacion)
    values(v_id,v_item->>'tipo',coalesce((v_item->>'orden')::integer,0),coalesce(v_item->>'descripcion',''),v_url,
      nullif(v_item->>'drive_id',''),nullif(v_item->>'color',''),nullif(v_item->>'prenda',''),nullif(v_item->>'posicion',''),
      nullif(v_item->>'tecnica',''),nullif(v_item->>'calidad_aplicable',''),nullif(v_item->>'observacion',''));
  end loop;

  select coalesce(nombre_completo,v_uid::text) into v_quien from public.perfiles where id=v_uid;
  insert into public.contrato_eventos(contrato_id,campo,valor_nuevo,quien,perfil_id)
  values(v_id,'alta',v_numero,v_quien,v_uid);
  v_resultado:=jsonb_build_object('duplicado',false,'contrato_id',v_id,'numero',v_numero,'total_prendas',v_total);
  insert into public.contrato_ingresos_v108(contrato_id,datos,usuario_id,idempotency_key,resultado)
  values(v_id,p_datos,v_uid,p_idempotency_key,v_resultado);
  return v_resultado;
end;
$fn$;

alter table public.contrato_ingresos_v108 enable row level security;
alter table public.contrato_archivos_pendientes_v108 enable row level security;
revoke all on public.contrato_ingresos_v108, public.contrato_archivos_pendientes_v108 from public,anon,authenticated;

revoke all on function public.preparar_archivo_contrato_v108(text,text,bigint,uuid) from public,anon;
revoke all on function public.puede_subir_archivo_contrato_v108(text) from public,anon;
revoke all on function public.buscar_contratos_reposicion_v108(text) from public,anon;
revoke all on function public.listar_contratos_v108(text,text,integer,integer) from public,anon;
revoke all on function public.obtener_plantilla_contrato_v108(uuid) from public,anon;
revoke all on function public.crear_contrato_v108(jsonb,uuid) from public,anon;
grant execute on function public.preparar_archivo_contrato_v108(text,text,bigint,uuid) to authenticated;
grant execute on function public.puede_subir_archivo_contrato_v108(text) to authenticated;
grant execute on function public.buscar_contratos_reposicion_v108(text) to authenticated;
grant execute on function public.listar_contratos_v108(text,text,integer,integer) to authenticated;
grant execute on function public.obtener_plantilla_contrato_v108(uuid) to authenticated;
grant execute on function public.crear_contrato_v108(jsonb,uuid) to authenticated;

commit;
notify pgrst,'reload schema';
