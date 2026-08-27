-- ============================================================
-- Verificación v16 - Incidencias de transferencia SGC
-- Solo lectura: no modifica datos.
-- ============================================================

select
  to_regclass('public.inventario_cuarentena') is not null as cuarentena_ok,
  to_regclass('public.incidencias_transferencia') is not null as incidencias_ok,
  to_regclass('public.incidencia_transferencia_lineas') is not null as lineas_ok,
  to_regclass('public.incidencia_transferencia_acciones') is not null as acciones_ok;

select
  to_regprocedure('public.recibir_transferencia(uuid,jsonb,text)') is not null as recepcion_v16_ok,
  to_regprocedure('public.resolver_incidencia_transferencia(uuid,jsonb,text,text,text,uuid)') is not null
    as resolucion_ok,
  to_regprocedure('public.puede_ver_incidencia_transferencia(uuid)') is not null as lectura_rls_ok;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'documento_inventario_lineas'
  and column_name in ('cantidad_no_conforme', 'cantidad_no_recibida')
order by column_name;

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'vista_stock_operativo'
  and column_name in ('transito_incidencia', 'stock_cuarentena')
order by column_name;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'inventario_cuarentena', 'incidencias_transferencia',
    'incidencia_transferencia_lineas', 'incidencia_transferencia_acciones'
  )
order by tablename;

select
  has_function_privilege('authenticated', 'public.cerrar_incidencia_transferencia(uuid,text)', 'execute')
    as cierre_legado_debe_ser_false,
  has_function_privilege('authenticated', 'public.resolver_incidencia_transferencia(uuid,jsonb,text,text,text,uuid)', 'execute')
    as resolver_nuevo_debe_ser_true;

select
  p.proname,
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('v_rol <> ''admin''' in pg_get_functiondef(p.oid)) > 0
    as perdida_exclusiva_admin,
  position('causa raíz' in pg_get_functiondef(p.oid)) > 0
    as exige_causa_raiz
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resolver_incidencia_transferencia';

-- Ambos resultados deben ser cero.
select count(*) as recepciones_mal_clasificadas_debe_ser_cero
from public.documento_inventario_lineas
where cantidad_recibida is not null
  and coalesce(cantidad_recibida, 0) + cantidad_no_conforme + cantidad_no_recibida
      <> coalesce(cantidad_despachada, 0);

select count(*) as incidencias_sin_lineas_debe_ser_cero
from public.incidencias_transferencia i
where not exists (
  select 1 from public.incidencia_transferencia_lineas l where l.incidencia_id = i.id
);

select
  count(*) filter (where estado <> 'resuelta') as incidencias_abiertas,
  coalesce(sum(
    (select sum(l.cantidad_no_recibida_inicial + l.cantidad_no_conforme_inicial)
     from public.incidencia_transferencia_lineas l where l.incidencia_id = i.id)
  ), 0) as unidades_inicialmente_afectadas
from public.incidencias_transferencia i;
