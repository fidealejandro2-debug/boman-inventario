-- ============================================================
-- BOMAN INVENTARIO - v56: archivar descuentos saldados y decimos en el rol
--
--   1. Un descuento pagado se queda en la lista para siempre y no hay forma de
--      sacarlo. Borrarlo no es opcion: es la prueba de un valor que ya se le
--      retuvo a una persona. Se archiva.
--   2. El rol no dice si los decimos van mensualizados o acumulados, ni cuando
--      se pagan los acumulados. Depende de la region y el trabajador no tiene
--      como saberlo mirando su comprobante.
--
-- Ejecutar despues de v55.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Archivar, que no es borrar
-- ------------------------------------------------------------
alter table public.descuentos_programados
  add column if not exists archivado_at timestamptz,
  add column if not exists archivado_por uuid references public.perfiles(id) on delete restrict,
  add column if not exists motivo_archivo text;

comment on column public.descuentos_programados.archivado_at is
  'Deja de aparecer en la lista activa. El registro y sus cuotas se conservan intactos.';

create or replace function public.archivar_descuento_v56(
  p_descuento_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  d public.descuentos_programados%rowtype;
  v_evento_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede archivar descuentos';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El archivo requiere un motivo de al menos 10 caracteres';
  end if;

  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;

  select * into d from public.descuentos_programados
  where id = p_descuento_id for update;
  if not found then raise exception 'El descuento programado no existe'; end if;
  if d.archivado_at is not null then
    raise exception 'Ese descuento ya estaba archivado';
  end if;

  -- Un descuento con saldo sigue vivo: archivarlo lo escondería de la vista y
  -- las cuotas se seguirian aplicando sin que nadie las mire. Primero se
  -- condona o se suspende, que son decisiones explicitas.
  if d.estado = 'vigente' then
    raise exception
      'No se archiva un descuento vigente. Si ya no se debe cobrar, condonalo o suspendelo; si esta saldado, el sistema lo marca como pagado solo.';
  end if;

  update public.descuentos_programados
  set archivado_at = now(), archivado_por = auth.uid(),
      motivo_archivo = btrim(p_motivo)
  where id = d.id;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, usuario_id, idempotency_key
  ) values (
    'descuento', d.id, d.empleado_id, 'archivado', d.estado, d.estado,
    btrim(p_motivo), auth.uid(), p_idempotency_key
  );

  return jsonb_build_object('id', d.id, 'duplicado', false,
    'mensaje', 'Descuento archivado; sigue en el historial');
end;
$fn$;

-- ------------------------------------------------------------
-- 1.b Anular un descuento que nunca llego a aplicarse
-- ------------------------------------------------------------
-- Caso real: se desembolsa un anticipo y la persona devuelve la plata el mismo
-- mes, antes de que corra el rol. No hay nada que recuperar por nomina, asi que
-- el descuento no debe quedar ni vigente ni "pagado": nunca ocurrio.
--
-- El anticipo desembolsado NO se anula y esta bien que no se pueda: el dinero
-- salio de caja y volvio, y las dos cosas son historia. Lo que se anula es su
-- recuperacion.
create or replace function public.anular_descuento_v56(
  p_descuento_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  d public.descuentos_programados%rowtype;
  v_evento_id uuid;
  v_cuotas integer;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina puede anular descuentos';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La anulacion requiere un motivo de al menos 10 caracteres';
  end if;

  select id into v_evento_id from public.nomina_eventos
  where idempotency_key = p_idempotency_key;
  if found then return jsonb_build_object('evento_id', v_evento_id, 'duplicado', true); end if;

  select * into d from public.descuentos_programados
  where id = p_descuento_id for update;
  if not found then raise exception 'El descuento programado no existe'; end if;
  if d.estado = 'anulado' then raise exception 'Ese descuento ya estaba anulado'; end if;

  -- La linea que no se cruza: si ya se le descontó algo a la persona, ese valor
  -- existio en un rol firmado. Anular aqui lo borraria del control sin
  -- devolverle nada. Primero se revierte la aplicacion, que si mueve el dinero.
  if d.monto_aplicado > 0 then
    raise exception
      'Este descuento ya aplico % en nomina. Revierte primero esa aplicacion con revertir_aplicacion_descuentos_v29 y despues anulalo; si el valor se le quedo retenido, devuelvelo como ingreso en el rol.',
      d.monto_aplicado;
  end if;

  update public.descuentos_programados
  set estado = 'anulado', updated_at = now()
  where id = d.id;

  -- Las cuotas futuras dejan de existir: si quedaran pendientes, el proximo
  -- cierre de nomina intentaria aplicarlas igual.
  update public.descuento_programado_cuotas
  set estado = 'anulada'
  where descuento_programado_id = d.id
    and estado in ('pendiente', 'parcial', 'diferida');
  get diagnostics v_cuotas = row_count;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, usuario_id, idempotency_key
  ) values (
    'descuento', d.id, d.empleado_id, 'anulado', d.estado, 'anulado',
    btrim(p_motivo), auth.uid(), p_idempotency_key
  );

  -- Si venia de un anticipo, queda anotado en el expediente del anticipo: el
  -- desembolso sigue registrado y ahora se sabe por que no se recupero.
  if d.origen = 'anticipo' and d.origen_id is not null then
    insert into public.nomina_eventos(
      entidad, entidad_id, empleado_id, tipo, detalle, usuario_id, idempotency_key
    ) values (
      'anticipo', d.origen_id, d.empleado_id, 'recuperacion_anulada',
      'Se anulo el descuento que recuperaba este anticipo: ' || btrim(p_motivo),
      auth.uid(), gen_random_uuid()
    );
  end if;

  return jsonb_build_object('id', d.id, 'duplicado', false, 'cuotas_anuladas', v_cuotas,
    'mensaje', 'Descuento anulado; se cancelaron ' || v_cuotas || ' cuota(s) pendiente(s)');
end;
$fn$;

-- La lista activa deja de mostrar lo archivado. Se reescribe entera y no con un
-- parche textual porque la vista termina en GROUP BY: pegarle un AND al final
-- seria un error de sintaxis. El historial completo sigue accesible
-- consultando public.descuentos_programados directamente.
create or replace view public.vista_descuentos_programados_v29
with (security_invoker = true) as
select
  d.id, d.grupo_id, d.empleado_id, e.identificacion,
  e.apellidos, e.nombres, d.empresa_acreedora_id,
  ep.razon_social as empresa_acreedora, d.origen, d.categoria_tope,
  d.origen_id, d.descripcion, d.monto_total, d.monto_aplicado,
  d.monto_condonado, d.saldo, d.cuotas_total, d.cuotas_pagadas,
  d.monto_cuota, d.fecha_inicio, d.fecha_fin, d.estado, d.prioridad,
  d.documento_respaldo_id,
  count(c.id) filter (where c.estado in ('pendiente', 'parcial', 'diferida'))
    as cuotas_pendientes,
  min(c.fecha_prevista) filter (where c.saldo > 0) as cuota_pendiente_mas_antigua,
  coalesce(sum(c.saldo) filter (where c.saldo > 0), 0)::numeric(14,2)
    as saldo_cuotas
from public.descuentos_programados d
join public.empleados e on e.id = d.empleado_id
left join public.empresas ep on ep.id = d.empresa_acreedora_id
left join public.descuento_programado_cuotas c on c.descuento_programado_id = d.id
where d.archivado_at is null
group by d.id, e.id, ep.id;

-- ------------------------------------------------------------
-- 2. Region del trabajador y decimos en el comprobante
-- ------------------------------------------------------------
-- El decimo cuarto acumulado se paga hasta el 15 de marzo en la Costa e Insular
-- y hasta el 15 de agosto en Sierra y Amazonia (Codigo del Trabajo, Art. 113).
-- Sin este dato el rol no puede decir cuando le toca cobrarlo a la persona.
alter table public.empleados
  add column if not exists region text
    check (region is null or region in ('sierra', 'costa'));

comment on column public.empleados.region is
  'Determina la fecha de pago del decimo cuarto acumulado: costa 15/03, sierra 15/08.';

-- El rol de impresion gana los datos de beneficios, que ya se calculaban pero
-- no se mostraban en ninguna parte.
create or replace view public.vista_rol_beneficios_v56
with (security_invoker = true) as
select
  l.id as rol_linea_id,
  l.mensualiza_decimo_tercero,
  l.mensualiza_decimo_cuarto,
  coalesce(e.region, 'sierra') as region,
  case when l.mensualiza_decimo_tercero
    then 'Mensualizado: se paga cada mes junto al sueldo'
    else 'Acumulado: se paga hasta el 24 de diciembre'
  end as detalle_decimo_tercero,
  case
    when l.mensualiza_decimo_cuarto
      then 'Mensualizado: se paga cada mes junto al sueldo'
    when coalesce(e.region, 'sierra') = 'costa'
      then 'Acumulado: se paga hasta el 15 de marzo (region Costa e Insular)'
    else 'Acumulado: se paga hasta el 15 de agosto (region Sierra y Amazonia)'
  end as detalle_decimo_cuarto,
  l.provision_decimo_tercero_declarada,
  l.provision_decimo_cuarto_declarada,
  l.decimo_tercero_mensualizado,
  l.decimo_cuarto_mensualizado,
  l.fondos_reserva_pagados,
  -- Lo acumulado en el ano hasta este periodo, que es lo que la persona
  -- pregunta cuando el decimo no le aparece en el rol.
  (
    select coalesce(sum(x.provision_decimo_tercero_declarada), 0)
    from public.nomina_rol_lineas x
    join public.nomina_periodos px on px.id = x.periodo_id
    where x.empleado_id = l.empleado_id and px.anio = p.anio and px.mes <= p.mes
  ) as acumulado_decimo_tercero,
  (
    select coalesce(sum(x.provision_decimo_cuarto_declarada), 0)
    from public.nomina_rol_lineas x
    join public.nomina_periodos px on px.id = x.periodo_id
    where x.empleado_id = l.empleado_id and px.anio = p.anio and px.mes <= p.mes
  ) as acumulado_decimo_cuarto
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empleados e on e.id = l.empleado_id;

alter function public.archivar_descuento_v56(uuid, text, uuid) owner to postgres;
revoke execute on function public.archivar_descuento_v56(uuid, text, uuid) from public, anon;
grant execute on function public.archivar_descuento_v56(uuid, text, uuid) to authenticated;

revoke all on public.vista_rol_beneficios_v56 from public, anon;
grant select on public.vista_rol_beneficios_v56 to authenticated;

alter function public.anular_descuento_v56(uuid, text, uuid) owner to postgres;
revoke execute on function public.anular_descuento_v56(uuid, text, uuid) from public, anon;
grant execute on function public.anular_descuento_v56(uuid, text, uuid) to authenticated;

notify pgrst, 'reload schema';
