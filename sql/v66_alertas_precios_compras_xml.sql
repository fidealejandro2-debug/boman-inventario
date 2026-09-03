-- ============================================================
-- BOMAN INVENTARIO - v66
-- Historial y alertas de variacion de precios en XML de compras
-- Ejecutar despues de v65 y antes de verificacion_v66.sql.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.proveedor_producto_homologaciones') is null
     or to_regclass('public.compras_xml_importacion_lineas') is null then
    raise exception 'Falta v65. Instalalo y validalo antes de v66';
  end if;
end $$;

alter table public.proveedor_producto_homologaciones
  add column if not exists ultimo_precio_unitario numeric(16,4),
  add column if not exists ultimo_precio_neto numeric(16,4),
  add column if not exists ultimo_precio_fecha date,
  add column if not exists ultimo_precio_documento text,
  add column if not exists precio_actualizado_at timestamptz;

alter table public.compras_xml_importacion_lineas
  add column if not exists precio_neto numeric(16,4) not null default 0,
  add column if not exists precio_referencia_unitario numeric(16,4),
  add column if not exists precio_referencia_neto numeric(16,4),
  add column if not exists precio_referencia_fecha date,
  add column if not exists precio_referencia_documento text,
  add column if not exists variacion_precio_pct numeric(12,4),
  add column if not exists alerta_precio boolean not null default false;

update public.compras_xml_importacion_lineas
set precio_neto = round(subtotal / cantidad, 4)
where precio_neto <> round(subtotal / cantidad, 4);

-- Recupera como punto de partida el ultimo precio de compras ya procesadas.
with ultimas as (
  select distinct on (h.id)
    h.id homologacion_id,
    l.precio_unitario,
    round(l.subtotal / l.cantidad, 4) precio_neto,
    i.fecha_emision,
    i.establecimiento || '-' || i.punto_emision || '-' || i.secuencial documento,
    coalesce(i.procesado_at, i.updated_at) registrado_at
  from public.proveedor_producto_homologaciones h
  join public.compras_xml_importaciones i
    on i.grupo_id = h.grupo_id
   and i.proveedor_ruc = h.proveedor_ruc
   and i.estado = 'procesado'
  join public.compras_xml_importacion_lineas l
    on l.importacion_id = i.id
   and l.producto_id = h.producto_id
   and coalesce(nullif(btrim(l.codigo_proveedor), ''), nullif(btrim(l.codigo_auxiliar), '')) = h.codigo_proveedor
  order by h.id, i.fecha_emision desc, coalesce(i.procesado_at, i.updated_at) desc,
           l.numero_linea desc
)
update public.proveedor_producto_homologaciones h
set ultimo_precio_unitario = u.precio_unitario,
    ultimo_precio_neto = u.precio_neto,
    ultimo_precio_fecha = u.fecha_emision,
    ultimo_precio_documento = u.documento,
    precio_actualizado_at = u.registrado_at
from ultimas u
where h.id = u.homologacion_id
  and h.ultimo_precio_unitario is null;

-- Si se corrige el producto interno de una homologacion, la referencia del
-- producto anterior no debe compararse contra el nuevo.
create or replace function public.limpiar_precio_al_cambiar_homologacion_v66()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if old.producto_id is distinct from new.producto_id then
    new.ultimo_precio_unitario := null;
    new.ultimo_precio_neto := null;
    new.ultimo_precio_fecha := null;
    new.ultimo_precio_documento := null;
    new.precio_actualizado_at := null;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_limpiar_precio_homologacion_v66
  on public.proveedor_producto_homologaciones;
create trigger trg_limpiar_precio_homologacion_v66
before update of producto_id on public.proveedor_producto_homologaciones
for each row execute function public.limpiar_precio_al_cambiar_homologacion_v66();

create or replace function public.preparar_alerta_precio_compra_xml_v66()
returns trigger
language plpgsql
set search_path = ''
as $fn$
declare
  v_grupo_id uuid;
  v_proveedor_ruc text;
  v_codigo text;
  v_ref_unitario numeric(16,4);
  v_ref_neto numeric(16,4);
  v_ref_fecha date;
  v_ref_documento text;
begin
  new.precio_neto := round(new.subtotal / new.cantidad, 4);
  new.precio_referencia_unitario := null;
  new.precio_referencia_neto := null;
  new.precio_referencia_fecha := null;
  new.precio_referencia_documento := null;
  new.variacion_precio_pct := null;
  new.alerta_precio := false;

  select i.grupo_id, i.proveedor_ruc
  into v_grupo_id, v_proveedor_ruc
  from public.compras_xml_importaciones i
  where i.id = new.importacion_id;

  v_codigo := coalesce(
    nullif(btrim(new.codigo_proveedor), ''),
    nullif(btrim(new.codigo_auxiliar), '')
  );
  if v_codigo is null then return new; end if;

  select h.ultimo_precio_unitario, h.ultimo_precio_neto,
         h.ultimo_precio_fecha, h.ultimo_precio_documento
  into v_ref_unitario, v_ref_neto, v_ref_fecha, v_ref_documento
  from public.proveedor_producto_homologaciones h
  where h.grupo_id = v_grupo_id and h.proveedor_ruc = v_proveedor_ruc
    and h.codigo_proveedor = v_codigo and h.activo;

  if found and (v_ref_unitario is not null or v_ref_neto is not null) then
    new.precio_referencia_unitario := v_ref_unitario;
    new.precio_referencia_neto := v_ref_neto;
    new.precio_referencia_fecha := v_ref_fecha;
    new.precio_referencia_documento := v_ref_documento;
    new.alerta_precio :=
      (v_ref_unitario is not null and abs(new.precio_unitario - v_ref_unitario) >= 0.0001)
      or (v_ref_neto is not null and abs(new.precio_neto - v_ref_neto) >= 0.0001);
    if coalesce(v_ref_neto, v_ref_unitario, 0) > 0 then
      new.variacion_precio_pct := round(
        100 * (coalesce(new.precio_neto, new.precio_unitario)
          - coalesce(v_ref_neto, v_ref_unitario))
        / coalesce(v_ref_neto, v_ref_unitario), 4
      );
    end if;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_preparar_alerta_precio_compra_xml_v66
  on public.compras_xml_importacion_lineas;
create trigger trg_preparar_alerta_precio_compra_xml_v66
before insert or update of precio_unitario, cantidad, subtotal, codigo_proveedor, codigo_auxiliar
on public.compras_xml_importacion_lineas
for each row execute function public.preparar_alerta_precio_compra_xml_v66();

-- Evalua tambien los XML que ya estaban pendientes al instalar esta version.
update public.compras_xml_importacion_lineas l
set precio_unitario = l.precio_unitario
from public.compras_xml_importaciones i
where i.id = l.importacion_id
  and i.estado in ('pendiente_homologacion', 'listo');

create or replace function public.actualizar_precio_homologado_v66()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if new.estado = 'procesado' and old.estado is distinct from 'procesado' then
    with precios as (
      select distinct on (codigo)
        codigo, l.producto_id, l.precio_unitario,
        round(l.subtotal / l.cantidad, 4) precio_neto
      from (
        select x.*,
          coalesce(nullif(btrim(x.codigo_proveedor), ''), nullif(btrim(x.codigo_auxiliar), '')) codigo
        from public.compras_xml_importacion_lineas x
        where x.importacion_id = new.id
      ) l
      where l.codigo is not null and l.producto_id is not null
      order by codigo, l.numero_linea desc
    )
    update public.proveedor_producto_homologaciones h
    set ultimo_precio_unitario = p.precio_unitario,
        ultimo_precio_neto = p.precio_neto,
        ultimo_precio_fecha = new.fecha_emision,
        ultimo_precio_documento = new.establecimiento || '-' || new.punto_emision || '-' || new.secuencial,
        precio_actualizado_at = now()
    from precios p
    where h.grupo_id = new.grupo_id and h.proveedor_ruc = new.proveedor_ruc
      and h.codigo_proveedor = p.codigo and h.producto_id = p.producto_id
      and h.activo;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_actualizar_precio_homologado_v66
  on public.compras_xml_importaciones;
create trigger trg_actualizar_precio_homologado_v66
after update of estado on public.compras_xml_importaciones
for each row execute function public.actualizar_precio_homologado_v66();

revoke all on function public.preparar_alerta_precio_compra_xml_v66() from public, anon, authenticated;
revoke all on function public.actualizar_precio_homologado_v66() from public, anon, authenticated;
revoke all on function public.limpiar_precio_al_cambiar_homologacion_v66() from public, anon, authenticated;

commit;
