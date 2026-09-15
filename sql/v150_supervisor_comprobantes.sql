-- ============================================================
-- v150 - Permiso delegable para supervisar comprobantes de venta de
-- TODAS las tiendas y franquicias, sin depender de ser admin/control.
--
-- No se inventa mecanismo de delegación nuevo: perfil_permisos (v107) ya
-- deja que admin otorgue un permiso puntual a una persona concreta
-- (Administración → Permisos por persona), pase lo que pase por su rol.
-- Aquí solo se crea el permiso y se deja sembrado en false para todos los
-- roles -nadie lo tiene por defecto, ni admin lo necesita (admin ya
-- pasa el check por su rol, ver Parte 5 del panel).
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v150', 0));

do $requisitos$
begin
  if to_regclass('public.venta_rapida_pagos_v148') is null then
    raise exception 'Falta v148: instala primero venta rapida de tienda propia';
  end if;
  if to_regclass('public.venta_franquicia_pagos') is null then
    raise exception 'Falta v149: instala primero el comprobante en venta de franquicia';
  end if;
end;
$requisitos$;

insert into public.permisos_sistema as p(
  codigo, modulo, nombre, descripcion, orden, es_boman_especifico
) values (
  'franquicia.comprobantes.auditar_todo', 'Franquicias', 'Auditar comprobantes de todas las tiendas',
  'Permite revisar los comprobantes de pago (transferencias) de TODAS las tiendas propias y franquicias, no solo la propia. Se otorga por persona, no por rol.',
  60, false
)
on conflict(codigo) do update set
  modulo=excluded.modulo, nombre=excluded.nombre,
  descripcion=excluded.descripcion, orden=excluded.orden,
  activo=true, es_boman_especifico=false, updated_at=now();

insert into public.rol_permisos(rol, permiso_codigo, permitido)
select r.rol, p.codigo, false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text <> 'admin' and p.codigo = 'franquicia.comprobantes.auditar_todo'
on conflict (rol, permiso_codigo) do nothing;

-- Extiende la lectura del bucket de comprobantes (v148) a quien tenga el
-- permiso nuevo, además de al dueño-pendiente y a quien opera ese almacén.
create or replace function public.puede_leer_comprobante_venta_v148(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $v150$
  select exists (
    select 1 from public.venta_comprobantes_pendientes_v148 p
    where p.storage_path = p_path and p.creado_por = auth.uid()
      and p.usado_en is null and p.vence_en > now()
  ) or exists (
    select 1 from public.venta_rapida_pagos_v148 vp
    join public.venta_rapida_v148 v on v.id = vp.venta_id
    where vp.comprobante_storage_path = p_path
      and public.usuario_puede_almacen(v.almacen_id, false)
  ) or (
    public.usuario_tiene_permiso_v35('franquicia.comprobantes.auditar_todo')
    and (
      exists (select 1 from public.venta_rapida_pagos_v148 where comprobante_storage_path = p_path)
      or exists (select 1 from public.venta_franquicia_pagos where comprobante_storage_path = p_path)
    )
  );
$v150$;

-- La vista de abajo usa security_invoker (respeta RLS de las tablas base,
-- no la salta). Sin esto, un supervisor delegado que NO es admin/control ni
-- opera esa tienda/franquicia vería la vista vacía aunque
-- puede_leer_comprobante_venta_v148 ya lo deje ver el archivo del bucket:
-- las políticas de las tablas no sabían nada del permiso nuevo.
drop policy if exists "leer_venta_rapida_v148" on public.venta_rapida_v148;
create policy "leer_venta_rapida_v148" on public.venta_rapida_v148
for select to authenticated using (
  public.usuario_puede_almacen(almacen_id, false)
  or public.usuario_tiene_permiso_v35('franquicia.comprobantes.auditar_todo')
);

drop policy if exists "leer_venta_rapida_pagos_v148" on public.venta_rapida_pagos_v148;
create policy "leer_venta_rapida_pagos_v148" on public.venta_rapida_pagos_v148
for select to authenticated using (
  exists (select 1 from public.venta_rapida_v148 v where v.id = venta_id and public.usuario_puede_almacen(v.almacen_id, false))
  or public.usuario_tiene_permiso_v35('franquicia.comprobantes.auditar_todo')
);

drop policy if exists "leer_franquicias_v42" on public.franquicias;
create policy "leer_franquicias_v42" on public.franquicias for select to authenticated using (
  public.usuario_puede_franquicia_v42(id, false, false)
  or public.rol_usuario_actual() in ('admin', 'control', 'gerencia', 'bodega', 'logistica')
  or public.usuario_tiene_permiso_v35('franquicia.comprobantes.auditar_todo')
);

drop policy if exists "leer_ventas_franquicia_v42" on public.ventas_franquicia;
create policy "leer_ventas_franquicia_v42" on public.ventas_franquicia for select to authenticated using (
  public.usuario_puede_franquicia_v42(franquicia_id, false, false)
  or public.usuario_tiene_permiso_v35('franquicia.comprobantes.auditar_todo')
);

drop policy if exists "leer_pagos_franquicia_v47" on public.venta_franquicia_pagos;
create policy "leer_pagos_franquicia_v47" on public.venta_franquicia_pagos
for select to authenticated using (
  exists (
    select 1 from public.ventas_franquicia v
    where v.id = venta_id
      and public.usuario_puede_franquicia_v42(v.franquicia_id, false, false)
  )
  or public.usuario_tiene_permiso_v35('franquicia.comprobantes.auditar_todo')
);

-- Vista consolidada para la pantalla de revisión: une los pagos por
-- transferencia de venta rápida (tienda) y de venta de franquicia. Sin
-- filtro de estado -el supervisor decide qué mirar.
create or replace view public.vista_comprobantes_venta_pendientes_v150
with (security_invoker = true) as
select
  'tienda'::text as origen,
  vp.id as pago_id,
  v.id as venta_id,
  v.almacen_id,
  a.nombre as almacen_nombre,
  null::uuid as franquicia_id,
  null::text as franquicia_nombre,
  v.fecha,
  v.numero,
  v.concepto as detalle,
  vp.monto,
  vp.referencia,
  vp.comprobante_storage_path,
  vp.comprobante_nombre,
  vp.comprobante_mime_type,
  vp.created_at,
  v.creada_por,
  pf.nombre_completo as creada_por_nombre
from public.venta_rapida_pagos_v148 vp
join public.venta_rapida_v148 v on v.id = vp.venta_id
join public.almacenes a on a.id = v.almacen_id
join public.perfiles pf on pf.id = v.creada_por
where vp.medio_pago = 'transferencia'

union all

select
  'franquicia'::text as origen,
  vp.id as pago_id,
  v.id as venta_id,
  f.almacen_id,
  a.nombre as almacen_nombre,
  f.id as franquicia_id,
  f.nombre as franquicia_nombre,
  v.fecha,
  v.numero,
  'Venta #' || v.numero as detalle,
  vp.monto,
  vp.referencia,
  vp.comprobante_storage_path,
  vp.comprobante_nombre,
  vp.comprobante_mime_type,
  vp.created_at,
  v.creada_por,
  pf.nombre_completo as creada_por_nombre
from public.venta_franquicia_pagos vp
join public.ventas_franquicia v on v.id = vp.venta_id
join public.franquicias f on f.id = v.franquicia_id
join public.almacenes a on a.id = f.almacen_id
join public.perfiles pf on pf.id = v.creada_por
where vp.medio_pago = 'transferencia';

alter function public.puede_leer_comprobante_venta_v148(text) owner to postgres;
alter view public.vista_comprobantes_venta_pendientes_v150 owner to postgres;
revoke all on public.vista_comprobantes_venta_pendientes_v150 from public, anon;
grant select on public.vista_comprobantes_venta_pendientes_v150 to authenticated;

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v150','150','v150_supervisor_comprobantes.sql',
  'Permiso delegable franquicia.comprobantes.auditar_todo + vista consolidada de comprobantes de transferencia')
on conflict(id) do update set version=excluded.version,archivo=excluded.archivo,
  notas=excluded.notas,aplicada_at=now();

notify pgrst, 'reload schema';
commit;
