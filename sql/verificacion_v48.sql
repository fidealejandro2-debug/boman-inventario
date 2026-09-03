-- ============================================================
-- Verificacion v48 - Cambio de SKU seguro y auditado
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v48 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regprocedure('public.admin_cambiar_sku_producto_v48(uuid,text,text)') is not null
    as cambiar_sku_ok,
  exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'productos_maestro_cambios'
      and column_name = 'motivo'
  ) as motivo_auditoria_ok;

select
  has_function_privilege(
    'authenticated',
    'public.admin_cambiar_sku_producto_v48(uuid,text,text)',
    'execute'
  ) as cambiar_sku_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.admin_cambiar_sku_producto_v48(uuid,text,text)',
    'execute'
  ) as cambiar_sku_anon_debe_ser_true,
  not has_column_privilege(
    'authenticated', 'public.productos', 'sku', 'update'
  ) as update_directo_sku_debe_ser_true;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  case when p.proname = 'admin_cambiar_sku_producto_v48'
    then position(
      'boman.motivo_maestro' in pg_get_functiondef(p.oid)
    ) > 0
    else null
  end as propaga_motivo_si_corresponde,
  case when p.proname = 'auditar_producto_maestro'
    then position(
      '''sku'', old.sku' in lower(pg_get_functiondef(p.oid))
    ) > 0
    else null
  end as audita_sku_si_corresponde
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_cambiar_sku_producto_v48',
    'auditar_producto_maestro'
  )
order by p.proname;

select
  exists (
    select 1
    from information_schema.triggers
    where trigger_schema = 'public'
      and event_object_table = 'productos'
      and trigger_name = 'trg_auditar_producto_maestro'
      and event_manipulation = 'UPDATE'
  ) as trigger_auditoria_producto_ok;

-- Todos los siguientes resultados deben ser cero.

select count(*) as sku_vacios_debe_ser_cero
from public.productos
where btrim(coalesce(sku, '')) = '';

select count(*) as sku_duplicados_sin_distinguir_mayusculas_debe_ser_cero
from (
  select upper(btrim(sku)) as sku_normalizado
  from public.productos
  group by upper(btrim(sku))
  having count(*) > 1
) duplicados;

select count(*) as auditorias_sku_sin_motivo_desde_v48
from public.productos_maestro_cambios
where valores_anteriores ? 'sku'
  and valores_nuevos ? 'sku'
  and valores_anteriores->>'sku' is distinct from valores_nuevos->>'sku'
  and btrim(coalesce(motivo, '')) = '';

