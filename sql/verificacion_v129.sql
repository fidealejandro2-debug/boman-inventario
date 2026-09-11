-- Verificación v129 - décimos solo para afiliados
-- Solo lectura. Ejecutar después de v129.

select
  position('v_d13_real := case when l.afiliado and' in pg_get_functiondef(p.oid))>0 as d13_mensual_ok,
  position('v_d14_real := case when l.afiliado and' in pg_get_functiondef(p.oid))>0 as d14_mensual_ok,
  position('v_prov_d13 := case when not l.afiliado or' in pg_get_functiondef(p.oid))>0 as d13_provision_ok,
  position('v_prov_d14 := case when not l.afiliado or' in pg_get_functiondef(p.oid))>0 as d14_provision_ok
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='calcular_rol_v30';

select exists(select 1 from pg_trigger where tgrelid='public.nomina_rol_lineas'::regclass and tgname='trg_normalizar_beneficios_rol_v129' and not tgisinternal) as snapshot_protegido_ok,
       position('v_afiliado and coalesce(p_mensualiza_decimo_tercero' in pg_get_functiondef('public.configurar_beneficios_empleado_v30(uuid,boolean,boolean,boolean,text,uuid)'::regprocedure))>0 as configuracion_protegida_ok;

-- Debe ser cero en los roles calculados después de aplicar v129. Los períodos
-- históricos cerrados no se reescriben automáticamente.
select count(*) as no_afiliados_con_decimos_en_periodos_no_cerrados_debe_ser_cero
from public.nomina_rol_lineas l join public.nomina_periodos p on p.id=l.periodo_id
where not l.afiliado and p.estado<>'cerrado'
  and (l.decimo_tercero_mensualizado<>0 or l.decimo_cuarto_mensualizado<>0
    or l.provision_decimo_tercero<>0 or l.provision_decimo_cuarto<>0);

select count(*) as snapshots_no_afiliados_marcados_mensualizados_debe_ser_cero
from public.nomina_rol_lineas l join public.nomina_periodos p on p.id=l.periodo_id
where p.estado<>'cerrado' and not l.afiliado
  and (l.mensualiza_decimo_tercero or l.mensualiza_decimo_cuarto);

-- Informativo: si aparecen filas aquí son roles históricos ya cerrados; deben
-- conservarse o corregirse mediante el procedimiento formal, nunca a mano.
select p.anio,p.mes,l.identificacion,l.apellidos||' '||l.nombres nombre,
  l.decimo_tercero_mensualizado,l.decimo_cuarto_mensualizado,
  l.provision_decimo_tercero,l.provision_decimo_cuarto
from public.nomina_rol_lineas l join public.nomina_periodos p on p.id=l.periodo_id
where not l.afiliado and p.estado='cerrado'
  and (l.decimo_tercero_mensualizado<>0 or l.decimo_cuarto_mensualizado<>0
    or l.provision_decimo_tercero<>0 or l.provision_decimo_cuarto<>0)
order by p.anio desc,p.mes desc,l.apellidos,l.nombres;
