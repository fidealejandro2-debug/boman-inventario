-- ============================================================
-- Verificacion v80 - Imagenes de productos y activos
-- Solo lectura. Ejecutar despues de instalar v80.
-- ============================================================

select
  to_regclass('public.imagenes_entidades') is not null as tabla_ok,
  exists (select 1 from storage.buckets b where b.id = 'imagenes-entidades' and not b.public)
    as bucket_privado_ok;

select
  to_regprocedure('public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)') is not null as preparar_ok,
  to_regprocedure('public.puede_subir_archivo_imagen_v80(text)') is not null as autorizar_storage_ok,
  to_regprocedure('public.confirmar_imagen_entidad_v80(uuid)') is not null as confirmar_ok,
  to_regprocedure('public.establecer_portada_imagen_v80(uuid)') is not null as portada_ok,
  to_regprocedure('public.archivar_imagen_entidad_v80(uuid,text)') is not null as archivar_ok;

select tablename, rowsecurity from pg_tables
where schemaname = 'public' and tablename = 'imagenes_entidades';

select
  has_function_privilege('authenticated', 'public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)', 'execute') as carga_authenticated_ok,
  not has_function_privilege('anon', 'public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)', 'execute') as carga_anon_bloqueada_ok,
  not has_table_privilege('authenticated', 'public.imagenes_entidades', 'insert') as insert_directo_bloqueado_ok;

-- Todos deben ser cero.
select count(*) as imagenes_activas_sin_archivo_debe_ser_cero
from public.imagenes_entidades i
where i.estado = 'activa' and not exists (
  select 1 from storage.objects o
  where o.bucket_id = 'imagenes-entidades' and o.name = i.storage_path
);

select count(*) as portadas_duplicadas_debe_ser_cero
from (
  select entidad_tipo, entidad_id from public.imagenes_entidades
  where estado = 'activa' and es_portada
  group by entidad_tipo, entidad_id having count(*) > 1
) x;

select count(*) as imagenes_activo_fuera_de_grupo_debe_ser_cero
from public.imagenes_entidades i
join public.activos_mantenimiento a on a.id = i.entidad_id
where i.entidad_tipo = 'activo' and i.grupo_id <> a.grupo_id;

select entidad_tipo, count(*) as imagenes_activas,
       count(*) filter (where es_portada) as portadas
from public.imagenes_entidades where estado = 'activa'
group by entidad_tipo order by entidad_tipo;
