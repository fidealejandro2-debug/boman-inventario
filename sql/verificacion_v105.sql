-- Verificacion v105 - Operacion masiva de Tesoreria. Solo lectura.
select to_regprocedure(
  'public.confirmar_lote_cheques_v105(uuid,text,uuid)'
) is not null as confirmar_lote_ok;

select has_function_privilege(
  'authenticated','public.confirmar_lote_cheques_v105(uuid,text,uuid)','execute'
) as authenticated_ok,
not has_function_privilege(
  'anon','public.confirmar_lote_cheques_v105(uuid,text,uuid)','execute'
) as anon_revocado;

select p.prosecdef as security_definer,pg_get_userbyid(p.proowner) propietario
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='confirmar_lote_cheques_v105';

select count(*) as lotes_confirmados_con_pendientes_debe_ser_cero
from public.tesoreria_importaciones i
where i.estado='confirmada' and exists(
  select 1 from public.tesoreria_importacion_lineas l
  where l.importacion_id=i.id and l.estado in('pendiente','lista','observada')
);
