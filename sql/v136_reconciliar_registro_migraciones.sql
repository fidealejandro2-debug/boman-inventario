-- ============================================================
-- v136 - Reconciliar la colision historica de la version v134
-- Ejecutar despues de las dos v134 y de v135.
--
-- Se publicaron dos cambios distintos con el numero 134. No se renombran los
-- archivos ya distribuidos: esta migracion registra ambos con identificadores
-- inequívocos y conserva el numero original como antecedente historico.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v136', 0));

do $v136$
declare
  v_definicion text;
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta v134_registro_migraciones.sql';
  end if;

  if to_regprocedure('public.registrar_intento_respaldo_v135(uuid,boolean,text)') is null then
    raise exception 'Falta v135_intentos_respaldo_contratos.sql';
  end if;

  select pg_get_functiondef(p.oid)
    into v_definicion
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'cronograma_produccion_v96'
     and pg_get_function_identity_arguments(p.oid) = 'p_desde date, p_hasta date';

  if v_definicion is null
     or position('contratos_dia' in v_definicion) = 0
     or position('totales_dia' in v_definicion) = 0 then
    raise exception 'Falta v134_cronograma_prendas_multiplicadas.sql';
  end if;
end;
$v136$;

-- La fila v134 original corresponde al archivo que creo el libro. Se cambia
-- solo su identificador ambiguo; fecha, usuario y demas evidencia se preservan.
update public.schema_migrations_boman
   set id = 'v134_registro'
 where id = 'v134'
   and archivo = 'v134_registro_migraciones.sql'
   and not exists (
     select 1 from public.schema_migrations_boman where id = 'v134_registro'
   );

insert into public.schema_migrations_boman(id, version, archivo, notas)
values
  ('v134_registro', 134, 'v134_registro_migraciones.sql',
   'Crea el libro formal de migraciones.'),
  ('v134_cronograma', 134, 'v134_cronograma_prendas_multiplicadas.sql',
   'Corrige la multiplicacion cartesiana de prendas por contrato en el cronograma.'),
  ('v136', 136, 'v136_reconciliar_registro_migraciones.sql',
   'Distingue formalmente las dos migraciones historicas publicadas como v134.')
on conflict do nothing;

commit;
