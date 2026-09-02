-- ============================================================
-- BOMAN INVENTARIO - v55: el respaldo del anticipo deja de bloquear
--
-- Aprobar y desembolsar exigian la solicitud firmada adjunta. En la practica el
-- papel se firma despues, asi que el anticipo se quedaba trabado o alguien
-- adjuntaba cualquier archivo para poder avanzar, que es peor: el expediente
-- termina con respaldo falso y nadie sabe cual falta de verdad.
--
-- Ahora el anticipo avanza sin el documento, pero queda marcado como respaldo
-- pendiente y aparece listado hasta que se suba. La obligacion no desaparece,
-- deja de ser un bloqueo y pasa a ser una deuda visible.
--
-- Ejecutar despues de v54.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Se levanta el bloqueo, sin tocar nada mas de las funciones
-- ------------------------------------------------------------
-- Se parchea el texto instalado en vez de reescribir las funciones enteras:
-- son largas y todo lo demas (topes, roles, idempotencia, eventos) debe quedar
-- byte a byte como esta. Misma tecnica que v42 y v50.
do $migra$
declare
  v_oid oid;
  v_def text;
  v_nuevo text;
begin
  -- 1.a Aprobacion
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'resolver_anticipo_v29'
  order by p.oid desc limit 1;
  if v_oid is null then
    raise exception 'No se encontro resolver_anticipo_v29; ejecuta v29 antes que v55';
  end if;
  v_def := pg_get_functiondef(v_oid);

  if position('respaldo pendiente' in v_def) = 0 then
    -- Quita el bloqueo por documento ausente.
    v_nuevo := replace(v_def,
      'if coalesce(p_aprobar, false) and a.documento_respaldo_id is null then
    raise exception ''Adjunta la solicitud o autorizacion firmada antes de aprobar'';
  end if;',
      '-- v55: sin documento se aprueba igual y queda respaldo pendiente.');
    if v_nuevo = v_def then
      raise exception 'No se pudo levantar el bloqueo en resolver_anticipo_v29: el texto cambio de forma';
    end if;

    -- El segundo control validaba que el documento siguiera activo. Con
    -- documento nulo ese "not exists" da verdadero y volveria a bloquear, asi
    -- que solo aplica cuando de verdad hay documento.
    v_def := v_nuevo;
    v_nuevo := replace(v_def,
      'if coalesce(p_aprobar, false) and not exists (',
      'if coalesce(p_aprobar, false) and a.documento_respaldo_id is not null and not exists (');
    if v_nuevo = v_def then
      raise exception 'No se pudo condicionar la validacion de documento en resolver_anticipo_v29';
    end if;
    execute v_nuevo;
  else
    raise notice 'resolver_anticipo_v29 ya estaba actualizada';
  end if;

  -- 1.b Desembolso
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'desembolsar_anticipo_v29'
  order by p.oid desc limit 1;
  if v_oid is null then
    raise exception 'No se encontro desembolsar_anticipo_v29; ejecuta v29 antes que v55';
  end if;
  v_def := pg_get_functiondef(v_oid);

  if position('respaldo pendiente' in v_def) = 0 then
    v_nuevo := replace(v_def,
      'if a.documento_respaldo_id is null then
    raise exception ''El anticipo aprobado no tiene solicitud o autorizacion firmada'';
  end if;',
      '-- v55: se desembolsa igual y queda respaldo pendiente.');
    if v_nuevo = v_def then
      raise exception 'No se pudo levantar el bloqueo en desembolsar_anticipo_v29: el texto cambio de forma';
    end if;
    execute v_nuevo;
  else
    raise notice 'desembolsar_anticipo_v29 ya estaba actualizada';
  end if;
end;
$migra$;

-- ------------------------------------------------------------
-- 2. La deuda documental queda a la vista
-- ------------------------------------------------------------
-- Sin esta lista, quitar el bloqueo seria simplemente perder el respaldo. Aqui
-- vive lo que falta subir, con los dias que lleva pendiente para que se pueda
-- reclamar por antiguedad.
create or replace view public.vista_anticipos_respaldo_pendiente_v55
with (security_invoker = true) as
select
  a.id as anticipo_id,
  a.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as empleado,
  emp.razon_social as empresa_pagadora,
  a.fecha,
  a.monto,
  a.cuotas,
  a.motivo,
  a.estado,
  (current_date - a.fecha) as dias_pendiente,
  case
    when (current_date - a.fecha) >= 30 then 'vencido'
    when (current_date - a.fecha) >= 15 then 'por_vencer'
    else 'reciente'
  end as antiguedad,
  a.aprobado_at,
  a.desembolsado_at,
  sol.nombre_completo as solicitado_por
from public.anticipos a
join public.empleados e on e.id = a.empleado_id
join public.empresas emp on emp.id = a.empresa_pagadora_id
left join public.perfiles sol on sol.id = a.solicitado_por
where a.documento_respaldo_id is null
  and a.estado in ('solicitado', 'aprobado', 'desembolsado');

-- ------------------------------------------------------------
-- 3. Adjuntar el respaldo despues, que es el caso real
-- ------------------------------------------------------------
create or replace function public.adjuntar_respaldo_anticipo_v55(
  p_anticipo_id uuid,
  p_documento_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  a public.anticipos%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'gerencia', 'nomina') then
    raise exception 'No tienes permiso para adjuntar respaldos de anticipos';
  end if;

  select * into a from public.anticipos where id = p_anticipo_id for update;
  if not found then raise exception 'El anticipo no existe'; end if;
  if a.estado = 'anulado' then raise exception 'El anticipo esta anulado'; end if;
  if a.documento_respaldo_id is not null then
    raise exception 'Ese anticipo ya tiene su respaldo adjunto';
  end if;
  if not exists (
    select 1 from public.empleado_documentos d
    where d.id = p_documento_id and d.empleado_id = a.empleado_id and d.activo
  ) then
    raise exception 'El documento no existe, no esta activo o es de otro empleado';
  end if;

  update public.anticipos
  set documento_respaldo_id = p_documento_id,
      version = version + 1, updated_at = now()
  where id = a.id;

  -- El descuento que recupera el anticipo hereda el mismo respaldo, para que el
  -- expediente quede completo por los dos lados.
  if a.descuento_programado_id is not null then
    update public.descuentos_programados
    set documento_respaldo_id = p_documento_id
    where id = a.descuento_programado_id and documento_respaldo_id is null;
  end if;

  insert into public.nomina_eventos(
    entidad, entidad_id, empleado_id, tipo, estado_anterior, estado_nuevo,
    detalle, usuario_id, idempotency_key
  ) values (
    'anticipo', a.id, a.empleado_id, 'respaldo_adjuntado', a.estado, a.estado,
    'Se adjunto el respaldo documental pendiente', auth.uid(), gen_random_uuid()
  );
end;
$fn$;

alter function public.adjuntar_respaldo_anticipo_v55(uuid, uuid) owner to postgres;
revoke execute on function public.adjuntar_respaldo_anticipo_v55(uuid, uuid) from public, anon;
grant execute on function public.adjuntar_respaldo_anticipo_v55(uuid, uuid) to authenticated;

revoke all on public.vista_anticipos_respaldo_pendiente_v55 from public, anon;
grant select on public.vista_anticipos_respaldo_pendiente_v55 to authenticated;

notify pgrst, 'reload schema';
