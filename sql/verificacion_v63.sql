-- ============================================================
-- Verificacion v63 - Importador general
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v63.
-- ============================================================

select
  exists (
    select 1 from public.permisos_sistema
    where codigo = 'importaciones.acceder' and activo
  ) as permiso_importaciones_ok,
  to_regprocedure('public.importar_conteo_fisico_v63(uuid,jsonb,text,uuid)') is not null
    as importar_conteo_ok;

select
  has_function_privilege(
    'authenticated',
    'public.importar_conteo_fisico_v63(uuid,jsonb,text,uuid)', 'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon',
    'public.importar_conteo_fisico_v63(uuid,jsonb,text,uuid)', 'execute'
  ) as anon_sin_execute_ok,
  not has_function_privilege(
    'authenticated',
    'public.guardar_conteo_inventario(uuid,jsonb,boolean,text)', 'execute'
  ) as guardado_legacy_sigue_cerrado_ok;

select
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('importaciones.acceder' in pg_get_functiondef(p.oid)) > 0
    as valida_permiso,
  position('crear_conteo_inventario' in pg_get_functiondef(p.oid)) > 0
    as usa_flujo_conteo,
  position('pendiente_revision' in pg_get_functiondef(p.oid)) > 0
    as envia_a_control,
  position('p_idempotency_key' in pg_get_functiondef(p.oid)) > 0
    as controla_idempotencia
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'importar_conteo_fisico_v63';

-- Debe ser cero: el importador no puede dejar documentos con su marca abiertos
-- ni lineas sin cantidad. No llama la funcion y por tanto no modifica datos.
select count(*) as conteos_importados_incompletos_debe_ser_cero
from public.documentos_inventario d
where d.tipo = 'conteo'
  and d.nota like 'Importador general:%'
  and (
    d.estado = 'en_conteo'
    or exists (
      select 1 from public.documento_inventario_lineas l
      where l.documento_id = d.id and l.cantidad_contada is null
    )
  );

select rol::text, permitido
from public.rol_permisos
where permiso_codigo = 'importaciones.acceder'
order by rol::text;
