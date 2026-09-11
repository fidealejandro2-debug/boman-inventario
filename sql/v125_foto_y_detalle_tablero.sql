-- ============================================================
-- BOMAN INVENTARIO - v125: ver el contrato en grande y agregarle una foto
--
-- Dos piezas que le faltan al tablero para igualar al de Codigo.gs:
--
-- 1. La lupa. Al tocar un contrato se abren sus mockups en grande, sus logos y
--    su ficha. Los mockups ya viajan en el tablero; los logos no, y meterlos
--    seria cargar los de cientos de contratos para mirar uno. Por eso se piden
--    aparte, igual que las prendas en v123.
--
-- 2. Agregar una foto (subirFotoTablero en la hoja). El caso real: un contrato
--    que entro sin mockup y alguien le saca una foto al diseño impreso desde el
--    celular. Se APENDA un archivo; no se reemplaza la lista como hace v120,
--    porque aqui no hay nada que rehacer, solo algo que sumar.
--
-- Permiso: contratos.editar_contenido. Agregar un mockup es tocar el contenido
-- del contrato, y eso quedo como cosa del administrador.
--
-- Ejecutar despues de v120.
-- ============================================================
begin;
select pg_advisory_xact_lock(1251142026);

do $$begin
  if to_regprocedure('public.actualizar_contrato_v120(uuid,jsonb,text,uuid)') is null
     or to_regclass('public.contrato_archivos_pendientes_v108') is null then
    raise exception 'Falta v120 (y v108) antes de v125';
  end if;
end$$;

-- Logos y mockups de UN contrato, para la lupa.
create or replace function public.archivos_contrato_v125(p_contrato_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_r jsonb;
begin
  if auth.uid() is null or not (public.usuario_tiene_permiso_v35('produccion.acceder')
                                or public.usuario_tiene_permiso_v35('produccion.estacion')) then
    raise exception 'No tienes permiso para consultar produccion';
  end if;
  select jsonb_build_object(
    'mockups', coalesce((
      select jsonb_agg(jsonb_build_object('id',ca.id,'drive',coalesce(ca.drive_id,''),'url',coalesce(ca.url,''),
                                          'descripcion',coalesce(ca.descripcion,'')) order by ca.orden)
        from public.contrato_archivos ca
       where ca.contrato_id = p_contrato_id and ca.tipo = 'mockup'), '[]'::jsonb),
    'logos', coalesce((
      select jsonb_agg(jsonb_build_object('id',ca.id,'drive',coalesce(ca.drive_id,''),'url',coalesce(ca.url,''),
                                          'descripcion',coalesce(ca.descripcion,''),'prenda',coalesce(ca.prenda,''),
                                          'posicion',coalesce(ca.posicion,''),'tecnica',coalesce(ca.tecnica,''),
                                          'observacion',coalesce(ca.observacion,'')) order by ca.orden)
        from public.contrato_archivos ca
       where ca.contrato_id = p_contrato_id and ca.tipo = 'logo'), '[]'::jsonb),
    -- El paso a paso de lo marcado, que es lo que se quiere ver al abrir un
    -- contrato desde el tablero: quien hizo que y cuando.
    'etapas', coalesce((
      select jsonb_agg(jsonb_build_object('area',ce.area,'etapa',ce.etapa,'operario',coalesce(ce.operario,''),
                                          'noAplica',ce.no_aplica,
                                          'cuando',to_char(ce.marcado_en at time zone 'America/Guayaquil','DD/MM HH24:MI'))
             order by ce.marcado_en)
        from public.contrato_etapas ce where ce.contrato_id = p_contrato_id), '[]'::jsonb)
  ) into v_r;
  return v_r;
end;$fn$;

-- Apenda UN archivo ya subido al bucket. El pendiente se valida igual que en
-- el alta: que exista, que sea de quien lo subio, que no se haya usado antes y
-- que el objeto este de verdad en storage -sin eso quedaria una fila apuntando
-- a un archivo que nunca termino de subir.
create or replace function public.agregar_archivo_contrato_v125(
  p_contrato_id uuid, p_pendiente_id uuid, p_url text, p_descripcion text, p_idempotency_key uuid
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_numero text;
  v_archivo public.contrato_archivos_pendientes_v108%rowtype;
  v_url text; v_orden integer; v_quien text; v_resultado jsonb;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar_contenido') then
    raise exception 'No tienes permiso para agregar archivos a un contrato';
  end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,125));
  select resultado into v_resultado from public.contrato_actualizaciones_v120
  where idempotency_key = p_idempotency_key;
  if found and v_resultado is not null then return v_resultado || jsonb_build_object('duplicado',true); end if;

  select numero into v_numero from public.contratos where id = p_contrato_id for update;
  if v_numero is null then raise exception 'El contrato no existe'; end if;

  select * into v_archivo from public.contrato_archivos_pendientes_v108
  where id = p_pendiente_id and creado_por = v_uid and usado_en is null for update;
  if not found then raise exception 'El archivo no fue preparado o ya fue utilizado'; end if;
  if not exists(select 1 from storage.objects o
                 where o.bucket_id='contratos-archivos' and o.name=v_archivo.storage_path) then
    raise exception 'El archivo no termino de subir';
  end if;
  v_url := coalesce(nullif(btrim(p_url),''),
                    '/storage/v1/object/public/contratos-archivos/'||v_archivo.storage_path);
  update public.contrato_archivos_pendientes_v108 set usado_en = p_contrato_id where id = v_archivo.id;

  select coalesce(max(ca.orden),-1)+1 into v_orden
    from public.contrato_archivos ca where ca.contrato_id = p_contrato_id;

  insert into public.contrato_archivos(contrato_id,tipo,orden,descripcion,url)
  values(p_contrato_id,'mockup',v_orden,
         coalesce(nullif(btrim(p_descripcion),''),'Foto agregada desde el tablero'),v_url);

  select coalesce(nombre_completo,v_uid::text) into v_quien from public.perfiles where id = v_uid;
  insert into public.contrato_eventos(contrato_id,campo,valor_nuevo,quien,perfil_id,motivo_gestion_v99)
  values(p_contrato_id,'Mockup agregado',
         coalesce(nullif(btrim(p_descripcion),''),'Foto desde el tablero'),
         v_quien,v_uid,'Foto agregada desde el tablero de producción');

  v_resultado := jsonb_build_object('ok',true,'duplicado',false,'contrato_id',p_contrato_id,
                                    'numero',v_numero,'url',v_url,'orden',v_orden);
  insert into public.contrato_actualizaciones_v120(contrato_id,datos,motivo,usuario_id,idempotency_key,resultado)
  values(p_contrato_id,jsonb_build_object('archivo_agregado',v_url),
         'Foto agregada desde el tablero de producción',v_uid,p_idempotency_key,v_resultado);
  return v_resultado;
end;$fn$;

alter function public.archivos_contrato_v125(uuid) owner to postgres;
alter function public.agregar_archivo_contrato_v125(uuid,uuid,text,text,uuid) owner to postgres;
revoke all on function public.archivos_contrato_v125(uuid) from public, anon;
revoke all on function public.agregar_archivo_contrato_v125(uuid,uuid,text,text,uuid) from public, anon;
grant execute on function public.archivos_contrato_v125(uuid) to authenticated;
grant execute on function public.agregar_archivo_contrato_v125(uuid,uuid,text,text,uuid) to authenticated;

commit;
