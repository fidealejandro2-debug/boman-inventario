-- ============================================================
-- BOMAN INVENTARIO - v124: ver los contratos entregados en el tablero
--
-- El tablero siempre excluyo lo entregado, y para el trabajo del dia esta
-- bien: lo que importa es lo que falta. Pero entonces no hay forma de
-- confirmar que un despacho quedo bien marcado sin salir a otra pantalla.
-- Codigo.gs resuelve esto con datosTablero(forzar, soloEntregados), un filtro
-- mas que cambia la fuente; aqui se hace igual.
--
-- OJO CON LA FIRMA: no se puede agregar el parametro con un simple create or
-- replace. Una funcion con parametro por defecto TAMBIEN responde a la llamada
-- sin argumentos, asi que convivirian dos candidatas y Postgres rechazaria la
-- llamada por ambigua ("function is not unique") -es decir, el tablero dejaria
-- de cargar. Por eso se borra la version sin parametros primero.
--
-- Ejecutar despues de v122.
-- ============================================================
begin;
select pg_advisory_xact_lock(1241142026);

do $$begin
  if to_regprocedure('public.columnas_tablero_v121()') is null then
    raise exception 'Falta v121 antes de v124';
  end if;
end$$;

drop function if exists public.tablero_produccion_v102();

-- p_solo_entregados = false: lo de siempre (todo lo que NO esta entregado).
-- true: solo lo entregado, para revisar despachos.
create or replace function public.tablero_produccion_v102(p_solo_entregados boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $v124$
declare v_resultado jsonb; v_solo boolean := coalesce(p_solo_entregados,false);
begin
 if auth.uid() is null or not (public.usuario_tiene_permiso_v35('produccion.acceder')
                               or public.usuario_tiene_permiso_v35('produccion.estacion'))
   then raise exception 'No tienes permiso para consultar produccion';end if;
 with cols as materialized(
   select c.orden, c.etapa, c.etiqueta, c.emoji, c.bg, c.fg, c.area, c.sub,
          public.orden_etapa_v116(c.etapa) as orden_estado
     from public.columnas_tablero_v121() c),
 activos as materialized(
   select c.*, public.orden_etapa_v116(c.estado) rango
     from public.contratos c
    where case when v_solo then lower(c.estado) = 'entregado'
                            else lower(c.estado) <> 'entregado' end),
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
   'soloEntregados', v_solo,
   'disenadores',coalesce((select jsonb_agg(d order by d) from (select distinct btrim(c.disenador) d from public.contratos c where nullif(btrim(coalesce(c.disenador,'')),'') is not null) q),'[]'::jsonb),
   'autoresMockup',coalesce((select jsonb_agg(d order by d) from (select distinct btrim(c.autor_mockup) d from public.contratos c where nullif(btrim(coalesce(c.autor_mockup,'')),'') is not null) q),'[]'::jsonb),
   'hora',to_char(now()at time zone'America/Guayaquil','DD/MM/YYYY HH24:MI')
 ) into v_resultado;
 return v_resultado;
end;$v124$;

alter function public.tablero_produccion_v102(boolean) owner to postgres;
revoke all on function public.tablero_produccion_v102(boolean) from public, anon;
grant execute on function public.tablero_produccion_v102(boolean) to authenticated;

commit;
