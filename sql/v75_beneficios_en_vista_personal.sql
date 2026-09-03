-- ============================================================
-- BOMAN INVENTARIO - v75: la vista de personal muestra los beneficios
--
-- Desde v30 existen las preferencias de decimos y fondos de reserva en
-- empleado_compensacion (mensualiza_decimo_tercero, mensualiza_decimo_cuarto,
-- paga_fondos_reserva_mensual) y el RPC configurar_beneficios_empleado_v30
-- para cambiarlas, pero la pantalla de Personal nunca las mostro ni las
-- escribio: toda la gente quedo en el default (decimos acumulados, fondos
-- mensuales) sin forma de cambiarlo. El rol de pago incluso IMPRIME si van
-- mensualizados, asi que podia decir "acumulado" de alguien que pidio
-- mensualizar.
--
-- Aqui solo se exponen los tres campos en la vista para que la pantalla pueda
-- leer el estado actual. No cambia ningun calculo.
--
-- Las columnas van AL FINAL a proposito: create or replace view solo admite
-- agregar columnas al final, nunca renombrar, reordenar ni quitar.
--
-- Ejecutar despues de v74.
-- ============================================================

do $$
begin
  if to_regclass('public.vista_personal_vigente') is null
     or to_regprocedure('public.configurar_beneficios_empleado_v30(uuid,boolean,boolean,boolean,text,uuid)') is null then
    raise exception 'Faltan v30 o v34. Instalalos antes de v75';
  end if;
end $$;

create or replace view public.vista_personal_vigente
with (security_invoker = true) as
select
  e.id as empleado_id,
  e.grupo_id,
  e.identificacion,
  e.apellidos || ' ' || e.nombres as nombre_completo,
  e.cargo,
  e.area,
  e.tipo_contrato,
  e.estado,
  e.fecha_ingreso_real,
  e.fecha_salida,
  a.afiliado,
  a.empresa_id as empresa_afiliacion_id,
  emp_af.razon_social as empresa_afiliacion,
  a.fecha_afiliacion,
  a.sueldo_declarado,
  c.empresa_pagadora_id,
  emp_pg.razon_social as empresa_pagadora,
  c.sueldo_real,
  coalesce(c.sueldo_real, 0) - coalesce(a.sueldo_declarado, 0) as brecha_sueldo,
  case
    when a.afiliado and a.fecha_afiliacion is not null
      then a.fecha_afiliacion - e.fecha_ingreso_real
  end as dias_entre_ingreso_y_afiliacion,
  (a.afiliado and c.empresa_pagadora_id is distinct from a.empresa_id)
    as paga_otro_ruc,
  e.departamento_id,
  d.codigo as departamento_codigo,
  d.nombre as departamento_nombre,
  -- Columnas nuevas de v75, al final por la restriccion de replace view.
  c.mensualiza_decimo_tercero,
  c.mensualiza_decimo_cuarto,
  c.paga_fondos_reserva_mensual
from public.empleados e
left join public.empleado_afiliaciones a
  on a.empleado_id = e.id and a.fecha_hasta is null
left join public.empleado_compensacion c
  on c.empleado_id = e.id and c.fecha_hasta is null
left join public.empresas emp_af on emp_af.id = a.empresa_id
left join public.empresas emp_pg on emp_pg.id = c.empresa_pagadora_id
left join public.departamentos_nomina d on d.id = e.departamento_id;

notify pgrst, 'reload schema';
