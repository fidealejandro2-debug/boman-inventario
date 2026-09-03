-- ============================================================
-- Verificacion v78 - Categorias de activo y tasa de depreciacion
-- Solo lectura: ejecutar despues de instalar v78.
-- ============================================================

-- 1. Las categorias nuevas estan admitidas.
select pg_get_constraintdef(c.oid) like '%muebles_enseres%' as muebles_ok,
       pg_get_constraintdef(c.oid) like '%equipo_computo%' as computo_ok
from pg_constraint c
where c.conrelid = 'public.activos_mantenimiento'::regclass
  and c.conname = 'activos_mantenimiento_categoria_check';

-- 2. La columna y su funcion de sugerencia existen.
select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'activos_mantenimiento'
      and column_name = 'porcentaje_depreciacion_anual'
  ) as columna_ok,
  to_regprocedure('public.depreciacion_sugerida_v78(text)') is not null as funcion_ok;

-- 3. Los topes por categoria coinciden con el RALRTI Art. 28 num. 6 lit. a).
select cat,
       public.depreciacion_sugerida_v78(cat) as tope,
       case cat
         when 'infraestructura' then 5 when 'maquinaria' then 10
         when 'equipo' then 10 when 'herramienta' then 10
         when 'muebles_enseres' then 10 when 'vehiculo' then 20
         when 'equipo_computo' then 33 else null
       end = public.depreciacion_sugerida_v78(cat) as coincide
from unnest(array[
  'infraestructura', 'maquinaria', 'equipo', 'herramienta',
  'muebles_enseres', 'vehiculo', 'equipo_computo', 'otro'
]) as cat;

-- 4. El RPC de guardado ya persiste la tasa (si esto sale false, el formulario
-- mandaria el dato y se perderia en silencio).
select pg_get_functiondef(p.oid) like '%porcentaje_depreciacion_anual%'
  as rpc_guarda_la_tasa
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'guardar_activo_mantenimiento_v54';

-- 5. Activos sin tasa. Solo deberian aparecer los de categoria "otro", que se
-- define a mano porque el reglamento no le fija un grupo.
select codigo, nombre, categoria, porcentaje_depreciacion_anual
from public.activos_mantenimiento
where porcentaje_depreciacion_anual is null
order by categoria, codigo;

-- 6. Reparto actual por categoria y tasa.
select categoria, porcentaje_depreciacion_anual, count(*) as activos
from public.activos_mantenimiento
where activo
group by categoria, porcentaje_depreciacion_anual
order by categoria;
