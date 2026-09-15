-- Verificacion v159. Solo lectura; ejecutar despues de la migracion.

select
  to_regprocedure('public.crear_solicitud_salida_v159(uuid,jsonb,text,text,uuid)') is not null as rpc_crear_ok,
  to_regprocedure('public.resolver_solicitud_salida_v159(uuid,boolean,text,uuid)') is not null as rpc_resolver_ok;

-- El check de tipo debe admitir 'salida' ahora.
select pg_get_constraintdef(oid) as definicion_check_tipo
from pg_constraint
where conrelid = 'public.documentos_inventario'::regclass
  and conname = 'documentos_inventario_tipo_check';

select
  has_function_privilege('authenticated','public.crear_solicitud_salida_v159(uuid,jsonb,text,text,uuid)','execute') as crear_ejecutable_authenticated,
  has_function_privilege('authenticated','public.resolver_solicitud_salida_v159(uuid,boolean,text,uuid)','execute') as resolver_ejecutable_authenticated,
  not has_function_privilege('anon','public.crear_solicitud_salida_v159(uuid,jsonb,text,text,uuid)','execute') as crear_bloqueada_anon;

-- La fuente debe listar los 3 roles que aprueban y solo 'tienda' (+admin) para solicitar.
select
  position($$v_rol not in ('admin', 'tienda')$$ in pg_get_functiondef(p.oid)) > 0 as solicitantes_correctos
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'crear_solicitud_salida_v159';

select
  position($$v_rol not in ('admin', 'bodega', 'supervisor')$$ in pg_get_functiondef(p.oid)) > 0 as aprobadores_correctos
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resolver_solicitud_salida_v159';
