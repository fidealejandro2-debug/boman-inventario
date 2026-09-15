-- Verificacion v149. Solo lectura; ejecutar despues de la migracion.

select
  exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='venta_franquicia_pagos'
      and column_name='comprobante_storage_path'
  ) as columna_comprobante_ok,
  coalesce((select position('Las ventas con transferencia requieren comprobante adjunto'
    in pg_get_functiondef(p.oid)) > 0
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='registrar_venta_franquicia_v143' limit 1), false) as exige_comprobante_ok;

select exists(select 1 from public.schema_migrations_boman where id='v149') as migracion_registrada;
