-- ============================================================
-- Verificacion v106 - Caja unificada y reaperturas autorizadas
-- Solo lectura. Ejecutar despues de instalar v106.
-- ============================================================

select
  to_regclass('public.franquicia_caja_turno_eventos_v106') is not null
    as auditoria_reaperturas_ok,
  to_regprocedure('public.reabrir_turno_caja_v106(uuid,text)') is not null
    as reapertura_turno_ok,
  to_regprocedure('public.abrir_turno_caja_v81(text,text,numeric,uuid)') is not null
    as apertura_compatible_ok,
  to_regprocedure('public.validar_turnos_antes_cierre_general_v106()') is not null
    as candado_cierre_general_ok;

select exists (
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'franquicia_caja_turnos'
    and column_name = 'reabierto_por'
) as reabierto_por_ok,
exists (
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'franquicia_caja_turnos'
    and column_name = 'reabierto_at'
) as reabierto_at_ok;

select
  has_function_privilege(
    'authenticated', 'public.reabrir_turno_caja_v106(uuid,text)', 'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon', 'public.reabrir_turno_caja_v106(uuid,text)', 'execute'
  ) as anon_revocado_ok,
  not has_table_privilege(
    'authenticated', 'public.franquicia_caja_turno_eventos_v106', 'insert'
  ) as auditoria_solo_rpc_ok;

select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario,
       position('El franquiciado o un administrador debe autorizar' in pg_get_functiondef(p.oid)) > 0
         as bloqueo_reapertura_directa,
       position('unique_violation' in pg_get_functiondef(p.oid)) > 0
         as error_duplicado_controlado
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'abrir_turno_caja_v81';

select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario,
       position('v_rol not in (''admin'', ''franquiciado'')' in pg_get_functiondef(p.oid)) > 0
         as solo_titular_o_admin
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('reabrir_turno_caja_v106', 'reabrir_caja_franquicia_v47')
order by p.proname;

-- Todos deben ser cero.
select count(*) as cajas_activas_duplicadas_debe_ser_cero
from (
  select almacen_id, caja_codigo
  from public.franquicia_caja_turnos
  where estado in ('abierto', 'reabierto')
  group by almacen_id, caja_codigo
  having count(*) > 1
) x;

select count(*) as operadores_activos_duplicados_debe_ser_cero
from (
  select abierto_por
  from public.franquicia_caja_turnos
  where estado in ('abierto', 'reabierto')
  group by abierto_por
  having count(*) > 1
) x;

select count(*) as reaperturas_sin_auditoria_debe_ser_cero
from public.franquicia_caja_turnos t
where t.estado = 'reabierto'
  and (t.reabierto_por is null or t.reabierto_at is null
    or not exists (
      select 1 from public.franquicia_caja_turno_eventos_v106 e
      where e.turno_id = t.id and e.tipo = 'reapertura_autorizada'
    ));

select exists (
  select 1 from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'franquicia_caja_cierres'
    and tg.tgname = 'trg_validar_turnos_cierre_general_v106'
    and not tg.tgisinternal
) as trigger_cierre_general_ok;
