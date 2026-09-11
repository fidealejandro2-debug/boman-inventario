-- ============================================================
-- BOMAN INVENTARIO - v120: reeditar el contenido de un contrato
--
-- v118 dejo corregir la cabecera (nombre, cliente, vendedor, canal). Lo que
-- seguia sin poder tocarse es el CUERPO: prendas y tallas, jugadores,
-- especificaciones, facturacion y mockups. Un error ahi obligaba a ingresar el
-- contrato otra vez.
--
-- Dos decisiones que conviene entender antes de tocar este archivo:
--
-- 1. Los hijos se REEMPLAZAN, no se parchean fila por fila. El asistente de
--    ingreso maneja la lista completa (agregar, quitar, reordenar) y no tiene
--    identidad estable por linea: mandar solo "lo que cambio" exigiria inventar
--    esa identidad en el cliente, que es justo donde se rompen estas cosas.
--    Borrar e insertar dentro de la misma transaccion da el mismo resultado y
--    no puede quedar a medias.
--
-- 2. NO se tocan numero, estado, presupuesto ni abono. Cada uno tiene su
--    dueno: el numero es la identidad, el estado lo mueve el taller
--    (marcar_etapa_contrato_v116) y las cifras viven en v100 con su libro de
--    abonos. Reeditar el contenido no puede ser una puerta trasera para eso.
--
-- El permiso nuevo se siembra en false para TODOS los roles: eso lo deja en
-- manos del administrador (que pasa por el bypass de v35) sin inventar un rol,
-- y permite concederlo a una persona puntual desde Permisos por persona.
--
-- Ejecutar despues de v108.
-- ============================================================
begin;
select pg_advisory_xact_lock(1201142026);

do $$begin
  if to_regprocedure('public.crear_contrato_v108(jsonb,uuid)') is null then
    raise exception 'Falta v108_ingreso_contratos.sql antes de v120';
  end if;
end$$;

insert into public.permisos_sistema as p (codigo, modulo, nombre, descripcion, orden)
values ('contratos.editar_contenido', 'Produccion', 'Reeditar contenido del contrato',
        'Cambiar prendas, tallas, jugadores, especificaciones y mockups de un contrato ya guardado.', 207)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden,
  activo = true, updated_at = now();

update public.permisos_sistema set es_boman_especifico = true
 where codigo = 'contratos.editar_contenido';

-- En false para todos: solo el administrador lo tiene (por el bypass de rol de
-- v35), y se puede conceder a alguien puntual desde Permisos por persona.
insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.codigo = 'contratos.editar_contenido'
on conflict (rol, permiso_codigo) do nothing;

-- Bitacora propia. No se reusa contrato_ingresos_v108: ahi vive el alta, y
-- mezclar altas con ediciones haria que "cuantos contratos se ingresaron"
-- deje de ser respondible con un count.
create table if not exists public.contrato_actualizaciones_v120 (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  datos jsonb not null,
  motivo text not null check (length(btrim(motivo)) >= 10),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  resultado jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_contrato_actualizaciones_v120
  on public.contrato_actualizaciones_v120(contrato_id, created_at desc);
alter table public.contrato_actualizaciones_v120 enable row level security;
revoke all on public.contrato_actualizaciones_v120 from public, anon, authenticated;

create or replace function public.actualizar_contrato_v120(
  p_contrato_id uuid, p_datos jsonb, p_motivo text, p_idempotency_key uuid
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $v120$
declare
  v_uid uuid := auth.uid();
  v_c jsonb := coalesce(p_datos->'contrato','{}'::jsonb);
  v_antes public.contratos%rowtype;
  v_item jsonb;
  v_total integer := 0;
  v_archivo public.contrato_archivos_pendientes_v108%rowtype;
  v_url text;
  v_resultado jsonb;
  v_quien text;
  v_n_jug integer; v_n_arch integer; v_n_spec integer;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar_contenido') then
    raise exception 'No tienes permiso para reeditar el contenido de un contrato';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo,''))) < 10 then
    raise exception 'El motivo debe tener al menos 10 caracteres';
  end if;
  if jsonb_typeof(coalesce(p_datos,'null'::jsonb)) <> 'object'
     or jsonb_typeof(v_c) <> 'object' then raise exception 'Los datos del contrato no son validos'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,120));
  select resultado into v_resultado from public.contrato_actualizaciones_v120
  where idempotency_key = p_idempotency_key;
  if found and v_resultado is not null then return v_resultado || jsonb_build_object('duplicado',true); end if;

  select * into v_antes from public.contratos where id = p_contrato_id for update;
  if not found then raise exception 'El contrato no existe'; end if;

  -- Mismas reglas que el alta: un contrato sin prendas no es un contrato.
  if jsonb_typeof(coalesce(p_datos->'prendas','null'::jsonb)) <> 'array'
     or jsonb_array_length(p_datos->'prendas') = 0 then
    raise exception 'Agrega al menos una prenda con talla y cantidad';
  end if;
  for v_item in select value from jsonb_array_elements(p_datos->'prendas') loop
    if length(btrim(coalesce(v_item->>'prenda',''))) = 0
       or coalesce(v_item->>'genero','') not in ('H','M','N')
       or length(btrim(coalesce(v_item->>'talla',''))) = 0
       or coalesce((v_item->>'cantidad')::integer,0) <= 0 then
      raise exception 'Hay una linea de prenda incompleta';
    end if;
    v_total := v_total + (v_item->>'cantidad')::integer;
  end loop;
  if length(btrim(coalesce(v_c->>'cliente',''))) < 2 then raise exception 'Escribe el cliente o equipo'; end if;
  if length(btrim(coalesce(v_c->>'vendedor',''))) < 2 then raise exception 'Escribe el vendedor'; end if;
  if nullif(v_c->>'fecha_entrega','') is null then raise exception 'Selecciona la fecha de entrega'; end if;

  -- Cabecera: todo lo que el asistente maneja MENOS numero, estado,
  -- presupuesto y abono (ver la nota de arriba).
  update public.contratos set
    fecha_entrega = (v_c->>'fecha_entrega')::date,
    fecha_inicio_produccion = nullif(v_c->>'fecha_inicio_produccion','')::date,
    vendedor = btrim(v_c->>'vendedor'),
    vendedor_responsable = coalesce(nullif(btrim(v_c->>'vendedor_responsable'),''), vendedor_responsable),
    canal = nullif(btrim(v_c->>'canal'),''),
    cliente = btrim(v_c->>'cliente'),
    telefono = nullif(btrim(v_c->>'telefono'),''),
    whatsapp = nullif(btrim(v_c->>'whatsapp'),''),
    email = nullif(btrim(v_c->>'email'),''),
    prioridad = coalesce(nullif(v_c->>'prioridad',''), prioridad),
    tipo_contrato = coalesce(nullif(v_c->>'tipo_contrato',''), tipo_contrato),
    prendas_txt = nullif(btrim(v_c->>'prendas_txt'),''),
    total_prendas = v_total,
    arqueros = coalesce((v_c->>'arqueros')::integer, 0),
    forma_entrega = nullif(btrim(v_c->>'forma_entrega'),''),
    direccion = nullif(btrim(v_c->>'direccion'),''),
    instrucciones = nullif(btrim(v_c->>'instrucciones'),''),
    nombre_tecnica = nullif(btrim(v_c->>'nombre_tecnica'),''),
    numero_tecnica = nullif(btrim(v_c->>'numero_tecnica'),''),
    sellos_tpu = nullif(btrim(v_c->>'sellos_tpu'),''),
    ubicacion_tpu = nullif(btrim(v_c->>'ubicacion_tpu'),''),
    bordado = nullif(btrim(v_c->>'bordado'),''),
    colores_generales = coalesce(v_c->'colores_generales','[]'::jsonb),
    adicionales = coalesce(v_c->'adicionales','{}'::jsonb),
    actualizado_por = v_uid
  where id = p_contrato_id;

  -- Reemplazo de hijos. Mismas columnas y mismos casts que crear_contrato_v108.
  delete from public.contrato_prendas where contrato_id = p_contrato_id;
  insert into public.contrato_prendas(contrato_id,prenda,calidad,detalle,genero,talla,cantidad)
  select p_contrato_id,btrim(x.prenda),btrim(coalesce(x.calidad,'')),btrim(coalesce(x.detalle,'')),x.genero,btrim(x.talla),x.cantidad
  from jsonb_to_recordset(p_datos->'prendas') as x(prenda text,calidad text,detalle text,genero text,talla text,cantidad integer);

  delete from public.contrato_jugadores where contrato_id = p_contrato_id;
  insert into public.contrato_jugadores(contrato_id,orden,nombre,numero,categoria,talla_superior,talla_inferior,manga,calidad,modelo_arquero,tipo_uniforme,detalle,mockup)
  select p_contrato_id,coalesce(x.orden,0),coalesce(x.nombre,''),x.numero,coalesce(x.categoria,'Hombre'),x.talla_superior,x.talla_inferior,
    nullif(x.manga,''),x.calidad,x.modelo_arquero,x.tipo_uniforme,x.detalle,x.mockup
  from jsonb_to_recordset(coalesce(p_datos->'jugadores','[]'::jsonb)) as x(orden integer,nombre text,numero text,categoria text,talla_superior text,talla_inferior text,manga text,calidad text,modelo_arquero text,tipo_uniforme text,detalle text,mockup text);
  get diagnostics v_n_jug = row_count;

  delete from public.contrato_specs where contrato_id = p_contrato_id;
  insert into public.contrato_specs(contrato_id,prenda_clave,orden,variante_mockup,variante_calidad,variante_otro,spec)
  select p_contrato_id,btrim(x.prenda_clave),coalesce(x.orden,0),x.variante_mockup,x.variante_calidad,x.variante_otro,coalesce(x.spec,'{}'::jsonb)
  from jsonb_to_recordset(coalesce(p_datos->'especificaciones','[]'::jsonb)) as x(prenda_clave text,orden integer,variante_mockup text,variante_calidad text,variante_otro text,spec jsonb)
  where btrim(coalesce(x.prenda_clave,''))<>'';
  get diagnostics v_n_spec = row_count;

  delete from public.contrato_facturacion where contrato_id = p_contrato_id;
  insert into public.contrato_facturacion(contrato_id,orden,concepto,calidad,cantidad,obsequio)
  select p_contrato_id,coalesce(x.orden,0),btrim(x.concepto),x.calidad,x.cantidad,coalesce(x.obsequio,false)
  from jsonb_to_recordset(coalesce(p_datos->'facturacion','[]'::jsonb)) as x(orden integer,concepto text,calidad text,cantidad integer,obsequio boolean)
  where btrim(coalesce(x.concepto,''))<>'' and x.cantidad>0;

  -- Los archivos que siguen en la lista llegan con su url ya guardada y se
  -- reinsertan igual; los nuevos traen pendiente_id y se validan como en el
  -- alta. El objeto que queda en el bucket tras quitar un mockup NO se borra:
  -- una referencia rota es peor que un archivo huerfano, y el bucket se limpia
  -- aparte si algun dia estorba.
  delete from public.contrato_archivos where contrato_id = p_contrato_id;
  v_n_arch := 0;
  for v_item in select value from jsonb_array_elements(coalesce(p_datos->'archivos','[]'::jsonb)) loop
    if nullif(v_item->>'pendiente_id','') is not null then
      select * into v_archivo from public.contrato_archivos_pendientes_v108
      where id=(v_item->>'pendiente_id')::uuid and creado_por=v_uid and usado_en is null for update;
      if not found then raise exception 'Uno de los archivos no fue preparado o ya fue utilizado'; end if;
      if not exists(select 1 from storage.objects o where o.bucket_id='contratos-archivos' and o.name=v_archivo.storage_path) then
        raise exception 'Uno de los archivos no termino de subir';
      end if;
      v_url := coalesce(nullif(v_item->>'url',''),'/storage/v1/object/public/contratos-archivos/'||v_archivo.storage_path);
      update public.contrato_archivos_pendientes_v108 set usado_en=p_contrato_id where id=v_archivo.id;
    else
      v_url := coalesce(v_item->>'url','');
    end if;
    insert into public.contrato_archivos(contrato_id,tipo,orden,descripcion,url,drive_id,color,prenda,posicion,tecnica,calidad_aplicable,observacion)
    values(p_contrato_id,v_item->>'tipo',coalesce((v_item->>'orden')::integer,0),coalesce(v_item->>'descripcion',''),v_url,
      nullif(v_item->>'drive_id',''),nullif(v_item->>'color',''),nullif(v_item->>'prenda',''),nullif(v_item->>'posicion',''),
      nullif(v_item->>'tecnica',''),nullif(v_item->>'calidad_aplicable',''),nullif(v_item->>'observacion',''));
    v_n_arch := v_n_arch + 1;
  end loop;

  select coalesce(nombre_completo,v_uid::text) into v_quien from public.perfiles where id = v_uid;
  insert into public.contrato_eventos(contrato_id,campo,valor_anterior,valor_nuevo,quien,perfil_id,motivo_gestion_v99)
  values(p_contrato_id,'Contenido reeditado',
    v_antes.total_prendas::text||' prendas',
    v_total::text||' prendas · '||v_n_jug::text||' jugadores · '||v_n_spec::text||' especificaciones · '||v_n_arch::text||' archivos',
    v_quien,v_uid,btrim(p_motivo));

  v_resultado := jsonb_build_object('duplicado',false,'contrato_id',p_contrato_id,
    'numero',v_antes.numero,'total_prendas',v_total,'jugadores',v_n_jug,'archivos',v_n_arch);
  insert into public.contrato_actualizaciones_v120(contrato_id,datos,motivo,usuario_id,idempotency_key,resultado)
  values(p_contrato_id,p_datos,btrim(p_motivo),v_uid,p_idempotency_key,v_resultado);
  return v_resultado;
end;
$v120$;

alter table public.contrato_actualizaciones_v120 owner to postgres;
alter function public.actualizar_contrato_v120(uuid,jsonb,text,uuid) owner to postgres;
revoke all on function public.actualizar_contrato_v120(uuid,jsonb,text,uuid) from public, anon;
grant execute on function public.actualizar_contrato_v120(uuid,jsonb,text,uuid) to authenticated;

comment on table public.contrato_actualizaciones_v120 is
  'Cada reedicion de contenido: datos enviados, motivo, quien e idempotencia. El alta vive en contrato_ingresos_v108.';

commit;
