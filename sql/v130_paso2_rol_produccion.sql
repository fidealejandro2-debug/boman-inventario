-- ============================================================
-- BOMAN INVENTARIO - v130 / PASO 2
-- Matriz inicial y alcance del rol Produccion.
-- Ejecutar como consulta nueva despues de confirmar el PASO 1.
-- ============================================================

begin;
select pg_advisory_xact_lock(13009112026);

do $v130_requisitos$
begin
  if not exists (
    select 1
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'rol_usuario'
      and e.enumlabel = 'produccion'
  ) then
    raise exception 'Ejecuta y confirma primero v130_paso1_rol_produccion.sql';
  end if;
  if to_regclass('public.permisos_sistema') is null
     or to_regclass('public.rol_permisos') is null then
    raise exception 'Falta instalar la matriz de permisos v35';
  end if;
end;
$v130_requisitos$;

-- La matriz queda completa para que Administracion pueda modificar despues
-- cualquier permiso del rol desde el panel, sin filas faltantes.
insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text = 'produccion' and p.activo
on conflict (rol, permiso_codigo) do nothing;

-- Perfil inicial de minimo privilegio: operacion diaria de planta, sin
-- edicion comercial, costos, cobros, descuentos ni cierres administrativos.
update public.rol_permisos
set permitido = permiso_codigo in (
      'produccion.acceder',
      'produccion.calidad.registrar',
      'contratos.marcar_etapa',
      'notificaciones.acceder'
    ),
    updated_at = now()
where rol::text = 'produccion';

-- La ultima definicion de la vista debe descubrir los roles desde el enum;
-- asi Produccion aparece tambien en Administracion > Permisos por rol.
create or replace view public.vista_matriz_permisos_v35
with (security_invoker = true) as
select
  r.rol::text as rol,
  ps.codigo as permiso_codigo,
  ps.modulo,
  ps.nombre,
  ps.descripcion,
  ps.orden,
  case when r.rol::text = 'admin' then true else coalesce(rp.permitido, false) end
    as permitido,
  r.rol::text <> 'admin' as configurable,
  rp.updated_at
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema ps
left join public.rol_permisos rp
  on rp.rol = r.rol and rp.permiso_codigo = ps.codigo
where ps.activo;

comment on view public.vista_matriz_permisos_v35 is
  'Matriz dinamica de permisos por rol; v130 incorpora el rol Produccion.';

commit;

