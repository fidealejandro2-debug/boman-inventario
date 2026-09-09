-- ============================================================
-- Verificacion v110 - Cupo de produccion por dia
-- Solo lectura. Ejecutar despues de instalar v110.
-- ============================================================

-- 1. La funcion existe y tiene los privilegios correctos.
select
  to_regprocedure('public.capacidad_dia_produccion_v110(date,uuid)') is not null as fn_ok,
  has_function_privilege('authenticated', 'public.capacidad_dia_produccion_v110(date,uuid)', 'execute') as authenticated_ok,
  not has_function_privilege('anon', 'public.capacidad_dia_produccion_v110(date,uuid)', 'execute') as anon_bloqueado_ok;

-- 2. Es security definer de postgres y valida permiso.
select p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as propietario,
       position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0 as valida_permiso
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'capacidad_dia_produccion_v110';

-- 3. Conteo manual del cupo de un dia con carga, para comparar contra lo que
-- devuelve la RPC desde la aplicacion (ajusta la fecha a un dia real).
select c.tipo_contrato, sum(c.total_prendas) as prendas_comprometidas
from public.contratos c
where c.fecha_inicio_produccion = current_date
  and lower(c.estado) <> 'entregado'
group by c.tipo_contrato
order by c.tipo_contrato;

-- 4. Dias que hoy ya superan el tope total de 900 (informativo: si hay muchos,
-- es que el legado venia autorizando excepciones, no que la funcion falle).
select fecha_inicio_produccion, sum(total_prendas) as prendas
from public.contratos
where fecha_inicio_produccion is not null and lower(estado) <> 'entregado'
group by fecha_inicio_produccion
having sum(total_prendas) > 900
order by fecha_inicio_produccion desc
limit 20;

-- La prueba funcional (que la barra de cupo aparezca y bloquee al pasar el
-- tope) se hace desde /ventas/contratos con sesion real: el editor SQL no
-- representa al usuario y auth.uid() seria null.
