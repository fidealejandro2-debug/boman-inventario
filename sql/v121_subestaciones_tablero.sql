-- ============================================================
-- BOMAN INVENTARIO - v121: sub-estaciones en el tablero
--
-- v117 le dio a cada etapa su estacion, pero el tablero de Supabase sigue
-- teniendo ONCE casillas planas y el taller no trabaja asi:
--
--   * "Estampado" no es un trabajo, son CUATRO de cuatro personas distintas
--     (corte de sellos, TPU, DTF, bordado) y un contrato suele llevar varios a
--     la vez. Una sola casilla miente: queda marcada con la mitad hecha.
--   * "Cortado" son dos: Mayte corta arriba y Lety abajo.
--   * "Sublimacion" y "En costura o maquila" pertenecen a la misma estacion de
--     Carol, y costura/maquila son alternativas entre si.
--
-- Mientras el tablero no lo desglose, darle la estacion "Sellos" a Daniela le
-- deja marcar tambien el DTF de Laura -que es justo lo que las cuentas por
-- estacion venian a evitar.
--
-- Los nombres salen literales de SUBETAPAS_* en Codigo.gs y se guardan en
-- contrato_etapas.area con el mismo formato que ya usa la hoja ("Sellos · TPU"),
-- para que la marca viaje en los dos sentidos sin duplicarse.
--
-- Ejecutar despues de v117.
-- ============================================================
begin;
select pg_advisory_xact_lock(1211142026);

do $$begin
  if to_regprocedure('public.area_etapa_v117(text)') is null
     or to_regprocedure('public.tablero_produccion_v102()') is null then
    raise exception 'Falta v117 antes de v121';
  end if;
end$$;

-- ------------------------------------------------------------
-- 1. Las columnas del tablero, en un solo sitio
-- ------------------------------------------------------------

-- `orden` es el de PANTALLA; el de proceso sale de orden_etapa_v116(etapa) y
-- puede repetirse (las cuatro columnas de Sellos son la misma etapa).
-- `area` vacia = no la marca ninguna estacion (Ingresado lo pone ventas).
-- `sub` vacia = la columna ES la etapa entera, no una parte.
create or replace function public.columnas_tablero_v121()
returns table(orden integer, etapa text, etiqueta text, emoji text, bg text, fg text, area text, sub text)
language sql immutable set search_path='' as $v121$
  values
  (1, 'Ingresado',            'Ingresado',     '📥','#BDD7EE','#1F4E78','',                    ''),
  (2, 'Por imprimir',         'Por imprimir',  '🖨️','#FFE599','#7A5C00','Diseño',              ''),
  (3, 'Impreso',              'Impreso',       '📄','#FFD966','#7A4F00','Diseño',              ''),
  -- Corte va antes que Sublimado aunque el orden canonico de ESTADOS_PRODUCCION
  -- diga lo contrario: las tres areas del medio son PARALELAS (asi estan
  -- marcadas en Codigo.gs), asi que ese orden no describe nada real, y en
  -- cambio dejar juntas las columnas de una misma estacion si.
  (4, 'Cortado',              'Corte sup.',    '👕','#F9CB9C','#783F04','Corte · Corte superior','Corte superior'),
  (5, 'Cortado',              'Corte inf.',    '🩳','#F9CB9C','#783F04','Corte · Corte inferior','Corte inferior'),
  (6, 'Sublimación',          'Sublimado',     '🎨','#EA9999','#7B1E1E','Sublimado y costura · Sublimado','Sublimado'),
  (7, 'En costura o maquila', 'Costura',       '🧵','#D9D2E9','#4A1870','Sublimado y costura · Costura','Costura'),
  (8, 'En costura o maquila', 'Maquila',       '🏭','#D9D2E9','#4A1870','Sublimado y costura · Maquila','Maquila'),
  (9, 'Estampado',            'Corte sellos',  '✂️','#C9DAF8','#1C4587','Sellos · Corte de sellos','Corte de sellos'),
  (10,'Estampado',            'TPU',           '🔧','#C9DAF8','#1C4587','Sellos · TPU',        'TPU'),
  (11,'Estampado',            'DTF',           '🖨️','#C9DAF8','#1C4587','Sellos · DTF',        'DTF'),
  (12,'Estampado',            'Bordado',       '🧵','#C9DAF8','#1C4587','Sellos · Bordado',    'Bordado'),
  (13,'Terminado',            'Terminado',     '✅','#A4C2F4','#1E3A8A','Terminado y entrega', ''),
  (14,'Estampado final',      'Estampado',     '🔖','#EAD1DC','#741B47','Estampado',           ''),
  (15,'Pendiente entrega',    'Por entregar',  '📦','#B6D7A8','#1A4731','Terminado y entrega', ''),
  (16,'Entregado',            'Entregado',     '🚚','#E2EFDA','#365F23','Terminado y entrega', '');
$v121$;

-- El catalogo de asignacion crece con las sub-estaciones: a Daniela se le da
-- "Sellos · TPU"; a un encargado de toda el area, "Sellos" a secas (que por
-- puede_marcar_area_v117 cubre todas sus sub-estaciones).
create or replace function public.estaciones_produccion_v117()
returns text[] language sql stable set search_path='' as $v121$
  select array(
    select distinct a from unnest(
      array['Diseño','Terminado y entrega','Estampado','Corte','Sublimado y costura','Sellos']
      || array(select c.area from public.columnas_tablero_v121() c where c.area <> '')
    ) a order by a);
$v121$;

-- ------------------------------------------------------------
-- 2. El tablero pinta esas columnas
-- ------------------------------------------------------------

-- Copia de v117 con un solo cambio de fondo: las columnas y el calculo de
-- "hecha" salen de columnas_tablero_v121 en vez de la lista fija de once.
--
-- REGLA QUE NO SE PUEDE RELAJAR: una columna con `sub` solo cuenta como hecha
-- si existe su marca EXACTA en la bitacora. Si se dejara valer el avance del
-- contrato (a.rango >= orden), llegar a "Estampado" marcaria de golpe TPU, DTF,
-- bordado y corte de sellos -los cuatro trabajos de cuatro personas- sin que
-- nadie los haya hecho. Codigo.gs tiene la misma regla y por la misma razon.
create or replace function public.tablero_produccion_v102()
returns jsonb language plpgsql stable security definer set search_path='' as $v121$
declare v_resultado jsonb;
begin
 if auth.uid() is null or not (public.usuario_tiene_permiso_v35('produccion.acceder')
                               or public.usuario_tiene_permiso_v35('produccion.estacion'))
   then raise exception 'No tienes permiso para consultar produccion';end if;
 with cols as materialized(
   select c.orden, c.etapa, c.etiqueta, c.emoji, c.bg, c.fg, c.area, c.sub,
          public.orden_etapa_v116(c.etapa) as orden_estado
     from public.columnas_tablero_v121() c),
 activos as materialized(select c.*,public.orden_etapa_v116(c.estado) rango from public.contratos c where lower(c.estado)<>'entregado'),
 hechas_por as (
   select a.id as contrato_id, c.orden,
     case when c.sub <> '' then
       exists(select 1 from public.contrato_etapas ce
               where ce.contrato_id=a.id and ce.area=c.area and ce.etapa=c.etapa)
     else
       a.rango >= c.orden_estado
       or exists(select 1 from public.contrato_etapas ce
                  where ce.contrato_id=a.id and ce.etapa=c.etapa)
     end as hecha
   from activos a cross join cols c),
 etapas_json as(select jsonb_agg(jsonb_build_object('nombre',c.etapa,'etiqueta',c.etiqueta,'emoji',c.emoji,'bg',c.bg,'fg',c.fg,'area',c.area,'sub',c.sub,'hechos',(select count(*) from hechas_por h where h.orden=c.orden and h.hecha))order by c.orden) valor from cols c),
 filas as(select jsonb_build_object('numero',a.numero,'corto',right(a.numero,4),'cliente',a.cliente,'vendedor',a.vendedor,'mks',coalesce((select jsonb_agg(jsonb_build_object('i',ca.drive_id,'d',ca.descripcion)order by ca.orden)from public.contrato_archivos ca where ca.contrato_id=a.id and ca.tipo='mockup' and ca.drive_id is not null),'[]'::jsonb),'prendas',a.total_prendas,'prendasTxt',coalesce(a.prendas_txt,''),'calidad',coalesce((select jsonb_agg(q.calidad order by q.calidad)from(select distinct cp.calidad from public.contrato_prendas cp where cp.contrato_id=a.id and btrim(cp.calidad)<>'')q),'[]'::jsonb),'urgente',lower(a.prioridad)='urgente','atrasado',a.fecha_entrega<(now()at time zone'America/Guayaquil')::date,'esExterior',lower(coalesce(a.prendas_txt,''))~'(chompa|rompeviento)','ingreso',to_char(a.fecha_ingreso at time zone'America/Guayaquil','DD/MM'),'entrega',to_char(a.fecha_entrega,'DD/MM'),'entregaMs',coalesce(extract(epoch from a.fecha_entrega::timestamp)*1000,0),'inicio',to_char(a.fecha_inicio_produccion,'DD/MM'),'disenador',coalesce(a.disenador,''),'autorMockup',coalesce(a.autor_mockup,''),'fabrica',case when lower(coalesce(a.disenador,''))like'%marco%'then 2 else 1 end,'obs',coalesce(a.observacion,''),'maquila',coalesce(a.maquila,''),'marca',coalesce((select ce.operario||' · '||to_char(ce.marcado_en at time zone'America/Guayaquil','DD/MM HH24:MI')from public.contrato_etapas ce where ce.contrato_id=a.id order by ce.marcado_en desc limit 1),''),'muestras',jsonb_build_object('tpu',a.muestras_tpu_faltan,'dtf',a.muestras_dtf_faltan),'hechas',(select jsonb_agg(h.hecha order by h.orden)from hechas_por h where h.contrato_id=a.id))fila,a.fecha_entrega,a.numero from activos a)
 select jsonb_build_object('etapas',(select valor from etapas_json),'filas',coalesce((select jsonb_agg(fila order by fecha_entrega nulls last,numero)from filas),'[]'::jsonb),'total',(select count(*)from activos),'hora',to_char(now()at time zone'America/Guayaquil','DD/MM/YYYY HH24:MI'))into v_resultado;
 return v_resultado;
end;$v121$;

revoke all on function public.columnas_tablero_v121() from public, anon;
grant execute on function public.columnas_tablero_v121() to authenticated;

commit;
