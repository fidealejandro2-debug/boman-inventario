-- ============================================================
-- Verificación v127 - Personal de diseño conectado con Nómina
-- Solo lectura. Ejecutar después de v127.
-- ============================================================

select exists (
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'contratos'
    and column_name = 'disenador_empleado_id'
) as disenador_empleado_ok,
exists (
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'contratos'
    and column_name = 'autor_mockup_empleado_id'
) as autor_mockup_empleado_ok;

select
  to_regprocedure('public.listar_personal_diseno_v127()') is not null as catalogo_nomina_ok,
  to_regprocedure('public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid)') is not null as asignacion_ok,
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.contratos'::regclass
      and tgname = 'trg_sincronizar_personal_diseno_v127'
      and not tgisinternal
  ) as sincronizacion_compatibilidad_ok;

select
  has_function_privilege('authenticated', 'public.listar_personal_diseno_v127()', 'execute') as listar_authenticated_ok,
  has_function_privilege('authenticated', 'public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid)', 'execute') as asignar_authenticated_ok,
  not has_function_privilege('anon', 'public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid)', 'execute') as asignar_anon_revocado_ok;

-- Todos los siguientes resultados deben ser cero.
select count(*) as disenadores_enlazados_inconsistentes_debe_ser_cero
from public.contratos c
join public.empleados e on e.id = c.disenador_empleado_id
where public.normalizar_persona_v127(c.disenador) <>
      public.normalizar_persona_v127(concat_ws(' ', e.nombres, e.apellidos));

select count(*) as autores_mockup_enlazados_inconsistentes_debe_ser_cero
from public.contratos c
join public.empleados e on e.id = c.autor_mockup_empleado_id
where public.normalizar_persona_v127(c.autor_mockup) <>
      public.normalizar_persona_v127(concat_ws(' ', e.nombres, e.apellidos));

-- Informativo: son nombres históricos que no pudieron enlazarse de forma
-- inequívoca y deben resolverse manualmente desde el tablero.
select count(*) as disenadores_historicos_pendientes_de_enlazar
from public.contratos
where nullif(btrim(disenador), '') is not null and disenador_empleado_id is null;

select count(*) as autores_mockup_historicos_pendientes_de_enlazar
from public.contratos
where nullif(btrim(autor_mockup), '') is not null and autor_mockup_empleado_id is null;
