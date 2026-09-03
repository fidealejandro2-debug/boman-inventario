-- ============================================================
-- BOMAN INVENTARIO - v76: los decimos se calculan solo para afiliados
--
-- Decision del negocio: hay personal que prefiere que no se le descuente el
-- IESS y cobrar mas. En ese arreglo el sueldo real ya viene inflado porque
-- absorbe los beneficios, asi que calcular ademas el decimo tercero y cuarto
-- sobre ese mismo sueldo seria pagar dos veces lo mismo.
--
-- Hasta ahora calcular_rol_v30 solo exigia afiliacion para los valores
-- DECLARADOS; los valores REALES del decimo se calculaban para todos. Aqui se
-- agrega la misma condicion a los cuatro casos del rol real: decimo tercero y
-- cuarto, tanto mensualizados como provisionados.
--
-- Los fondos de reserva NO se tocan: ya exigian afiliacion y un ano cumplido,
-- que es lo correcto (Art. 196 del Codigo del Trabajo, sobre la relacion con
-- el IESS).
--
-- ADVERTENCIA REGISTRADA: el decimo tercero y el decimo cuarto son derechos de
-- todo trabajador segun los Art. 111 y 113 del Codigo del Trabajo, con
-- independencia de la afiliacion al IESS. Este cambio responde a que el sueldo
-- real acordado ya los incluye. La defensa de ese criterio depende de poder
-- probar el acuerdo, asi que conviene conservar el respaldo firmado y el
-- motivo registrado en empleado_afiliaciones.
--
-- Las vacaciones (v_prov_vac) se mantienen para todos a proposito: son otro
-- beneficio (Art. 69) y nadie pidio cambiarlas.
--
-- Ejecutar despues de v75.
-- ============================================================

-- Mismo criterio de v41 al parchear esta misma funcion: se cuenta cuantas
-- veces aparece el texto viejo y el nuevo, para poder distinguir tres casos:
-- pendiente (se aplica), ya aplicado (no se toca nada y se puede reejecutar
-- el archivo sin miedo) y a medias (se aborta, porque un rol con la mitad de
-- las lineas parchadas pagaria mal).
do $migra$
declare
  v_oid oid;
  v_def text;
  v_nuevo text;
  v_viejos text[] := array[
    -- 1. Decimo tercero mensualizado del rol real.
    'v_d13_real := case when l.mensualiza_decimo_tercero',
    -- 2. Decimo cuarto mensualizado del rol real.
    'v_d14_real := case when l.mensualiza_decimo_cuarto',
    -- 3 y 4. Provisiones: la condicion se invierte, porque sin afiliacion no
    -- se mensualiza NI se acumula. Queda igual a como v30 ya trata las
    -- provisiones declaradas (v_prov_d13_declarada).
    'v_prov_d13 := case when l.mensualiza_decimo_tercero then 0',
    'v_prov_d14 := case when l.mensualiza_decimo_cuarto then 0'
  ];
  v_nuevos text[] := array[
    'v_d13_real := case when l.afiliado and l.mensualiza_decimo_tercero',
    'v_d14_real := case when l.afiliado and l.mensualiza_decimo_cuarto',
    'v_prov_d13 := case when not l.afiliado or l.mensualiza_decimo_tercero then 0',
    'v_prov_d14 := case when not l.afiliado or l.mensualiza_decimo_cuarto then 0'
  ];
  i integer;
  v_n_viejo integer;
  v_n_nuevo integer;
  v_pendientes integer := 0;
  v_aplicadas integer := 0;
begin
  select p.oid into v_oid
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'calcular_rol_v30'
    and pg_catalog.pg_get_function_identity_arguments(p.oid)
        = 'p_periodo_id uuid, p_idempotency_key uuid';
  if v_oid is null then
    raise exception 'No existe calcular_rol_v30(uuid,uuid); instala v30 antes de v76';
  end if;

  v_def := pg_catalog.pg_get_functiondef(v_oid);

  for i in 1 .. array_length(v_viejos, 1) loop
    v_n_viejo := (length(v_def) - length(replace(v_def, v_viejos[i], '')))
                 / length(v_viejos[i]);
    v_n_nuevo := (length(v_def) - length(replace(v_def, v_nuevos[i], '')))
                 / length(v_nuevos[i]);
    if v_n_viejo = 1 and v_n_nuevo = 0 then
      v_pendientes := v_pendientes + 1;
    elsif v_n_viejo = 0 and v_n_nuevo = 1 then
      v_aplicadas := v_aplicadas + 1;
    else
      raise exception
        'v76: la linea % de decimos no calza (viejas=%, nuevas=%). calcular_rol_v30 cambio de forma; revisar a mano',
        i, v_n_viejo, v_n_nuevo;
    end if;
  end loop;

  if v_pendientes = 0 then
    raise notice 'v76 ya estaba aplicado: calcular_rol_v30 no se modifico';
    return;
  end if;

  if v_aplicadas > 0 then
    raise exception
      'v76: % lineas ya aplicadas y % pendientes. La funcion quedo a medias de una corrida anterior; revisar a mano antes de continuar',
      v_aplicadas, v_pendientes;
  end if;

  v_nuevo := v_def;
  for i in 1 .. array_length(v_viejos, 1) loop
    v_nuevo := replace(v_nuevo, v_viejos[i], v_nuevos[i]);
  end loop;
  execute v_nuevo;
end;
$migra$;

notify pgrst, 'reload schema';
