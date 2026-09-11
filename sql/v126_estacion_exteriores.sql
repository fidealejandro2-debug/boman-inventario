-- ============================================================
-- BOMAN INVENTARIO - v126: la estacion de Exteriores
--
-- Es la ultima area del taller que no existia en Supabase. Angely lleva las
-- chompas y exteriores por su cuenta: imprime, marca impreso y corta ESAS
-- prendas, en paralelo a lo que Diseño y Corte hacen con el resto del mismo
-- contrato. Por eso en Codigo.gs son tres columnas APARTE y no las mismas:
-- un contrato puede tener las camisetas cortadas y las chompas no.
--
-- Dos cosas que se deciden aqui:
--
--  * `exterior` pasa a ser una columna del catalogo, no un caso especial
--    escondido en el tablero. Cambiar el tipo de retorno obliga a borrar la
--    funcion antes de recrearla: create or replace no puede hacerlo.
--
--  * Que cuenta como contrato "de exteriores" se amplia para que coincida con
--    la hoja. Supabase miraba (chompa|rompeviento) y Codigo.gs mira
--    (chompa|exterior|chaleco): un contrato de chalecos salia como exterior en
--    el taller y no en Vercel, asi que Angely lo veia en un tablero y no en el
--    otro. Se toma la union de ambos.
--
-- Ejecutar despues de v124.
-- ============================================================
begin;
select pg_advisory_xact_lock(1261142026);

do $$begin
  if to_regprocedure('public.tablero_produccion_v102(boolean)') is null then
    raise exception 'Falta v124_tablero_entregados.sql antes de v126';
  end if;
end$$;

-- Un contrato es de exteriores si entre sus prendas hay chompa, exterior,
-- chaleco o rompevientos. Vive en una funcion para que el tablero y cualquier
-- consulta futura usen el MISMO criterio; antes estaba escrito a mano en el
-- medio de la consulta y ya se habia desviado del de la hoja.
create or replace function public.es_contrato_exterior_v126(p_prendas_txt text)
returns boolean language sql immutable set search_path='' as $v126$
  select lower(coalesce(p_prendas_txt,'')) ~ '(chompa|exterior|chaleco|rompeviento)';
$v126$;

-- El catalogo gana la columna `exterior`. Cambia el tipo de retorno, asi que
-- hay que borrar antes: create or replace no puede.
drop function if exists public.columnas_tablero_v121();

create or replace function public.columnas_tablero_v121()
returns table(orden integer, etapa text, etiqueta text, emoji text, bg text, fg text,
              area text, sub text, exterior boolean)
language sql immutable set search_path='' as $v126$
  values
  (1, 'Ingresado',            'Ingresado',     '📥','#BDD7EE','#1F4E78','',                    '', false),
  (2, 'Por imprimir',         'Por imprimir',  '🖨️','#FFE599','#7A5C00','Diseño',              '', false),
  (3, 'Impreso',              'Impreso',       '📄','#FFD966','#7A4F00','Diseño',              '', false),
  (4, 'Cortado',              'Corte sup.',    '👕','#F9CB9C','#783F04','Corte · Corte superior','Corte superior', false),
  (5, 'Cortado',              'Corte inf.',    '🩳','#F9CB9C','#783F04','Corte · Corte inferior','Corte inferior', false),
  (6, 'Sublimación',          'Sublimado',     '🎨','#EA9999','#7B1E1E','Sublimado y costura · Sublimado','Sublimado', false),
  (7, 'En costura o maquila', 'Costura',       '🧵','#D9D2E9','#4A1870','Sublimado y costura · Costura','Costura', false),
  (8, 'En costura o maquila', 'Maquila',       '🏭','#D9D2E9','#4A1870','Sublimado y costura · Maquila','Maquila', false),
  (9, 'Estampado',            'Corte sellos',  '✂️','#C9DAF8','#1C4587','Sellos · Corte de sellos','Corte de sellos', false),
  (10,'Estampado',            'TPU',           '🔧','#C9DAF8','#1C4587','Sellos · TPU',        'TPU', false),
  (11,'Estampado',            'DTF',           '🖨️','#C9DAF8','#1C4587','Sellos · DTF',        'DTF', false),
  (12,'Estampado',            'Bordado',       '🧵','#C9DAF8','#1C4587','Sellos · Bordado',    'Bordado', false),
  -- Exteriores: mismas tres etapas, pero de las chompas. Van al final y no
  -- junto a las de Diseño/Corte a proposito: son trabajo de otra persona sobre
  -- otras prendas del mismo contrato, y mezclarlas haria creer que una
  -- sustituye a la otra.
  (13,'Por imprimir',         'Ext. imprimir', '🧥','#FEF3C7','#92400E','Exteriores',          '', true),
  (14,'Impreso',              'Ext. impreso',  '🧥','#FEF3C7','#92400E','Exteriores',          '', true),
  (15,'Cortado',              'Ext. cortado',  '🧥','#FEF3C7','#92400E','Exteriores',          '', true),
  (16,'Terminado',            'Terminado',     '✅','#A4C2F4','#1E3A8A','Terminado y entrega', '', false),
  (17,'Estampado final',      'Estampado',     '🔖','#EAD1DC','#741B47','Estampado',           '', false),
  (18,'Pendiente entrega',    'Por entregar',  '📦','#B6D7A8','#1A4731','Terminado y entrega', '', false),
  (19,'Entregado',            'Entregado',     '🚚','#E2EFDA','#365F23','Terminado y entrega', '', false);
$v126$;

-- El tablero con las columnas de Exteriores. Igual que v124 salvo el calculo
-- de `hecha` para esas tres y el campo `exterior` en el json.
create or replace function public.tablero_produccion_v102(p_solo_entregados boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $v126$
declare v_resultado jsonb; v_solo boolean := coalesce(p_solo_entregados,false);
begin
 if auth.uid() is null or not (public.usuario_tiene_permiso_v35('produccion.acceder')
                               or public.usuario_tiene_permiso_v35('produccion.estacion'))
   then raise exception 'No tienes permiso para consultar produccion';end if;
 with cols as materialized(
   select c.orden, c.etapa, c.etiqueta, c.emoji, c.bg, c.fg, c.area, c.sub, c.exterior,
          public.orden_etapa_v116(c.etapa) as orden_estado
     from public.columnas_tablero_v121() c),
 activos as materialized(
   select c.*, public.orden_etapa_v116(c.estado) rango,
          public.es_contrato_exterior_v126(c.prendas_txt) es_ext
     from public.contratos c
    where case when v_solo then lower(c.estado) = 'entregado'
                            else lower(c.estado) <> 'entregado' end),
 hechas_por as (
   select a.id as contrato_id, c.orden,
     case
       -- Exteriores lleva su propio avance en la bitacora, bajo el area
       -- 'Exteriores'. Nunca se deduce del estado del contrato: ese lo mueve
       -- el resto del taller y daria por cortadas chompas que nadie toco.
       when c.exterior then a.es_ext and exists(
         select 1 from public.contrato_etapas ce
          where ce.contrato_id = a.id and ce.area = 'Exteriores'
            and public.orden_etapa_v116(ce.etapa) >= c.orden_estado)
       -- Una columna con `sub` solo cuenta por marca EXACTA: si valiera el
       -- avance del contrato, llegar a "Estampado" marcaria de golpe los
       -- cuatro trabajos de Sellos sin que nadie los haya hecho (ver v121).
       when c.sub <> '' then exists(
         select 1 from public.contrato_etapas ce
          where ce.contrato_id = a.id and ce.area = c.area and ce.etapa = c.etapa)
       else
         a.rango >= c.orden_estado
         or exists(select 1 from public.contrato_etapas ce
                    where ce.contrato_id = a.id and ce.etapa = c.etapa
                      and ce.area <> 'Exteriores')
     end as hecha
   from activos a cross join cols c),
 etapas_json as(select jsonb_agg(jsonb_build_object('nombre',c.etapa,'etiqueta',c.etiqueta,'emoji',c.emoji,'bg',c.bg,'fg',c.fg,'area',c.area,'sub',c.sub,'exterior',c.exterior,'hechos',(select count(*) from hechas_por h where h.orden=c.orden and h.hecha))order by c.orden) valor from cols c),
 filas as(select jsonb_build_object('id',a.id,'numero',a.numero,'corto',right(a.numero,4),'cliente',a.cliente,'vendedor',a.vendedor,'mks',coalesce((select jsonb_agg(jsonb_build_object('i',ca.drive_id,'d',ca.descripcion)order by ca.orden)from public.contrato_archivos ca where ca.contrato_id=a.id and ca.tipo='mockup' and ca.drive_id is not null),'[]'::jsonb),'prendas',a.total_prendas,'prendasTxt',coalesce(a.prendas_txt,''),'calidad',coalesce((select jsonb_agg(q.calidad order by q.calidad)from(select distinct cp.calidad from public.contrato_prendas cp where cp.contrato_id=a.id and btrim(cp.calidad)<>'')q),'[]'::jsonb),'urgente',lower(a.prioridad)='urgente','atrasado',a.fecha_entrega<(now()at time zone'America/Guayaquil')::date,'esExterior',a.es_ext,'ingreso',to_char(a.fecha_ingreso at time zone'America/Guayaquil','DD/MM'),'entrega',to_char(a.fecha_entrega,'DD/MM'),'entregaISO',to_char(a.fecha_entrega,'YYYY-MM-DD'),'entregaMs',coalesce(extract(epoch from a.fecha_entrega::timestamp)*1000,0),'inicio',to_char(a.fecha_inicio_produccion,'DD/MM'),'inicioISO',to_char(a.fecha_inicio_produccion,'YYYY-MM-DD'),'disenador',coalesce(a.disenador,''),'autorMockup',coalesce(a.autor_mockup,''),'fabrica',case when lower(coalesce(a.disenador,''))like'%marco%'then 2 else 1 end,'obs',coalesce(a.observacion,''),'maquila',coalesce(a.maquila,''),'marca',coalesce((select ce.operario||' · '||to_char(ce.marcado_en at time zone'America/Guayaquil','DD/MM HH24:MI')from public.contrato_etapas ce where ce.contrato_id=a.id order by ce.marcado_en desc limit 1),''),'muestras',jsonb_build_object('tpu',a.muestras_tpu_faltan,'dtf',a.muestras_dtf_faltan),'hechas',(select jsonb_agg(h.hecha order by h.orden)from hechas_por h where h.contrato_id=a.id))fila,a.fecha_entrega,a.numero from activos a)
 select jsonb_build_object(
   'etapas',(select valor from etapas_json),
   'filas',coalesce((select jsonb_agg(fila order by fecha_entrega nulls last,numero)from filas),'[]'::jsonb),
   'total',(select count(*)from activos),
   'soloEntregados', v_solo,
   'disenadores',coalesce((select jsonb_agg(d order by d) from (select distinct btrim(c.disenador) d from public.contratos c where nullif(btrim(coalesce(c.disenador,'')),'') is not null) q),'[]'::jsonb),
   'autoresMockup',coalesce((select jsonb_agg(d order by d) from (select distinct btrim(c.autor_mockup) d from public.contratos c where nullif(btrim(coalesce(c.autor_mockup,'')),'') is not null) q),'[]'::jsonb),
   'hora',to_char(now()at time zone'America/Guayaquil','DD/MM/YYYY HH24:MI')
 ) into v_resultado;
 return v_resultado;
end;$v126$;

alter function public.es_contrato_exterior_v126(text) owner to postgres;
revoke all on function public.es_contrato_exterior_v126(text) from public, anon;
revoke all on function public.columnas_tablero_v121() from public, anon;
grant execute on function public.es_contrato_exterior_v126(text) to authenticated;
grant execute on function public.columnas_tablero_v121() to authenticated;

commit;
