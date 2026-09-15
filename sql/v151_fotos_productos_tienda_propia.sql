-- ============================================================
-- BOMAN INVENTARIO - v151: fotos de productos en tienda propia
-- Permite al rol tienda administrar fotos solo para productos configurados
-- en uno de sus locales asignados. Ejecutar despues de v150.
-- ============================================================
begin;

do $$begin
 if to_regprocedure('public.puede_editar_fotos_producto_v89(uuid)')is null
    or to_regclass('public.producto_almacen_config')is null then
  raise exception 'Falta instalar v89 y la configuracion de productos por local';
 end if;
end$$;

create or replace function public.puede_editar_fotos_producto_v89(p_producto_id uuid)
returns boolean language sql stable security definer set search_path=''as $$
 select exists(
  select 1 from public.perfiles p
  where p.id=auth.uid()and p.activo
   and exists(select 1 from public.productos pr where pr.id=p_producto_id and pr.activo)
   and(
    p.rol::text='admin'
    or(
     p.rol::text in('franquiciado','tienda')
     and exists(
      select 1 from public.perfil_almacenes pa
      join public.producto_almacen_config pac
       on pac.almacen_id=pa.almacen_id and pac.producto_id=p_producto_id and pac.activo
      where pa.perfil_id=p.id
       and(
        p.rol::text='tienda'
        or exists(select 1 from public.franquicias f where f.almacen_id=pa.almacen_id and f.activo)
       )
     )
    )
   )
 );
$$;

alter function public.puede_editar_fotos_producto_v89(uuid)owner to postgres;
revoke all on function public.puede_editar_fotos_producto_v89(uuid)from public,anon,authenticated;
comment on function public.puede_editar_fotos_producto_v89(uuid)is
 'Autoriza fotos a admin, franquiciado de su franquicia o tienda propia sobre productos configurados en su local asignado.';

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v151','151','v151_fotos_productos_tienda_propia.sql','Habilita fotos de productos al rol tienda con alcance por local')
on conflict(id)do update set version=excluded.version,archivo=excluded.archivo,notas=excluded.notas,aplicada_at=now();

commit;
notify pgrst,'reload schema';
