-- Verificacion v102 - Sincronizacion definitiva. Solo lectura.
select to_regprocedure('public.tablero_produccion_v102()') is not null as tablero_supabase_ok,
to_regprocedure('public.resumen_sincronizacion_v102()') is not null as diagnostico_ok,
to_regprocedure('public.resolver_origen_contrato_v102()') is not null as origen_nuevas_altas_ok,
to_regprocedure('public.proteger_finanzas_contrato_v102()') is not null as proteccion_financiera_ok;
select column_name from information_schema.columns where table_schema='public' and table_name='contratos'
and column_name in('fuente_v102','origen_hash_v102','sincronizado_at_v102','finanzas_gestionadas_v100')order by column_name;
select tgname,tgenabled from pg_trigger where tgrelid in('public.contratos'::regclass,'public.bomansport_contratos'::regclass)
and tgname in('trg_marcar_origen_bomansport_v102','trg_resolver_origen_contrato_v102','trg_proteger_finanzas_contrato_v102')order by tgname;
select has_function_privilege('authenticated','public.tablero_produccion_v102()','execute')as tablero_authenticated_ok,
not has_function_privilege('anon','public.tablero_produccion_v102()','execute')as tablero_anon_debe_ser_true,
not has_function_privilege('authenticated','public.proteger_finanzas_contrato_v102()','execute')as trigger_directo_debe_ser_true;
select count(*) as marcas_huerfanas_debe_ser_cero from public.contratos c where c.fuente_v102='bomansport' and not exists(select 1 from public.bomansport_contratos b where b.numero=c.numero);
select count(*) as contratos_legacy_sin_normalizar from public.bomansport_contratos b left join public.contratos c on c.numero=b.numero where c.id is null;
select count(*) as finanzas_inconsistentes_debe_ser_cero from public.contratos c left join lateral(select coalesce(sum(a.monto)filter(where a.estado='aplicado'),0)monto from public.contrato_abonos_v100 a where a.contrato_id=c.id)x on true where c.finanzas_gestionadas_v100 and c.abono<>round(c.abono_inicial_v100+x.monto,2);
-- Con sesion admin: select public.resumen_sincronizacion_v102();
