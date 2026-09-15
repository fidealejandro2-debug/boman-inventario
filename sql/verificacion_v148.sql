-- Verificacion v148. Solo lectura; ejecutar despues de la migracion.

select
  to_regclass('public.venta_rapida_v148') is not null as tabla_venta_ok,
  to_regclass('public.venta_rapida_lineas_v148') is not null as tabla_lineas_ok,
  to_regclass('public.venta_rapida_pagos_v148') is not null as tabla_pagos_ok,
  to_regclass('public.venta_comprobantes_pendientes_v148') is not null as tabla_pendientes_ok,
  to_regprocedure('public.preparar_comprobante_venta_v148(uuid,text,text,bigint,uuid)') is not null as preparar_ok,
  to_regprocedure('public.registrar_venta_rapida_v148(date,text,jsonb,jsonb,numeric,text,uuid,uuid)') is not null as registrar_ok,
  to_regprocedure('public.vincular_venta_rapida_factura_v148(uuid,uuid)') is not null as vincular_ok,
  to_regprocedure('public.marcar_venta_rapida_sin_factura_v148(uuid,text)') is not null as sin_factura_ok,
  to_regprocedure('public.anular_venta_rapida_v148(uuid,text,uuid)') is not null as anular_ok;

select id, public, file_size_limit, allowed_mime_types
from storage.buckets where id = 'ventas-comprobantes';

select
  has_function_privilege('authenticated','public.registrar_venta_rapida_v148(date,text,jsonb,jsonb,numeric,text,uuid,uuid)','execute') as registrar_permitido,
  not has_function_privilege('anon','public.registrar_venta_rapida_v148(date,text,jsonb,jsonb,numeric,text,uuid,uuid)','execute') as registrar_anon_bloqueado,
  exists(select 1 from public.rol_permisos where rol::text='tienda' and permiso_codigo='franquicia.ventas' and permitido) as tienda_tiene_ventas;

-- RLS activo y anon sin privilegios en las 4 tablas.
select relname, relrowsecurity
from pg_class where relname in (
  'venta_rapida_v148','venta_rapida_lineas_v148','venta_rapida_pagos_v148','venta_comprobantes_pendientes_v148'
);
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_name in ('venta_rapida_v148','venta_rapida_lineas_v148','venta_rapida_pagos_v148','venta_comprobantes_pendientes_v148')
  and grantee in ('anon','public');
-- La consulta de arriba debe devolver CERO filas.

select policyname, tablename from pg_policies
where tablename in ('venta_rapida_v148','venta_rapida_lineas_v148','venta_rapida_pagos_v148')
order by tablename;

select policyname from pg_policies where tablename = 'objects' and policyname like '%comprobante_venta_v148%';
