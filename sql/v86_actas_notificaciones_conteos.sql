-- ============================================================
-- BOMAN INVENTARIO - v86: actas y avisos de conteos fisicos
-- Ejecutar despues de v85.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.resolver_conteo_inventario(uuid,boolean,text)') is null
     or to_regclass('public.notificaciones_comunicados') is null then
    raise exception 'Faltan v53/v85. Instalalas antes de v86';
  end if;
end $$;

-- Resumen estable para imprimir y auditar el acta sin recalcularla en cada UI.
create or replace view public.vista_actas_conteos_v86
with (security_invoker = true)
as
select
  d.id as documento_id,
  d.numero,
  d.origen_id as almacen_id,
  a.nombre as almacen,
  d.estado,
  d.created_at as iniciado_at,
  d.aprobado_at,
  d.aplicado_at,
  d.nota,
  d.creado_por,
  creador.nombre_completo as creado_por_nombre,
  d.revisado_por,
  revisor.nombre_completo as revisado_por_nombre,
  d.aprobado_por,
  aprobador.nombre_completo as aprobado_por_nombre,
  count(l.id)::integer as lineas_total,
  count(l.id) filter (
    where coalesce(l.stock_sistema, 0) <> 0
       or coalesce(l.cantidad_reconteo, l.cantidad_contada, 0) <> 0
  )::integer as lineas_relevantes,
  count(l.id) filter (
    where l.cantidad_contada is distinct from l.stock_sistema
  )::integer as diferencias_primer_conteo,
  count(l.id) filter (
    where coalesce(l.cantidad_reconteo, l.cantidad_contada)
      is distinct from l.stock_sistema
  )::integer as diferencias_finales,
  coalesce(sum(greatest(
    coalesce(l.cantidad_reconteo, l.cantidad_contada, l.stock_sistema, 0)
      - coalesce(l.stock_sistema, 0), 0
  )), 0)::bigint as unidades_incrementadas,
  coalesce(sum(greatest(
    coalesce(l.stock_sistema, 0)
      - coalesce(l.cantidad_reconteo, l.cantidad_contada, l.stock_sistema, 0), 0
  )), 0)::bigint as unidades_disminuidas
from public.documentos_inventario d
join public.almacenes a on a.id = d.origen_id
left join public.documento_inventario_lineas l on l.documento_id = d.id
left join public.perfiles creador on creador.id = d.creado_por
left join public.perfiles revisor on revisor.id = d.revisado_por
left join public.perfiles aprobador on aprobador.id = d.aprobado_por
where d.tipo = 'conteo'
group by d.id, a.nombre, creador.nombre_completo,
  revisor.nombre_completo, aprobador.nombre_completo;

comment on view public.vista_actas_conteos_v86 is
  'Cabecera auditable del acta de conteo: responsables, diferencias y ajustes finales.';

-- Al aplicar se avisa a administracion/control; al devolver se avisa a quien
-- inicio el conteo. La clave incluye la version para admitir ciclos legitimos
-- de rechazo y nueva revision sin duplicar un mismo evento.
create or replace function public.notificar_resolucion_conteo_v86()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_almacen text;
  v_href text;
  v_actor uuid := coalesce(auth.uid(), new.aprobado_por, new.revisado_por, new.creado_por);
  v_rol public.rol_usuario;
begin
  if new.tipo <> 'conteo'
     or old.estado <> 'pendiente_revision'
     or new.estado not in ('aplicado', 'en_conteo') then
    return new;
  end if;

  select a.nombre into v_almacen
  from public.almacenes a where a.id = new.origen_id;
  select case when exists (
    select 1 from public.franquicias f
    where f.almacen_id = new.origen_id and f.activo
  ) then '/franquicia' else '/conteos' end into v_href;

  if new.estado = 'aplicado' then
    foreach v_rol in array array['admin', 'control']::public.rol_usuario[] loop
      insert into public.notificaciones_comunicados (
        origen_clave, origen_tipo, almacen_id, rol_destino,
        modulo, nivel, titulo, mensaje, href, creado_por
      ) values (
        'conteo:aplicado:' || new.id::text || ':v' || new.version::text || ':' || v_rol::text,
        'conteo', new.origen_id, v_rol,
        'Inventario', 'informativa', 'Conteo fisico aprobado',
        new.numero || ' de ' || coalesce(v_almacen, 'almacen') ||
          ' fue aprobado y sus diferencias se aplicaron al inventario.',
        '/conteos', v_actor
      ) on conflict (origen_clave) do nothing;
    end loop;
  else
    insert into public.notificaciones_comunicados (
      origen_clave, origen_tipo, almacen_id, usuario_destino_id,
      modulo, nivel, titulo, mensaje, href, creado_por
    ) values (
      'conteo:devuelto:' || new.id::text || ':v' || new.version::text,
      'conteo', new.origen_id, new.creado_por,
      'Inventario', 'accion', 'Conteo devuelto para correccion',
      new.numero || ' de ' || coalesce(v_almacen, 'almacen') ||
        ' debe contarse nuevamente. Revisa la resolucion registrada.',
      v_href, v_actor
    ) on conflict (origen_clave) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notificar_resolucion_conteo_v86
  on public.documentos_inventario;
create trigger trg_notificar_resolucion_conteo_v86
after update of estado on public.documentos_inventario
for each row execute function public.notificar_resolucion_conteo_v86();

alter view public.vista_actas_conteos_v86 owner to postgres;
alter function public.notificar_resolucion_conteo_v86() owner to postgres;

revoke all on public.vista_actas_conteos_v86 from public, anon;
grant select on public.vista_actas_conteos_v86 to authenticated;
revoke execute on function public.notificar_resolucion_conteo_v86()
  from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';
