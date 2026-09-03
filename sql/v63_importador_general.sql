-- ============================================================
-- BOMAN INVENTARIO - v63
-- Centro general de importaciones y conteos fisicos desde Excel
-- Ejecutar despues de v62 y antes de verificacion_v63.sql.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.crear_conteo_inventario(uuid,uuid[],text,uuid)') is null
     or to_regprocedure('public.guardar_conteo_inventario(uuid,jsonb,boolean,text)') is null then
    raise exception 'Falta el flujo seguro de conteos requerido por v63';
  end if;
  if to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Falta el motor de permisos v35';
  end if;
end $$;

insert into public.permisos_sistema as p
  (codigo, modulo, nombre, descripcion, orden)
values
  ('importaciones.acceder', 'Administracion', 'Centro de importaciones',
   'Carga archivos con vista previa usando los flujos auditados de cada modulo.', 150)
on conflict (codigo) do update set
  modulo = excluded.modulo,
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  orden = excluded.orden,
  activo = true,
  updated_at = now();

insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol, 'importaciones.acceder', false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
where r.rol::text <> 'admin'
on conflict (rol, permiso_codigo) do nothing;

-- Cada pantalla interna conserva ademas su propio control. Este permiso solo
-- abre el centro; no convierte a Nomina en Bodega ni a Tienda en Administrador.
update public.rol_permisos
set permitido = true, updated_at = now()
where rol::text in ('bodega', 'control', 'tienda', 'nomina', 'franquiciado')
  and permiso_codigo = 'importaciones.acceder';

-- Importar stock nunca lo sobrescribe directamente. El archivo crea un conteo
-- parcial, congela el stock del sistema y lo envia a Control. Las diferencias
-- pasan por segundo conteo y aprobacion exactamente igual que una captura manual.
create or replace function public.importar_conteo_fisico_v63(
  p_almacen_id uuid,
  p_items jsonb,
  p_nota text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_uid uuid := auth.uid();
  v_rol text := public.rol_usuario_actual();
  v_existente public.documentos_inventario%rowtype;
  v_documento_id uuid;
  v_numero text;
  v_items_guardar jsonb;
  v_total integer;
  v_diferencias integer;
  v_skus_invalidos text;
begin
  if v_uid is null then
    raise exception 'Debes iniciar sesion para importar datos';
  end if;
  if not public.usuario_tiene_permiso_v35('importaciones.acceder') then
    raise exception 'No tienes permiso para usar el centro de importaciones';
  end if;
  if v_rol not in ('admin', 'control', 'bodega', 'tienda', 'franquiciado') then
    raise exception 'Tu rol no puede importar conteos de inventario';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if p_almacen_id is null or not public.usuario_puede_almacen(p_almacen_id, true) then
    raise exception 'No tienes permiso para contar ese almacen';
  end if;
  if btrim(coalesce(p_nota, '')) = '' then
    raise exception 'Indica el motivo o referencia del archivo';
  end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'El archivo no contiene filas validas';
  end if;
  if jsonb_array_length(p_items) > 5000 then
    raise exception 'El archivo supera el maximo de 5000 filas';
  end if;

  select d.* into v_existente
  from public.documentos_inventario d
  where d.idempotency_key = p_idempotency_key;
  if found then
    if v_existente.tipo <> 'conteo'
       or v_existente.origen_id is distinct from p_almacen_id
       or v_existente.creado_por is distinct from v_uid
       or coalesce(v_existente.nota, '') not like 'Importador general:%' then
      raise exception 'La clave de idempotencia ya fue usada por otra operacion';
    end if;
    return jsonb_build_object(
      'documento_id', v_existente.id,
      'numero', v_existente.numero,
      'duplicado', true,
      'mensaje', 'Este archivo ya fue procesado'
    );
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_items) x
    where btrim(coalesce(x->>'sku', '')) = ''
       or btrim(coalesce(x->>'cantidad', '')) !~ '^[0-9]+$'
  ) then
    raise exception 'Cada fila debe contener SKU y una cantidad entera igual o mayor que cero';
  end if;

  create temp table pg_temp._conteo_import_v63 (
    orden bigint not null,
    sku text primary key,
    cantidad integer not null check (cantidad >= 0),
    producto_id uuid,
    observacion text
  ) on commit drop;

  insert into pg_temp._conteo_import_v63 (orden, sku, cantidad, observacion)
  select distinct on (upper(btrim(valor->>'sku')))
    posicion,
    upper(btrim(valor->>'sku')),
    (valor->>'cantidad')::integer,
    nullif(btrim(valor->>'observacion'), '')
  from jsonb_array_elements(p_items) with ordinality entrada(valor, posicion)
  order by upper(btrim(valor->>'sku')), posicion desc;

  update pg_temp._conteo_import_v63 i
  set producto_id = p.id
  from public.productos p
  where upper(btrim(p.sku)) = i.sku and p.activo;

  select string_agg(i.sku, ', ' order by i.sku) into v_skus_invalidos
  from pg_temp._conteo_import_v63 i
  where i.producto_id is null
     or not exists (
       select 1 from public.producto_almacen_config c
       where c.producto_id = i.producto_id and c.almacen_id = p_almacen_id and c.activo
     );
  if v_skus_invalidos is not null then
    raise exception 'SKU inexistente, inactivo o no habilitado en el almacen: %', v_skus_invalidos;
  end if;

  select count(*)::integer into v_total from pg_temp._conteo_import_v63;
  select jsonb_agg(jsonb_build_object(
    'producto_id', i.producto_id,
    'cantidad', i.cantidad,
    'observacion', coalesce(i.observacion, 'Cargado desde el importador general')
  ) order by i.orden)
  into v_items_guardar
  from pg_temp._conteo_import_v63 i;

  v_documento_id := public.crear_conteo_inventario(
    p_almacen_id,
    (select array_agg(i.producto_id order by i.orden) from pg_temp._conteo_import_v63 i),
    'Importador general: ' || btrim(p_nota),
    p_idempotency_key
  );

  -- Es una operacion atomica: si guardar o enviar falla, tambien se revierte la
  -- creacion del conteo y no queda un documento incompleto.
  perform public.guardar_conteo_inventario(
    v_documento_id,
    v_items_guardar,
    true,
    'Conteo importado; pendiente de revision independiente por Control'
  );

  select d.numero into v_numero
  from public.documentos_inventario d where d.id = v_documento_id;

  select count(*)::integer into v_diferencias
  from public.documento_inventario_lineas l
  where l.documento_id = v_documento_id
    and l.cantidad_contada is distinct from l.stock_sistema;

  return jsonb_build_object(
    'documento_id', v_documento_id,
    'numero', v_numero,
    'total', v_total,
    'diferencias', v_diferencias,
    'estado', 'pendiente_revision',
    'duplicado', false,
    'mensaje', 'Conteo importado y enviado a Control'
  );
end;
$fn$;

alter function public.importar_conteo_fisico_v63(uuid,jsonb,text,uuid)
  owner to postgres;

revoke execute on function public.importar_conteo_fisico_v63(uuid,jsonb,text,uuid)
  from public, anon;
grant execute on function public.importar_conteo_fisico_v63(uuid,jsonb,text,uuid)
  to authenticated;

commit;

notify pgrst, 'reload schema';
