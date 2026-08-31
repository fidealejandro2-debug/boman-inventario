-- ============================================================
-- BOMAN INVENTARIO - Reportes de nomina v31
-- Vistas de explotacion sobre los roles congelados de v30: rol real, rol
-- declarado, brecha entre ambos, costo por RUC afiliador y desembolso por
-- RUC pagador. Solo lectura: no crea tablas ni modifica datos.
-- Ejecutar una sola vez DESPUES de v30.
--
-- Todas las vistas llevan security_invoker para respetar el RLS de las
-- tablas base. Sin eso cualquier autenticado leeria sueldos reales.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Rol real - lo que la persona efectivamente cobra
-- ------------------------------------------------------------
-- Cubre a todo el personal, afiliado o no. Es la base del rol individual
-- que se entrega y del costo verdadero de cada empresa.
create or replace view public.vista_rol_real_v31
with (security_invoker = true) as
select
  l.id as rol_linea_id,
  l.periodo_id,
  p.anio,
  p.mes,
  p.estado as estado_periodo,
  l.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  l.cargo,
  l.area,
  l.fecha_ingreso_real,
  l.afiliado,
  l.empresa_pagadora_id,
  pag.razon_social as empresa_pagadora,
  pag.ruc as ruc_pagador,

  l.dias_periodo,
  l.dias_laborados,
  l.dias_vacaciones,
  l.dias_ausencia_con_sueldo,
  l.dias_ausencia_sin_sueldo,
  l.horas_extra_50,
  l.horas_extra_100,

  l.sueldo_real,
  l.sueldo_proporcional_real,
  l.valor_horas_extra,
  l.comisiones,
  l.bonos,
  l.vacaciones_pagadas,
  l.decimo_tercero_mensualizado,
  l.decimo_cuarto_mensualizado,
  l.fondos_reserva_pagados,
  l.otros_ingresos,
  l.total_ingresos_real,

  l.aporte_personal,
  l.anticipos_cuota,
  l.multas,
  l.prestamos_iess,
  l.prestamos_empresa,
  l.retencion_judicial,
  l.otros_descuentos,
  l.total_egresos,

  l.neto_real,
  l.costo_empleador_real
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empleados e on e.id = l.empleado_id
left join public.empresas pag on pag.id = l.empresa_pagadora_id;

-- ------------------------------------------------------------
-- 2. Rol declarado - lo que consta ante el IESS
-- ------------------------------------------------------------
-- Excluye al personal no afiliado: no aparece en planilla.
create or replace view public.vista_rol_declarado_v31
with (security_invoker = true) as
select
  l.id as rol_linea_id,
  l.periodo_id,
  p.anio,
  p.mes,
  p.estado as estado_periodo,
  l.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  l.cargo,
  l.empresa_afiliacion_id,
  afi.razon_social as empresa_afiliacion,
  afi.ruc as ruc_afiliador,
  l.fecha_afiliacion,

  l.dias_laborados,
  l.sueldo_declarado,
  l.sueldo_proporcional_declarado,
  l.total_ingresos_declarado,
  l.aporte_personal,
  l.neto_declarado,

  l.aporte_patronal,
  l.provision_decimo_tercero,
  l.provision_decimo_cuarto,
  l.provision_vacaciones,
  l.provision_fondos_reserva,
  l.costo_empleador_declarado
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empleados e on e.id = l.empleado_id
join public.empresas afi on afi.id = l.empresa_afiliacion_id
where l.afiliado;

-- ------------------------------------------------------------
-- 3. Brecha entre lo real y lo declarado
-- ------------------------------------------------------------
-- El reporte que justifica todo el modulo. Incluye la brecha de fechas:
-- dias que la persona trabajo antes de que se registrara su afiliacion.
create or replace view public.vista_brecha_nomina_v31
with (security_invoker = true) as
select
  l.periodo_id,
  p.anio,
  p.mes,
  l.empleado_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  l.cargo,
  l.afiliado,
  afi.razon_social as empresa_afiliacion,
  pag.razon_social as empresa_pagadora,
  (l.empresa_pagadora_id is distinct from l.empresa_afiliacion_id)
    as paga_otro_ruc,

  l.sueldo_real,
  l.sueldo_declarado,
  l.sueldo_real - l.sueldo_declarado as brecha_sueldo,
  case
    when l.sueldo_real > 0
      then round((l.sueldo_real - l.sueldo_declarado) * 100 / l.sueldo_real, 2)
  end as brecha_sueldo_pct,

  l.total_ingresos_real,
  l.total_ingresos_declarado,
  l.total_ingresos_real - l.total_ingresos_declarado as brecha_ingresos,

  l.neto_real,
  l.neto_declarado,
  l.brecha as brecha_neto,

  l.costo_empleador_real,
  l.costo_empleador_declarado,
  l.costo_empleador_real - l.costo_empleador_declarado as brecha_costo,

  case
    when l.afiliado and l.fecha_afiliacion is not null and l.fecha_ingreso_real is not null
      then l.fecha_afiliacion - l.fecha_ingreso_real
  end as dias_entre_ingreso_y_afiliacion
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empleados e on e.id = l.empleado_id
left join public.empresas afi on afi.id = l.empresa_afiliacion_id
left join public.empresas pag on pag.id = l.empresa_pagadora_id;

-- ------------------------------------------------------------
-- 4. Costo de personal por RUC afiliador
-- ------------------------------------------------------------
-- Lo que cada empresa carga como costo laboral: declarado frente a real.
create or replace view public.vista_costo_empleador_por_empresa_v31
with (security_invoker = true) as
select
  p.id as periodo_id,
  p.anio,
  p.mes,
  l.empresa_afiliacion_id,
  coalesce(afi.razon_social, 'Sin afiliacion') as empresa,
  afi.ruc,
  count(*) as personas,
  count(*) filter (where l.afiliado) as afiliados,
  count(*) filter (where not l.afiliado) as no_afiliados,

  sum(l.sueldo_declarado) as masa_declarada,
  sum(l.sueldo_real) as masa_real,
  sum(l.sueldo_real - l.sueldo_declarado) as brecha_masa,

  sum(l.aporte_personal) as aporte_personal,
  sum(l.aporte_patronal) as aporte_patronal,
  sum(l.provision_decimo_tercero) as provision_decimo_tercero,
  sum(l.provision_decimo_cuarto) as provision_decimo_cuarto,
  sum(l.provision_vacaciones) as provision_vacaciones,
  sum(l.provision_fondos_reserva) as provision_fondos_reserva,

  sum(l.costo_empleador_declarado) as costo_declarado,
  sum(l.costo_empleador_real) as costo_real,
  sum(l.costo_empleador_real - l.costo_empleador_declarado) as brecha_costo
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
left join public.empresas afi on afi.id = l.empresa_afiliacion_id
group by p.id, p.anio, p.mes, l.empresa_afiliacion_id, afi.razon_social, afi.ruc;

-- ------------------------------------------------------------
-- 5. Desembolso por RUC pagador
-- ------------------------------------------------------------
-- Hoy casi todo sale de una persona natural aunque la afiliacion este en
-- otro RUC. Esta vista mide exactamente eso: cuanto dinero pone cada
-- empresa y cuanto de ese pago corresponde a gente afiliada en otra.
create or replace view public.vista_pagos_por_empresa_pagadora_v31
with (security_invoker = true) as
select
  p.id as periodo_id,
  p.anio,
  p.mes,
  l.empresa_pagadora_id,
  coalesce(pag.razon_social, 'Sin pagadora asignada') as empresa_pagadora,
  pag.ruc,
  count(*) as personas,
  count(*) filter (
    where l.empresa_pagadora_id is distinct from l.empresa_afiliacion_id
  ) as personas_afiliadas_en_otro_ruc,
  sum(l.neto_real) as total_a_pagar,
  sum(l.neto_real) filter (
    where l.empresa_pagadora_id is distinct from l.empresa_afiliacion_id
  ) as pagado_por_cuenta_de_otro_ruc,
  sum(l.total_egresos) as total_descuentos,
  sum(l.anticipos_cuota) as anticipos,
  sum(l.multas) as multas,
  sum(l.retencion_judicial) as retencion_judicial
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
left join public.empresas pag on pag.id = l.empresa_pagadora_id
group by p.id, p.anio, p.mes, l.empresa_pagadora_id, pag.razon_social, pag.ruc;

-- ------------------------------------------------------------
-- 6. Planilla consolidada para el IESS
-- ------------------------------------------------------------
-- Un renglon por afiliado y RUC. Es lo unico que sale hacia afuera.
create or replace view public.vista_planilla_iess_v31
with (security_invoker = true) as
select
  p.anio,
  p.mes,
  afi.ruc,
  afi.razon_social as empresa,
  e.identificacion as cedula,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  l.cargo,
  l.fecha_afiliacion,
  l.dias_laborados,
  l.sueldo_proporcional_declarado as remuneracion,
  l.aporte_personal,
  l.aporte_patronal,
  l.provision_fondos_reserva as fondos_reserva,
  l.aporte_personal + l.aporte_patronal as total_aportes
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empleados e on e.id = l.empleado_id
join public.empresas afi on afi.id = l.empresa_afiliacion_id
where l.afiliado
  and p.estado in ('calculado', 'cerrado');

-- ------------------------------------------------------------
-- 7. Resumen del periodo
-- ------------------------------------------------------------
create or replace view public.vista_resumen_periodo_nomina_v31
with (security_invoker = true) as
select
  p.id as periodo_id,
  p.grupo_id,
  p.anio,
  p.mes,
  p.estado,
  p.generado_at,
  p.calculado_at,
  p.cerrado_at,
  count(l.id) as personas,
  count(l.id) filter (where l.afiliado) as afiliados,
  count(l.id) filter (where not l.afiliado) as no_afiliados,
  coalesce(sum(l.total_ingresos_real), 0) as ingresos_reales,
  coalesce(sum(l.total_egresos), 0) as egresos,
  coalesce(sum(l.neto_real), 0) as neto_a_pagar,
  coalesce(sum(l.neto_declarado), 0) as neto_declarado,
  coalesce(sum(l.brecha), 0) as brecha_total,
  coalesce(sum(l.aporte_personal + l.aporte_patronal), 0) as aportes_iess,
  coalesce(sum(l.costo_empleador_real), 0) as costo_empleador_real
from public.nomina_periodos p
left join public.nomina_rol_lineas l on l.periodo_id = p.id
group by p.id, p.grupo_id, p.anio, p.mes, p.estado,
         p.generado_at, p.calculado_at, p.cerrado_at;

-- ------------------------------------------------------------
-- 8. Rol individual para impresion
-- ------------------------------------------------------------
-- Cabecera del comprobante que firma el trabajador. El detalle variable
-- sale de vista_rol_rubros_v31.
create or replace view public.vista_rol_impresion_v31
with (security_invoker = true) as
select
  l.id as rol_linea_id,
  p.anio,
  p.mes,
  p.estado as estado_periodo,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  l.cargo,
  l.area,
  l.fecha_ingreso_real,
  l.afiliado,
  afi.razon_social as empresa_afiliacion,
  afi.ruc as ruc_afiliador,
  pag.razon_social as empresa_pagadora,
  pag.ruc as ruc_pagador,
  l.dias_laborados,
  l.dias_vacaciones,
  l.dias_ausencia_sin_sueldo,
  l.horas_extra_50,
  l.horas_extra_100,
  l.sueldo_proporcional_real,
  l.valor_horas_extra,
  l.comisiones,
  l.bonos,
  l.vacaciones_pagadas,
  l.decimo_tercero_mensualizado,
  l.decimo_cuarto_mensualizado,
  l.fondos_reserva_pagados,
  l.otros_ingresos,
  l.total_ingresos_real,
  l.aporte_personal,
  l.anticipos_cuota,
  l.multas,
  l.prestamos_iess,
  l.prestamos_empresa,
  l.retencion_judicial,
  l.otros_descuentos,
  l.total_egresos,
  l.neto_real,
  firma.storage_path as firma_empleado_path
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.empleados e on e.id = l.empleado_id
left join public.empresas afi on afi.id = l.empresa_afiliacion_id
left join public.empresas pag on pag.id = l.empresa_pagadora_id
left join public.empleado_documentos firma
  on firma.empleado_id = e.id and firma.tipo = 'firma' and firma.activo;

-- Detalle de rubros variables por linea, para el cuerpo del comprobante.
create or replace view public.vista_rol_rubros_v31
with (security_invoker = true) as
select
  rr.rol_linea_id,
  r.codigo,
  r.nombre,
  r.tipo,
  rr.cantidad,
  rr.valor,
  rr.descripcion_extra
from public.nomina_rol_rubros rr
join public.nomina_rubros r on r.id = rr.rubro_id;

-- ------------------------------------------------------------
-- 9. Permisos
-- ------------------------------------------------------------
revoke all on public.vista_rol_real_v31 from public, anon;
revoke all on public.vista_rol_declarado_v31 from public, anon;
revoke all on public.vista_brecha_nomina_v31 from public, anon;
revoke all on public.vista_costo_empleador_por_empresa_v31 from public, anon;
revoke all on public.vista_pagos_por_empresa_pagadora_v31 from public, anon;
revoke all on public.vista_planilla_iess_v31 from public, anon;
revoke all on public.vista_resumen_periodo_nomina_v31 from public, anon;
revoke all on public.vista_rol_impresion_v31 from public, anon;
revoke all on public.vista_rol_rubros_v31 from public, anon;

grant select on public.vista_rol_real_v31 to authenticated;
grant select on public.vista_rol_declarado_v31 to authenticated;
grant select on public.vista_brecha_nomina_v31 to authenticated;
grant select on public.vista_costo_empleador_por_empresa_v31 to authenticated;
grant select on public.vista_pagos_por_empresa_pagadora_v31 to authenticated;
grant select on public.vista_planilla_iess_v31 to authenticated;
grant select on public.vista_resumen_periodo_nomina_v31 to authenticated;
grant select on public.vista_rol_impresion_v31 to authenticated;
grant select on public.vista_rol_rubros_v31 to authenticated;

notify pgrst, 'reload schema';
