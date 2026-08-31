-- ============================================================
-- Verificacion v28 - Novedades disciplinarias
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v28 y nunca en paralelo con la migracion.
-- ============================================================

-- 1. Objetos creados
select
  to_regclass('public.novedades_empleado') is not null as novedades_ok,
  to_regclass('public.novedad_documentos') is not null as evidencias_ok,
  to_regclass('public.vista_novedades_v28') is not null as vista_novedades_ok,
  to_regclass('public.vista_novedad_impresion_v28') is not null as vista_impresion_ok,
  to_regclass('public.vista_multas_pendientes_v28') is not null as vista_multas_ok;

-- 2. Funciones instaladas
select
  to_regprocedure('public.tope_multa_empleado_v28(uuid,date)') is not null
    as tope_multa_ok,
  to_regprocedure('public.guardar_novedad_v28(uuid,uuid,uuid,text,date,text,text,text,text,boolean,numeric,uuid)') is not null
    as guardar_ok,
  to_regprocedure('public.emitir_novedad_v28(uuid,date)') is not null
    as emitir_ok,
  to_regprocedure('public.notificar_novedad_v28(uuid,text,uuid,text)') is not null
    as notificar_ok,
  to_regprocedure('public.registrar_descargo_novedad_v28(uuid,text)') is not null
    as descargo_ok,
  to_regprocedure('public.resolver_novedad_v28(uuid,text,uuid,uuid)') is not null
    as resolver_ok,
  to_regprocedure('public.anular_novedad_v28(uuid,text)') is not null
    as anular_ok,
  to_regprocedure('public.adjuntar_documento_novedad_v28(uuid,uuid,text)') is not null
    as adjuntar_ok,
  to_regprocedure('public.contar_novedades_v28(uuid,integer,date)') is not null
    as contar_ok;

-- 3. nomina_eventos acepta la entidad 'novedad' sin haber perdido las de v26/v27
select
  pg_get_constraintdef(c.oid) as definicion_entidad
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname = 'nomina_eventos'
  and c.conname = 'nomina_eventos_entidad_check';

-- 4. RLS activa
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('novedades_empleado', 'novedad_documentos')
order by tablename;

-- 5. Las vistas respetan el RLS de las tablas base.
--    Sin security_invoker cualquier autenticado leeria el expediente.
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
  and c.relname in (
    'vista_novedades_v28', 'vista_novedad_impresion_v28',
    'vista_multas_pendientes_v28'
  )
order by c.relname;

-- 6. Las dos funciones de consulta NO deben ser security definer: si lo
--    fueran, un usuario sin acceso a nomina deduciria el sueldo real a
--    partir del tope de multa.
select
  p.proname,
  p.prosecdef as security_definer_debe_ser_false
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('tope_multa_empleado_v28', 'contar_novedades_v28')
order by p.proname;

-- 7. Las RPC de escritura si deben ser security definer y de postgres
select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'guardar_novedad_v28', 'emitir_novedad_v28', 'notificar_novedad_v28',
    'registrar_descargo_novedad_v28', 'resolver_novedad_v28',
    'anular_novedad_v28', 'adjuntar_documento_novedad_v28'
  )
order by p.proname;

-- 8. anon no ejecuta nada
select
  has_function_privilege(
    'authenticated', 'public.emitir_novedad_v28(uuid,date)', 'execute'
  ) as emitir_authenticated_ok,
  not has_function_privilege(
    'anon', 'public.emitir_novedad_v28(uuid,date)', 'execute'
  ) as emitir_anon_debe_ser_true,
  not has_function_privilege(
    'anon', 'public.anular_novedad_v28(uuid,text)', 'execute'
  ) as anular_anon_debe_ser_true,
  not has_function_privilege(
    'anon', 'public.tope_multa_empleado_v28(uuid,date)', 'execute'
  ) as tope_anon_debe_ser_true;

-- 9. Indice unico del correlativo
select indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and indexname = 'uq_novedades_correlativo_v28';

-- ------------------------------------------------------------
-- Consistencia de datos. Todos los conteos deben ser cero.
-- ------------------------------------------------------------

-- Correlativos repetidos dentro del mismo RUC y anio
select count(*) as correlativos_repetidos_debe_ser_cero
from (
  select empresa_id, anio, numero
  from public.novedades_empleado
  where numero is not null
  group by empresa_id, anio, numero
  having count(*) > 1
) t;

-- Novedades emitidas sin correlativo asignado
select count(*) as emitidas_sin_numero_debe_ser_cero
from public.novedades_empleado
where estado in ('emitida', 'notificada', 'con_descargo', 'archivada')
  and numero is null;

-- Borradores que ya consumieron numero
select count(*) as borradores_con_numero_debe_ser_cero
from public.novedades_empleado
where estado = 'borrador' and numero is not null;

-- Estados avanzados sin constancia de notificacion
select count(*) as sin_notificacion_debe_ser_cero
from public.novedades_empleado
where estado in ('notificada', 'con_descargo', 'archivada')
  and (notificado_at is null or forma_notificacion is null);

-- Multas sin monto, o montos sin multa declarada
select count(*) as multas_incoherentes_debe_ser_cero
from public.novedades_empleado
where (genera_descuento and monto_descuento is null)
   or (not genera_descuento and monto_descuento is not null);

-- Felicitaciones que sancionan
select count(*) as felicitaciones_que_sancionan_debe_ser_cero
from public.novedades_empleado
where tipo = 'felicitacion'
  and (genera_descuento or ausencia_id is not null);

-- Suspensiones enlazadas a una ausencia de otro empleado o de otro tipo
select count(*) as suspensiones_mal_enlazadas_debe_ser_cero
from public.novedades_empleado n
join public.ausencias a on a.id = n.ausencia_id
where a.empleado_id <> n.empleado_id
   or a.tipo <> 'suspension_disciplinaria';

-- Evidencias que no pertenecen al empleado de la novedad
select count(*) as evidencias_ajenas_debe_ser_cero
from public.novedad_documentos nd
join public.novedades_empleado n on n.id = nd.novedad_id
join public.empleado_documentos d on d.id = nd.documento_id
where d.empleado_id <> n.empleado_id;

-- Multas que superan el tope vigente de los parametros del anio
select count(*) as multas_sobre_el_tope_debe_ser_cero
from public.novedades_empleado n
where n.genera_descuento
  and n.estado <> 'anulada'
  and n.monto_descuento > coalesce(
    public.tope_multa_empleado_v28(n.empleado_id, n.fecha_hechos),
    n.monto_descuento
  );

-- ------------------------------------------------------------
-- Panorama del expediente disciplinario (informativo)
-- ------------------------------------------------------------
select
  tipo,
  estado,
  count(*) as novedades
from public.novedades_empleado
group by tipo, estado
order by tipo, estado;

-- Reincidencia del ultimo anio, de mayor a menor
select
  nombre_completo,
  empresa,
  count(*) as sanciones_ultimo_anio
from public.vista_novedades_v28
where estado in ('emitida', 'notificada', 'con_descargo', 'archivada')
  and tipo in (
    'llamado_atencion', 'amonestacion_escrita', 'sancion_economica',
    'solicitud_visto_bueno'
  )
  and fecha_hechos > current_date - 365
group by nombre_completo, empresa
having count(*) > 1
order by sanciones_ultimo_anio desc, nombre_completo;

-- Multas esperando que v29 les cree el descuento
select count(*) as multas_pendientes_de_descuento
from public.vista_multas_pendientes_v28;
