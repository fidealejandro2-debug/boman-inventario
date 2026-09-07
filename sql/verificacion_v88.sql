-- ============================================================
-- Verificacion v88 - Portadas de productos en inventario
-- Solo lectura. Ejecutar despues de instalar v88.
-- ============================================================

select
  to_regclass('public.vista_portadas_productos_v88') is not null as vista_ok,
  has_table_privilege(
    'authenticated', 'public.vista_portadas_productos_v88', 'select'
  ) as lectura_authenticated_ok,
  not has_table_privilege(
    'anon', 'public.vista_portadas_productos_v88', 'select'
  ) as lectura_anon_bloqueada_ok;

select c.relname,
  coalesce((select option_value from pg_options_to_table(c.reloptions)
    where option_name = 'security_invoker'), 'false')
    as security_invoker_debe_ser_true
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'vista_portadas_productos_v88';

-- Todos deben ser cero.
select count(*) as productos_con_mas_de_una_portada_visible_debe_ser_cero
from (
  select producto_id
  from public.vista_portadas_productos_v88
  group by producto_id
  having count(*) > 1
) duplicadas;

select count(*) as portadas_sin_archivo_debe_ser_cero
from public.vista_portadas_productos_v88 p
where not exists (
  select 1 from storage.objects o
  where o.bucket_id = 'imagenes-entidades'
    and o.name = p.storage_path
);

select count(*) as portadas_fuera_de_producto_debe_ser_cero
from public.vista_portadas_productos_v88 p
left join public.productos producto on producto.id = p.producto_id
where producto.id is null;

select count(*) as productos_con_portada,
       count(*) filter (where descripcion is not null) as portadas_descritas
from public.vista_portadas_productos_v88;
