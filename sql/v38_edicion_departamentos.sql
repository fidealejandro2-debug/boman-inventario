-- ============================================================
-- v38 - Edicion robusta de departamentos de nomina
--
-- Al editar, conserva el grupo economico almacenado en el propio
-- departamento. La operacion ya no depende de que la interfaz haya podido
-- consultar la lista de empresas activas.
-- ============================================================

begin;

create or replace function public.guardar_departamento_nomina_v38(
  p_departamento_id uuid,
  p_grupo_id uuid,
  p_codigo text,
  p_nombre text,
  p_descripcion text,
  p_activo boolean,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grupo_id uuid;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'Solo Administracion o Nomina pueden configurar departamentos';
  end if;

  if p_departamento_id is null then
    -- Para un alta sí es obligatorio indicar a qué grupo pertenece.
    v_grupo_id := p_grupo_id;
  else
    -- Para una edición, la base es la fuente de verdad. Así un grupo vacío o
    -- desactualizado en el navegador nunca impide renombrar el departamento
    -- ni permite trasladarlo accidentalmente a otro grupo.
    select d.grupo_id into v_grupo_id
    from public.departamentos_nomina d
    where d.id = p_departamento_id;

    if not found then
      raise exception 'El departamento no existe';
    end if;
  end if;

  return public.guardar_departamento_nomina_v34(
    p_departamento_id,
    v_grupo_id,
    p_codigo,
    p_nombre,
    p_descripcion,
    p_activo,
    p_idempotency_key
  );
end;
$$;

alter function public.guardar_departamento_nomina_v38(
  uuid, uuid, text, text, text, boolean, uuid
) owner to postgres;

revoke all on function public.guardar_departamento_nomina_v38(
  uuid, uuid, text, text, text, boolean, uuid
) from public, anon;
grant execute on function public.guardar_departamento_nomina_v38(
  uuid, uuid, text, text, text, boolean, uuid
) to authenticated;

comment on function public.guardar_departamento_nomina_v38(
  uuid, uuid, text, text, text, boolean, uuid
) is 'Crea departamentos y edita los existentes conservando su grupo economico real.';

commit;
