-- ============================================================
-- Verificacion v32 - Trazabilidad de nomina
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v32 y nunca en paralelo con la migracion.
-- ============================================================

-- 1. Objetos creados
select
  to_regclass('public.nomina_cambios') is not null as bitacora_ok,
  to_regclass('public.vista_auditoria_nomina_v32') is not null as vista_auditoria_ok,
  to_regclass('public.vista_historial_sueldo_v32') is not null as vista_historial_ok,
  to_regclass('public.vista_cambios_sin_justificar_v32') is not null as vista_excepciones_ok;

-- 2. Columnas nuevas de motivo y respaldo
select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and table_name in ('empleado_compensacion', 'empleado_afiliaciones')
  and column_name in ('motivo_tipo', 'documento_respaldo_id')
order by table_name, column_name;

-- 3. Los cuatro triggers de auditoria deben existir y estar habilitados
select
  c.relname as tabla,
  t.tgname as trigger,
  t.tgenabled = 'O' as habilitado
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and t.tgname like '%_v32'
order by c.relname;

-- 4. Funciones instaladas
select
  to_regprocedure('public.registrar_compensacion_v32(uuid,uuid,numeric,date,text,text,uuid,uuid)') is not null
    as compensacion_ok,
  to_regprocedure('public.rectificar_compensacion_v32(uuid,numeric,uuid,text,uuid)') is not null
    as rectificar_ok,
  to_regprocedure('public.registrar_afiliacion_v32(uuid,boolean,uuid,date,numeric,date,text,text,uuid,uuid)') is not null
    as afiliacion_ok,
  to_regprocedure('public.guardar_nomina_parametros_v32(integer,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,text)') is not null
    as parametros_ok,
  to_regprocedure('public.fecha_en_periodo_cerrado_v32(date)') is not null
    as periodo_cerrado_ok,
  to_regprocedure('public.anio_con_roles_cerrados_v32(integer)') is not null
    as anio_cerrado_ok;

-- 5. Las versiones sin controles deben quedar fuera de servicio.
--    Si siguen disponibles, basta llamarlas para saltarse la validacion.
select
  not has_function_privilege(
    'authenticated',
    'public.registrar_compensacion_v26(uuid,uuid,numeric,date,text,uuid)',
    'execute'
  ) as v26_compensacion_revocada_debe_ser_true,
  not has_function_privilege(
    'authenticated',
    'public.registrar_afiliacion_v26(uuid,boolean,uuid,date,numeric,date,text,uuid)',
    'execute'
  ) as v26_afiliacion_revocada_debe_ser_true,
  not has_function_privilege(
    'authenticated',
    'public.guardar_nomina_parametros_v26(integer,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric)',
    'execute'
  ) as v26_parametros_revocada_debe_ser_true,
  has_function_privilege(
    'authenticated',
    'public.registrar_compensacion_v32(uuid,uuid,numeric,date,text,text,uuid,uuid)',
    'execute'
  ) as v32_compensacion_disponible_ok;

-- 6. La bitacora es de solo lectura desde la aplicacion
select
  has_table_privilege('authenticated', 'public.nomina_cambios', 'select') as lectura_ok,
  not has_table_privilege('authenticated', 'public.nomina_cambios', 'insert')
    as sin_insert_debe_ser_true,
  not has_table_privilege('authenticated', 'public.nomina_cambios', 'update')
    as sin_update_debe_ser_true,
  not has_table_privilege('authenticated', 'public.nomina_cambios', 'delete')
    as sin_delete_debe_ser_true,
  not has_table_privilege('anon', 'public.nomina_cambios', 'select')
    as anon_sin_lectura_debe_ser_true;

-- 7. Las vistas respetan el RLS de las tablas base
select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname like 'vista_%_v32'
order by c.relname;

-- 8. RLS activa en la bitacora
select tablename, rowsecurity
from pg_tables
where schemaname = 'public' and tablename = 'nomina_cambios';

-- ------------------------------------------------------------
-- Consistencia. Todos los conteos deben ser cero.
-- ------------------------------------------------------------

-- Cambios sensibles registrados sin ninguna justificacion
select count(*) as cambios_sensibles_sin_motivo
from public.vista_cambios_sin_justificar_v32;

-- Reducciones de sueldo sin documento de respaldo, posteriores a v32
select count(*) as reducciones_sin_respaldo_debe_ser_cero
from public.vista_historial_sueldo_v32
where variacion < 0
  and motivo_tipo is not null
  and not tiene_respaldo;

-- Desafiliaciones sin respaldo, posteriores a v32
select count(*) as desafiliaciones_sin_respaldo_debe_ser_cero
from public.empleado_afiliaciones
where motivo_tipo = 'desafiliacion' and documento_respaldo_id is null;

-- Compensaciones cuya vigencia cae en un periodo cerrado sin ser correccion
select count(*) as retroactivos_indebidos_debe_ser_cero
from public.empleado_compensacion
where motivo_tipo is not null
  and motivo_tipo <> 'correccion_error'
  and public.fecha_en_periodo_cerrado_v32(fecha_desde);

-- Documentos de respaldo que pertenecen a otra persona
select count(*) as respaldos_ajenos_debe_ser_cero
from public.empleado_compensacion c
join public.empleado_documentos d on d.id = c.documento_respaldo_id
where d.empleado_id <> c.empleado_id;

-- ------------------------------------------------------------
-- Panorama de auditoria (informativo)
-- ------------------------------------------------------------

-- Movimiento de la bitacora por tabla y campo sensible
select tabla, campo, count(*) as cambios
from public.nomina_cambios
where sensible
group by tabla, campo
order by cambios desc;

-- Quien cambio datos sensibles en los ultimos 90 dias
select usuario, db_usuario, count(*) as cambios_sensibles
from public.vista_auditoria_nomina_v32
where sensible and created_at > now() - interval '90 days'
group by usuario, db_usuario
order by cambios_sensibles desc;

-- Aumentos por tipo de motivo: el indicador que pide el SGC
select
  motivo_tipo,
  count(*) as veces,
  round(avg(variacion), 2) as variacion_promedio,
  count(*) filter (where tiene_respaldo) as con_respaldo
from public.vista_historial_sueldo_v32
where variacion is not null and motivo_tipo is not null
group by motivo_tipo
order by veces desc;

-- Cambios de cuenta bancaria: el vector de fraude que antes no dejaba rastro
select created_at, nombre_completo, valor_anterior, valor_nuevo, usuario
from public.vista_auditoria_nomina_v32
where campo = 'numero_cuenta' and operacion = 'modificacion'
order by created_at desc
limit 20;
