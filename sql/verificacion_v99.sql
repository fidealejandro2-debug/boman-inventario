-- ============================================================
-- Verificacion v99 - Gestion controlada de contratos
-- Solo lectura. Ejecutar despues de instalar v99.
-- ============================================================

select
  to_regclass('public.contrato_gestion_operaciones_v99') is not null as operaciones_ok,
  to_regprocedure('public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)') is not null as guardar_ok;

select exists (
  select 1 from information_schema.columns
  where table_schema='public' and table_name='contrato_eventos'
    and column_name='gestion_operacion_id'
) as eventos_enlazados_ok;

select exists (
  select 1 from information_schema.columns
  where table_schema='public' and table_name='contrato_eventos'
    and column_name='motivo_gestion_v99'
) as motivo_auditable_ok;

select tablename, rowsecurity
from pg_tables
where schemaname='public' and tablename='contrato_gestion_operaciones_v99';

select
  has_function_privilege('authenticated','public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)','execute') as authenticated_ok,
  not has_function_privilege('anon','public.guardar_gestion_contrato_v99(uuid,jsonb,text,uuid)','execute') as anon_bloqueado_ok,
  not has_table_privilege('authenticated','public.contrato_gestion_operaciones_v99','insert') as insert_directo_bloqueado_ok,
  not has_table_privilege('authenticated','public.contratos','update') as update_directo_bloqueado_ok;

select p.prosecdef as security_definer,
       position('contratos.editar' in pg_get_functiondef(p.oid)) > 0 as permiso_editar_ok,
       position('jsonb_object_keys' in pg_get_functiondef(p.oid)) > 0 as lista_blanca_ok,
       position('pg_advisory_xact_lock' in pg_get_functiondef(p.oid)) > 0 as idempotencia_concurrente_ok
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='guardar_gestion_contrato_v99';

-- Todos los siguientes resultados deben ser cero.
select count(*) as operaciones_sin_cambio_debe_ser_cero
from public.contrato_gestion_operaciones_v99
where cambios_aplicados='{}'::jsonb or resultado is null;

select count(*) as eventos_gestion_sin_operacion_debe_ser_cero
from public.contrato_eventos
where gestion_operacion_id is not null and not exists (
  select 1 from public.contrato_gestion_operaciones_v99 o
  where o.id=contrato_eventos.gestion_operacion_id
);

select count(*) as operaciones_sin_eventos_debe_ser_cero
from public.contrato_gestion_operaciones_v99 o
where not exists (
  select 1 from public.contrato_eventos e where e.gestion_operacion_id=o.id
);

select count(*) as eventos_gestion_sin_motivo_debe_ser_cero
from public.contrato_eventos
where gestion_operacion_id is not null
  and length(btrim(coalesce(motivo_gestion_v99,''))) < 10;

select count(*) as contratos_con_fechas_invalidas_debe_ser_cero
from public.contratos
where (fecha_inicio_produccion is not null and fecha_entrega is not null
       and fecha_entrega < fecha_inicio_produccion)
   or (fecha_inicio_produccion is not null and fecha_salida_produccion is not null
       and fecha_salida_produccion < fecha_inicio_produccion);

-- La RPC con sesion se prueba desde la interfaz; este archivo no suplanta auth.uid().
