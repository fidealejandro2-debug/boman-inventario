-- ============================================================
-- Verificacion v31 - Reportes de nomina
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v31 y nunca en paralelo con la migracion.
-- ============================================================

-- 1. Vistas creadas
select
  to_regclass('public.vista_rol_real_v31') is not null as rol_real_ok,
  to_regclass('public.vista_rol_declarado_v31') is not null as rol_declarado_ok,
  to_regclass('public.vista_brecha_nomina_v31') is not null as brecha_ok,
  to_regclass('public.vista_costo_empleador_por_empresa_v31') is not null as costo_ok,
  to_regclass('public.vista_pagos_por_empresa_pagadora_v31') is not null as pagos_ok,
  to_regclass('public.vista_planilla_iess_v31') is not null as planilla_ok,
  to_regclass('public.vista_resumen_periodo_nomina_v31') is not null as resumen_ok,
  to_regclass('public.vista_rol_impresion_v31') is not null as impresion_ok,
  to_regclass('public.vista_rol_rubros_v31') is not null as rubros_ok;

-- 2. Todas deben respetar el RLS de las tablas base.
--    Sin security_invoker cualquier autenticado leeria sueldos reales.
select
  c.relname,
  coalesce(
    (select option_value from pg_options_to_table(c.reloptions)
     where option_name = 'security_invoker'),
    'false'
  ) as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname like 'vista_%_v31'
order by c.relname;

-- 3. anon no lee ninguna
select
  count(*) filter (where has_table_privilege('anon', c.oid, 'select')) as anon_debe_ser_cero,
  count(*) filter (where has_table_privilege('authenticated', c.oid, 'select')) as authenticated_todas
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname like 'vista_%_v31'
  and c.relkind = 'v';

-- ------------------------------------------------------------
-- Cuadres contables. Todos los conteos deben ser cero.
-- ------------------------------------------------------------

-- El rol declarado nunca puede incluir a un no afiliado
select count(*) as no_afiliados_en_planilla_debe_ser_cero
from public.vista_rol_declarado_v31 d
join public.nomina_rol_lineas l on l.id = d.rol_linea_id
where not l.afiliado;

-- El neto real jamas puede ser negativo: los descuentos se difieren
select count(*) as netos_negativos_debe_ser_cero
from public.vista_rol_real_v31
where neto_real < 0;

-- Ingresos menos egresos tiene que dar el neto real
select count(*) as neto_real_descuadrado_debe_ser_cero
from public.vista_rol_real_v31
where round(total_ingresos_real - total_egresos, 2) <> round(neto_real, 2);

-- La brecha nunca puede ser negativa: lo declarado no supera a lo real
select count(*) as brecha_invertida_debe_ser_cero
from public.vista_brecha_nomina_v31
where brecha_sueldo < 0;

-- Un afiliado siempre tiene RUC afiliador y fecha de afiliacion
select count(*) as afiliados_incompletos_debe_ser_cero
from public.nomina_rol_lineas
where afiliado
  and (empresa_afiliacion_id is null or fecha_afiliacion is null);

-- La afiliacion nunca precede al ingreso real
select count(*) as afiliacion_antes_del_ingreso_debe_ser_cero
from public.vista_brecha_nomina_v31
where dias_entre_ingreso_y_afiliacion < 0;

-- Los dias del rol deben cuadrar con los del periodo
select count(*) as dias_descuadrados_debe_ser_cero
from public.nomina_rol_lineas
where dias_laborados + dias_vacaciones
      + dias_ausencia_con_sueldo + dias_ausencia_sin_sueldo > dias_periodo;

-- La suma por empresa pagadora tiene que igualar el neto total del periodo
select count(*) as pagos_descuadrados_debe_ser_cero
from (
  select
    r.periodo_id,
    round(r.neto_a_pagar, 2) as neto_periodo,
    round(coalesce(sum(pg.total_a_pagar), 0), 2) as neto_por_pagadora
  from public.vista_resumen_periodo_nomina_v31 r
  left join public.vista_pagos_por_empresa_pagadora_v31 pg
    on pg.periodo_id = r.periodo_id
  group by r.periodo_id, r.neto_a_pagar
) t
where neto_periodo <> neto_por_pagadora;

-- La suma por empresa afiliadora tiene que igualar el costo total
select count(*) as costos_descuadrados_debe_ser_cero
from (
  select
    r.periodo_id,
    round(r.costo_empleador_real, 2) as costo_periodo,
    round(coalesce(sum(c.costo_real), 0), 2) as costo_por_empresa
  from public.vista_resumen_periodo_nomina_v31 r
  left join public.vista_costo_empleador_por_empresa_v31 c
    on c.periodo_id = r.periodo_id
  group by r.periodo_id, r.costo_empleador_real
) t
where costo_periodo <> costo_por_empresa;

-- ------------------------------------------------------------
-- Panorama del ultimo periodo calculado (informativo)
-- ------------------------------------------------------------
select anio, mes, estado, personas, afiliados, no_afiliados,
       neto_a_pagar, brecha_total, costo_empleador_real
from public.vista_resumen_periodo_nomina_v31
order by anio desc, mes desc
limit 6;

-- Cuanto pone cada RUC y cuanto de eso es por cuenta de otro
select anio, mes, empresa_pagadora, ruc, personas,
       personas_afiliadas_en_otro_ruc,
       total_a_pagar, pagado_por_cuenta_de_otro_ruc
from public.vista_pagos_por_empresa_pagadora_v31
order by anio desc, mes desc, total_a_pagar desc;

-- Las diez brechas individuales mas grandes del ultimo periodo
select nombre_completo, empresa_afiliacion, empresa_pagadora,
       sueldo_real, sueldo_declarado, brecha_sueldo, brecha_sueldo_pct
from public.vista_brecha_nomina_v31
where (anio, mes) = (
  select anio, mes from public.vista_resumen_periodo_nomina_v31
  order by anio desc, mes desc limit 1
)
order by brecha_sueldo desc nulls last
limit 10;
