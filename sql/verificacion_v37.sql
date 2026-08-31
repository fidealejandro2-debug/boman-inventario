-- ============================================================
-- Verificación v37 - Integridad de usuarios y almacenes
-- Solo lectura: ejecutar después de instalar v37.
-- ============================================================

select
  to_regprocedure('public.admin_asignar_almacenes(uuid,uuid[])') is not null
    as asignar_almacenes_ok,
  to_regprocedure(
    'public.admin_guardar_usuario_v37(uuid,text,public.rol_usuario,uuid[],boolean)'
  ) is not null as guardar_atomico_ok;

select
  position(
    '''nomina''' in pg_get_functiondef(
      'public.admin_asignar_almacenes(uuid,uuid[])'::regprocedure
    )
  ) > 0 as nomina_sin_almacen_ok,
  position(
    'admin_asignar_almacenes' in pg_get_functiondef(
      'public.admin_guardar_usuario_v37(uuid,text,public.rol_usuario,uuid[],boolean)'::regprocedure
    )
  ) > 0 as perfil_y_almacenes_atomicos_ok;

select
  has_function_privilege(
    'authenticated',
    'public.admin_guardar_usuario_v37(uuid,text,public.rol_usuario,uuid[],boolean)',
    'execute'
  ) as authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.admin_guardar_usuario_v37(uuid,text,public.rol_usuario,uuid[],boolean)',
    'execute'
  ) as anon_bloqueado_ok;

-- Todos los siguientes resultados deben ser cero.

select count(*) as operativos_activos_sin_almacen_debe_ser_cero
from public.perfiles p
where p.activo
  and p.rol::text not in ('admin', 'control', 'gerencia', 'nomina')
  and not exists (
    select 1 from public.perfil_almacenes pa where pa.perfil_id = p.id
  );

select count(*) as asignaciones_a_almacenes_inactivos_debe_ser_cero
from public.perfil_almacenes pa
left join public.almacenes a on a.id = pa.almacen_id
where a.id is null or not a.activo;

select count(*) as entidad_principal_fuera_de_asignaciones_debe_ser_cero
from public.perfiles p
where p.activo
  and p.rol::text not in ('admin', 'control', 'gerencia', 'nomina')
  and (
    p.entidad_id is null
    or not exists (
      select 1 from public.perfil_almacenes pa
      where pa.perfil_id = p.id and pa.almacen_id = p.entidad_id
    )
  );

select count(*) as roles_globales_con_almacenes_innecesarios_debe_ser_cero
from public.perfil_almacenes pa
join public.perfiles p on p.id = pa.perfil_id
where p.activo and p.rol::text in ('admin', 'control', 'gerencia', 'nomina');

select count(*) as roles_globales_con_entidad_innecesaria_debe_ser_cero
from public.perfiles
where activo
  and rol::text in ('admin', 'control', 'gerencia', 'nomina')
  and entidad_id is not null;

-- Informativo: permite localizar un perfil que hubiese quedado incompleto
-- antes de instalar v37 y asignarle almacenes desde Administración.
select p.id, p.nombre_completo, p.rol, p.activo, p.entidad_id,
       count(pa.almacen_id) as almacenes
from public.perfiles p
left join public.perfil_almacenes pa on pa.perfil_id = p.id
group by p.id, p.nombre_completo, p.rol, p.activo, p.entidad_id
order by p.nombre_completo;
