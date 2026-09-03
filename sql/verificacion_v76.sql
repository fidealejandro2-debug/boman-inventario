-- ============================================================
-- Verificacion v76 - Decimos solo para afiliados
-- Solo lectura: ejecutar despues de instalar v76.
-- ============================================================

-- 1. Las cuatro lineas quedaron condicionadas a la afiliacion.
select
  pg_get_functiondef(p.oid) like '%v_d13_real := case when l.afiliado and%' as d13_mensual_ok,
  pg_get_functiondef(p.oid) like '%v_d14_real := case when l.afiliado and%' as d14_mensual_ok,
  pg_get_functiondef(p.oid) like '%v_prov_d13 := case when not l.afiliado or%' as d13_provision_ok,
  pg_get_functiondef(p.oid) like '%v_prov_d14 := case when not l.afiliado or%' as d14_provision_ok
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'calcular_rol_v30';

-- 2. Los fondos de reserva NO debieron cambiar: siguen exigiendo afiliacion,
-- fecha de afiliacion y un ano cumplido.
select pg_get_functiondef(p.oid) like '%l.afiliado and l.fecha_afiliacion is not null%'
  as fondos_intactos
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'calcular_rol_v30';

-- 3. Las vacaciones se mantienen para todos, afiliados o no (Art. 69).
select pg_get_functiondef(p.oid) like '%v_prov_vac := round(v_base_real / 24, 2)%'
  as vacaciones_sin_cambios
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'calcular_rol_v30';

-- 4. Personal no afiliado que HOY tiene decimos ya calculados en roles
-- anteriores. v76 no toca lo ya calculado: estos valores quedan como estan y
-- solo cambian los periodos que se calculen de aqui en adelante. Sirve para
-- saber a quien hay que explicarle el cambio.
-- Se filtra por el afiliado de la propia linea y no por el del maestro: la
-- linea es la foto de como estaba la persona en ESE periodo, que es lo que
-- explica el valor que se le pago.
select rl.apellidos || ' ' || rl.nombres as nombre_completo,
       rl.identificacion,
       pe.anio, pe.mes,
       rl.decimo_tercero_mensualizado, rl.decimo_cuarto_mensualizado,
       rl.provision_decimo_tercero, rl.provision_decimo_cuarto
from public.nomina_rol_lineas rl
join public.nomina_periodos pe on pe.id = rl.periodo_id
where not rl.afiliado
  and (rl.decimo_tercero_mensualizado > 0 or rl.decimo_cuarto_mensualizado > 0
       or rl.provision_decimo_tercero > 0 or rl.provision_decimo_cuarto > 0)
order by pe.anio desc, pe.mes desc, nombre_completo
limit 50;

-- 5. Informativo: personal no afiliado vigente, que es a quien aplica el
-- criterio de "sueldo real ya incluye los beneficios".
select nombre_completo, identificacion, sueldo_real,
       mensualiza_decimo_tercero, mensualiza_decimo_cuarto
from public.vista_personal_vigente
where coalesce(afiliado, false) = false and estado = 'activo'
order by nombre_completo;
