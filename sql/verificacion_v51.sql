-- ============================================================
-- Verificacion v51 - Panel principal por rol
-- Solo lectura: no modifica datos.
-- Ejecutar despues de instalar v51.
-- ============================================================

select
  to_regprocedure('public.resumen_panel_principal_v51()') is not null
    as resumen_panel_ok;

select
  has_function_privilege(
    'authenticated', 'public.resumen_panel_principal_v51()', 'execute'
  ) as authenticated_execute_ok,
  not has_function_privilege(
    'anon', 'public.resumen_panel_principal_v51()', 'execute'
  ) as anon_execute_debe_ser_true;

select
  p.prosecdef as security_definer,
  pg_get_userbyid(p.proowner) as propietario,
  position('usuario_tiene_permiso_v35' in pg_get_functiondef(p.oid)) > 0
    as valida_permisos,
  position('usuario_puede_almacen' in pg_get_functiondef(p.oid)) > 0
    as limita_almacenes,
  position('usuario_puede_empresa' in pg_get_functiondef(p.oid)) > 0
    as limita_empresas,
  position('usuario_puede_franquicia_v42' in pg_get_functiondef(p.oid)) > 0
    as limita_franquicias,
  position('America/Guayaquil' in pg_get_functiondef(p.oid)) > 0
    as usa_fecha_ecuador
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'resumen_panel_principal_v51';

-- ------------------------------------------------------------
-- Comprobaciones que EJECUTAN la funcion
-- ------------------------------------------------------------
-- El panel es de quien lo consulta, asi que la funcion exige sesion. El editor
-- SQL de Supabase corre sin ella (auth.uid() es null) y la funcion se niega,
-- que es el comportamiento correcto. Por eso estas comprobaciones se saltan
-- solas en vez de reventar la verificacion entera.
--
-- Para ejecutarlas de verdad, ponte en la piel de un usuario antes de correr
-- este archivo, reemplazando el uuid por uno de public.perfiles:
--
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000"}';
--
do $verifica$
declare
  r jsonb;
  v_almacenes integer;
  v_empresas integer;
begin
  if auth.uid() is null then
    raise notice ' ';
    raise notice 'OMITIDO: las comprobaciones de contenido necesitan una sesion.';
    raise notice 'Lo demas de este archivo ya se verifico. Para incluirlas, corre';
    raise notice 'antes:  set local role authenticated;';
    raise notice '        set local request.jwt.claims = ''{"sub":"<uuid de perfiles>"}'';';
    return;
  end if;

  r := public.resumen_panel_principal_v51();

  raise notice 'respuesta_es_objeto: %', jsonb_typeof(r) = 'object';
  raise notice 'secciones_completas: %', r ?& array[
    'generado_at', 'hoy', 'rol', 'ambito', 'inventario', 'operaciones',
    'ventas', 'compras', 'produccion', 'nomina', 'franquicia',
    'administracion', 'actividad'
  ];
  raise notice 'actividad_es_lista: %', jsonb_typeof(r->'actividad') = 'array';
  raise notice 'almacenes_es_lista: %', jsonb_typeof(r->'ambito'->'almacenes') = 'array';
  raise notice 'empresas_es_lista: %', jsonb_typeof(r->'ambito'->'empresas') = 'array';

  -- Deben ser cero: el resumen nunca puede anunciar un alcance que el usuario
  -- no tenga segun las funciones de seguridad vigentes.
  select count(*) into v_almacenes
  from public.almacenes a
  where a.activo
    and a.nombre in (select jsonb_array_elements_text(r->'ambito'->'almacenes'))
    and not public.usuario_puede_almacen(a.id, false);

  select count(*) into v_empresas
  from public.empresas e
  where e.activo
    and e.razon_social in (select jsonb_array_elements_text(r->'ambito'->'empresas'))
    and not public.usuario_puede_empresa(e.id, false);

  raise notice 'almacenes_fuera_de_alcance (debe ser 0): %', v_almacenes;
  raise notice 'empresas_fuera_de_alcance (debe ser 0): %', v_empresas;

  if v_almacenes > 0 or v_empresas > 0 then
    raise exception 'El panel anuncia un alcance que el usuario no tiene: % almacen(es), % empresa(s)',
      v_almacenes, v_empresas;
  end if;
end;
$verifica$;
