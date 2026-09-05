-- ============================================================
-- Verificacion v87 - Conciliacion y depositos de caja
-- Solo lectura. Ejecutar despues de instalar v87.
-- ============================================================

select
  to_regclass('public.caja_depositos_v87') is not null as depositos_ok,
  to_regclass('public.vista_depositos_caja_v87') is not null as vista_ok,
  to_regprocedure('public.registrar_deposito_caja_v87(uuid,date,numeric,text,text,text,text,uuid)') is not null as registrar_ok,
  to_regprocedure('public.confirmar_deposito_caja_v87(uuid,text)') is not null as confirmar_ok,
  to_regprocedure('public.proteger_movimiento_deposito_v87()') is not null as protector_ok;

select trigger_name, event_manipulation, action_timing
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name = 'trg_proteger_movimiento_deposito_v87';

select tablename, rowsecurity from pg_tables
where schemaname = 'public' and tablename = 'caja_depositos_v87';

select
  has_function_privilege('authenticated', 'public.registrar_deposito_caja_v87(uuid,date,numeric,text,text,text,text,uuid)', 'execute') as registrar_authenticated_ok,
  has_function_privilege('authenticated', 'public.confirmar_deposito_caja_v87(uuid,text)', 'execute') as confirmar_authenticated_ok,
  not has_function_privilege('anon', 'public.registrar_deposito_caja_v87(uuid,date,numeric,text,text,text,text,uuid)', 'execute') as anon_bloqueado_ok,
  not has_table_privilege('authenticated', 'public.caja_depositos_v87', 'insert') as insert_directo_bloqueado_ok;

select c.relname,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
    where option_name = 'security_invoker'), 'false') as security_invoker_debe_ser_true
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_depositos_caja_v87';

-- Todos deben ser cero.
select count(*) as depositos_inconsistentes_debe_ser_cero
from public.caja_depositos_v87 d
join public.franquicia_caja_cierres c on c.id = d.cierre_id
left join public.franquicia_caja_movimientos m on m.id = d.movimiento_id
where d.almacen_id <> c.almacen_id
   or m.id is null or m.almacen_id <> d.almacen_id
   or m.tipo <> 'egreso' or m.medio_pago <> 'efectivo'
   or m.monto <> d.monto
   or (d.estado = 'anulado' and m.estado <> 'revertido')
   or (d.estado <> 'anulado' and m.estado <> 'vigente');

select count(*) as cierres_sobredepositados_debe_ser_cero
from (
  select c.id
  from public.caja_depositos_v87 d
  join public.franquicia_caja_cierres c on c.id = d.cierre_id
  where d.estado <> 'anulado'
  group by c.id, c.efectivo_contado
  having sum(d.monto) > c.efectivo_contado
) inconsistentes;

select count(*) as confirmaciones_incompletas_debe_ser_cero
from public.caja_depositos_v87
where estado = 'confirmado'
  and (confirmado_por is null or confirmado_at is null);

select count(*) as anulaciones_incompletas_debe_ser_cero
from public.caja_depositos_v87
where estado = 'anulado'
  and (confirmado_por is not null or confirmado_at is not null);

select almacen, fecha_cierre, efectivo_contado, fecha_deposito,
       monto, banco, referencia, estado, registrado_por_nombre,
       confirmado_por_nombre
from public.vista_depositos_caja_v87
order by created_at desc
limit 50;
