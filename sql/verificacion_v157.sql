-- Verificacion v157. Solo lectura; ejecutar despues de la migracion.

select
  has_table_privilege('authenticated','public.venta_rapida_v148','select') as venta_select_ok,
  has_table_privilege('authenticated','public.venta_rapida_lineas_v148','select') as lineas_select_ok,
  has_table_privilege('authenticated','public.venta_rapida_pagos_v148','select') as pagos_select_ok,
  not has_table_privilege('authenticated','public.venta_comprobantes_pendientes_v148','select') as pendientes_sigue_bloqueada_ok,
  not has_table_privilege('anon','public.venta_rapida_v148','select') as anon_bloqueado_ok;
