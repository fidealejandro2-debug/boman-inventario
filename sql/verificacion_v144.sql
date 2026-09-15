-- Verificacion v144. Solo lectura; ejecutar despues de la migracion.

select
  to_regclass('public.novedad_calidad_responsables_v144') is not null as responsables_ok,
  to_regprocedure('public.registrar_novedad_calidad_v144(jsonb,uuid)') is not null as registrar_ok,
  to_regprocedure('public.resolver_novedad_calidad_v144(uuid,jsonb,uuid)') is not null as resolver_ok,
  to_regprocedure('public.generar_novedades_laborales_calidad_v144(uuid,uuid,text,text,uuid)') is not null as derivar_ok;

select
  has_function_privilege('authenticated','public.registrar_novedad_calidad_v144(jsonb,uuid)','execute') as registrar_permitido,
  has_function_privilege('authenticated','public.resolver_novedad_calidad_v144(uuid,jsonb,uuid)','execute') as resolver_permitido,
  has_function_privilege('authenticated','public.generar_novedades_laborales_calidad_v144(uuid,uuid,text,text,uuid)','execute') as derivar_permitido,
  not has_function_privilege('authenticated','public.registrar_novedad_calidad_v74(jsonb,uuid)','execute') as registrar_v74_revocado;

-- Todos los siguientes resultados deben ser cero.
select count(*) as solicitudes_sin_responsables_debe_ser_cero
from public.novedades_calidad_produccion n
where n.solicita_descuento and not exists (
  select 1 from public.novedad_calidad_responsables_v144 r where r.novedad_id=n.id
);

select count(*) as repartos_incorrectos_debe_ser_cero
from public.novedades_calidad_produccion n
join (
  select novedad_id, round(sum(monto_solicitado),2) total
  from public.novedad_calidad_responsables_v144 group by novedad_id
) r on r.novedad_id=n.id
where r.total <> round(n.monto_descuento_solicitado,2);

select count(*) as personas_ajenas_o_inactivas_debe_ser_cero
from public.novedad_calidad_responsables_v144 r
join public.novedades_calidad_produccion n on n.id=r.novedad_id
join public.empleados e on e.id=r.empleado_id
where e.grupo_id<>n.grupo_id or e.estado<>'activo' or e.fecha_salida is not null;

select count(*) as expedientes_inconsistentes_debe_ser_cero
from public.novedad_calidad_responsables_v144 r
join public.novedades_empleado ne on ne.id=r.novedad_empleado_id
where ne.empleado_id<>r.empleado_id or ne.tipo<>'sancion_economica'
  or not ne.genera_descuento or round(ne.monto_descuento,2)<>round(r.monto_solicitado,2);

select n.codigo, count(r.id) personas, sum(r.monto_solicitado) monto_total,
       count(r.novedad_empleado_id) expedientes_creados
from public.novedades_calidad_produccion n
join public.novedad_calidad_responsables_v144 r on r.novedad_id=n.id
group by n.id,n.codigo order by n.created_at desc limit 50;
