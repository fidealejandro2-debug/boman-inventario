-- ============================================================
-- Verificacion v116 - Marcar etapas desde Vercel
-- Solo lectura. Ejecutar despues de instalar v116.
-- ============================================================

-- 1) Las tres funciones existen.
select
  to_regprocedure('public.marcar_etapa_contrato_v116(text,text,text,text,boolean,text,uuid)') is not null as marcar_ok,
  to_regprocedure('public.desmarcar_etapa_contrato_v116(text,text,text,text,uuid)') is not null as desmarcar_ok,
  to_regprocedure('public.orden_etapa_v116(text)') is not null as orden_ok;

-- 2) Privilegios: authenticated si, anon no.
select
  has_function_privilege('authenticated','public.marcar_etapa_contrato_v116(text,text,text,text,boolean,text,uuid)','execute') as auth_marcar_ok,
  not has_function_privilege('anon','public.marcar_etapa_contrato_v116(text,text,text,text,boolean,text,uuid)','execute') as anon_bloqueado_ok,
  has_function_privilege('authenticated','public.desmarcar_etapa_contrato_v116(text,text,text,text,uuid)','execute') as auth_desmarcar_ok,
  not has_function_privilege('anon','public.desmarcar_etapa_contrato_v116(text,text,text,text,uuid)','execute') as anon_desmarcar_bloqueado_ok;

-- 3) Son security definer y controlan el permiso correcto.
select p.proname, p.prosecdef as security_definer,
       position('contratos.marcar_etapa' in pg_get_functiondef(p.oid)) > 0 as controla_permiso
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('marcar_etapa_contrato_v116','desmarcar_etapa_contrato_v116')
 order by p.proname;

-- 4) Columnas y llaves nuevas de contrato_etapas.
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='contrato_etapas'
      and column_name in ('origen','idempotency_key','marcado_por')) = 3 as columnas_ok,
  (select count(*) from pg_indexes
    where schemaname='public'
      and indexname in ('contrato_etapas_idempotency_v116','contrato_etapas_marca_unica_v116')) as indices_creados;

-- 5) El orden de etapas coincide con ESTADOS_PRODUCCION de Codigo.gs.
--    Debe devolver 1..11 en ese orden y 0 para una etapa inventada.
select public.orden_etapa_v116(e) as orden, e as etapa
  from unnest(array['Ingresado','Por imprimir','Impreso','Sublimación','Cortado',
                    'En costura o maquila','Estampado','Terminado','Estampado final',
                    'Pendiente entrega','Entregado','Etapa inventada']) as e;

-- 6) Marcas repetidas que impedirian el indice unico. Debe ser cero.
--    Si no lo es, el indice contrato_etapas_marca_unica_v116 no se creo (la
--    migracion avisa con un warning) y hay que limpiar estas filas.
select contrato_id, area, etapa, count(*) as veces
  from public.contrato_etapas
 group by contrato_id, area, etapa
having count(*) > 1
 order by veces desc
 limit 20;

-- 7) Informativo: de donde vienen las marcas registradas.
select origen, count(*) as marcas
  from public.contrato_etapas
 group by origen
 order by marcas desc;
