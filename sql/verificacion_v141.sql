select exists(select 1 from public.schema_migrations_boman where id='v141') as migracion_v141_registrada;
select to_regprocedure('public.adjuntar_respaldo_ausencia_v141(uuid,uuid,uuid)') is not null as adjuntar_respaldo_ok;
select position('Este tipo de ausencia requiere un documento de respaldo' in pg_get_functiondef(
  'public.solicitar_ausencia_v27(uuid,text,date,date,numeric,uuid,uuid,text,uuid)'::regprocedure
)) = 0 as solicitud_admite_pendiente;
select count(*) as aprobadas_obligatorias_sin_respaldo_debe_ser_cero from public.ausencias
where estado='aprobada'
and tipo in ('enfermedad_iess','enfermedad_particular','maternidad','paternidad','calamidad_domestica','suspension_disciplinaria')
and documento_respaldo_id is null;
