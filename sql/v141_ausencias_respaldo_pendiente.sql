-- v141 - Registrar ausencias con respaldo pendiente y completarlo después.
begin;
select pg_advisory_xact_lock(hashtextextended('boman:v141', 0));

-- La función v27 ya contiene todas las validaciones de fechas, empleado,
-- calendario e idempotencia. Se retira únicamente el bloqueo al solicitar;
-- el trigger de abajo mantiene el documento obligatorio para aprobar.
do $ajustar_solicitud$
declare v_sql text; v_inicio integer; v_fin_rel integer;
begin
  if to_regprocedure('public.solicitar_ausencia_v27(uuid,text,date,date,numeric,uuid,uuid,text,uuid)') is null then
    raise exception 'Falta v27: no existe solicitar_ausencia_v27';
  end if;
  v_sql := pg_get_functiondef('public.solicitar_ausencia_v27(uuid,text,date,date,numeric,uuid,uuid,text,uuid)'::regprocedure);
  v_inicio := strpos(v_sql, E'\n  if p_tipo in (\n    ''enfermedad_iess'', ''enfermedad_particular'', ''maternidad'',');
  if v_inicio = 0 then
    if position('Este tipo de ausencia requiere un documento de respaldo' in v_sql) > 0 then
      raise exception 'No se pudo localizar de forma segura la validacion de respaldo';
    end if;
  else
    v_fin_rel := strpos(substr(v_sql, v_inicio + 1), E'\n  if exists (');
    if v_fin_rel = 0 then raise exception 'No se pudo localizar el final de la validacion'; end if;
    v_sql := left(v_sql, v_inicio - 1) || substr(v_sql, v_inicio + v_fin_rel);
    execute v_sql;
  end if;
end;
$ajustar_solicitud$;

create or replace function public.exigir_respaldo_al_aprobar_ausencia_v141()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.estado = 'aprobada' and old.estado is distinct from new.estado
     and new.tipo in ('enfermedad_iess','enfermedad_particular','maternidad','paternidad','calamidad_domestica','suspension_disciplinaria')
     and new.documento_respaldo_id is null then
    raise exception 'Adjunta el documento de respaldo antes de aprobar esta ausencia';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_exigir_respaldo_ausencia_v141 on public.ausencias;
create trigger trg_exigir_respaldo_ausencia_v141 before update of estado on public.ausencias
for each row execute function public.exigir_respaldo_al_aprobar_ausencia_v141();

create or replace function public.adjuntar_respaldo_ausencia_v141(
  p_ausencia_id uuid, p_documento_respaldo_id uuid, p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_ausencia public.ausencias%rowtype; v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then raise exception 'Solo Administracion o Nomina puede adjuntar respaldos'; end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_evento_id from public.nomina_eventos where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('evento_id',v_evento_id,'duplicado',true); end if;
  select * into v_ausencia from public.ausencias where id=p_ausencia_id for update;
  if not found then raise exception 'La ausencia no existe'; end if;
  if v_ausencia.estado <> 'solicitada' then raise exception 'Solo se puede completar una solicitud pendiente'; end if;
  if not exists(select 1 from public.empleado_documentos d where d.id=p_documento_respaldo_id and d.empleado_id=v_ausencia.empleado_id and d.activo) then
    raise exception 'El documento no pertenece a la persona o esta inactivo';
  end if;
  update public.ausencias set documento_respaldo_id=p_documento_respaldo_id,updated_at=now() where id=p_ausencia_id;
  insert into public.nomina_eventos(entidad,entidad_id,empleado_id,tipo,estado_anterior,estado_nuevo,detalle,datos,usuario_id,idempotency_key)
  values('ausencia',p_ausencia_id,v_ausencia.empleado_id,'respaldo_adjuntado',v_ausencia.estado,v_ausencia.estado,
    'Documento pendiente completado',jsonb_build_object('documento_respaldo_id',p_documento_respaldo_id),auth.uid(),p_idempotency_key)
  returning id into v_evento_id;
  return jsonb_build_object('ausencia_id',p_ausencia_id,'evento_id',v_evento_id,'duplicado',false);
end;
$$;

alter function public.exigir_respaldo_al_aprobar_ausencia_v141() owner to postgres;
alter function public.adjuntar_respaldo_ausencia_v141(uuid,uuid,uuid) owner to postgres;
revoke all on function public.adjuntar_respaldo_ausencia_v141(uuid,uuid,uuid) from public,anon;
grant execute on function public.adjuntar_respaldo_ausencia_v141(uuid,uuid,uuid) to authenticated;
insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v141',141,'v141_ausencias_respaldo_pendiente.sql','Permite solicitar con respaldo pendiente y lo exige antes de aprobar.')
on conflict(id) do nothing;
notify pgrst,'reload schema';
commit;
