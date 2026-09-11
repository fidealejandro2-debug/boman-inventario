-- ============================================================
-- BOMAN INVENTARIO - v122: lo que el tablero necesita para editar en la fila
--
-- El tablero se armo para mirar, asi que devolvia el numero de contrato pero
-- no su id, y las fechas ya formateadas "DD/MM" -bonitas para leer, inservibles
-- para un <input type="date">. Para editar diseñador, autor de mockup,
-- observacion y fechas sin salir de la fila hacen falta tres cosas:
--
--   * `id`: guardar_gestion_contrato_v99 recibe el contrato por uuid, no por
--     numero. Sin esto habria que resolverlo con una consulta por cada clic.
--   * `entregaISO` / `inicioISO`: el valor que entiende el input de fecha.
--   * las listas de diseñadores y autores ya usados, para ofrecerlos en vez de
--     escribir el nombre a mano cada vez (y que "Elliot" y "elliot" terminen
--     siendo dos personas distintas).
--
-- Nada de esto cambia lo que ya se mostraba. Ejecutar despues de v121.
-- ============================================================
begin;
select pg_advisory_xact_lock(1221142026);

do $$begin
  if to_regprocedure('public.columnas_tablero_v121()') is null then
    raise exception 'Falta v121_subestaciones_tablero.sql antes de v122';
  end if;
end$$;

create or replace function public.tablero_produccion_v102()
returns jsonb language plpgsql stable security definer set search_path='' as $v122$
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
 -- Una columna con `sub` solo cuenta por marca EXACTA en la bitacora: si
 -- valiera el avance del contrato, llegar a "Estampado" marcaria de golpe los
 -- cuatro trabajos de Sellos sin que nadie los haya hecho (ver v121).
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
 filas as(select jsonb_build_object('id',a.id,'numero',a.numero,'corto',right(a.numero,4),'cliente',a.cliente,'vendedor',a.vendedor,'mks',coalesce((select jsonb_agg(jsonb_build_object('i',ca.drive_id,'d',ca.descripcion)order by ca.orden)from public.contrato_archivos ca where ca.contrato_id=a.id and ca.tipo='mockup' and ca.drive_id is not null),'[]'::jsonb),'prendas',a.total_prendas,'prendasTxt',coalesce(a.prendas_txt,''),'calidad',coalesce((select jsonb_agg(q.calidad order by q.calidad)from(select distinct cp.calidad from public.contrato_prendas cp where cp.contrato_id=a.id and btrim(cp.calidad)<>'')q),'[]'::jsonb),'urgente',lower(a.prioridad)='urgente','atrasado',a.fecha_entrega<(now()at time zone'America/Guayaquil')::date,'esExterior',lower(coalesce(a.prendas_txt,''))~'(chompa|rompeviento)','ingreso',to_char(a.fecha_ingreso at time zone'America/Guayaquil','DD/MM'),'entrega',to_char(a.fecha_entrega,'DD/MM'),'entregaISO',to_char(a.fecha_entrega,'YYYY-MM-DD'),'entregaMs',coalesce(extract(epoch from a.fecha_entrega::timestamp)*1000,0),'inicio',to_char(a.fecha_inicio_produccion,'DD/MM'),'inicioISO',to_char(a.fecha_inicio_produccion,'YYYY-MM-DD'),'disenador',coalesce(a.disenador,''),'autorMockup',coalesce(a.autor_mockup,''),'fabrica',case when lower(coalesce(a.disenador,''))like'%marco%'then 2 else 1 end,'obs',coalesce(a.observacion,''),'maquila',coalesce(a.maquila,''),'marca',coalesce((select ce.operario||' · '||to_char(ce.marcado_en at time zone'America/Guayaquil','DD/MM HH24:MI')from public.contrato_etapas ce where ce.contrato_id=a.id order by ce.marcado_en desc limit 1),''),'muestras',jsonb_build_object('tpu',a.muestras_tpu_faltan,'dtf',a.muestras_dtf_faltan),'hechas',(select jsonb_agg(h.hecha order by h.orden)from hechas_por h where h.contrato_id=a.id))fila,a.fecha_entrega,a.numero from activos a)
 select jsonb_build_object(
   'etapas',(select valor from etapas_json),
   'filas',coalesce((select jsonb_agg(fila order by fecha_entrega nulls last,numero)from filas),'[]'::jsonb),
   'total',(select count(*)from activos),
   -- Listas para los desplegables de la fila. Salen de lo ya usado, como en el
   -- cronograma: mantener un catalogo aparte solo lo dejaria desincronizado
   -- con la hoja, donde estos nombres se siguen escribiendo a mano.
   'disenadores',coalesce((select jsonb_agg(d order by d) from (select distinct btrim(c.disenador) d from public.contratos c where nullif(btrim(coalesce(c.disenador,'')),'') is not null) q),'[]'::jsonb),
   'autoresMockup',coalesce((select jsonb_agg(d order by d) from (select distinct btrim(c.autor_mockup) d from public.contratos c where nullif(btrim(coalesce(c.autor_mockup,'')),'') is not null) q),'[]'::jsonb),
   'hora',to_char(now()at time zone'America/Guayaquil','DD/MM/YYYY HH24:MI')
 ) into v_resultado;
 return v_resultado;
end;$v122$;

commit;
