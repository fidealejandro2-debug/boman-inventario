-- ============================================================
-- BOMAN INVENTARIO - v57: la alerta de cierre de caja deja de ser ruido
--
-- El panel avisaba "Cierre de caja pendiente" contando los locales que no
-- tenian cierre con fecha de HOY, sin mirar nada mas. Tres problemas:
--
--   1. Un local sin una sola venta ni movimiento no tiene nada que conciliar.
--      Latacunga, recien creada y sin operar, disparaba la alerta igual.
--   2. El dia en curso no esta "pendiente", esta corriendo. A las 9 de la
--      manana nadie puede cerrar la caja del dia.
--   3. Le salia a cualquiera con permiso de caja, incluido Admin. Pero
--      cerrar_caja_franquicia_v49 exige rol franquiciado: al administrador se
--      le pedia una tarea que el sistema no le deja hacer.
--
-- Una alerta que aparece sin que haya nada que hacer entrena a ignorar todas
-- las demas. Ahora cuenta dias con movimiento real, ya terminados, y solo a
-- quien puede cerrarlos.
--
-- Ejecutar despues de v56.
-- ============================================================

do $migra$
declare
  v_oid oid;
  v_def text;
  v_nuevo text;
  v_viejo text;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'resumen_panel_principal_v51'
  order by p.oid desc limit 1;
  if v_oid is null then
    raise exception 'No se encontro resumen_panel_principal_v51; ejecuta v51 antes que v57';
  end if;
  v_def := pg_get_functiondef(v_oid);

  if position('dias_con_movimiento' in v_def) > 0 then
    raise notice 'La alerta de cierre ya estaba corregida';
    return;
  end if;

  v_viejo :=
'        when public.usuario_tiene_permiso_v35(''franquicia.caja'') then (
          select count(*)
          from accesibles f
          where not exists (
            select 1 from public.franquicia_caja_cierres c
            where c.franquicia_id = f.id and c.fecha = v_hoy and c.estado = ''cerrado''
          )
        ) else 0 end';

  v_nuevo :=
'        when v_rol = ''franquiciado''
             and public.usuario_tiene_permiso_v35(''franquicia.caja'') then (
          -- dias_con_movimiento: solo se cuenta un dia que de verdad tuvo caja
          -- y que ya termino. El dia en curso no es un pendiente.
          select count(*)
          from (
            select distinct m.franquicia_id, m.fecha
            from public.franquicia_caja_movimientos m
            join accesibles f on f.id = m.franquicia_id
            where m.estado = ''vigente'' and m.reversa_de_id is null
              and m.fecha < v_hoy
              and m.fecha >= v_hoy - 60
          ) dias_con_movimiento
          where not exists (
            select 1 from public.franquicia_caja_cierres c
            where c.franquicia_id = dias_con_movimiento.franquicia_id
              and c.fecha = dias_con_movimiento.fecha
              and c.estado = ''cerrado''
          )
        ) else 0 end';

  if position(v_viejo in v_def) = 0 then
    raise exception
      'No se pudo corregir la alerta de cierre: el bloque de cierres_pendientes_hoy cambio de forma en resumen_panel_principal_v51';
  end if;

  v_nuevo := replace(v_def, v_viejo, v_nuevo);
  execute v_nuevo;
end;
$migra$;

-- Para quien supervisa, el estado de los cierres es informacion, no una tarea
-- suya: no puede cerrar la caja de un local. Va como consulta aparte.
create or replace view public.vista_cierres_pendientes_v57
with (security_invoker = true) as
select
  f.id as franquicia_id,
  f.nombre as franquicia,
  d.fecha,
  ((now() at time zone 'America/Guayaquil')::date - d.fecha) as dias_sin_cerrar,
  d.movimientos,
  d.ingresos_efectivo,
  d.egresos_efectivo
from public.franquicias f
join lateral (
  select m.fecha,
         count(*) as movimientos,
         coalesce(sum(m.monto) filter (where m.tipo = 'ingreso' and m.medio_pago = 'efectivo'), 0) as ingresos_efectivo,
         coalesce(sum(m.monto) filter (where m.tipo = 'egreso' and m.medio_pago = 'efectivo'), 0) as egresos_efectivo
  from public.franquicia_caja_movimientos m
  where m.franquicia_id = f.id
    and m.estado = 'vigente' and m.reversa_de_id is null
    and m.fecha < (now() at time zone 'America/Guayaquil')::date
  group by m.fecha
) d on true
where f.activo
  and not exists (
    select 1 from public.franquicia_caja_cierres c
    where c.franquicia_id = f.id and c.fecha = d.fecha and c.estado = 'cerrado'
  );

revoke all on public.vista_cierres_pendientes_v57 from public, anon;
grant select on public.vista_cierres_pendientes_v57 to authenticated;

notify pgrst, 'reload schema';
