-- ============================================================
-- BOMAN INVENTARIO - v52: novedades del periodo para el rol de pagos
--
-- El comprobante mostraba totales, pero no de donde salian. Un trabajador que
-- ve "Multas $15,00" no puede verificar nada; uno que lee "Multa (11/07) 5,00$
-- LIMPIEZA AREA, Multa (04/07) 10,00$ FALTA ENTRADA/SALIDA" si, y ahi la firma
-- deja de ser un tramite.
--
-- Reune en una sola consulta lo que hoy vive en cuatro modulos: descuentos
-- aplicados (v29), ausencias (v27), novedades disciplinarias (v28) y los
-- rubros variables de la propia linea (v30).
--
-- Ejecutar despues de v51.
-- ============================================================

create or replace view public.vista_rol_novedades_v52
with (security_invoker = true) as

-- 1. Descuentos efectivamente aplicados en el rol. Se lee la aplicacion y no
-- el descuento programado, porque el tope legal puede haber diferido parte de
-- la cuota a otro mes: lo que se imprime es lo que de verdad se descuenta.
select
  l.id as rol_linea_id,
  'descuento'::text as grupo,
  dp.origen as tipo,
  case dp.origen
    when 'anticipo' then 'Anticipo'
    when 'multa' then 'Multa'
    when 'judicial' then 'Retencion judicial'
    when 'prestamo_iess' then 'Prestamo IESS'
    when 'prestamo_quirografario' then 'Prestamo quirografario'
    when 'prestamo_hipotecario' then 'Prestamo hipotecario'
    when 'prestamo_empresa' then 'Prestamo de la empresa'
    when 'uniforme' then 'Uniforme'
    when 'consumo_interno' then 'Consumo interno'
    else 'Descuento'
  end as etiqueta,
  c.fecha_prevista as fecha,
  null::numeric as cantidad,
  da.monto_aplicado as monto,
  dp.descripcion as detalle,
  case when da.monto_diferido > 0
    then 'Se difirio ' || da.monto_diferido || ' por tope legal'
    else null end as nota,
  10 as orden
from public.nomina_rol_lineas l
join public.descuento_aplicacion_lotes lo on lo.nomina_rol_linea_id = l.id
join public.descuento_aplicaciones da on da.lote_id = lo.id and da.estado = 'aplicada'
join public.descuento_programado_cuotas c on c.id = da.cuota_id
join public.descuentos_programados dp on dp.id = da.descuento_programado_id
where da.monto_aplicado > 0

union all

-- 2. Ausencias aprobadas que caen dentro del periodo. Las con sueldo se
-- informan igual: explican por que los dias trabajados no son el mes completo.
select
  l.id,
  case when a.tipo in ('permiso_sin_sueldo', 'falta_injustificada', 'suspension_disciplinaria')
    then 'descuento' else 'informativo' end,
  a.tipo,
  case a.tipo
    when 'vacaciones' then 'Vacaciones'
    when 'enfermedad_iess' then 'Enfermedad IESS'
    when 'enfermedad_particular' then 'Enfermedad particular'
    when 'permiso_con_sueldo' then 'Permiso con sueldo'
    when 'permiso_sin_sueldo' then 'Permiso sin sueldo'
    when 'maternidad' then 'Maternidad'
    when 'paternidad' then 'Paternidad'
    when 'lactancia' then 'Lactancia'
    when 'calamidad_domestica' then 'Calamidad domestica'
    when 'falta_injustificada' then 'Falta injustificada'
    when 'suspension_disciplinaria' then 'Suspension disciplinaria'
    else a.tipo
  end,
  a.fecha_desde,
  coalesce(a.horas, a.dias_habiles),
  null::numeric,
  case when a.horas is not null
    then a.horas || ' h'
    else a.dias_habiles || ' dia(s)' end
    || case when a.fecha_hasta > a.fecha_desde
         then ' hasta ' || to_char(a.fecha_hasta, 'DD/MM') else '' end,
  a.observacion,
  20
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.ausencias a
  on a.empleado_id = l.empleado_id
 and a.estado = 'aprobada'
 and a.fecha_desde <= (make_date(p.anio, p.mes, 1) + interval '1 month - 1 day')::date
 and a.fecha_hasta >= make_date(p.anio, p.mes, 1)

union all

-- 3. Novedades disciplinarias del periodo. Se listan tengan o no descuento:
-- una amonestacion sin multa tambien es una novedad que el trabajador debe
-- ver en su rol, y no en un papel suelto.
select
  l.id,
  case when n.genera_descuento then 'descuento' else 'informativo' end,
  n.tipo,
  case n.tipo
    when 'llamado_atencion' then 'Llamado de atencion'
    when 'amonestacion_escrita' then 'Amonestacion escrita'
    when 'memorando' then 'Memorando'
    when 'acta_compromiso' then 'Acta de compromiso'
    when 'felicitacion' then 'Felicitacion'
    when 'sancion_economica' then 'Sancion economica'
    when 'solicitud_visto_bueno' then 'Solicitud de visto bueno'
    else n.tipo
  end,
  n.fecha_hechos,
  null::numeric,
  n.monto_descuento,
  n.asunto,
  null::text,
  30
from public.nomina_rol_lineas l
join public.nomina_periodos p on p.id = l.periodo_id
join public.novedades_empleado n
  on n.empleado_id = l.empleado_id
 and n.fecha_hechos >= make_date(p.anio, p.mes, 1)
 and n.fecha_hechos < (make_date(p.anio, p.mes, 1) + interval '1 month')::date
where n.estado in ('emitida', 'notificada', 'con_descargo', 'archivada')

union all

-- 4. Rubros variables cargados a mano sobre la linea (ingresos adicionales y
-- descuentos puntuales que no vienen de un programado).
select
  l.id,
  case when r.tipo = 'ingreso' then 'ingreso' else 'descuento' end,
  r.codigo,
  r.nombre,
  null::date,
  rr.cantidad,
  rr.valor_real,
  rr.descripcion,
  null::text,
  40
from public.nomina_rol_lineas l
join public.nomina_rol_rubros rr on rr.rol_linea_id = l.id
join public.nomina_rubros r on r.id = rr.rubro_id
where rr.valor_real <> 0;

revoke all on public.vista_rol_novedades_v52 from public, anon;
grant select on public.vista_rol_novedades_v52 to authenticated;

notify pgrst, 'reload schema';
