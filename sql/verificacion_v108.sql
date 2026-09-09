-- Verificacion v108 - ingreso nativo de contratos. Solo lectura.
select
  to_regclass('public.contrato_ingresos_v108') is not null as ingresos_ok,
  to_regclass('public.contrato_archivos_pendientes_v108') is not null as archivos_pendientes_ok,
  exists(select 1 from storage.buckets where id='contratos-archivos' and public) as bucket_publico_ok;

select
  to_regprocedure('public.preparar_archivo_contrato_v108(text,text,bigint,uuid)') is not null as preparar_archivo_ok,
  to_regprocedure('public.buscar_contratos_reposicion_v108(text)') is not null as buscar_reposicion_ok,
  to_regprocedure('public.listar_contratos_v108(text,text,integer,integer)') is not null as listado_ok,
  to_regprocedure('public.obtener_plantilla_contrato_v108(uuid)') is not null as plantilla_ok,
  to_regprocedure('public.crear_contrato_v108(jsonb,uuid)') is not null as crear_ok;

select
  has_function_privilege('authenticated','public.crear_contrato_v108(jsonb,uuid)','execute') as crear_authenticated_ok,
  not has_function_privilege('anon','public.crear_contrato_v108(jsonb,uuid)','execute') as crear_anon_bloqueado_ok,
  not has_table_privilege('authenticated','public.contratos','insert') as insert_directo_bloqueado_ok;

select count(*) as ingresos_sin_contrato_debe_ser_cero
from public.contrato_ingresos_v108 i left join public.contratos c on c.id=i.contrato_id
where c.id is null or i.resultado is null;

select count(*) as archivos_usados_sin_detalle_debe_ser_cero
from public.contrato_archivos_pendientes_v108 p
where p.usado_en is not null and not exists(
  select 1 from public.contrato_archivos a
  where a.contrato_id=p.usado_en and a.url like '%'||p.storage_path
);

select respaldo_sheets_estado, count(*)
from public.contrato_ingresos_v108
group by respaldo_sheets_estado order by respaldo_sheets_estado;
