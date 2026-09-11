-- ============================================================
-- Verificacion v121 - Sub-estaciones en el tablero
-- Solo lectura. Ejecutar despues de instalar v121.
-- ============================================================

-- 1) Las columnas del tablero, tal como se van a pintar.
--    Deben salir 16, con Sellos abierto en 4 y Corte en 2.
select orden, etapa, etiqueta, area, sub
  from public.columnas_tablero_v121()
 order by orden;

-- 2) Cada etapa de produccion sigue teniendo al menos una columna.
--    Cualquier fila con columnas = 0 es una etapa que nadie podria marcar.
select e as etapa,
       (select count(*) from public.columnas_tablero_v121() c where c.etapa = e) as columnas
  from unnest(array['Ingresado','Por imprimir','Impreso','Sublimación','Cortado',
                    'En costura o maquila','Estampado','Terminado','Estampado final',
                    'Pendiente entrega','Entregado']) as e
 order by public.orden_etapa_v116(e);

-- 3) Toda area de columna esta en el catalogo de asignacion (si no, nadie
--    podria quedar a cargo de esa columna).
select c.area, c.area = any(public.estaciones_produccion_v117()) as asignable
  from public.columnas_tablero_v121() c
 where c.area <> ''
 group by c.area
 order by c.area;

-- 4) El catalogo ahora incluye areas completas y sub-estaciones.
select unnest(public.estaciones_produccion_v117()) as estacion_asignable;

-- 5) La regla que no se puede relajar: una columna con `sub` solo cuenta por
--    marca exacta en la bitacora, nunca por el avance del contrato.
select position('c.sub <> ''''' in pg_get_functiondef(p.oid)) > 0 as regla_sub_exacta_ok,
       position('columnas_tablero_v121' in pg_get_functiondef(p.oid)) > 0 as usa_columnas_ok
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and p.proname='tablero_produccion_v102';

-- 6) Marcas ya registradas por area: las de la hoja deben caer dentro del
--    catalogo. Lo que salga con asignable=false son areas viejas o escritas
--    distinto, y esas columnas nunca se veran marcadas en el tablero.
select ce.area, count(*) as marcas,
       ce.area = any(public.estaciones_produccion_v117()) as asignable
  from public.contrato_etapas ce
 group by ce.area
 order by marcas desc
 limit 30;

-- 7) Quien quedo a cargo de que.
select p.nombre_completo, p.rol, p.estaciones
  from public.perfiles p
 where coalesce(array_length(p.estaciones,1),0) > 0
 order by p.nombre_completo;
