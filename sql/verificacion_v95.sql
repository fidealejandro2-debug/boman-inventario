-- ============================================================
-- Verificacion v95 - Dashboard ejecutivo de produccion
-- Solo lectura. Ejecutar despues de instalar v95.
-- ============================================================

select
  to_regprocedure('public.resumen_dashboard_produccion_v95(date,date,text,text,text,boolean)') is not null
    as resumen_ok,
  to_regprocedure('public.listar_dashboard_produccion_v95(date,date,text,text,text,boolean,integer,integer)') is not null
    as detalle_paginado_ok;

select
  has_function_privilege(
    'authenticated',
    'public.resumen_dashboard_produccion_v95(date,date,text,text,text,boolean)',
    'execute'
  ) as resumen_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.resumen_dashboard_produccion_v95(date,date,text,text,text,boolean)',
    'execute'
  ) as resumen_anon_bloqueado_ok,
  has_function_privilege(
    'authenticated',
    'public.listar_dashboard_produccion_v95(date,date,text,text,text,boolean,integer,integer)',
    'execute'
  ) as detalle_authenticated_ok,
  not has_function_privilege(
    'anon',
    'public.listar_dashboard_produccion_v95(date,date,text,text,text,boolean,integer,integer)',
    'execute'
  ) as detalle_anon_bloqueado_ok;

select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario,
       position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0
         as valida_permiso
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'resumen_dashboard_produccion_v95',
    'listar_dashboard_produccion_v95'
  )
order by p.proname;

-- Deben ser cero.
select count(*) as contratos_con_saldo_invalido_debe_ser_cero
from public.contratos
where presupuesto < 0 or abono < 0 or total_prendas < 0;

select count(*) as prendas_sin_contrato_debe_ser_cero
from public.contrato_prendas cp
left join public.contratos c on c.id = cp.contrato_id
where c.id is null;

select count(*) as contratos_con_total_diferente_debe_ser_cero
from public.contratos c
join lateral (
  select coalesce(sum(cp.cantidad), 0)::integer as cantidad
  from public.contrato_prendas cp where cp.contrato_id = c.id
) p on true
where exists (select 1 from public.contrato_prendas cp where cp.contrato_id = c.id)
  and c.total_prendas <> p.cantidad;

-- La prueba funcional se realiza desde la pantalla con una sesion autenticada.
-- No se invocan aqui las RPC protegidas: el editor SQL no representa al usuario
-- de la aplicacion y auth.uid() seria null aunque la instalacion este correcta.
