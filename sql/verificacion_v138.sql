-- ============================================================
-- Verificacion v138 - Comprobantes privados de depositos
-- Solo lectura. Ejecutar despues de v138.
-- ============================================================

select
  to_regclass('public.caja_comprobantes_pendientes_v138') is not null
    as pendientes_ok,
  to_regprocedure('public.preparar_comprobante_deposito_v138(uuid,text,text,bigint,uuid)') is not null
    as preparar_ok,
  to_regprocedure('public.registrar_deposito_caja_v138(uuid,date,numeric,text,text,uuid,text,uuid)') is not null
    as registrar_ok,
  exists (
    select 1 from storage.buckets
    where id = 'caja-comprobantes' and not public
      and file_size_limit = 8388608
  ) as bucket_privado_ok;

select
  exists (
    select 1 from pg_attribute
    where attrelid = 'public.caja_depositos_v87'::regclass
      and attname = 'comprobante_storage_path' and not attisdropped
  ) as deposito_path_ok,
  has_function_privilege(
    'authenticated',
    'public.registrar_deposito_caja_v138(uuid,date,numeric,text,text,uuid,text,uuid)',
    'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon',
    'public.registrar_deposito_caja_v138(uuid,date,numeric,text,text,uuid,text,uuid)',
    'execute'
  ) as anon_sin_execute_ok;

select policyname, cmd
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and policyname in ('subir_comprobante_deposito_v138', 'leer_comprobante_deposito_v138')
order by policyname;

select count(*) as archivos_vinculados_sin_objeto_debe_ser_cero
from public.caja_depositos_v87 d
where d.comprobante_storage_path is not null
  and not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'caja-comprobantes'
      and o.name = d.comprobante_storage_path
  );

select count(*) as registro_migracion_debe_ser_uno
from public.schema_migrations_boman
where id = 'v138' and archivo = 'v138_comprobantes_depositos_caja.sql';
