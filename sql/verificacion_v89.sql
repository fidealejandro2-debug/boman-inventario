-- ============================================================
-- Verificacion v89 - Fotos de productos para franquiciados
-- Solo lectura. Ejecutar despues de instalar v89.
-- ============================================================

select
  to_regprocedure('public.puede_editar_fotos_producto_v89(uuid)') is not null
    as autorizacion_franquicia_ok,
  to_regprocedure('public.puede_ver_imagen_entidad_v80(uuid,boolean)') is not null
    as lectura_y_escritura_imagen_ok,
  to_regprocedure('public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)') is not null
    as preparar_imagen_ok;

select
  not has_function_privilege(
    'authenticated', 'public.puede_editar_fotos_producto_v89(uuid)', 'execute'
  ) as autorizador_interno_no_expuesto_ok,
  has_function_privilege(
    'authenticated', 'public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)', 'execute'
  ) as carga_authenticated_ok,
  not has_function_privilege(
    'anon', 'public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)', 'execute'
  ) as carga_anon_bloqueada_ok;

select
  position('p.rol::text = ''franquiciado''' in pg_get_functiondef(p.oid)) > 0
    as admite_administrador_franquicia,
  position('public.perfil_almacenes' in pg_get_functiondef(p.oid)) > 0
    as restringe_a_almacen_asignado,
  position('public.producto_almacen_config' in pg_get_functiondef(p.oid)) > 0
    as restringe_a_producto_del_almacen,
  position('vendedor_franquicia' in pg_get_functiondef(p.oid)) = 0
    as vendedor_permanece_solo_lectura
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'puede_editar_fotos_producto_v89';

select
  position('puede_editar_fotos_producto_v89' in pg_get_functiondef(p.oid)) > 0
    as preparar_usa_autorizador_v89
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'preparar_imagen_entidad_v80';

-- Todos deben ser cero.
select count(*) as portadas_duplicadas_debe_ser_cero
from (
  select entidad_tipo, entidad_id
  from public.imagenes_entidades
  where entidad_tipo = 'producto' and estado = 'activa' and es_portada
  group by entidad_tipo, entidad_id
  having count(*) > 1
) duplicadas;

select count(*) as fotos_producto_huerfanas_debe_ser_cero
from public.imagenes_entidades i
left join public.productos p on p.id = i.entidad_id
where i.entidad_tipo = 'producto' and p.id is null;
