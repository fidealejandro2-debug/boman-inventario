-- Verificacion v100 - Presupuesto y abonos. Solo lectura.
select to_regclass('public.contrato_abonos_v100') is not null as abonos_ok,
to_regclass('public.contrato_finanzas_eventos_v100') is not null as auditoria_ok;
select to_regprocedure('public.registrar_abono_contrato_v100(uuid,date,numeric,text,text,text,text,uuid)') is not null as registrar_ok,
to_regprocedure('public.anular_abono_contrato_v100(uuid,text,uuid)') is not null as anular_ok,
to_regprocedure('public.ajustar_finanzas_contrato_v100(uuid,numeric,numeric,text,uuid)') is not null as ajustar_ok,
to_regprocedure('public.listar_finanzas_contratos_v100(text,text,integer,integer)') is not null as listar_ok;
select tablename,rowsecurity from pg_tables where schemaname='public' and tablename in('contrato_abonos_v100','contrato_finanzas_eventos_v100') order by tablename;
select has_function_privilege('authenticated','public.registrar_abono_contrato_v100(uuid,date,numeric,text,text,text,text,uuid)','execute') as registrar_authenticated_ok,
not has_function_privilege('anon','public.registrar_abono_contrato_v100(uuid,date,numeric,text,text,text,text,uuid)','execute') as registrar_anon_debe_ser_true,
not has_function_privilege('authenticated','public.recalcular_abono_contrato_v100(uuid)','execute') as recalculo_interno_debe_ser_true,
not has_table_privilege('authenticated','public.contrato_abonos_v100','insert') as insert_directo_debe_ser_true;
-- Todos deben ser cero.
select count(*) as contratos_con_abono_inconsistente_debe_ser_cero from public.contratos c
left join lateral(select coalesce(sum(a.monto) filter(where a.estado='aplicado'),0) pagos from public.contrato_abonos_v100 a where a.contrato_id=c.id)x on true
where c.abono<>round(c.abono_inicial_v100+x.pagos,2) or c.abono>c.presupuesto;
select count(*) as pagos_sin_evento_debe_ser_cero from public.contrato_abonos_v100 a
where not exists(select 1 from public.contrato_finanzas_eventos_v100 e where e.abono_id=a.id and e.accion='registrar_abono');
select count(*) as anulaciones_incompletas_debe_ser_cero from public.contrato_abonos_v100
where estado='anulado' and(anulado_por is null or anulado_at is null or length(btrim(coalesce(motivo_anulacion,'')))<10);
select count(*) as eventos_incompletos_debe_ser_cero from public.contrato_finanzas_eventos_v100
where usuario_id is null or idempotency_key is null or length(btrim(motivo))<10 or resultado is null;
select count(*) pagos_vigentes,coalesce(sum(monto),0) monto_cobrado from public.contrato_abonos_v100 where estado='aplicado';
