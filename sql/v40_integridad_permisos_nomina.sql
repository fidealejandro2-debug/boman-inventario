-- ============================================================
-- v40 - Integridad de permisos y vinculos de nomina
--
-- Corrige dos brechas detectadas al revisar v32-v39:
--   1. La lectura de empresas debe seguir el permiso configurable
--      nomina.acceder de v35, no el nombre fijo del rol.
--   2. Una compensacion o afiliacion no puede enlazar una empresa de otro
--      grupo ni un documento perteneciente a otra persona.
--
-- Ejecutar una sola vez DESPUES de v39.
-- ============================================================

begin;

-- Mantiene intactas las reglas operativas de v18/v39. Solo reemplaza la
-- excepcion de lectura fija por el permiso que realmente gobierna Nomina.
create or replace function public.usuario_puede_empresa(
  p_empresa_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_empresa_id is not null and exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text in ('admin', 'control')
        or (not p_escritura and public.usuario_puede_nomina(false))
        or exists (
          select 1
          from public.perfil_empresas pe
          where pe.perfil_id = p.id
            and pe.empresa_id = p_empresa_id
            and (not p_escritura or pe.puede_operar)
        )
        or exists (
          select 1
          from public.empresa_almacenes ea
          where ea.empresa_id = p_empresa_id
            and public.usuario_puede_almacen(ea.almacen_id, p_escritura)
        )
      )
  );
$$;

alter function public.usuario_puede_empresa(uuid, boolean) owner to postgres;
revoke execute on function public.usuario_puede_empresa(uuid, boolean)
  from public, anon;
grant execute on function public.usuario_puede_empresa(uuid, boolean)
  to authenticated;

comment on function public.usuario_puede_empresa(uuid, boolean) is
  'Acceso por empresa. La lectura global de Nomina sigue nomina.acceder; la escritura conserva las asignaciones operativas.';

-- v30 almacenaba los porcentajes de IECE y SECAP, pero no los llevaba al
-- costo del empleador. Se conservan separados del aporte patronal IESS para
-- que la planilla no mezcle conceptos distintos.
alter table public.nomina_rol_lineas
  add column if not exists aporte_iece numeric(14,2) not null default 0
    check (aporte_iece >= 0),
  add column if not exists aporte_secap numeric(14,2) not null default 0
    check (aporte_secap >= 0);

create or replace function public.calcular_aportes_capacitacion_v40()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_iece numeric;
  v_secap numeric;
begin
  -- La reapertura de v30 limpia calculado_at y todos los totales. Estos dos
  -- rubros nuevos deben seguir el mismo ciclo.
  if new.calculado_at is null then
    new.aporte_iece := 0;
    new.aporte_secap := 0;
    return new;
  end if;

  select prm.pct_iece, prm.pct_secap
  into v_iece, v_secap
  from public.nomina_periodos p
  join public.nomina_parametros prm on prm.anio = p.anio
  where p.id = new.periodo_id;

  if not found then
    raise exception 'No se encontraron parametros para calcular IECE y SECAP';
  end if;

  new.aporte_iece := round(new.base_aportacion_declarada * v_iece / 100, 2);
  new.aporte_secap := round(new.base_aportacion_declarada * v_secap / 100, 2);

  -- v30 entrega ambos costos sin estos conceptos. Al restar los valores
  -- anteriores, la operacion tambien es segura si calculado_at se actualiza
  -- mas de una vez sobre la misma fila.
  new.costo_empleador_real := round(
    new.costo_empleador_real
      - coalesce(old.aporte_iece, 0) - coalesce(old.aporte_secap, 0)
      + new.aporte_iece + new.aporte_secap,
    2
  );
  new.costo_empleador_declarado := round(
    new.costo_empleador_declarado
      - coalesce(old.aporte_iece, 0) - coalesce(old.aporte_secap, 0)
      + new.aporte_iece + new.aporte_secap,
    2
  );
  return new;
end;
$$;

alter function public.calcular_aportes_capacitacion_v40() owner to postgres;
revoke all on function public.calcular_aportes_capacitacion_v40()
  from public, anon, authenticated;

drop trigger if exists trg_aportes_capacitacion_v40
  on public.nomina_rol_lineas;
create trigger trg_aportes_capacitacion_v40
  before update of calculado_at
  on public.nomina_rol_lineas
  for each row execute function public.calcular_aportes_capacitacion_v40();

-- Defensa en profundidad para todos los RPC presentes y futuros. La FK por
-- si sola solo comprueba que empresa/documento existan, no que correspondan
-- al mismo grupo y a la misma persona.
create or replace function public.validar_integridad_vinculo_nomina_v40()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grupo_id uuid;
  v_empresa_id uuid;
  v_documento_id uuid;
begin
  select e.grupo_id into v_grupo_id
  from public.empleados e
  where e.id = new.empleado_id;

  if not found then
    raise exception 'La persona vinculada no existe';
  end if;

  if tg_table_name = 'empleado_compensacion' then
    v_empresa_id := new.empresa_pagadora_id;
  elsif tg_table_name = 'empleado_afiliaciones' then
    v_empresa_id := new.empresa_id;
  else
    raise exception 'Tabla no soportada por el control de integridad de nomina';
  end if;

  if v_empresa_id is not null and not exists (
    select 1
    from public.empresas ep
    where ep.id = v_empresa_id
      and ep.grupo_id = v_grupo_id
      and ep.activo
  ) then
    raise exception 'La empresa debe estar activa y pertenecer al mismo grupo economico que la persona';
  end if;

  v_documento_id := new.documento_respaldo_id;
  if v_documento_id is not null and not exists (
    select 1
    from public.empleado_documentos d
    where d.id = v_documento_id
      and d.empleado_id = new.empleado_id
      and d.activo
  ) then
    raise exception 'El documento de respaldo debe estar activo y pertenecer a la misma persona';
  end if;

  return new;
end;
$$;

alter function public.validar_integridad_vinculo_nomina_v40() owner to postgres;
revoke all on function public.validar_integridad_vinculo_nomina_v40()
  from public, anon, authenticated;

drop trigger if exists trg_integridad_compensacion_v40
  on public.empleado_compensacion;
create trigger trg_integridad_compensacion_v40
  before insert or update of empleado_id, empresa_pagadora_id, documento_respaldo_id
  on public.empleado_compensacion
  for each row execute function public.validar_integridad_vinculo_nomina_v40();

drop trigger if exists trg_integridad_afiliacion_v40
  on public.empleado_afiliaciones;
create trigger trg_integridad_afiliacion_v40
  before insert or update of empleado_id, afiliado, empresa_id, documento_respaldo_id
  on public.empleado_afiliaciones
  for each row execute function public.validar_integridad_vinculo_nomina_v40();

commit;

notify pgrst, 'reload schema';
