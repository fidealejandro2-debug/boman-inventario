-- ============================================================
-- Verificacion v130 - Rol Produccion
-- Solo lectura. Ejecutar despues de los pasos 1 y 2 de v130.
-- ============================================================

select exists (
  select 1
  from pg_enum e
  join pg_type t on t.oid = e.enumtypid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'rol_usuario'
    and e.enumlabel = 'produccion'
) as rol_produccion_ok;

select
  count(*) filter (where rp.permiso_codigo is not null) =
    count(*) filter (where ps.activo) as matriz_completa_ok,
  bool_and(
    case when ps.codigo in (
      'produccion.acceder', 'produccion.calidad.registrar',
      'contratos.marcar_etapa', 'notificaciones.acceder'
    ) then coalesce(rp.permitido, false)
    else not coalesce(rp.permitido, false)
    end
  ) filter (where ps.activo) as minimo_privilegio_ok
from public.permisos_sistema ps
left join public.rol_permisos rp
  on rp.permiso_codigo = ps.codigo and rp.rol::text = 'produccion';

select count(*) = (select count(*) from public.permisos_sistema where activo)
  as vista_muestra_matriz_completa_ok
from public.vista_matriz_permisos_v35
where rol = 'produccion';

select permiso_codigo, permitido
from public.vista_matriz_permisos_v35
where rol = 'produccion' and permitido
order by orden;

-- Deben ser cero: ningun usuario Produccion queda activo sin alcance de
-- almacen. El almacen determina las empresas/ordenes que puede consultar.
select count(*) as usuarios_produccion_sin_almacen_debe_ser_cero
from public.perfiles p
where p.rol::text = 'produccion' and p.activo
  and not exists (
    select 1 from public.perfil_almacenes pa where pa.perfil_id = p.id
  );

