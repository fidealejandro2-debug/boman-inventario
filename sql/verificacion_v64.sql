-- ============================================================
-- Verificacion v64 - Consolidado de tiendas propias
-- Solo lectura: no modifica datos ni exige una sesion simulada.
-- Ejecutar despues de instalar v64.
-- ============================================================

select
  to_regprocedure('public.resumen_consolidado_tiendas_v64(date,date)') is not null
    as resumen_tiendas_ok;

select
  has_function_privilege(
    'authenticated',
    'public.resumen_consolidado_tiendas_v64(date,date)', 'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon',
    'public.resumen_consolidado_tiendas_v64(date,date)', 'execute'
  ) as anon_sin_execute_ok;

select
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('franquicia.consolidado' in pg_get_functiondef(p.oid)) > 0
    as valida_permiso,
  position('America/Guayaquil' in pg_get_functiondef(p.oid)) > 0
    as usa_fecha_ecuador,
  position('not exists' in lower(pg_get_functiondef(p.oid))) > 0
    as excluye_franquicias
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'resumen_consolidado_tiendas_v64';

-- Deben ser cero.
select count(*) as tiendas_activas_sin_operadora_principal
from public.almacenes a
where a.activo and a.tipo = 'tienda'
  and not exists (
    select 1 from public.franquicias f
    where f.almacen_id = a.id and f.activo
  )
  and not exists (
    select 1 from public.empresa_almacenes ea
    join public.empresas e on e.id = ea.empresa_id and e.activo
    where ea.almacen_id = a.id and ea.es_operadora_principal
  );

select count(*) as franquicias_en_almacenes_no_tienda_debe_ser_cero
from public.almacenes a
join public.franquicias f on f.almacen_id = a.id and f.activo
where a.activo and a.tipo <> 'tienda';
