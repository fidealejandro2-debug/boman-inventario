-- ============================================================
-- Verificacion v62 - Consolidado de franquicias
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v62 y nunca en paralelo con la migracion.
-- ============================================================

select
  exists (
    select 1 from public.permisos_sistema
    where codigo = 'franquicia.consolidado' and activo
  ) as permiso_consolidado_ok,
  to_regprocedure('public.resumen_consolidado_franquicias_v62(date,date)') is not null
    as resumen_consolidado_ok;

select
  has_function_privilege(
    'authenticated',
    'public.resumen_consolidado_franquicias_v62(date,date)', 'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon',
    'public.resumen_consolidado_franquicias_v62(date,date)', 'execute'
  ) as anon_sin_execute_ok;

select
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('franquicia.consolidado' in pg_get_functiondef(p.oid)) > 0
    as valida_permiso,
  position('America/Guayaquil' in pg_get_functiondef(p.oid)) > 0
    as usa_fecha_ecuador
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'resumen_consolidado_franquicias_v62';

-- Debe ser cero. Se valida la fuente sin ejecutar el RPC protegido, para que
-- este archivo siga siendo util en el SQL Editor sin simular una sesion.
select count(*) as franquicias_activas_con_relaciones_invalidas_debe_ser_cero
from public.franquicias f
left join public.empresas e on e.id = f.empresa_id and e.activo
left join public.almacenes a on a.id = f.almacen_id and a.activo
where f.activo and (e.id is null or a.id is null);

select count(*) as almacenes_con_mas_de_una_franquicia_activa_debe_ser_cero
from (
  select almacen_id
  from public.franquicias
  where activo
  group by almacen_id
  having count(*) > 1
) x;

select rol::text, permitido
from public.rol_permisos
where permiso_codigo = 'franquicia.consolidado'
order by rol::text;
