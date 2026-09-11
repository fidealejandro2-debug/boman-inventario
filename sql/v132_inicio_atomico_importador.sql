-- ============================================================
-- v132 - Inicio atomico del importador BomanSport
-- Ejecutar despues de v90 y antes de verificacion_v132.sql.
-- Nunca ejecutar migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v132', 0));

do $v132$
begin
  if to_regclass('public.bomansport_importaciones') is null then
    raise exception 'Falta v90: no existe bomansport_importaciones';
  end if;
end;
$v132$;

create or replace function public.iniciar_importacion_bomansport_v132(
  p_origen text,
  p_ejecutado_por uuid default null
)
returns jsonb
language plpgsql security definer set search_path = '' as $v132$
declare
  v_activa uuid;
  v_nueva uuid;
begin
  if p_origen not in ('cron', 'manual') then
    raise exception 'Origen de importacion invalido';
  end if;
  if (p_origen = 'manual') <> (p_ejecutado_por is not null) then
    raise exception 'La importacion manual exige responsable y el cron no debe tenerlo';
  end if;

  -- Serializa solamente el arranque; la importacion larga ocurre fuera de la
  -- transaccion. Ninguna pareja check/insert puede intercalarse.
  perform pg_advisory_xact_lock(hashtextextended('bomansport:importacion-activa', 132));

  update public.bomansport_importaciones
     set estado = 'error',
         mensaje_error = coalesce(mensaje_error, 'Ejecucion abandonada: supero 10 minutos en curso'),
         finalizado_en = coalesce(finalizado_en, now())
   where estado = 'en_curso'
     and iniciado_en <= now() - interval '10 minutes';

  select id into v_activa
  from public.bomansport_importaciones
  where estado = 'en_curso'
  order by iniciado_en
  limit 1;

  if v_activa is not null then
    return jsonb_build_object('iniciada', false, 'activa_id', v_activa);
  end if;

  insert into public.bomansport_importaciones(origen, ejecutado_por)
  values (p_origen, p_ejecutado_por)
  returning id into v_nueva;

  return jsonb_build_object('iniciada', true, 'id', v_nueva);
end;
$v132$;

revoke all on function public.iniciar_importacion_bomansport_v132(text,uuid)
  from public, anon, authenticated;
grant execute on function public.iniciar_importacion_bomansport_v132(text,uuid)
  to service_role;

comment on function public.iniciar_importacion_bomansport_v132(text,uuid) is
  'Comprueba e inicia una sola importacion bajo bloqueo transaccional; cierra ejecuciones abandonadas.';

commit;
