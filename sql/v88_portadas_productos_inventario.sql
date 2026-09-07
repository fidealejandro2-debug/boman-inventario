-- ============================================================
-- BOMAN INVENTARIO - v88: portadas de productos en inventario
--
-- Reutiliza el bucket privado y la galeria de v80. Expone una sola portada
-- activa por producto para que Inventario y Productos puedan cargar todas
-- las miniaturas en lote, sin consultar una fila a la vez.
-- Ejecutar una sola vez DESPUES de v87.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.imagenes_entidades') is null
     or to_regprocedure('public.preparar_imagen_entidad_v80(text,uuid,text,text,bigint,text,boolean,uuid)') is null then
    raise exception 'Falta v80. Instalalo y validalo antes de v88';
  end if;
end $$;

create or replace view public.vista_portadas_productos_v88
with (security_invoker = true)
as
select
  p.id as producto_id,
  portada.id as imagen_id,
  portada.storage_path,
  portada.descripcion,
  portada.nombre_archivo,
  portada.updated_at
from public.productos p
join lateral (
  select i.id, i.storage_path, i.descripcion, i.nombre_archivo, i.updated_at
  from public.imagenes_entidades i
  where i.entidad_tipo = 'producto'
    and i.entidad_id = p.id
    and i.estado = 'activa'
  order by i.es_portada desc, i.created_at, i.id
  limit 1
) portada on true;

comment on view public.vista_portadas_productos_v88 is
  'Portada activa de cada producto. El archivo sigue privado y se abre mediante URL firmada.';

alter view public.vista_portadas_productos_v88 owner to postgres;
revoke all on public.vista_portadas_productos_v88 from public, anon;
grant select on public.vista_portadas_productos_v88 to authenticated;

commit;

notify pgrst, 'reload schema';
