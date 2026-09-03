-- ============================================================
-- Verificacion v73 - Cuentas por pagar y efectivo comprometido
-- Solo lectura: ejecutar despues de instalar v73.
-- ============================================================

select
  to_regclass('public.tesoreria_configuracion') is not null as configuracion_ok,
  to_regclass('public.cuentas_por_pagar') is not null as cuentas_ok,
  to_regclass('public.cuentas_por_pagar_pagos') is not null as pagos_ok,
  to_regclass('public.cuentas_por_pagar_eventos') is not null as eventos_ok,
  to_regclass('public.vista_cuentas_por_pagar_v73') is not null as cartera_ok,
  to_regclass('public.vista_efectivo_comprometido_v73') is not null as flujo_ok,
  to_regclass('public.vista_resumen_tesoreria_v73') is not null as resumen_ok,
  to_regclass('public.vista_empresas_tesoreria_v73') is not null as empresas_ok;

select
  to_regprocedure('public.usuario_puede_tesoreria_v73(uuid,boolean)') is not null
    as acceso_ok,
  to_regprocedure('public.sincronizar_cuenta_comprobante_v73()') is not null
    as sincronizacion_ok,
  to_regprocedure('public.configurar_tesoreria_v73(uuid,integer,boolean,text,uuid)') is not null
    as configurar_ok,
  to_regprocedure('public.actualizar_cuenta_por_pagar_v73(uuid,uuid,date,text,uuid)') is not null
    as actualizar_cuenta_ok,
  to_regprocedure('public.programar_pago_cuenta_v73(uuid,text,numeric,date,text,text,text,boolean,date,text,uuid)') is not null
    as programar_pago_ok,
  to_regprocedure('public.gestionar_pago_cuenta_v73(uuid,text,date,text,uuid)') is not null
    as gestionar_pago_ok;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'tesoreria_configuracion', 'cuentas_por_pagar',
    'cuentas_por_pagar_pagos', 'cuentas_por_pagar_eventos'
  )
order by tablename;

select c.relname,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
    where option_name = 'security_invoker'), 'false')
    as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'vista_cuentas_por_pagar_v73', 'vista_efectivo_comprometido_v73',
    'vista_resumen_tesoreria_v73', 'vista_empresas_tesoreria_v73'
  )
order by c.relname;

select
  has_function_privilege(
    'authenticated',
    'public.programar_pago_cuenta_v73(uuid,text,numeric,date,text,text,text,boolean,date,text,uuid)',
    'execute'
  ) as programar_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.programar_pago_cuenta_v73(uuid,text,numeric,date,text,text,text,boolean,date,text,uuid)',
    'execute'
  ) as programar_anon_revocado,
  not has_function_privilege(
    'authenticated', 'public.sincronizar_cuenta_comprobante_v73()', 'execute'
  ) as trigger_directo_revocado,
  not has_table_privilege('authenticated', 'public.cuentas_por_pagar', 'insert')
    as insert_directo_cuenta_revocado,
  not has_table_privilege('authenticated', 'public.cuentas_por_pagar_pagos', 'update')
    as update_directo_pago_revocado;

select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'usuario_puede_tesoreria_v73', 'sincronizar_cuenta_comprobante_v73',
  'configurar_tesoreria_v73', 'actualizar_cuenta_por_pagar_v73',
  'programar_pago_cuenta_v73', 'gestionar_pago_cuenta_v73'
)
order by p.proname;

-- Todos los siguientes resultados deben ser cero.
select count(*) as facturas_vigentes_sin_cuenta_debe_ser_cero
from public.comprobantes_compra cc
where cc.estado = 'registrado'
  and cc.tipo in ('factura', 'nota_venta', 'liquidacion_compra', 'nota_debito')
  and not exists (
    select 1 from public.cuentas_por_pagar c where c.comprobante_id = cc.id
  );

select count(*) as cuentas_con_entidades_de_otro_grupo_debe_ser_cero
from public.cuentas_por_pagar c
join public.empresas ed on ed.id = c.empresa_deudora_id
join public.empresas ep on ep.id = c.empresa_pagadora_id
join public.comprobantes_compra cc on cc.id = c.comprobante_id
where ed.grupo_id <> c.grupo_id or ep.grupo_id <> c.grupo_id
   or cc.empresa_id <> c.empresa_deudora_id
   or cc.proveedor_id <> c.proveedor_id;

select count(*) as configuraciones_con_pagadora_ajena_debe_ser_cero
from public.tesoreria_configuracion tc
join public.empresas e on e.id = tc.empresa_pagadora_predeterminada_id
where e.grupo_id <> tc.grupo_id or not e.activo;

select count(*) as cuentas_anuladas_con_pagos_activos_debe_ser_cero
from public.cuentas_por_pagar c
join public.cuentas_por_pagar_pagos p on p.cuenta_id = c.id
where c.estado_registro = 'anulada' and p.estado <> 'anulado';

select count(*) as facturas_anuladas_con_cuenta_activa_debe_ser_cero
from public.cuentas_por_pagar c
join public.comprobantes_compra cc on cc.id = c.comprobante_id
where cc.estado = 'anulado' and c.estado_registro <> 'anulada';

select count(*) as pagos_con_pagadora_inconsistente_debe_ser_cero
from public.cuentas_por_pagar_pagos p
join public.cuentas_por_pagar c on c.id = p.cuenta_id
where p.empresa_pagadora_id <> c.empresa_pagadora_id;

select count(*) as cheques_incompletos_debe_ser_cero
from public.cuentas_por_pagar_pagos
where medio = 'cheque' and (
  btrim(coalesce(banco, '')) = '' or btrim(coalesce(numero_cuenta, '')) = ''
  or btrim(coalesce(numero_cheque, '')) = ''
);

select count(*) as cuentas_sobrecubiertas_debe_ser_cero
from public.vista_cuentas_por_pagar_v73
where total_pagado + total_comprometido > total_exigible;

select count(*) as pagos_confirmados_sin_fecha_debe_ser_cero
from public.cuentas_por_pagar_pagos
where estado = 'pagado' and fecha_pago is null;

select count(*) as pagos_futuros_marcados_pagados_debe_ser_cero
from public.cuentas_por_pagar_pagos
where estado = 'pagado' and fecha_programada > current_date;

select count(*) as eventos_incompletos_debe_ser_cero
from public.cuentas_por_pagar_eventos
where usuario_id is null or idempotency_key is null
   or length(btrim(detalle)) < 5;

-- Panorama informativo por compania que desembolsa.
select empresa_pagadora_codigo, empresa_pagadora,
       saldo_total, saldo_vencido, saldo_por_programar,
       comprometido_total, comprometido_hoy,
       comprometido_7_dias, comprometido_30_dias,
       cheques_en_transito
from public.vista_resumen_tesoreria_v73
where saldo_total <> 0 or comprometido_total <> 0
order by empresa_pagadora_codigo;

select fecha_programada, empresa_pagadora_codigo, proveedor,
       numero_documento, medio, numero_cheque, estado, monto
from public.vista_efectivo_comprometido_v73
where estado in ('programado', 'emitido', 'entregado')
order by fecha_programada, empresa_pagadora_codigo, proveedor;
