-- ============================================================
-- BOMAN INVENTARIO - v105
-- Operacion masiva para la interfaz de Tesoreria
-- Ejecutar despues de v104.
-- ============================================================

begin;

do $$ begin
  if to_regprocedure('public.confirmar_cheque_importado_v104(uuid,uuid,uuid,text,text,uuid)') is null then
    raise exception 'Falta v104. Instalalo antes de v105';
  end if;
end $$;

create or replace function public.confirmar_lote_cheques_v105(
  p_importacion_id uuid,p_nota text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path=''
as $fn$
declare
  v_uid uuid:=auth.uid(); v_import public.tesoreria_importaciones%rowtype;
  v_linea record; v_confirmadas integer:=0; v_observadas integer:=0;
  v_resultado jsonb;
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select datos->'resultado' into v_resultado
  from public.tesoreria_instrumento_eventos where idempotency_key=p_idempotency_key;
  if found then return v_resultado||jsonb_build_object('duplicado',true); end if;
  if length(btrim(coalesce(p_nota,'')))<10 then raise exception 'Indica un motivo de al menos 10 caracteres'; end if;
  select * into v_import from public.tesoreria_importaciones where id=p_importacion_id for update;
  if not found then raise exception 'La importacion no existe'; end if;
  if not public.usuario_puede_tesoreria_v73(v_import.grupo_id,true) then raise exception 'No tienes permiso para confirmar el lote'; end if;
  if v_import.estado not in('cargada','en_revision') then raise exception 'La importacion ya fue cerrada'; end if;

  for v_linea in
    select l.id,l.cuenta_bancaria_sugerida_id
    from public.tesoreria_importacion_lineas l
    where l.importacion_id=v_import.id and l.estado='lista'
    order by l.fila_origen
  loop
    begin
      if v_linea.cuenta_bancaria_sugerida_id is null then
        raise exception 'La fila no tiene cuenta bancaria sugerida';
      end if;
      perform public.confirmar_cheque_importado_v104(
        v_linea.id,v_linea.cuenta_bancaria_sugerida_id,null,
        'programado',btrim(p_nota),gen_random_uuid()
      );
      v_confirmadas:=v_confirmadas+1;
    exception when others then
      update public.tesoreria_importacion_lineas
      set estado='observada',errores=errores||jsonb_build_array('confirmacion: '||sqlerrm),updated_at=now()
      where id=v_linea.id;
      v_observadas:=v_observadas+1;
    end;
  end loop;

  update public.tesoreria_importaciones i set
    filas_migradas=x.migradas,
    filas_observadas=x.observadas,
    filas_validas=x.listas,
    estado=case when x.pendientes=0 then 'confirmada' else 'en_revision' end,
    updated_at=now()
  from(
    select count(*) filter(where estado='migrada')::integer migradas,
      count(*) filter(where estado='observada')::integer observadas,
      count(*) filter(where estado='lista')::integer listas,
      count(*) filter(where estado in('pendiente','lista','observada'))::integer pendientes
    from public.tesoreria_importacion_lineas where importacion_id=v_import.id
  ) x where i.id=v_import.id;

  v_resultado:=jsonb_build_object(
    'duplicado',false,'importacion_id',v_import.id,
    'confirmadas',v_confirmadas,'observadas',v_observadas
  );
  insert into public.tesoreria_instrumento_eventos(
    grupo_id,tipo,detalle,datos,usuario_id,idempotency_key
  ) values(
    v_import.grupo_id,'lote_confirmado',btrim(p_nota),
    jsonb_build_object('resultado',v_resultado),v_uid,p_idempotency_key
  );
  return v_resultado;
end;$fn$;

alter function public.confirmar_lote_cheques_v105(uuid,text,uuid) owner to postgres;
revoke all on function public.confirmar_lote_cheques_v105(uuid,text,uuid) from public,anon;
grant execute on function public.confirmar_lote_cheques_v105(uuid,text,uuid) to authenticated;

commit;
notify pgrst,'reload schema';
