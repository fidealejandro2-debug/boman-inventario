-- ============================================================
-- Verificacion v38 - Edicion robusta de departamentos
-- Solo lectura: ejecutar despues de instalar v38.
-- ============================================================

select
  to_regprocedure(
    'public.guardar_departamento_nomina_v38(uuid,uuid,text,text,text,boolean,uuid)'
  ) is not null as guardar_departamento_v38_ok;

select
  position(
    'select d.grupo_id' in lower(pg_get_functiondef(
      'public.guardar_departamento_nomina_v38(uuid,uuid,text,text,text,boolean,uuid)'::regprocedure
    ))
  ) > 0 as edicion_usa_grupo_del_departamento_ok,
  position(
    'guardar_departamento_nomina_v34' in pg_get_functiondef(
      'public.guardar_departamento_nomina_v38(uuid,uuid,text,text,text,boolean,uuid)'::regprocedure
    )
  ) > 0 as conserva_validaciones_y_auditoria_v34_ok;

select
  has_function_privilege(
    'authenticated',
    'public.guardar_departamento_nomina_v38(uuid,uuid,text,text,text,boolean,uuid)',
    'execute'
  ) as authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.guardar_departamento_nomina_v38(uuid,uuid,text,text,text,boolean,uuid)',
    'execute'
  ) as anon_bloqueado_ok;

-- Debe ser cero: ningún departamento puede apuntar a un grupo inexistente.
select count(*) as departamentos_sin_grupo_debe_ser_cero
from public.departamentos_nomina d
left join public.grupos_economicos g on g.id = d.grupo_id
where g.id is null;

-- Informativo: muestra el grupo que v38 utilizará al editar cada registro.
select d.id as departamento_id, d.codigo, d.nombre, d.grupo_id, g.nombre as grupo
from public.departamentos_nomina d
join public.grupos_economicos g on g.id = d.grupo_id
order by d.nombre;
