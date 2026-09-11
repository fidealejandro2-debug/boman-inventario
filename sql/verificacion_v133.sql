-- ============================================================
-- Verificacion v133 - Cheques sin factura
-- Solo lectura. Ejecutar despues de instalar v133.
-- ============================================================

-- 1) Las columnas nuevas y la funcion con el parametro de comprobante.
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='tesoreria_instrumentos_pago'
      and column_name in ('comprobante_estado','comprobante_id')) = 2 as columnas_ok,
  to_regprocedure('public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid,text)') is not null as registrar_ok,
  -- La firma vieja NO debe seguir existiendo: dos candidatas hacen ambigua la llamada.
  to_regprocedure('public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid)') is null as firma_vieja_borrada_ok,
  to_regprocedure('public.regularizar_cheque_v133(uuid,uuid,text,uuid)') is not null as regularizar_ok;

-- 2) Un cheque "regularizado" sin comprobante enlazado seria mentira: debe
--    existir el check que lo impide.
select count(*) = 1 as check_coherencia_ok
  from pg_constraint
 where conname = 'tesoreria_instrumento_comprobante_v133';

-- 3) La vista expone el estado del comprobante (la pantalla lo lee de ahi).
select count(*) = 3 as vista_ok
  from information_schema.columns
 where table_schema='public' and table_name='vista_instrumentos_tesoreria_v104'
   and column_name in ('comprobante_estado','comprobante_id','comprobante_numero');

-- 4) Privilegios: authenticated si, anon no.
select
  has_function_privilege('authenticated','public.regularizar_cheque_v133(uuid,uuid,text,uuid)','execute') as auth_ok,
  not has_function_privilege('anon','public.regularizar_cheque_v133(uuid,uuid,text,uuid)','execute') as anon_bloqueado_ok;

-- 5) Como quedaron los instrumentos existentes. Todos deberian estar en
--    'no_aplica': son los historicos, que no contrajeron deuda documental nueva.
select comprobante_estado, count(*) as instrumentos, sum(monto) as monto
  from public.tesoreria_instrumentos_pago
 group by comprobante_estado order by instrumentos desc;

-- 6) Lo que habria que regularizar (vacio hasta que se use la pantalla).
select numero_instrumento, beneficiario, monto, fecha_compromiso
  from public.vista_instrumentos_tesoreria_v104
 where comprobante_estado = 'pendiente'
 order by fecha_compromiso
 limit 30;
