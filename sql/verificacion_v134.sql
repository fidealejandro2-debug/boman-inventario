-- ============================================================
-- Verificacion v134 - El cronograma ya no multiplica las prendas
-- Solo lectura. Ejecutar despues de instalar v134.
-- ============================================================

-- 1) La funcion ya no cruza `rango` contra la carga por prenda.
select
  position('contratos_dia' in pg_get_functiondef(p.oid)) > 0 as agregados_separados_ok,
  position('left join carga_prenda_capacidad cpc on cpc.dia = r.dia' in pg_get_functiondef(p.oid)) = 0 as cartesiano_eliminado_ok
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public' and p.proname='cronograma_produccion_v96';

-- 2) LA PRUEBA DE VERDAD. Calcula el total del dia por el camino simple
--    -sumar contrato_prendas de los contratos que arrancan ese dia- y lo
--    compara con lo que devuelve la funcion. Antes de v134 la columna
--    `factor` daba el numero de contratos del dia; ahora debe dar 1.
--
--    Requiere sesion con permiso de produccion; desde el editor de Supabase
--    puede fallar por auth.uid() nulo. Si falla, usa el punto 3.
with rango as (
  select (now() at time zone 'America/Guayaquil')::date as desde,
         ((now() at time zone 'America/Guayaquil')::date + 13) as hasta
),
real as (
  select c.fecha_inicio_produccion as dia, sum(cp.cantidad)::bigint total
    from public.contratos c
    join public.contrato_prendas cp on cp.contrato_id = c.id
   cross join rango r
   where c.fecha_inicio_produccion between r.desde and r.hasta
     and lower(c.estado) <> 'entregado'
     and lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
   group by c.fecha_inicio_produccion
),
segun_funcion as (
  select (x->>'fecha')::date dia, (x->>'total_prendas')::bigint total, (x->>'contratos')::bigint contratos
    from rango r, jsonb_array_elements((public.cronograma_produccion_v96(r.desde, r.hasta))->'dias') x
)
select f.dia, f.contratos, r.total as real, f.total as segun_funcion,
       round(f.total::numeric / nullif(r.total,0), 2) as factor
  from segun_funcion f join real r on r.dia = f.dia
 order by f.dia;

-- 3) Alternativa sin sesion: el total real por dia, para comparar a ojo con
--    lo que muestre la pantalla.
select c.fecha_inicio_produccion as dia,
       count(distinct c.id) as contratos,
       sum(cp.cantidad)::bigint as prendas_reales
  from public.contratos c
  join public.contrato_prendas cp on cp.contrato_id = c.id
 where c.fecha_inicio_produccion >= (now() at time zone 'America/Guayaquil')::date
   and c.fecha_inicio_produccion < (now() at time zone 'America/Guayaquil')::date + 14
   and lower(c.estado) <> 'entregado'
   and lower(cp.prenda) !~ '(media|banderin|banderín|bandera|cinta)'
 group by c.fecha_inicio_produccion
 order by c.fecha_inicio_produccion;

-- 4) Capacidades configuradas. Si sale vacio, TODAS las prendas usan el
--    defecto de 100 y por eso casi todos los dias salen en "Sobrecarga":
--    eso no es un error del calculo, es que los topes reales nunca se
--    cargaron.
select prenda, capacidad_dia
  from public.capacidad_produccion_diaria_v96
 order by prenda;
