-- Verificacion v145. Solo lectura; ejecutar despues de la migracion.

-- Todos los siguientes conteos deben ser CERO: ya no debe quedar ninguna
-- clave vieja dentro de spec.campos para contratos nativos de Vercel.
select count(*) as camiseta_botones_pendiente
from public.contrato_specs
where prenda_clave = 'camiseta' and spec ? 'campos' and spec->'campos' ? 'botones';

select count(*) as camisetapolo_botones_pendiente
from public.contrato_specs
where prenda_clave = 'camisetaPolo' and spec ? 'campos' and spec->'campos' ? 'botones';

select count(*) as chompa_tipo_pendiente
from public.contrato_specs
where prenda_clave = 'chompa' and spec ? 'campos' and spec->'campos' ? 'tipo';

select count(*) as chompa_velcro_pendiente
from public.contrato_specs
where prenda_clave = 'chompa' and spec ? 'campos' and spec->'campos' ? 'velcro';

select count(*) as chompa_basta_pendiente
from public.contrato_specs
where prenda_clave = 'chompa' and spec ? 'campos' and spec->'campos' ? 'basta';

select count(*) as retro_punos_pendiente
from public.contrato_specs
where prenda_clave = 'retro' and spec ? 'campos' and spec->'campos' ? 'punos';

select count(*) as deportiva_punos_pendiente
from public.contrato_specs
where prenda_clave = 'deportiva' and spec ? 'campos' and spec->'campos' ? 'punos';

select count(*) as pantalon_punos_pendiente
from public.contrato_specs
where prenda_clave = 'pantalon' and spec ? 'campos' and spec->'campos' ? 'punos';

select count(*) as bermuda_tipo_pendiente
from public.contrato_specs
where prenda_clave = 'bermuda' and spec ? 'campos' and spec->'campos' ? 'tipo';

select count(*) as faldashort_tipo_pendiente
from public.contrato_specs
where prenda_clave = 'faldaShort' and spec ? 'campos' and spec->'campos' ? 'tipo';

select count(*) as licra_punos_pendiente
from public.contrato_specs
where prenda_clave = 'licra' and spec ? 'campos' and spec->'campos' ? 'punos';

select count(*) as licra_basta_tipo_pendiente
from public.contrato_specs
where prenda_clave = 'licra' and spec ? 'campos' and spec->'campos' ? 'basta_tipo';

-- Muestra cuántas filas por prenda quedaron con la clave nueva (para ver que
-- el renombre de verdad escribió algo, no solo que no quedó nada viejo).
select prenda_clave, jsonb_object_keys(spec->'campos') as clave, count(*)
from public.contrato_specs
where spec ? 'campos'
  and prenda_clave in ('camiseta','camisetaPolo','chompa','retro','deportiva','pantalon','bermuda','faldaShort','licra')
group by prenda_clave, clave
order by prenda_clave, clave;
