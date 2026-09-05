-- ============================================================
-- Verificacion v86 - Actas y avisos de conteos fisicos
-- Solo lectura. Ejecutar despues de instalar v86.
-- ============================================================

select
  to_regclass('public.vista_actas_conteos_v86') is not null as vista_actas_ok,
  to_regprocedure('public.notificar_resolucion_conteo_v86()') is not null as notificador_ok;

select trigger_name, event_manipulation, action_timing
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name = 'trg_notificar_resolucion_conteo_v86';

select c.relname,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
    where option_name = 'security_invoker'), 'false') as security_invoker_debe_ser_true
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_actas_conteos_v86';

select
  has_table_privilege('authenticated', 'public.vista_actas_conteos_v86', 'select')
    as lectura_authenticated_ok,
  not has_function_privilege('authenticated', 'public.notificar_resolucion_conteo_v86()', 'execute')
    as trigger_directo_bloqueado_ok;

-- Todos deben ser cero.
select count(*) as actas_aplicadas_sin_aprobador_debe_ser_cero
from public.vista_actas_conteos_v86
where estado = 'aplicado'
  and (aprobado_por is null or aprobado_at is null or aplicado_at is null);

select count(*) as actas_con_totales_invalidos_debe_ser_cero
from public.vista_actas_conteos_v86
where lineas_relevantes > lineas_total
   or diferencias_primer_conteo > lineas_total
   or diferencias_finales > lineas_total
   or unidades_incrementadas < 0 or unidades_disminuidas < 0;

select count(*) as avisos_conteo_incompletos_debe_ser_cero
from public.notificaciones_comunicados
where origen_tipo = 'conteo'
  and (almacen_id is null or btrim(coalesce(titulo, '')) = ''
    or btrim(coalesce(mensaje, '')) = '');

select numero, almacen, estado, creado_por_nombre, revisado_por_nombre,
       aprobado_por_nombre, diferencias_primer_conteo, diferencias_finales,
       unidades_incrementadas, unidades_disminuidas, aprobado_at
from public.vista_actas_conteos_v86
order by iniciado_at desc
limit 50;
