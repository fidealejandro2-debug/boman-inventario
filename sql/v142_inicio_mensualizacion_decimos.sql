-- ============================================================
-- BOMAN INVENTARIO - v142
-- Mes efectivo para la mensualizacion de decimos.
-- Los roles cerrados se conservan; la preferencia se aplica desde el mes
-- elegido a los periodos nuevos y a periodos abiertos.
-- ============================================================

begin;
select pg_advisory_xact_lock(14209142026);

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null
     or to_regprocedure('public.configurar_beneficios_empleado_v30(uuid,boolean,boolean,boolean,text,uuid)') is null
     or to_regclass('public.nomina_rol_lineas') is null then
    raise exception 'Faltan las migraciones de Nomina o el registro de migraciones antes de v142';
  end if;
end
$requisitos$;

alter table public.empleado_compensacion
  add column if not exists inicio_mensualiza_decimo_tercero date,
  add column if not exists inicio_mensualiza_decimo_cuarto date;

-- Las preferencias que ya estaban activas empiezan en el mes actual. No se
-- inventa una fecha pasada ni se reescriben roles que ya constituyen historia.
update public.empleado_compensacion
set inicio_mensualiza_decimo_tercero = date_trunc('month',current_date)::date
where mensualiza_decimo_tercero and inicio_mensualiza_decimo_tercero is null;

update public.empleado_compensacion
set inicio_mensualiza_decimo_cuarto = date_trunc('month',current_date)::date
where mensualiza_decimo_cuarto and inicio_mensualiza_decimo_cuarto is null;

create or replace function public.normalizar_inicio_decimos_v142()
returns trigger language plpgsql set search_path='' as $fn$
begin
  if new.mensualiza_decimo_tercero then
    new.inicio_mensualiza_decimo_tercero:=coalesce(new.inicio_mensualiza_decimo_tercero,date_trunc('month',current_date)::date);
  else
    new.inicio_mensualiza_decimo_tercero:=null;
  end if;
  if new.mensualiza_decimo_cuarto then
    new.inicio_mensualiza_decimo_cuarto:=coalesce(new.inicio_mensualiza_decimo_cuarto,date_trunc('month',current_date)::date);
  else
    new.inicio_mensualiza_decimo_cuarto:=null;
  end if;
  if extract(day from new.inicio_mensualiza_decimo_tercero)<>1
     or extract(day from new.inicio_mensualiza_decimo_cuarto)<>1 then
    raise exception 'El inicio de mensualizacion debe ser el primer dia de un mes';
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_normalizar_inicio_decimos_v142 on public.empleado_compensacion;
create trigger trg_normalizar_inicio_decimos_v142
before insert or update of mensualiza_decimo_tercero,mensualiza_decimo_cuarto,
  inicio_mensualiza_decimo_tercero,inicio_mensualiza_decimo_cuarto
on public.empleado_compensacion for each row execute function public.normalizar_inicio_decimos_v142();

create or replace function public.aplicar_inicio_decimos_rol_v142()
returns trigger language plpgsql set search_path='' as $fn$
declare v_mes date; v_d13 date; v_d14 date;
begin
  select p.fecha_desde into strict v_mes from public.nomina_periodos p where p.id=new.periodo_id;
  select c.inicio_mensualiza_decimo_tercero,c.inicio_mensualiza_decimo_cuarto
    into v_d13,v_d14 from public.empleado_compensacion c where c.id=new.compensacion_id;
  new.mensualiza_decimo_tercero:=new.mensualiza_decimo_tercero and v_d13 is not null and v_mes>=v_d13;
  new.mensualiza_decimo_cuarto:=new.mensualiza_decimo_cuarto and v_d14 is not null and v_mes>=v_d14;
  return new;
end
$fn$;

drop trigger if exists trg_aplicar_inicio_decimos_rol_v142 on public.nomina_rol_lineas;
create trigger trg_aplicar_inicio_decimos_rol_v142
before insert on public.nomina_rol_lineas for each row execute function public.aplicar_inicio_decimos_rol_v142();

create or replace function public.configurar_beneficios_empleado_v142(
  p_empleado_id uuid,
  p_mensualiza_decimo_tercero boolean,
  p_mensualiza_decimo_cuarto boolean,
  p_inicio_decimo_tercero date,
  p_inicio_decimo_cuarto date,
  p_paga_fondos_reserva_mensual boolean,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  c public.empleado_compensacion%rowtype;
  v_evento_id uuid; v_afiliado boolean:=false; v_d13 boolean; v_d14 boolean;
begin
  if not public.usuario_puede_nomina(true) then raise exception 'Solo Administracion o Nomina puede configurar beneficios'; end if;
  if p_idempotency_key is null or length(btrim(coalesce(p_motivo,'')))<10 then
    raise exception 'La configuracion requiere idempotencia y motivo de al menos 10 caracteres';
  end if;
  select id into v_evento_id from public.nomina_eventos where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('evento_id',v_evento_id,'duplicado',true); end if;
  if (coalesce(p_mensualiza_decimo_tercero,false) and p_inicio_decimo_tercero is null)
     or (coalesce(p_mensualiza_decimo_cuarto,false) and p_inicio_decimo_cuarto is null) then
    raise exception 'Selecciona el mes de inicio de cada decimo mensualizado';
  end if;
  if extract(day from p_inicio_decimo_tercero)<>1 or extract(day from p_inicio_decimo_cuarto)<>1 then
    raise exception 'El inicio de mensualizacion debe ser el primer dia de un mes';
  end if;
  select * into c from public.empleado_compensacion
  where empleado_id=p_empleado_id and fecha_hasta is null for update;
  if not found then raise exception 'El empleado no tiene compensacion vigente'; end if;
  select coalesce(a.afiliado,false) into v_afiliado from public.empleado_afiliaciones a
  where a.empleado_id=p_empleado_id and a.fecha_hasta is null order by a.fecha_desde desc limit 1;
  v_afiliado:=coalesce(v_afiliado,false);
  v_d13:=v_afiliado and coalesce(p_mensualiza_decimo_tercero,false);
  v_d14:=v_afiliado and coalesce(p_mensualiza_decimo_cuarto,false);
  perform set_config('nomina.motivo',btrim(p_motivo),true);
  update public.empleado_compensacion set
    mensualiza_decimo_tercero=v_d13,
    mensualiza_decimo_cuarto=v_d14,
    inicio_mensualiza_decimo_tercero=case when v_d13 then p_inicio_decimo_tercero end,
    inicio_mensualiza_decimo_cuarto=case when v_d14 then p_inicio_decimo_cuarto end,
    paga_fondos_reserva_mensual=case when v_afiliado then coalesce(p_paga_fondos_reserva_mensual,true) else true end
  where id=c.id;

  -- Solo se actualizan snapshots abiertos. Un rol calculado o cerrado conserva
  -- exactamente la decision con la que fue procesado.
  update public.nomina_rol_lineas l set
    mensualiza_decimo_tercero=v_d13 and p_inicio_decimo_tercero<=p.fecha_desde,
    mensualiza_decimo_cuarto=v_d14 and p_inicio_decimo_cuarto<=p.fecha_desde
  from public.nomina_periodos p
  where p.id=l.periodo_id and l.empleado_id=p_empleado_id and p.estado='abierto';

  v_evento_id:=public.registrar_evento_nomina_v30('compensacion',c.id,p_empleado_id,
    'beneficios_configurados',null,null,btrim(p_motivo),jsonb_build_object(
      'afiliado',v_afiliado,'mensualiza_decimo_tercero',v_d13,
      'inicio_decimo_tercero',case when v_d13 then p_inicio_decimo_tercero end,
      'mensualiza_decimo_cuarto',v_d14,
      'inicio_decimo_cuarto',case when v_d14 then p_inicio_decimo_cuarto end,
      'paga_fondos_reserva_mensual',case when v_afiliado then coalesce(p_paga_fondos_reserva_mensual,true) else true end
    ),p_idempotency_key);
  return jsonb_build_object('compensacion_id',c.id,'evento_id',v_evento_id,
    'mensualiza_decimo_tercero',v_d13,'mensualiza_decimo_cuarto',v_d14,'duplicado',false);
end
$fn$;

-- Se vuelve a publicar la vista con las fechas al final para no cambiar el
-- orden de las columnas existentes.
create or replace view public.vista_personal_vigente with (security_invoker=true) as
select e.id empleado_id,e.grupo_id,e.identificacion,e.apellidos||' '||e.nombres nombre_completo,
  e.cargo,e.area,e.tipo_contrato,e.estado,e.fecha_ingreso_real,e.fecha_salida,
  a.afiliado,a.empresa_id empresa_afiliacion_id,emp_af.razon_social empresa_afiliacion,
  a.fecha_afiliacion,a.sueldo_declarado,c.empresa_pagadora_id,emp_pg.razon_social empresa_pagadora,
  c.sueldo_real,coalesce(c.sueldo_real,0)-coalesce(a.sueldo_declarado,0) brecha_sueldo,
  case when a.afiliado and a.fecha_afiliacion is not null then a.fecha_afiliacion-e.fecha_ingreso_real end dias_entre_ingreso_y_afiliacion,
  (a.afiliado and c.empresa_pagadora_id is distinct from a.empresa_id) paga_otro_ruc,
  e.departamento_id,d.codigo departamento_codigo,d.nombre departamento_nombre,
  c.mensualiza_decimo_tercero,c.mensualiza_decimo_cuarto,c.paga_fondos_reserva_mensual,
  c.inicio_mensualiza_decimo_tercero,c.inicio_mensualiza_decimo_cuarto
from public.empleados e
left join public.empleado_afiliaciones a on a.empleado_id=e.id and a.fecha_hasta is null
left join public.empleado_compensacion c on c.empleado_id=e.id and c.fecha_hasta is null
left join public.empresas emp_af on emp_af.id=a.empresa_id
left join public.empresas emp_pg on emp_pg.id=c.empresa_pagadora_id
left join public.departamentos_nomina d on d.id=e.departamento_id;

alter function public.normalizar_inicio_decimos_v142() owner to postgres;
alter function public.aplicar_inicio_decimos_rol_v142() owner to postgres;
alter function public.configurar_beneficios_empleado_v142(uuid,boolean,boolean,date,date,boolean,text,uuid) owner to postgres;
revoke all on function public.normalizar_inicio_decimos_v142(),public.aplicar_inicio_decimos_rol_v142() from public,anon,authenticated;
revoke all on function public.configurar_beneficios_empleado_v142(uuid,boolean,boolean,date,date,boolean,text,uuid) from public,anon;
grant execute on function public.configurar_beneficios_empleado_v142(uuid,boolean,boolean,date,date,boolean,text,uuid) to authenticated;

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v142','142','v142_inicio_mensualizacion_decimos.sql','Mes efectivo auditado para mensualizacion de decimos')
on conflict(id) do update set version=excluded.version,archivo=excluded.archivo,notas=excluded.notas,aplicada_at=now();

commit;
notify pgrst,'reload schema';
