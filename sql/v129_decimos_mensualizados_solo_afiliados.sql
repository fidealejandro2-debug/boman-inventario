-- ============================================================
-- BOMAN INVENTARIO - v129
-- Regla operativa: personal no afiliado no cobra ni provisiona décimos.
-- Ejecutar después de v128. No modifica roles históricos ya cerrados.
-- ============================================================

begin;
select pg_advisory_xact_lock(12909112026);

do $v129_requisitos$
begin
  if to_regprocedure('public.calcular_rol_v30(uuid,uuid)') is null
     or to_regprocedure('public.configurar_beneficios_empleado_v30(uuid,boolean,boolean,boolean,text,uuid)') is null
     or to_regclass('public.nomina_rol_lineas') is null then
    raise exception 'Falta instalar Nomina v30 antes de v129';
  end if;
end
$v129_requisitos$;

-- Garantiza la corrección de v76 aunque esa migración se haya omitido. Solo
-- reemplaza los cuatro fragmentos originales; si ya están corregidos no toca
-- la función completa ni pisa mejoras posteriores.
do $v129_calculo$
declare
  v_oid oid;
  v_def text;
  v_nuevo text;
  v_viejos text[]:=array[
    'v_d13_real := case when l.mensualiza_decimo_tercero',
    'v_d14_real := case when l.mensualiza_decimo_cuarto',
    'v_prov_d13 := case when l.mensualiza_decimo_tercero then 0',
    'v_prov_d14 := case when l.mensualiza_decimo_cuarto then 0'
  ];
  v_nuevos text[]:=array[
    'v_d13_real := case when l.afiliado and l.mensualiza_decimo_tercero',
    'v_d14_real := case when l.afiliado and l.mensualiza_decimo_cuarto',
    'v_prov_d13 := case when not l.afiliado or l.mensualiza_decimo_tercero then 0',
    'v_prov_d14 := case when not l.afiliado or l.mensualiza_decimo_cuarto then 0'
  ];
  i integer;
begin
  select p.oid into strict v_oid
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='calcular_rol_v30'
    and pg_catalog.pg_get_function_identity_arguments(p.oid)='p_periodo_id uuid, p_idempotency_key uuid';
  v_def:=pg_catalog.pg_get_functiondef(v_oid);
  v_nuevo:=v_def;
  for i in 1..array_length(v_viejos,1) loop
    if position(v_nuevos[i] in v_nuevo)>0 then
      continue;
    elsif position(v_viejos[i] in v_nuevo)>0 then
      v_nuevo:=replace(v_nuevo,v_viejos[i],v_nuevos[i]);
    else
      raise exception 'v129 no reconoce el fragmento % de calcular_rol_v30; no se aplicó ningún cambio',i;
    end if;
  end loop;
  if v_nuevo is distinct from v_def then execute v_nuevo; end if;
end
$v129_calculo$;

-- La foto de un período tampoco debe decir "mensualiza" para un no afiliado.
create or replace function public.normalizar_beneficios_rol_v129()
returns trigger language plpgsql set search_path='' as $v129_snapshot$
begin
  if not coalesce(new.afiliado,false) then
    new.mensualiza_decimo_tercero:=false;
    new.mensualiza_decimo_cuarto:=false;
  end if;
  return new;
end
$v129_snapshot$;

drop trigger if exists trg_normalizar_beneficios_rol_v129 on public.nomina_rol_lineas;
create trigger trg_normalizar_beneficios_rol_v129
before insert or update of afiliado,mensualiza_decimo_tercero,mensualiza_decimo_cuarto
on public.nomina_rol_lineas for each row execute function public.normalizar_beneficios_rol_v129();

-- Normaliza preferencias vigentes y snapshots todavía editables. Los roles
-- cerrados son evidencia histórica y no se reescriben con una migración.
select set_config('nomina.motivo','v129: normalización de décimos para personal no afiliado',true);
update public.empleado_compensacion c
set mensualiza_decimo_tercero=false,mensualiza_decimo_cuarto=false
where c.fecha_hasta is null
  and (c.mensualiza_decimo_tercero or c.mensualiza_decimo_cuarto)
  and not exists (
    select 1 from public.empleado_afiliaciones a
    where a.empleado_id=c.empleado_id and a.fecha_hasta is null and a.afiliado
  );

update public.nomina_rol_lineas l
set mensualiza_decimo_tercero=false,mensualiza_decimo_cuarto=false
from public.nomina_periodos p
where p.id=l.periodo_id and p.estado<>'cerrado' and not l.afiliado
  and (l.mensualiza_decimo_tercero or l.mensualiza_decimo_cuarto);

create or replace function public.configurar_beneficios_empleado_v30(
  p_empleado_id uuid,
  p_mensualiza_decimo_tercero boolean,
  p_mensualiza_decimo_cuarto boolean,
  p_paga_fondos_reserva_mensual boolean,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path='' as $v129_config$
declare
  c public.empleado_compensacion%rowtype;
  v_evento_id uuid;
  v_afiliado boolean:=false;
  v_d13 boolean;
  v_d14 boolean;
begin
  if not public.usuario_puede_nomina(true) then raise exception 'Solo Administracion o Nomina puede configurar beneficios';end if;
  if p_idempotency_key is null or length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'La configuracion requiere idempotencia y motivo de al menos 10 caracteres';end if;
  select id into v_evento_id from public.nomina_eventos where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('evento_id',v_evento_id,'duplicado',true);end if;
  select * into c from public.empleado_compensacion where empleado_id=p_empleado_id and fecha_hasta is null for update;
  if not found then raise exception 'El empleado no tiene compensacion vigente';end if;
  select coalesce(a.afiliado,false) into v_afiliado
  from public.empleado_afiliaciones a where a.empleado_id=p_empleado_id and a.fecha_hasta is null
  order by a.fecha_desde desc limit 1;
  v_afiliado:=coalesce(v_afiliado,false);
  v_d13:=v_afiliado and coalesce(p_mensualiza_decimo_tercero,false);
  v_d14:=v_afiliado and coalesce(p_mensualiza_decimo_cuarto,false);
  perform set_config('nomina.motivo',btrim(p_motivo),true);
  update public.empleado_compensacion set mensualiza_decimo_tercero=v_d13,
    mensualiza_decimo_cuarto=v_d14,
    paga_fondos_reserva_mensual=case when v_afiliado then coalesce(p_paga_fondos_reserva_mensual,true) else true end
  where id=c.id;
  v_evento_id:=public.registrar_evento_nomina_v30('compensacion',c.id,p_empleado_id,'beneficios_configurados',null,null,btrim(p_motivo),
    jsonb_build_object('afiliado',v_afiliado,'mensualiza_decimo_tercero',v_d13,
      'mensualiza_decimo_cuarto',v_d14,'paga_fondos_reserva_mensual',case when v_afiliado then coalesce(p_paga_fondos_reserva_mensual,true) else true end),p_idempotency_key);
  return jsonb_build_object('compensacion_id',c.id,'evento_id',v_evento_id,'afiliado',v_afiliado,
    'mensualiza_decimo_tercero',v_d13,'mensualiza_decimo_cuarto',v_d14,'duplicado',false);
end
$v129_config$;

alter function public.normalizar_beneficios_rol_v129() owner to postgres;
alter function public.configurar_beneficios_empleado_v30(uuid,boolean,boolean,boolean,text,uuid) owner to postgres;
revoke all on function public.normalizar_beneficios_rol_v129() from public,anon,authenticated;

commit;
notify pgrst,'reload schema';
