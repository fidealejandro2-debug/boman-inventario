-- ============================================================
-- BOMAN INVENTARIO - v85: recuperar un conteo tras toma de control
--
-- Bug reportado: cuando un admin toma el control de un conteo fisico de
-- una tienda propia (para revisar o intervenir), el vendedor original
-- queda bloqueado para siempre - "Asignado a otro usuario" sin boton,
-- porque abrir_edicion_conteo_v22 solo permite forzar la reasignacion si
-- quien llama tiene rol admin. No existia ningun camino para devolver el
-- conteo a quien realmente lo esta contando.
--
-- Fix: se permite forzar la reasignacion tambien cuando el RESPONSABLE
-- ACTUAL es admin/control (es decir, recuperar un conteo que un admin
-- tomo), siempre que quien reclama tenga acceso al almacen (ya exigido
-- antes en la funcion) y registre un motivo (igual que hoy). Esto NO abre
-- la puerta a robarle el conteo a un companero: si el responsable actual
-- es tienda/bodega/franquiciado/vendedor_franquicia, solo admin puede
-- forzar, exactamente como antes.
--
-- Ejecutar despues de v82.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.abrir_edicion_conteo_v22(uuid,boolean,text)') is null then
    raise exception 'Falta v22/v82. Instalalos antes de v85';
  end if;
end $$;

create or replace function public.abrir_edicion_conteo_v22(
  p_documento_id uuid,
  p_forzar boolean default false,
  p_motivo text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.documentos_inventario%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_responsable_id uuid;
  v_responsable_nombre text;
  v_responsable_rol text;
  v_version integer;
  v_forzado boolean := false;
begin
  if v_rol not in ('admin', 'control', 'bodega', 'tienda', 'franquiciado', 'vendedor_franquicia') then
    raise exception 'No tienes permiso para editar conteos';
  end if;

  select * into d
  from public.documentos_inventario
  where id = p_documento_id
  for update;

  if not found or d.tipo <> 'conteo' or d.estado <> 'en_conteo' then
    raise exception 'El conteo no esta abierto';
  end if;
  if not public.usuario_puede_almacen(d.origen_id, true) then
    raise exception 'No tienes permiso sobre el almacen';
  end if;

  v_responsable_id := coalesce(d.conteo_responsable_id, d.creado_por);
  select nombre_completo, rol::text into v_responsable_nombre, v_responsable_rol
  from public.perfiles where id = v_responsable_id;

  if v_responsable_id is distinct from auth.uid() then
    -- Admin siempre puede forzar. Quien no es admin tambien puede forzar
    -- si el responsable actual es admin/control: es recuperar un conteo
    -- que quedo tomado por una intervencion administrativa, no quitarselo
    -- a un companero.
    if not coalesce(p_forzar, false)
       or (v_rol <> 'admin' and coalesce(v_responsable_rol, '') not in ('admin', 'control')) then
      raise exception 'Conteo asignado a %. Solicita al administrador que tome el control.',
        coalesce(v_responsable_nombre, 'otro usuario');
    end if;
    if btrim(coalesce(p_motivo, '')) = '' then
      raise exception 'La toma de control requiere un motivo';
    end if;

    update public.documentos_inventario
    set conteo_responsable_id = auth.uid(),
        conteo_actividad_at = now(),
        updated_at = now(),
        version = version + 1
    where id = d.id
    returning version into v_version;

    insert into public.conteo_responsable_eventos (
      documento_id, responsable_anterior_id, responsable_nuevo_id,
      motivo, realizado_por
    ) values (
      d.id, v_responsable_id, auth.uid(), btrim(p_motivo), auth.uid()
    );

    perform public.registrar_evento_documento(
      d.id, 'en_conteo', 'en_conteo',
      'Toma de control administrativa. Responsable anterior: '
        || coalesce(v_responsable_nombre, v_responsable_id::text)
        || '. Motivo: ' || btrim(p_motivo)
    );
    v_forzado := true;
  else
    update public.documentos_inventario
    set conteo_responsable_id = auth.uid(), conteo_actividad_at = now()
    where id = d.id
    returning version into v_version;
  end if;

  select nombre_completo into v_responsable_nombre
  from public.perfiles where id = auth.uid();

  return jsonb_build_object(
    'documento_id', d.id,
    'version', v_version,
    'responsable_id', auth.uid(),
    'responsable_nombre', v_responsable_nombre,
    'actividad_at', now(),
    'toma_control', v_forzado
  );
end;
$$;

alter function public.abrir_edicion_conteo_v22(uuid, boolean, text) owner to postgres;

revoke execute on function public.abrir_edicion_conteo_v22(uuid, boolean, text)
  from public, anon;
grant execute on function public.abrir_edicion_conteo_v22(uuid, boolean, text)
  to authenticated;

commit;

notify pgrst, 'reload schema';
