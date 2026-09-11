-- ============================================================
-- Verificacion v126 - Estacion de Exteriores
-- Solo lectura. Ejecutar despues de instalar v126.
-- ============================================================

-- 1) El catalogo ahora trae 19 columnas, tres de ellas marcadas exterior.
select count(*) as columnas,
       count(*) filter (where exterior) as de_exteriores
  from public.columnas_tablero_v121();

-- 2) Las tres de Exteriores, con su etapa real.
select orden, etapa, etiqueta, area
  from public.columnas_tablero_v121()
 where exterior order by orden;

-- 3) "Exteriores" es asignable como estacion (sin esto Angely no podria
--    tener cuenta propia).
select 'Exteriores' = any(public.estaciones_produccion_v117()) as asignable_ok;

-- 4) El criterio de "contrato de exteriores" coincide con el de Codigo.gs
--    (chompa|exterior|chaleco) mas rompevientos. Todos deben dar true salvo
--    el ultimo.
select p as prendas, public.es_contrato_exterior_v126(p) as es_exterior
  from unnest(array['Chompa de Frio x10','2 Exterior completo','Chaleco reversible',
                    'Rompevientos x4','Camiseta Jugador x22']) as p;

-- 5) Cuantos contratos activos llevan exteriores hoy.
select count(*) filter (where public.es_contrato_exterior_v126(prendas_txt)) as con_exteriores,
       count(*) as activos
  from public.contratos where lower(estado) <> 'entregado';

-- 6) Marcas ya registradas por Angely (area 'Exteriores') desde la hoja.
select etapa, count(*) as marcas, max(marcado_en) as ultima
  from public.contrato_etapas where area = 'Exteriores'
 group by etapa order by marcas desc;
