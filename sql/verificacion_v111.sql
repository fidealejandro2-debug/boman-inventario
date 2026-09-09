-- ============================================================
-- Verificacion v111 - Panel nativo de vendedores
-- Solo lectura. Ejecutar despues de instalar v111.
-- ============================================================

select
  to_regprocedure(
    'public.panel_vendedores_v111(text[],date,date,text[],text[],text,integer,integer)'
  ) is not null as panel_vendedores_ok,
  to_regprocedure('public.obtener_brief_vendedor_v111(uuid)') is not null
    as brief_vendedor_ok;

select
  has_function_privilege(
    'authenticated',
    'public.panel_vendedores_v111(text[],date,date,text[],text[],text,integer,integer)',
    'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon',
    'public.panel_vendedores_v111(text[],date,date,text[],text[],text,integer,integer)',
    'execute'
  ) as anon_bloqueado_ok,
  has_function_privilege(
    'authenticated', 'public.obtener_brief_vendedor_v111(uuid)', 'execute'
  ) as brief_authenticated_ok,
  not has_function_privilege(
    'anon', 'public.obtener_brief_vendedor_v111(uuid)', 'execute'
  ) as brief_anon_bloqueado_ok;

select p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario,
       position('contratos.acceder' in pg_get_functiondef(p.oid)) > 0
         as controla_permiso,
       position('America/Guayaquil' in pg_get_functiondef(p.oid)) > 0
         as fecha_local_ecuador
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('panel_vendedores_v111', 'obtener_brief_vendedor_v111')
order by p.proname;

select indexname
from pg_indexes
where schemaname = 'public'
  and indexname in (
    'idx_contratos_vendedor_v111',
    'idx_contratos_entrega_estado_v111'
  )
order by indexname;

-- Debe ser cero.
select count(*) as contratos_financieramente_invalidos_debe_ser_cero
from public.contratos
where presupuesto < 0 or abono < 0
   or (presupuesto > 0 and abono > presupuesto);

-- Informativo: panorama que alimentara las alertas del panel.
select
  count(*) as contratos,
  count(*) filter (
    where fecha_entrega < (now() at time zone 'America/Guayaquil')::date
      and lower(btrim(estado)) not in ('entregado', 'anulado')
  ) as atrasados,
  coalesce(sum(total_prendas), 0) as prendas,
  coalesce(sum(greatest(presupuesto - abono, 0)), 0) as saldo
from public.contratos;
