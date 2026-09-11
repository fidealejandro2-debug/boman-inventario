-- ============================================================
-- BOMAN INVENTARIO - v118: editar los datos comerciales del contrato
--
-- El editor de gestion (v99) solo dejaba tocar planificacion y responsables.
-- Faltaba lo que mas se corrige en la practica: el NOMBRE del contrato, el
-- CLIENTE real, el vendedor y el canal. Sin esto, un contrato mal ingresado
-- se corregia a mano en la hoja o no se corregia.
--
-- Presupuesto y abono NO se agregan aqui, y no es un olvido:
--   * `abono` es un valor DERIVADO (abono_inicial_v100 + abonos aplicados,
--     ver recalcular_abono_contrato_v100). Escribirlo a mano lo dejaria
--     peleado con su propio libro de abonos hasta el siguiente recalculo.
--   * Las dos columnas estan protegidas por trg_proteger_finanzas_contrato_v102,
--     que revierte en silencio cualquier update que no venga con la
--     autorizacion de v100. Un campo suelto aqui no fallaria: no haria nada,
--     que es peor.
-- Para eso ya existe ajustar_finanzas_contrato_v100 (presupuesto + abono
-- inicial, con permiso contratos.finanzas.editar y su propia auditoria). La
-- pantalla lo llama desde el mismo editor; la base no cambia.
--
-- Ejecutar despues de v99, v100 y v115.
-- ============================================================
begin;
select pg_advisory_xact_lock(1181142026);

-- Un mensaje que nombra dos culpables no sirve de nada: hay que ir a buscar
-- cual de los dos es. Cada requisito avisa por separado.
do $$begin
  if to_regprocedure('public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)') is null then
    raise exception 'Falta v99_gestion_contratos.sql (no existe guardar_gestion_contrato_v99). Correla antes de v118';
  end if;
  if to_regprocedure('public.ajustar_finanzas_contrato_v100(uuid,numeric,numeric,text,uuid)') is null then
    raise exception 'Falta v100_abonos_presupuesto_contratos.sql (no existe ajustar_finanzas_contrato_v100). Correla antes de v118';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='contratos'
                    and column_name='nombre_contrato_v115') then
    raise exception 'Falta v115 antes de v118';
  end if;
end$$;

-- v99 con cuatro campos mas. El resto del cuerpo es identico; los agregados
-- van marcados con "v118".
create or replace function public.guardar_gestion_contrato_v99(
  p_contrato_id uuid,
  p_cambios jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $v118$
declare
  v_uid uuid := auth.uid();
  v_antes public.contratos%rowtype;
  v_despues public.contratos%rowtype;
  v_operacion_id uuid;
  v_resultado jsonb;
  v_aplicados jsonb := '{}'::jsonb;
  v_clave text;
  v_quien text;
  v_inicio date;
  v_salida date;
  v_entrega date;
begin
  if v_uid is null then
    raise exception 'Debes iniciar sesion para gestionar contratos';
  end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar') then
    raise exception 'No tienes permiso para editar contratos';
  end if;
  if p_contrato_id is null then raise exception 'Selecciona un contrato'; end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if jsonb_typeof(coalesce(p_cambios, 'null'::jsonb)) <> 'object'
     or p_cambios = '{}'::jsonb then
    raise exception 'Selecciona al menos un cambio';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El motivo debe tener al menos 10 caracteres';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 99));
  select resultado into v_resultado
  from public.contrato_gestion_operaciones_v99
  where idempotency_key = p_idempotency_key;
  if found then return v_resultado; end if;

  for v_clave in select jsonb_object_keys(p_cambios) loop
    if v_clave not in (
      'fecha_inicio_produccion', 'fecha_salida_produccion', 'fecha_entrega',
      'prioridad', 'tipo_contrato', 'estado', 'disenador', 'autor_mockup',
      'observacion', 'maquila', 'orden_dia',
      'muestras_tpu_faltan', 'muestras_dtf_faltan',
      -- v118
      'nombre_contrato_v115', 'cliente', 'vendedor', 'canal'
    ) then
      raise exception 'El campo % no se puede editar desde Gestion de contratos', v_clave;
    end if;
  end loop;

  -- v118: el nombre del contrato y el cliente son NOT NULL y con longitud
  -- minima; vaciarlos desde aqui reventaria el check de la tabla con un
  -- mensaje que nadie entiende.
  if p_cambios ? 'nombre_contrato_v115'
     and length(btrim(coalesce(p_cambios->>'nombre_contrato_v115', ''))) < 2 then
    raise exception 'Escribe el nombre del contrato (minimo 2 caracteres)';
  end if;
  if p_cambios ? 'cliente'
     and length(btrim(coalesce(p_cambios->>'cliente', ''))) < 2 then
    raise exception 'Escribe el nombre del cliente (minimo 2 caracteres)';
  end if;

  select * into v_antes from public.contratos
  where id = p_contrato_id for update;
  if not found then raise exception 'El contrato no existe'; end if;

  if p_cambios ? 'prioridad'
     and coalesce(p_cambios->>'prioridad', '') not in ('Normal', 'Urgente') then
    raise exception 'La prioridad no es valida';
  end if;
  if p_cambios ? 'tipo_contrato'
     and coalesce(p_cambios->>'tipo_contrato', '') not in
       ('Normal', 'Equipo Profesional', 'Mercadería', 'Emergente') then
    raise exception 'El tipo de contrato no es valido';
  end if;
  if p_cambios ? 'estado'
     and coalesce(p_cambios->>'estado', '') not in (
       'Ingresado', 'Por imprimir', 'Impreso', 'Sublimación', 'Cortado',
       'En costura o maquila', 'Estampado', 'Terminado', 'Estampado final',
       'Pendiente entrega', 'Entregado'
     ) then
    raise exception 'El estado de produccion no es valido';
  end if;
  if p_cambios ? 'orden_dia'
     and nullif(btrim(p_cambios->>'orden_dia'), '') is not null
     and (p_cambios->>'orden_dia')::numeric < 0 then
    raise exception 'El orden del dia no puede ser negativo';
  end if;

  v_inicio := case when p_cambios ? 'fecha_inicio_produccion'
    then nullif(p_cambios->>'fecha_inicio_produccion', '')::date
    else v_antes.fecha_inicio_produccion end;
  v_salida := case when p_cambios ? 'fecha_salida_produccion'
    then nullif(p_cambios->>'fecha_salida_produccion', '')::date
    else v_antes.fecha_salida_produccion end;
  v_entrega := case when p_cambios ? 'fecha_entrega'
    then nullif(p_cambios->>'fecha_entrega', '')::date
    else v_antes.fecha_entrega end;
  if v_inicio is not null and v_entrega is not null and v_entrega < v_inicio then
    raise exception 'La entrega no puede ser anterior al inicio de produccion';
  end if;
  if v_inicio is not null and v_salida is not null and v_salida < v_inicio then
    raise exception 'La salida no puede ser anterior al inicio de produccion';
  end if;

  update public.contratos set
    fecha_inicio_produccion = v_inicio,
    fecha_salida_produccion = v_salida,
    fecha_entrega = v_entrega,
    prioridad = case when p_cambios ? 'prioridad' then p_cambios->>'prioridad' else prioridad end,
    tipo_contrato = case when p_cambios ? 'tipo_contrato' then p_cambios->>'tipo_contrato' else tipo_contrato end,
    estado = case when p_cambios ? 'estado' then p_cambios->>'estado' else estado end,
    disenador = case when p_cambios ? 'disenador' then nullif(btrim(p_cambios->>'disenador'), '') else disenador end,
    autor_mockup = case when p_cambios ? 'autor_mockup' then nullif(btrim(p_cambios->>'autor_mockup'), '') else autor_mockup end,
    observacion = case when p_cambios ? 'observacion' then nullif(btrim(p_cambios->>'observacion'), '') else observacion end,
    maquila = case when p_cambios ? 'maquila' then nullif(btrim(p_cambios->>'maquila'), '') else maquila end,
    orden_dia = case when p_cambios ? 'orden_dia' then nullif(btrim(p_cambios->>'orden_dia'), '')::numeric else orden_dia end,
    muestras_tpu_faltan = case when p_cambios ? 'muestras_tpu_faltan' then (p_cambios->>'muestras_tpu_faltan')::boolean else muestras_tpu_faltan end,
    muestras_dtf_faltan = case when p_cambios ? 'muestras_dtf_faltan' then (p_cambios->>'muestras_dtf_faltan')::boolean else muestras_dtf_faltan end,
    -- v118
    nombre_contrato_v115 = case when p_cambios ? 'nombre_contrato_v115' then btrim(p_cambios->>'nombre_contrato_v115') else nombre_contrato_v115 end,
    cliente = case when p_cambios ? 'cliente' then btrim(p_cambios->>'cliente') else cliente end,
    vendedor = case when p_cambios ? 'vendedor' then nullif(btrim(p_cambios->>'vendedor'), '') else vendedor end,
    canal = case when p_cambios ? 'canal' then nullif(btrim(p_cambios->>'canal'), '') else canal end,
    actualizado_por = v_uid
  where id = p_contrato_id
  returning * into v_despues;

  select coalesce(p.nombre_completo, v_uid::text) into v_quien
  from public.perfiles p where p.id = v_uid;

  insert into public.contrato_gestion_operaciones_v99(
    contrato_id, cambios_solicitados, motivo, usuario_id, idempotency_key
  ) values (
    p_contrato_id, p_cambios, btrim(p_motivo), v_uid, p_idempotency_key
  ) returning id into v_operacion_id;

  if v_antes.fecha_inicio_produccion is distinct from v_despues.fecha_inicio_produccion then v_aplicados := v_aplicados || jsonb_build_object('fecha_inicio_produccion', v_despues.fecha_inicio_produccion); end if;
  if v_antes.fecha_salida_produccion is distinct from v_despues.fecha_salida_produccion then v_aplicados := v_aplicados || jsonb_build_object('fecha_salida_produccion', v_despues.fecha_salida_produccion); end if;
  if v_antes.fecha_entrega is distinct from v_despues.fecha_entrega then v_aplicados := v_aplicados || jsonb_build_object('fecha_entrega', v_despues.fecha_entrega); end if;
  if v_antes.prioridad is distinct from v_despues.prioridad then v_aplicados := v_aplicados || jsonb_build_object('prioridad', v_despues.prioridad); end if;
  if v_antes.tipo_contrato is distinct from v_despues.tipo_contrato then v_aplicados := v_aplicados || jsonb_build_object('tipo_contrato', v_despues.tipo_contrato); end if;
  if v_antes.estado is distinct from v_despues.estado then v_aplicados := v_aplicados || jsonb_build_object('estado', v_despues.estado); end if;
  if v_antes.disenador is distinct from v_despues.disenador then v_aplicados := v_aplicados || jsonb_build_object('disenador', v_despues.disenador); end if;
  if v_antes.autor_mockup is distinct from v_despues.autor_mockup then v_aplicados := v_aplicados || jsonb_build_object('autor_mockup', v_despues.autor_mockup); end if;
  if v_antes.observacion is distinct from v_despues.observacion then v_aplicados := v_aplicados || jsonb_build_object('observacion', v_despues.observacion); end if;
  if v_antes.maquila is distinct from v_despues.maquila then v_aplicados := v_aplicados || jsonb_build_object('maquila', v_despues.maquila); end if;
  if v_antes.orden_dia is distinct from v_despues.orden_dia then v_aplicados := v_aplicados || jsonb_build_object('orden_dia', v_despues.orden_dia); end if;
  if v_antes.muestras_tpu_faltan is distinct from v_despues.muestras_tpu_faltan then v_aplicados := v_aplicados || jsonb_build_object('muestras_tpu_faltan', v_despues.muestras_tpu_faltan); end if;
  if v_antes.muestras_dtf_faltan is distinct from v_despues.muestras_dtf_faltan then v_aplicados := v_aplicados || jsonb_build_object('muestras_dtf_faltan', v_despues.muestras_dtf_faltan); end if;
  -- v118
  if v_antes.nombre_contrato_v115 is distinct from v_despues.nombre_contrato_v115 then v_aplicados := v_aplicados || jsonb_build_object('nombre_contrato_v115', v_despues.nombre_contrato_v115); end if;
  if v_antes.cliente is distinct from v_despues.cliente then v_aplicados := v_aplicados || jsonb_build_object('cliente', v_despues.cliente); end if;
  if v_antes.vendedor is distinct from v_despues.vendedor then v_aplicados := v_aplicados || jsonb_build_object('vendedor', v_despues.vendedor); end if;
  if v_antes.canal is distinct from v_despues.canal then v_aplicados := v_aplicados || jsonb_build_object('canal', v_despues.canal); end if;

  if v_aplicados = '{}'::jsonb then
    raise exception 'Los datos enviados no producen ningun cambio';
  end if;

  insert into public.contrato_eventos(
    contrato_id, campo, valor_anterior, valor_nuevo, quien, perfil_id,
    gestion_operacion_id, motivo_gestion_v99
  )
  select p_contrato_id, e.key,
    case e.key
      when 'fecha_inicio_produccion' then v_antes.fecha_inicio_produccion::text
      when 'fecha_salida_produccion' then v_antes.fecha_salida_produccion::text
      when 'fecha_entrega' then v_antes.fecha_entrega::text
      when 'prioridad' then v_antes.prioridad
      when 'tipo_contrato' then v_antes.tipo_contrato
      when 'estado' then v_antes.estado
      when 'disenador' then v_antes.disenador
      when 'autor_mockup' then v_antes.autor_mockup
      when 'observacion' then v_antes.observacion
      when 'maquila' then v_antes.maquila
      when 'orden_dia' then v_antes.orden_dia::text
      when 'muestras_tpu_faltan' then v_antes.muestras_tpu_faltan::text
      when 'muestras_dtf_faltan' then v_antes.muestras_dtf_faltan::text
      -- v118
      when 'nombre_contrato_v115' then v_antes.nombre_contrato_v115
      when 'cliente' then v_antes.cliente
      when 'vendedor' then v_antes.vendedor
      when 'canal' then v_antes.canal
    end,
    case when e.value = 'null'::jsonb then null
         when jsonb_typeof(e.value) = 'string' then e.value #>> '{}'
         else e.value::text end,
    v_quien, v_uid, v_operacion_id, btrim(p_motivo)
  from jsonb_each(v_aplicados) e;

  v_resultado := jsonb_build_object(
    'duplicado', false, 'operacion_id', v_operacion_id,
    'contrato_id', p_contrato_id, 'cambios', v_aplicados,
    'updated_at', v_despues.updated_at
  );
  update public.contrato_gestion_operaciones_v99
  set cambios_aplicados = v_aplicados, resultado = v_resultado
  where id = v_operacion_id;
  return v_resultado;
end;
$v118$;

alter function public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid) owner to postgres;
revoke all on function public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid) from public, anon;
grant execute on function public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid) to authenticated;

commit;
