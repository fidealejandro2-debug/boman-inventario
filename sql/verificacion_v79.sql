-- ============================================================
-- Verificacion v79 - Esquema de contratos de Boman Sport
-- Solo lectura: ejecutar despues de instalar v79. Antes de la carga de datos
-- todo esta vacio a proposito; esto valida ESTRUCTURA, no contenido.
-- ============================================================

-- 1. Las 8 tablas existen.
select
  to_regclass('public.contratos') is not null as contratos_ok,
  to_regclass('public.contrato_prendas') is not null as prendas_ok,
  to_regclass('public.contrato_jugadores') is not null as jugadores_ok,
  to_regclass('public.contrato_archivos') is not null as archivos_ok,
  to_regclass('public.contrato_specs') is not null as specs_ok,
  to_regclass('public.contrato_facturacion') is not null as facturacion_ok,
  to_regclass('public.contrato_etapas') is not null as etapas_ok,
  to_regclass('public.contrato_eventos') is not null as eventos_ok;

-- 2. Permisos registrados y otorgados a admin.
select codigo, descripcion from public.permisos_sistema
where codigo like 'contratos.%' order by codigo;

select rol, permiso_codigo, permitido from public.rol_permisos
where permiso_codigo like 'contratos.%' order by rol, permiso_codigo;

-- 3. RLS encendida en las 8 tablas, sin escritura directa para authenticated
-- (todo pasa por RPC, que aun no existen).
select tablename, rowsecurity from pg_tables
where schemaname = 'public' and tablename like 'contrato%'
order by tablename;

select
  t.tablename,
  has_table_privilege('authenticated', 'public.' || t.tablename, 'select') as lectura_ok,
  not has_table_privilege('authenticated', 'public.' || t.tablename, 'insert') as insert_bloqueado,
  not has_table_privilege('authenticated', 'public.' || t.tablename, 'update') as update_bloqueado
from pg_tables t
where t.schemaname = 'public' and t.tablename like 'contrato%'
order by t.tablename;

-- 4. El trigger de updated_at esta activo.
select tgname, tgenabled from pg_trigger
where tgrelid = 'public.contratos'::regclass and tgname = 'trg_tocar_contrato_v79';

-- 5. Los indices esperados existen (ninguna fila con reporte de produccion
-- diario deberia hacer table scan sobre contratos ni contrato_prendas).
select indexname from pg_indexes
where schemaname = 'public' and tablename in ('contratos', 'contrato_prendas')
order by indexname;
