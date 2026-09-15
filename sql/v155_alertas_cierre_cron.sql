-- ============================================================
-- v155 - Revision diaria de cierres: recordatorio del dia + deteccion de
-- cierres pendientes y depositos faltantes (novedades operativas de v154).
--
-- El plan de hosting es Hobby: los cron jobs de Vercel solo corren 1 vez al
-- dia. Por eso esto NO es un aviso "X minutos antes" de la hora limite de
-- cada tienda -eso exigiria un cron cada 15-30 min (plan Pro)-, sino una
-- sola pasada diaria (temprano en la manana) que hace dos cosas:
--   1. Deja un recordatorio de HOY visible todo el dia en el Centro de
--      Avisos del encargado de cada tienda que aun no cerro.
--   2. Revisa AYER (dia ya terminado del todo) para detectar cierres que
--      nunca se hicieron y depositos que nunca se registraron, y ahi si
--      escala con una notificacion critica a control/gerencia/supervisor.
--
-- revisar_operacion_diaria_v155() es de uso interno: SIN grant a
-- authenticated. Solo la llama la ruta /api/cron/revisar-operacion con la
-- llave de servicio (mismo patron que /api/bomansport/sincronizar-pendientes).
--
-- Ejecutar despues de v154 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v155', 0));

do $requisitos$
begin
  if to_regclass('public.almacen_configuracion_operativa_v153') is null then
    raise exception 'Falta v153: instala primero la configuracion operativa por almacen';
  end if;
  if to_regprocedure('public._crear_novedad_operativa_v154(uuid,text,uuid,uuid,date,text,numeric,text,uuid,uuid)') is null then
    raise exception 'Falta v154: instala primero las novedades operativas';
  end if;
end;
$requisitos$;

create or replace function public.revisar_operacion_diaria_v155()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $v155$
declare
  v_hoy date := (now() at time zone 'America/Guayaquil')::date;
  v_ayer date := v_hoy - 1;
  v_autor uuid := public._perfil_sistema_v154();
  v_recordatorios integer := 0;
  v_cierres_pendientes integer := 0;
  v_depositos_faltantes integer := 0;
  r record;
begin
  -- 1) Recordatorio de HOY: locales operativos (tipo tienda: cubre tanto
  --    franquicias como tiendas propias) sin cierre registrado hoy.
  if v_autor is not null then
    for r in
      select a.id as almacen_id, a.nombre,
        coalesce(co.hora_limite_cierre, '20:00'::time) as hora_limite
      from public.almacenes a
      left join public.almacen_configuracion_operativa_v153 co on co.almacen_id = a.id
      where a.activo and a.tipo = 'tienda'
        and not exists (
          select 1 from public.franquicia_caja_cierres cc
          where cc.almacen_id = a.id and cc.fecha = v_hoy
        )
    loop
      insert into public.notificaciones_comunicados(
        origen_clave, origen_tipo, almacen_id, rol_destino,
        modulo, nivel, titulo, mensaje, href, creado_por
      )
      select 'recordatorio_cierre:' || r.almacen_id::text || ':' || v_hoy::text || ':' || rd.rol::text,
        'recordatorio_cierre', r.almacen_id, rd.rol, 'Franquicias', 'accion',
        'Cierre de caja pendiente hoy',
        'Recuerda cerrar la caja de "' || r.nombre || '" antes de las ' ||
          to_char(r.hora_limite, 'HH24:MI') || ' de hoy.',
        case when rd.rol = 'tienda' then '/tienda' else '/franquicia' end,
        v_autor
      from unnest(array['franquiciado', 'tienda']::public.rol_usuario[]) rd(rol)
      on conflict (origen_clave) do nothing;
      v_recordatorios := v_recordatorios + 1;
    end loop;
  end if;

  -- 2) Cierre pendiente de AYER: hubo movimiento de caja pero nunca se cerro.
  --    Sin movimiento (local sin actividad ese dia) no se marca -evita
  --    ensuciar el tablero con locales simplemente cerrados por descanso.
  for r in
    select a.id as almacen_id, a.nombre
    from public.almacenes a
    where a.activo and a.tipo = 'tienda'
      and exists (
        select 1 from public.franquicia_caja_movimientos m
        where m.almacen_id = a.id and m.fecha = v_ayer
          and m.estado = 'vigente' and m.reversa_de_id is null
      )
      and not exists (
        select 1 from public.franquicia_caja_cierres cc
        where cc.almacen_id = a.id and cc.fecha = v_ayer
      )
  loop
    perform public._crear_novedad_operativa_v154(
      r.almacen_id, 'cierre_pendiente', null, null, v_ayer,
      'El local "' || r.nombre || '" no cerro la caja del ' || v_ayer::text || '.',
      null, 'urgente', null,
      md5('cierre_pendiente:' || r.almacen_id::text || ':' || v_ayer::text)::uuid
    );
    v_cierres_pendientes := v_cierres_pendientes + 1;
  end loop;

  -- 3) Deposito faltante: cierre confirmado con efectivo > 0, de hace mas de
  --    2 dias, sin ningun deposito vigente registrado todavia.
  for r in
    select cc.id as cierre_id, cc.almacen_id, a.nombre, cc.fecha, cc.efectivo_contado
    from public.franquicia_caja_cierres cc
    join public.almacenes a on a.id = cc.almacen_id
    where cc.estado = 'cerrado'
      and cc.efectivo_contado > 0
      and cc.fecha <= v_hoy - 2
      and not exists (
        select 1 from public.caja_depositos_v87 d
        where d.cierre_id = cc.id and d.estado <> 'anulado'
      )
  loop
    perform public._crear_novedad_operativa_v154(
      r.almacen_id, 'deposito_faltante', r.cierre_id, null, r.fecha,
      'El cierre del ' || r.fecha::text || ' en "' || r.nombre ||
        '" tiene ' || r.efectivo_contado::text || ' de efectivo sin depositar.',
      r.efectivo_contado, 'urgente', null,
      md5('deposito_faltante:' || r.cierre_id::text)::uuid
    );
    v_depositos_faltantes := v_depositos_faltantes + 1;
  end loop;

  return jsonb_build_object(
    'recordatorios', v_recordatorios,
    'cierres_pendientes', v_cierres_pendientes,
    'depositos_faltantes', v_depositos_faltantes
  );
end;
$v155$;

alter function public.revisar_operacion_diaria_v155() owner to postgres;
-- Deliberadamente SIN grant a authenticated ni anon: solo se llama con la
-- llave de servicio desde /api/cron/revisar-operacion (mismo patron que
-- reclamar_sincronizaciones_bomansport_v131, que tampoco necesita grant
-- explicito para que el cliente admin la invoque).
revoke all on function public.revisar_operacion_diaria_v155() from public, anon, authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v155', 155, 'v155_alertas_cierre_cron.sql',
  'Revision diaria (cron, 1x/dia por plan Hobby): recordatorio de cierre de hoy + novedades automaticas de cierre pendiente y deposito faltante.'
)
on conflict (id) do update set version=excluded.version, archivo=excluded.archivo,
  notas=excluded.notas, aplicada_at=now();

notify pgrst, 'reload schema';
commit;
