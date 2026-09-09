-- ============================================================
-- Verificacion v112 - Despachos y entregas de contratos
-- Solo lectura. Ejecutar despues de instalar v112.
-- ============================================================
select
 to_regclass('public.contrato_entregas_v112') is not null as entregas_ok,
 to_regclass('public.contrato_entrega_lineas_v112') is not null as lineas_ok,
 to_regclass('public.contrato_entrega_archivos_v112') is not null as evidencias_ok,
 exists(select 1 from storage.buckets where id='contratos-entregas' and not public) as bucket_privado_ok;

select
 to_regprocedure('public.preparar_evidencia_entrega_v112(text,text,bigint,uuid)') is not null as preparar_ok,
 to_regprocedure('public.listar_despachos_v112(text,integer,integer)') is not null as listar_ok,
 to_regprocedure('public.obtener_despacho_contrato_v112(uuid)') is not null as detalle_ok,
 to_regprocedure('public.registrar_entrega_contrato_v112(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)') is not null as registrar_ok,
 to_regprocedure('public.revertir_entrega_contrato_v112(uuid,text,uuid)') is not null as revertir_ok;

select
 has_function_privilege('authenticated','public.registrar_entrega_contrato_v112(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)','execute') as registrar_authenticated_ok,
 not has_function_privilege('anon','public.registrar_entrega_contrato_v112(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)','execute') as registrar_anon_bloqueado_ok,
 not has_table_privilege('authenticated','public.contrato_entregas_v112','insert') as insert_directo_bloqueado_ok,
 not has_table_privilege('authenticated','public.contrato_entregas_v112','update') as update_directo_bloqueado_ok;

select p.proname,p.prosecdef as security_definer,pg_get_userbyid(p.proowner) propietario,
 position('idempotency' in lower(pg_get_functiondef(p.oid)))>0 as controla_idempotencia,
 case when p.proname='revertir_entrega_contrato_v112' then position('contratos.revertir_entrega' in pg_get_functiondef(p.oid))>0 else position('contratos.entregar' in pg_get_functiondef(p.oid))>0 end as controla_permiso
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in('registrar_entrega_contrato_v112','revertir_entrega_contrato_v112') order by p.proname;

-- Todos deben ser cero.
select count(*) as entregas_sin_lineas_debe_ser_cero from public.contrato_entregas_v112 e where not exists(select 1 from public.contrato_entrega_lineas_v112 l where l.entrega_id=e.id);
select count(*) as lineas_de_otro_contrato_debe_ser_cero from public.contrato_entrega_lineas_v112 l join public.contrato_entregas_v112 e on e.id=l.entrega_id join public.contrato_prendas p on p.id=l.contrato_prenda_id where p.contrato_id<>e.contrato_id;
select count(*) as prendas_sobreentregadas_debe_ser_cero from(select p.id,p.cantidad,coalesce(sum(l.cantidad)filter(where e.estado='aplicada'),0)entregada from public.contrato_prendas p left join public.contrato_entrega_lineas_v112 l on l.contrato_prenda_id=p.id left join public.contrato_entregas_v112 e on e.id=l.entrega_id group by p.id,p.cantidad)x where entregada>cantidad;
select count(*) as reversiones_incompletas_debe_ser_cero from public.contrato_entregas_v112 where estado='revertida' and(revertido_por is null or revertido_en is null or length(btrim(coalesce(motivo_reversion,'')))<10);
select count(*) as evidencias_huerfanas_debe_ser_cero from public.contrato_entrega_archivos_v112 a left join public.contrato_entregas_v112 e on e.id=a.entrega_id where e.id is null;

select estado,tipo,count(*) entregas,coalesce(sum((select sum(l.cantidad)from public.contrato_entrega_lineas_v112 l where l.entrega_id=e.id)),0) prendas from public.contrato_entregas_v112 e group by estado,tipo order by estado,tipo;
