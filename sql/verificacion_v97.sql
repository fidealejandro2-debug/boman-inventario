-- ============================================================
-- Verificacion v97 - Expediente y brief de contratos
-- Solo lectura. Ejecutar despues de instalar v97.
-- ============================================================

select
  to_regclass('public.contrato_enlaces_compartidos_v97') is not null as enlaces_ok,
  to_regprocedure('public.listar_contratos_v97(text,text,integer,integer)') is not null as listar_ok,
  to_regprocedure('public.obtener_expediente_contrato_v97(uuid)') is not null as expediente_ok,
  to_regprocedure('public.crear_enlace_brief_v97(uuid,integer)') is not null as compartir_ok,
  to_regprocedure('public.revocar_enlace_brief_v97(uuid)') is not null as revocar_ok,
  to_regprocedure('public.obtener_brief_publico_v97(text)') is not null as brief_publico_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'contrato_enlaces_compartidos_v97';

select
  has_function_privilege('authenticated','public.listar_contratos_v97(text,text,integer,integer)','execute') as listar_authenticated_ok,
  not has_function_privilege('anon','public.listar_contratos_v97(text,text,integer,integer)','execute') as listar_anon_bloqueado_ok,
  has_function_privilege('anon','public.obtener_brief_publico_v97(text)','execute') as brief_anon_ok,
  not has_table_privilege('anon','public.contrato_enlaces_compartidos_v97','select') as tokens_anon_ocultos_ok,
  not has_table_privilege('authenticated','public.contrato_enlaces_compartidos_v97','select') as hashes_authenticated_ocultos_ok;

select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'listar_contratos_v97','obtener_expediente_contrato_v97',
  'crear_enlace_brief_v97','revocar_enlace_brief_v97','obtener_brief_publico_v97'
) order by p.proname;

-- Todos deben ser cero.
select count(*) as enlaces_con_hash_invalido_debe_ser_cero
from public.contrato_enlaces_compartidos_v97
where token_hash !~ '^[0-9a-f]{64}$';

select count(*) as enlaces_vencidos_sin_marca_informativo
from public.contrato_enlaces_compartidos_v97
where vence_en <= now() and revocado_en is null;

select count(*) as archivos_sin_contrato_debe_ser_cero
from public.contrato_archivos a left join public.contratos c on c.id=a.contrato_id
where c.id is null;

-- Las RPC con sesion se prueban desde la interfaz. La verificacion no suplanta
-- auth.uid() para evitar falsos errores al ejecutarla desde el editor SQL.
