-- v141 - Registrar ausencias con respaldo pendiente y completarlo después.
begin;
select pg_advisory_xact_lock(hashtextextended('boman:v141', 0));

-- Definicion explicita de v27, conservando todas sus reglas salvo una: el
-- respaldo obligatorio ya no bloquea la SOLICITUD. El trigger de abajo lo
-- sigue exigiendo al APROBAR. Evita depender del formato que pg_get_functiondef
-- use en cada version de PostgreSQL.
create or replace function public.solicitar_ausencia_v27(
  p_empleado_id uuid,
  p_tipo text,
  p_fecha_desde date,
  p_fecha_hasta date,
  p_horas numeric,
  p_almacen_id uuid,
  p_documento_respaldo_id uuid,
  p_observacion text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $solicitud$
declare
  e public.empleados%rowtype;
  v_ausencia_id uuid;
  v_dias_calendario numeric(7,2);
  v_dias_habiles numeric(7,2);
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede registrar ausencias';
  end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  select id into v_ausencia_id from public.ausencias where idempotency_key=p_idempotency_key;
  if found then
    return jsonb_build_object('id',v_ausencia_id,'duplicado',true,'mensaje','La solicitud ya estaba registrada');
  end if;
  if p_tipo not in (
    'vacaciones','enfermedad_iess','enfermedad_particular','permiso_con_sueldo',
    'permiso_sin_sueldo','maternidad','paternidad','lactancia',
    'calamidad_domestica','falta_injustificada','suspension_disciplinaria'
  ) then raise exception 'El tipo de ausencia no es valido'; end if;
  if p_fecha_desde is null or p_fecha_hasta is null or p_fecha_hasta<p_fecha_desde then
    raise exception 'El rango de la ausencia no es valido';
  end if;
  if p_horas is not null and (p_horas<=0 or p_horas>24 or p_fecha_desde<>p_fecha_hasta) then
    raise exception 'Una ausencia por horas debe ocurrir en un solo dia y no superar 24 horas';
  end if;
  if p_tipo='vacaciones' and p_horas is not null then
    raise exception 'Las vacaciones se registran en dias calendario completos';
  end if;

  select * into e from public.empleados where id=p_empleado_id for update;
  if not found then raise exception 'El empleado no existe'; end if;
  if e.estado<>'activo' then raise exception 'El empleado no esta activo'; end if;
  if p_tipo='vacaciones' and e.tipo_contrato='servicios_profesionales' then
    raise exception 'Servicios profesionales no genera vacaciones laborales automaticamente';
  end if;
  if p_fecha_desde<e.fecha_ingreso_real then raise exception 'La ausencia no puede iniciar antes del ingreso real'; end if;
  if e.fecha_salida is not null and p_fecha_hasta>e.fecha_salida then
    raise exception 'La ausencia no puede terminar despues de la salida del empleado';
  end if;

  if p_almacen_id is not null and not exists(
    select 1 from public.empresa_almacenes ea
    join public.empresas ep on ep.id=ea.empresa_id and ep.activo
    join public.almacenes a on a.id=ea.almacen_id and a.activo
    where ea.almacen_id=p_almacen_id and ep.grupo_id=e.grupo_id
  ) then raise exception 'El almacen de la ausencia no pertenece al grupo del empleado'; end if;

  if p_documento_respaldo_id is not null and not exists(
    select 1 from public.empleado_documentos d
    where d.id=p_documento_respaldo_id and d.empleado_id=e.id and d.activo
  ) then raise exception 'El documento de respaldo no pertenece al empleado o esta inactivo'; end if;

  if exists(
    select 1 from public.ausencias a
    where a.empleado_id=e.id and a.estado in('solicitada','aprobada')
      and daterange(a.fecha_desde,a.fecha_hasta,'[]')&&daterange(p_fecha_desde,p_fecha_hasta,'[]')
  ) then raise exception 'El empleado ya tiene una ausencia que se cruza con estas fechas'; end if;

  perform public.validar_calendarios_feriados_v27(e.grupo_id,p_fecha_desde,p_fecha_hasta);
  if p_horas is null then
    v_dias_calendario:=p_fecha_hasta-p_fecha_desde+1;
    v_dias_habiles:=public.calcular_dias_habiles_v27(e.grupo_id,p_fecha_desde,p_fecha_hasta,p_almacen_id);
  else
    v_dias_calendario:=0;
    v_dias_habiles:=0;
  end if;

  insert into public.ausencias(
    grupo_id,empleado_id,almacen_id,tipo,fecha_desde,fecha_hasta,horas,
    dias_calendario,dias_habiles,documento_respaldo_id,observacion,idempotency_key,solicitado_por
  ) values(
    e.grupo_id,e.id,p_almacen_id,p_tipo,p_fecha_desde,p_fecha_hasta,p_horas,
    v_dias_calendario,v_dias_habiles,p_documento_respaldo_id,
    nullif(btrim(p_observacion),''),p_idempotency_key,auth.uid()
  ) returning id into v_ausencia_id;

  insert into public.nomina_eventos(
    entidad,entidad_id,empleado_id,tipo,estado_nuevo,detalle,datos,usuario_id,idempotency_key
  ) values(
    'ausencia',v_ausencia_id,e.id,'solicitada','solicitada','Solicitud de ausencia registrada',
    jsonb_build_object('tipo',p_tipo,'fecha_desde',p_fecha_desde,'fecha_hasta',p_fecha_hasta,
      'horas',p_horas,'dias_calendario',v_dias_calendario,'dias_habiles',v_dias_habiles,
      'respaldo_pendiente',p_documento_respaldo_id is null),
    auth.uid(),gen_random_uuid()
  ) returning id into v_evento_id;

  return jsonb_build_object('id',v_ausencia_id,'evento_id',v_evento_id,
    'dias_calendario',v_dias_calendario,'dias_habiles',v_dias_habiles,
    'respaldo_pendiente',p_documento_respaldo_id is null,'duplicado',false,
    'mensaje','Solicitud registrada para aprobacion');
end;
$solicitud$;

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
