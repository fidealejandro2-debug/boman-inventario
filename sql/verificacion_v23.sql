-- ============================================================
-- Verificacion v23 - Maestro de produccion y costos
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v23 y nunca en paralelo con la migracion.
-- ============================================================

select
  to_regclass('public.unidades_medida_produccion') is not null as unidades_ok,
  to_regclass('public.productos_produccion_eventos') is not null as auditoria_productos_ok,
  to_regclass('public.formulas_produccion') is not null as formulas_ok,
  to_regclass('public.formula_produccion_componentes') is not null as componentes_ok,
  to_regclass('public.formula_produccion_eventos') is not null as eventos_ok;

select
  to_regprocedure('public.usuario_puede_grupo_produccion(uuid)') is not null
    as acceso_grupo_ok,
  to_regprocedure('public.clasificar_productos_produccion_v23(jsonb,text)') is not null
    as clasificar_productos_ok,
  to_regprocedure('public.guardar_formula_produccion_v23(uuid,uuid,text,uuid,numeric,numeric,numeric,text,jsonb)') is not null
    as guardar_formula_ok,
  to_regprocedure('public.resolver_formula_produccion_v23(uuid,boolean,text)') is not null
    as resolver_formula_ok;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'productos'
  and column_name in (
    'tipo_inventario', 'unidad_medida', 'costo_estandar',
    'produccion_updated_at', 'produccion_updated_by'
  )
order by column_name;

select codigo, nombre, simbolo, familia
from public.unidades_medida_produccion
where activo
order by familia, codigo;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'unidades_medida_produccion', 'productos_produccion_eventos',
    'formulas_produccion', 'formula_produccion_componentes',
    'formula_produccion_eventos'
  )
order by tablename;

select
  has_function_privilege(
    'authenticated',
    'public.clasificar_productos_produccion_v23(jsonb,text)', 'execute'
  ) as clasificar_authenticated_ok,
  has_function_privilege(
    'authenticated',
    'public.guardar_formula_produccion_v23(uuid,uuid,text,uuid,numeric,numeric,numeric,text,jsonb)',
    'execute'
  ) as guardar_authenticated_ok,
  has_function_privilege(
    'anon',
    'public.guardar_formula_produccion_v23(uuid,uuid,text,uuid,numeric,numeric,numeric,text,jsonb)',
    'execute'
  ) as guardar_anon_debe_ser_false;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  case
    when p.proname = 'resolver_formula_produccion_v23'
      then position('dependencia circular' in pg_get_functiondef(p.oid)) > 0
    else null
  end as valida_ciclos_si_corresponde
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'clasificar_productos_produccion_v23',
    'guardar_formula_produccion_v23',
    'resolver_formula_produccion_v23'
  )
order by p.proname;

-- Todos deben ser cero.
select count(*) as formulas_activas_duplicadas_debe_ser_cero
from (
  select grupo_id, producto_resultado_id
  from public.formulas_produccion
  where estado = 'activa'
  group by grupo_id, producto_resultado_id
  having count(*) > 1
) duplicadas;

select count(*) as formulas_sin_componentes_debe_ser_cero
from public.formulas_produccion f
where f.estado = 'activa' and not exists (
  select 1 from public.formula_produccion_componentes c where c.formula_id = f.id
);

select count(*) as formulas_autorreferenciadas_debe_ser_cero
from public.formulas_produccion f
join public.formula_produccion_componentes c on c.formula_id = f.id
where c.producto_id = f.producto_resultado_id;

select count(*) as componentes_inactivos_en_formula_activa_debe_ser_cero
from public.formulas_produccion f
join public.formula_produccion_componentes c on c.formula_id = f.id
join public.productos p on p.id = c.producto_id
where f.estado = 'activa' and not p.activo;

select
  tipo_inventario,
  count(*) as productos
from public.productos
where activo
group by tipo_inventario
order by tipo_inventario;

select
  count(*) filter (where estado = 'borrador') as formulas_borrador,
  count(*) filter (where estado = 'activa') as formulas_activas,
  count(*) filter (where estado = 'inactiva') as formulas_inactivas
from public.formulas_produccion;

select empresa_codigo, formula_codigo, version, resultado_sku,
       costo_materiales_lote, costo_mano_obra_lote, costo_indirecto_lote,
       costo_unitario_estimado, componentes_sin_costo
from public.vista_formula_costos_empresa_v23
where estado = 'activa'
order by empresa_codigo, formula_codigo;
