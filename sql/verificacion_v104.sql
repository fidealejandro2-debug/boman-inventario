-- ============================================================
-- Verificacion v104 - Instrumentos y migracion de cheques
-- Solo lectura. Ejecutar despues de instalar v104.
-- Las consultas de datos respetan la sesion y permisos de Tesoreria.
-- ============================================================

select
  to_regclass('public.tesoreria_cuentas_bancarias') is not null as cuentas_bancarias_ok,
  to_regclass('public.tesoreria_saldos_bancarios') is not null as saldos_ok,
  to_regclass('public.tesoreria_instrumentos_pago') is not null as instrumentos_ok,
  to_regclass('public.tesoreria_instrumento_aplicaciones') is not null as aplicaciones_ok,
  to_regclass('public.tesoreria_importaciones') is not null as importaciones_ok,
  to_regclass('public.tesoreria_importacion_lineas') is not null as lineas_importacion_ok,
  to_regclass('public.tesoreria_instrumento_eventos') is not null as eventos_ok;

select
  to_regclass('public.vista_instrumentos_tesoreria_v104') is not null as instrumentos_vista_ok,
  to_regclass('public.vista_efectivo_comprometido_v104') is not null as compromisos_vista_ok,
  to_regclass('public.vista_cuentas_por_pagar_v104') is not null as cartera_vista_ok,
  to_regclass('public.vista_resumen_compromisos_v104') is not null as resumen_vista_ok,
  to_regclass('public.vista_importacion_cheques_v104') is not null as importacion_vista_ok;

select
  to_regprocedure('public.guardar_cuenta_bancaria_v104(uuid,uuid,text,text,text,text,text,boolean,text,uuid)') is not null as guardar_cuenta_ok,
  to_regprocedure('public.registrar_saldo_bancario_v104(uuid,date,numeric,text,text,uuid)') is not null as registrar_saldo_ok,
  to_regprocedure('public.cargar_cheques_migracion_v104(text,text,date,jsonb,text,uuid)') is not null as cargar_lote_ok,
  to_regprocedure('public.confirmar_cheque_importado_v104(uuid,uuid,uuid,text,text,uuid)') is not null as confirmar_importado_ok,
  to_regprocedure('public.descartar_linea_importacion_v104(uuid,text,uuid)') is not null as descartar_linea_ok,
  to_regprocedure('public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid)') is not null as registrar_cheque_ok,
  to_regprocedure('public.gestionar_instrumento_v104(uuid,text,date,text,uuid)') is not null as gestionar_estado_ok,
  to_regprocedure('public.aplicar_instrumento_cxp_v104(uuid,uuid,numeric,text,uuid)') is not null as aplicar_cxp_ok;

select tablename, rowsecurity
from pg_tables
where schemaname='public' and tablename in(
  'tesoreria_cuentas_bancarias','tesoreria_saldos_bancarios',
  'tesoreria_instrumentos_pago','tesoreria_instrumento_aplicaciones',
  'tesoreria_importaciones','tesoreria_importacion_lineas',
  'tesoreria_instrumento_eventos'
)
order by tablename;

select c.relname,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
    where option_name='security_invoker'),'false') as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in(
  'vista_instrumentos_tesoreria_v104','vista_efectivo_comprometido_v104',
  'vista_cuentas_por_pagar_v104','vista_resumen_compromisos_v104',
  'vista_importacion_cheques_v104'
)
order by c.relname;

select
  has_function_privilege('authenticated','public.cargar_cheques_migracion_v104(text,text,date,jsonb,text,uuid)','execute') as importar_authenticated_ok,
  not has_function_privilege('anon','public.cargar_cheques_migracion_v104(text,text,date,jsonb,text,uuid)','execute') as importar_anon_revocado,
  has_function_privilege('authenticated','public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid)','execute') as registrar_authenticated_ok,
  not has_function_privilege('anon','public.gestionar_instrumento_v104(uuid,text,date,text,uuid)','execute') as gestionar_anon_revocado,
  not has_function_privilege('authenticated','public.validar_aplicacion_instrumento_v104()','execute') as trigger_directo_revocado,
  not has_table_privilege('authenticated','public.tesoreria_instrumentos_pago','insert') as insert_directo_revocado,
  not has_table_privilege('authenticated','public.tesoreria_importacion_lineas','update') as update_linea_directo_revocado;

select p.proname,p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in(
  'validar_aplicacion_instrumento_v104','guardar_cuenta_bancaria_v104',
  'sincronizar_instrumento_pago_v73_v104',
  'registrar_saldo_bancario_v104','cargar_cheques_migracion_v104',
  'confirmar_cheque_importado_v104','registrar_cheque_v104',
  'descartar_linea_importacion_v104',
  'gestionar_instrumento_v104','aplicar_instrumento_cxp_v104'
)
order by p.proname;

-- Todos los siguientes resultados deben ser cero.
select count(*) as cheques_v73_sin_instrumento_debe_ser_cero
from public.cuentas_por_pagar_pagos p
where p.medio='cheque' and not exists(
  select 1 from public.tesoreria_instrumentos_pago i where i.pago_v73_id=p.id
);

select count(*) as instrumentos_con_cuenta_ajena_debe_ser_cero
from public.tesoreria_instrumentos_pago i
left join public.tesoreria_cuentas_bancarias cb on cb.id=i.cuenta_bancaria_id
join public.empresas e on e.id=i.empresa_pagadora_id
where e.grupo_id<>i.grupo_id
   or (i.cuenta_bancaria_id is not null and (
     cb.id is null or cb.grupo_id<>i.grupo_id
     or cb.empresa_titular_id<>i.empresa_pagadora_id
   ));

select count(*) as cheques_incompletos_debe_ser_cero
from public.tesoreria_instrumentos_pago
where medio='cheque' and (
  cuenta_bancaria_id is null or btrim(coalesce(numero_instrumento,''))=''
);

select count(*) as numeros_cheque_duplicados_debe_ser_cero
from(
  select cuenta_bancaria_id,lower(btrim(numero_instrumento)) numero
  from public.tesoreria_instrumentos_pago where medio='cheque'
  group by cuenta_bancaria_id,lower(btrim(numero_instrumento)) having count(*)>1
) x;

select count(*) as instrumentos_sobreaplicados_debe_ser_cero
from public.tesoreria_instrumentos_pago i
join lateral(
  select coalesce(sum(a.monto),0) aplicado
  from public.tesoreria_instrumento_aplicaciones a where a.instrumento_id=i.id
) x on true
where x.aplicado>i.monto;

select count(*) as aplicaciones_entre_pagadoras_debe_ser_cero
from public.tesoreria_instrumento_aplicaciones a
join public.tesoreria_instrumentos_pago i on i.id=a.instrumento_id
join public.cuentas_por_pagar c on c.id=a.cuenta_por_pagar_id
where i.grupo_id<>c.grupo_id or i.empresa_pagadora_id<>c.empresa_pagadora_id;

select count(*) as cuentas_sobrecubiertas_debe_ser_cero
from public.vista_cuentas_por_pagar_v104
where total_pagado+total_comprometido>total_exigible;

select count(*) as cobrados_sin_fecha_debe_ser_cero
from public.tesoreria_instrumentos_pago
where estado='cobrado' and fecha_efectiva is null;

select count(*) as lineas_migradas_sin_instrumento_debe_ser_cero
from public.tesoreria_importacion_lineas
where estado='migrada' and instrumento_id is null;

select count(*) as instrumentos_importados_sin_linea_debe_ser_cero
from public.tesoreria_instrumentos_pago
where origen='migracion_excel' and importacion_linea_id is null;

select count(*) as lotes_con_totales_inconsistentes_debe_ser_cero
from public.tesoreria_importaciones i
join lateral(
  select count(*)::integer total,
    count(*) filter(where l.estado='migrada')::integer migradas
  from public.tesoreria_importacion_lineas l where l.importacion_id=i.id
) x on true
where i.total_filas<>x.total or i.filas_migradas<>x.migradas;

select count(*) as eventos_incompletos_debe_ser_cero
from public.tesoreria_instrumento_eventos
where usuario_id is null or idempotency_key is null
   or length(btrim(detalle))<5;

-- Panorama informativo del efectivo efectivamente comprometido.
select empresa_pagadora_codigo,alias,banco,numero_cuenta,saldo_fecha,
  saldo_disponible,comprometido_total,comprometido_vencido,
  comprometido_7_dias,comprometido_30_dias,comprometido_60_dias,
  comprometido_90_dias,saldo_proyectado_30_dias,
  saldo_proyectado_total,cheques_pendientes
from public.vista_resumen_compromisos_v104
order by empresa_pagadora_codigo,alias;

select fecha_compromiso,empresa_pagadora_codigo,cuenta_alias,
  beneficiario,numero_instrumento,estado,monto,monto_sin_asignar,horizonte
from public.vista_efectivo_comprometido_v104
order by fecha_compromiso,empresa_pagadora_codigo,numero_instrumento;
