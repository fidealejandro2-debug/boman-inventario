-- Verificación v128 - colaboradores externos de diseño
-- Solo lectura. Ejecutar después de v128.

select
  to_regclass('public.colaboradores_diseno_v128') is not null as catalogo_externos_ok,
  to_regprocedure('public.crear_colaborador_diseno_v128(text,boolean,boolean,text,text,uuid)') is not null as crear_externo_ok,
  to_regprocedure('public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid)') is not null as asignacion_unificada_ok;

select exists(select 1 from information_schema.columns where table_schema='public' and table_name='contratos' and column_name='disenador_externo_id') as disenador_externo_ok,
       exists(select 1 from information_schema.columns where table_schema='public' and table_name='contratos' and column_name='autor_mockup_externo_id') as autor_mockup_externo_ok;

select has_function_privilege('authenticated','public.crear_colaborador_diseno_v128(text,boolean,boolean,text,text,uuid)','execute') as crear_authenticated_ok,
       not has_function_privilege('anon','public.crear_colaborador_diseno_v128(text,boolean,boolean,text,text,uuid)','execute') as crear_anon_revocado_ok,
       not has_table_privilege('authenticated','public.colaboradores_diseno_v128','insert') as insercion_directa_revocada_ok;

-- Todos deben ser cero.
select count(*) as responsables_con_doble_origen_debe_ser_cero
from public.contratos
where num_nonnulls(disenador_empleado_id,disenador_externo_id)>1
   or num_nonnulls(autor_mockup_empleado_id,autor_mockup_externo_id)>1;

select count(*) as externos_invalidos_debe_ser_cero
from public.colaboradores_diseno_v128
where length(btrim(nombre))<3 or not(es_disenador or es_mockup)
   or creado_por is null or idempotency_key is null
   or length(btrim(motivo_alta))<10;

-- Informativo.
select activo,es_disenador,es_mockup,count(*) total
from public.colaboradores_diseno_v128
group by activo,es_disenador,es_mockup
order by activo desc,es_disenador desc,es_mockup desc;
