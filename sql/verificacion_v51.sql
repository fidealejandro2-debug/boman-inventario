-- ============================================================
-- Verificacion v51 - Panel principal por rol
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v51.
-- ============================================================

select
  to_regprocedure('public.resumen_panel_principal_v51()') is not null
    as resumen_panel_ok;

select
  has_function_privilege(
    'authenticated', 'public.resumen_panel_principal_v51()', 'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon', 'public.resumen_panel_principal_v51()', 'execute'
  ) as anon_execute_debe_ser_true;

select
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0
    as valida_permisos,
  position('usuario_puede_almacen' in pg_get_functiondef(p.oid)) > 0
    as limita_almacenes,
  position('usuario_puede_empresa' in pg_get_functiondef(p.oid)) > 0
    as limita_empresas,
  position('usuario_puede_franquicia_v42' in pg_get_functiondef(p.oid)) > 0
    as limita_franquicias,
  position('America/Guayaquil' in pg_get_functiondef(p.oid)) > 0
    as usa_fecha_ecuador
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resumen_panel_principal_v51';

-- Debe devolver un objeto con todas las secciones. Los valores dependen del
-- rol y alcance del usuario que ejecuta esta verificacion.
select
  jsonb_typeof(r) = 'object' as respuesta_es_objeto,
  r ?& array[
    'generado_at', 'hoy', 'rol', 'ambito', 'inventario', 'operaciones',
    'ventas', 'compras', 'produccion', 'nomina', 'franquicia',
    'administracion', 'actividad'
  ] as secciones_completas,
  jsonb_typeof(r->'actividad') = 'array' as actividad_es_lista,
  jsonb_typeof(r->'ambito'->'almacenes') = 'array' as almacenes_es_lista,
  jsonb_typeof(r->'ambito'->'empresas') = 'array' as empresas_es_lista
from (select public.resumen_panel_principal_v51() r) x;

-- Deben ser cero: el resumen nunca puede anunciar un alcance que el usuario
-- no tenga segun las funciones de seguridad vigentes.
select count(*) as almacenes_fuera_de_alcance_debe_ser_cero
from public.almacenes a
where a.activo
  and a.nombre in (
    select jsonb_array_elements_text(
      public.resumen_panel_principal_v51()->'ambito'->'almacenes'
    )
  )
  and not public.usuario_puede_almacen(a.id, false);

select count(*) as empresas_fuera_de_alcance_debe_ser_cero
from public.empresas e
where e.activo
  and e.razon_social in (
    select jsonb_array_elements_text(
      public.resumen_panel_principal_v51()->'ambito'->'empresas'
    )
  )
  and not public.usuario_puede_empresa(e.id, false);
