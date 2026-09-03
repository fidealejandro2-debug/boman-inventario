-- ============================================================
-- BOMAN INVENTARIO - v68: infraestructura de planes por cliente
--
-- El sistema se vende por partes: Base (lo que existe hoy), Plus (+ emision
-- de factura electronica) y Pro (+ contabilidad). Esto NO decide que incluye
-- cada plan de forma fija en el codigo: registra capacidades como DATOS,
-- igual que permisos_sistema/rol_permisos deciden que puede hacer cada ROL.
-- Aqui se decide que puede hacer cada CLIENTE (grupo economico), un nivel
-- arriba del rol.
--
-- Diferencia importante con los permisos de rol: 'admin' NO se salta esta
-- verificacion. Un permiso de rol es sobre lo que la PERSONA puede hacer
-- dentro de su empresa; una capacidad de plan es sobre lo que la EMPRESA
-- contrato. El administrador de un cliente en plan Base no debe poder emitir
-- factura electronica solo por ser admin.
--
-- Este archivo NO activa ningun modulo nuevo: solo construye el catalogo y
-- retrofita v58 (comprobantes de compra) como primer consumidor real, para
-- probar que el gating efectivamente bloquea y no solo queda en una tabla
-- bonita sin nadie que la consulte.
--
-- Ejecutar despues de v67.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Catalogo de planes y capacidades
-- ------------------------------------------------------------
create table if not exists public.planes (
  codigo text primary key check (btrim(codigo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  descripcion text not null check (btrim(descripcion) <> ''),
  orden integer not null default 0,
  activo boolean not null default true
);

insert into public.planes (codigo, nombre, descripcion, orden) values
  ('base', 'Base', 'Inventario, produccion, nomina, franquicias y mantenimiento.', 10),
  ('plus', 'Plus', 'Base + emision de factura electronica autorizada por el SRI.', 20),
  ('pro', 'Pro', 'Plus + contabilidad: retenciones, libro de compras y estados financieros.', 30)
on conflict (codigo) do update set
  nombre = excluded.nombre, descripcion = excluded.descripcion, orden = excluded.orden;

create table if not exists public.capacidades_sistema (
  codigo text primary key check (codigo ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  modulo text not null check (btrim(modulo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  descripcion text not null check (btrim(descripcion) <> ''),
  orden integer not null default 0,
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.plan_capacidades (
  plan_codigo text not null references public.planes(codigo) on delete restrict,
  capacidad_codigo text not null references public.capacidades_sistema(codigo) on delete restrict,
  incluida boolean not null default false,
  primary key (plan_codigo, capacidad_codigo)
);

create table if not exists public.plan_cambios_eventos (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  plan_anterior text,
  plan_nuevo text not null,
  motivo text not null check (btrim(motivo) <> ''),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

-- Se registran las capacidades ya identificadas. facturacion.emision y
-- contabilidad.acceder quedan catalogadas para que el plan sea visible desde
-- ya, aunque el modulo todavia no exista: cuando se construya, solo agrega la
-- verificacion en su RPC, no una tabla nueva.
insert into public.capacidades_sistema (codigo, modulo, nombre, descripcion, orden) values
  ('compras.tributario', 'Compras', 'Comprobantes y retenciones',
   'Registrar comprobantes de compra, retenciones y el libro de compras (v58).', 10),
  ('facturacion.emision', 'Facturacion', 'Emitir factura electronica',
   'Firmar, autorizar ante el SRI y emitir comprobantes propios. Modulo aun no construido.', 20),
  ('contabilidad.acceder', 'Contabilidad', 'Contabilidad',
   'Plan de cuentas, libro diario, libro mayor y estados financieros. Modulo aun no construido.', 30)
on conflict (codigo) do update set
  modulo = excluded.modulo, nombre = excluded.nombre,
  descripcion = excluded.descripcion, orden = excluded.orden, activo = true;

-- Matriz inicial: Base no incluye nada de esto; Plus suma emision; Pro suma
-- ademas contabilidad y el tributario de compras.
insert into public.plan_capacidades (plan_codigo, capacidad_codigo, incluida)
select p.codigo, c.codigo, false
from public.planes p cross join public.capacidades_sistema c
on conflict (plan_codigo, capacidad_codigo) do nothing;

update public.plan_capacidades set incluida = true
where plan_codigo = 'plus' and capacidad_codigo = 'facturacion.emision';
update public.plan_capacidades set incluida = true
where plan_codigo = 'pro' and capacidad_codigo in ('facturacion.emision', 'contabilidad.acceder', 'compras.tributario');

-- ------------------------------------------------------------
-- 2. El cliente (grupo economico) queda con un plan
-- ------------------------------------------------------------
alter table public.grupos_economicos
  add column if not exists plan_codigo text references public.planes(codigo) on delete restrict;

-- El grupo existente (Boman Sport) se queda con todo: construyo v58 para
-- ellos y ya lo estan usando. Un cliente nuevo se crea explicitamente en
-- 'base'; este default de aqui es solo para no romper al que ya existe.
update public.grupos_economicos set plan_codigo = 'pro' where plan_codigo is null;
alter table public.grupos_economicos alter column plan_codigo set default 'base';
alter table public.grupos_economicos alter column plan_codigo set not null;

-- ------------------------------------------------------------
-- 3. Cada perfil sabe a que cliente pertenece, sin recorrer cadenas
-- ------------------------------------------------------------
-- Hoy perfiles.entidad_id apunta a un almacen (o null = ve todos los almacenes
-- DE SU EMPRESA). Ninguna de las dos cosas dice a que CLIENTE pertenece la
-- persona. Se guarda el grupo directamente en el perfil: resolverlo en cada
-- verificacion recorriendo almacen -> empresa -> grupo seria mas lento y,
-- para un admin con entidad_id null, ambiguo.
alter table public.perfiles
  add column if not exists grupo_id uuid references public.grupos_economicos(id) on delete restrict;

do $backfill$
declare v_grupos integer;
begin
  select count(*) into v_grupos from public.grupos_economicos;
  if v_grupos = 1 then
    -- Un solo cliente hoy: no hay ambiguedad posible.
    update public.perfiles set grupo_id = (select id from public.grupos_economicos limit 1)
    where grupo_id is null;
  else
    -- Con mas de un grupo se resuelve por la cadena almacen->empresa->grupo
    -- para quien tenga almacen asignado. Admin/gerencia sin almacen (entidad_id
    -- null) quedan sin grupo y hay que asignarlos a mano: no se puede adivinar
    -- a cual de varios clientes pertenecen.
    update public.perfiles p
    set grupo_id = e.grupo_id
    from public.almacenes a
    join public.empresas e on e.id = a.empresa_id
    where p.entidad_id = a.id and p.grupo_id is null;
  end if;
end;
$backfill$;

-- ------------------------------------------------------------
-- 4. Verificacion de capacidad
-- ------------------------------------------------------------
create or replace function public.grupo_tiene_capacidad_v68(
  p_grupo_id uuid,
  p_capacidad_codigo text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select exists (
    select 1
    from public.grupos_economicos g
    join public.plan_capacidades pc on pc.plan_codigo = g.plan_codigo
    join public.capacidades_sistema cs on cs.codigo = pc.capacidad_codigo and cs.activo
    where g.id = p_grupo_id and g.activo
      and pc.capacidad_codigo = p_capacidad_codigo
      and pc.incluida
  );
$fn$;

-- La que se usa desde las RPC: resuelve el grupo del usuario actual. Sin
-- excepcion para 'admin' a proposito, ver el comentario del encabezado.
create or replace function public.usuario_tiene_capacidad_v68(
  p_capacidad_codigo text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce((
    select public.grupo_tiene_capacidad_v68(p.grupo_id, p_capacidad_codigo)
    from public.perfiles p
    where p.id = auth.uid() and p.activo
  ), false);
$fn$;

-- ------------------------------------------------------------
-- 5. Cambiar el plan de un cliente, auditado
-- ------------------------------------------------------------
create or replace function public.admin_cambiar_plan_grupo_v68(
  p_grupo_id uuid,
  p_plan_codigo text,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare v_anterior text;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede cambiar el plan de un cliente';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El cambio de plan requiere un motivo de al menos 10 caracteres';
  end if;
  if not exists (select 1 from public.planes where codigo = p_plan_codigo and activo) then
    raise exception 'El plan indicado no existe o esta inactivo';
  end if;

  select plan_codigo into v_anterior from public.grupos_economicos
  where id = p_grupo_id for update;
  if not found then raise exception 'El cliente no existe'; end if;

  update public.grupos_economicos set plan_codigo = p_plan_codigo where id = p_grupo_id;

  insert into public.plan_cambios_eventos (grupo_id, plan_anterior, plan_nuevo, motivo, usuario_id)
  values (p_grupo_id, v_anterior, p_plan_codigo, btrim(p_motivo), auth.uid());
end;
$fn$;

-- ------------------------------------------------------------
-- 6. Primer consumidor real: v58 queda detras de compras.tributario
-- ------------------------------------------------------------
-- No se reescribe v58 a mano: se recrean sus dos RPC con la misma logica y
-- una linea nueva al principio, igual que las demas veces que este proyecto
-- superpuso una version sobre la anterior (v42, v44, v50...). El resto del
-- cuerpo es identico al de v58.
create or replace function public.registrar_comprobante_compra_v58(
  p_comprobante jsonb,
  p_lineas jsonb,
  p_retenciones jsonb,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_id uuid;
  v_empresa uuid := nullif(p_comprobante->>'empresa_id', '')::uuid;
  v_proveedor uuid := nullif(p_comprobante->>'proveedor_id', '')::uuid;
  v_total numeric(14,2);
  v_suma_lineas numeric(14,2);
  r record;
begin
  if public.rol_usuario_actual() not in ('admin', 'control', 'gerencia') then
    raise exception 'No tienes permiso para registrar comprobantes de compra';
  end if;
  -- v68: ademas del rol, el cliente tiene que tener contratado el modulo.
  if not public.usuario_tiene_capacidad_v68('compras.tributario') then
    raise exception 'Tu plan no incluye comprobantes de compra y retenciones. Contacta a soporte para actualizarlo.';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;

  select id into v_id from public.comprobantes_compra
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('id', v_id, 'duplicado', true);
  end if;

  if v_empresa is null or not public.usuario_puede_empresa(v_empresa, true) then
    raise exception 'No tienes permiso sobre la empresa que recibe la compra';
  end if;
  if v_proveedor is null then raise exception 'Falta el proveedor'; end if;
  if jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'El comprobante debe tener al menos una linea';
  end if;

  v_total := round((p_comprobante->>'total')::numeric, 2);

  insert into public.comprobantes_compra (
    empresa_id, proveedor_id, tipo, establecimiento, punto_emision, secuencial,
    clave_acceso, numero_autorizacion, fecha_emision, fecha_autorizacion,
    sustento_codigo, base_cero, base_gravada, tarifa_gravada, base_no_objeto,
    base_exenta, monto_iva, monto_ice, propina, total, forma_pago,
    orden_compra_id, recepcion_id, nota, archivo_nombre, archivo_hash,
    idempotency_key, registrado_por
  ) values (
    v_empresa, v_proveedor,
    coalesce(p_comprobante->>'tipo', 'factura'),
    p_comprobante->>'establecimiento',
    p_comprobante->>'punto_emision',
    p_comprobante->>'secuencial',
    nullif(p_comprobante->>'clave_acceso', ''),
    nullif(p_comprobante->>'numero_autorizacion', ''),
    (p_comprobante->>'fecha_emision')::date,
    nullif(p_comprobante->>'fecha_autorizacion', '')::timestamptz,
    coalesce(nullif(p_comprobante->>'sustento_codigo', ''), '01'),
    coalesce((p_comprobante->>'base_cero')::numeric, 0),
    coalesce((p_comprobante->>'base_gravada')::numeric, 0),
    coalesce((p_comprobante->>'tarifa_gravada')::numeric, 15),
    coalesce((p_comprobante->>'base_no_objeto')::numeric, 0),
    coalesce((p_comprobante->>'base_exenta')::numeric, 0),
    coalesce((p_comprobante->>'monto_iva')::numeric, 0),
    coalesce((p_comprobante->>'monto_ice')::numeric, 0),
    coalesce((p_comprobante->>'propina')::numeric, 0),
    v_total,
    nullif(p_comprobante->>'forma_pago', ''),
    nullif(p_comprobante->>'orden_compra_id', '')::uuid,
    nullif(p_comprobante->>'recepcion_id', '')::uuid,
    nullif(p_comprobante->>'nota', ''),
    nullif(p_comprobante->>'archivo_nombre', ''),
    nullif(p_comprobante->>'archivo_hash', ''),
    p_idempotency_key, auth.uid()
  ) returning id into v_id;

  insert into public.comprobante_compra_lineas (
    comprobante_id, numero_linea, codigo_proveedor, descripcion, cantidad,
    precio_unitario, descuento, subtotal, tarifa_iva, valor_iva, producto_id
  )
  select
    v_id, x.numero_linea, nullif(x.codigo_proveedor, ''), x.descripcion,
    x.cantidad, x.precio_unitario, coalesce(x.descuento, 0), x.subtotal,
    coalesce(x.tarifa_iva, 0), coalesce(x.valor_iva, 0), x.producto_id
  from jsonb_to_recordset(p_lineas) x(
    numero_linea integer, codigo_proveedor text, descripcion text,
    cantidad numeric, precio_unitario numeric, descuento numeric,
    subtotal numeric, tarifa_iva numeric, valor_iva numeric, producto_id uuid
  );

  select round(coalesce(sum(subtotal), 0), 2) into v_suma_lineas
  from public.comprobante_compra_lineas where comprobante_id = v_id;

  if v_suma_lineas <> round(
       coalesce((p_comprobante->>'base_cero')::numeric, 0)
     + coalesce((p_comprobante->>'base_gravada')::numeric, 0)
     + coalesce((p_comprobante->>'base_no_objeto')::numeric, 0)
     + coalesce((p_comprobante->>'base_exenta')::numeric, 0), 2) then
    raise exception
      'Las lineas suman % y las bases del comprobante suman otra cosa. Revisa el desglose antes de registrarlo.',
      v_suma_lineas;
  end if;

  if jsonb_typeof(coalesce(p_retenciones, '[]'::jsonb)) = 'array' then
    for r in
      select * from jsonb_to_recordset(coalesce(p_retenciones, '[]'::jsonb)) y(
        concepto_codigo text, base_imponible numeric, porcentaje numeric,
        establecimiento text, punto_emision text, secuencial text,
        clave_acceso text, fecha_emision date
      )
    loop
      insert into public.retenciones_compra (
        comprobante_id, concepto_codigo, base_imponible, porcentaje, valor,
        establecimiento, punto_emision, secuencial, clave_acceso, fecha_emision
      ) values (
        v_id, r.concepto_codigo, round(r.base_imponible, 2), r.porcentaje,
        round(r.base_imponible * r.porcentaje / 100, 2),
        nullif(r.establecimiento, ''), nullif(r.punto_emision, ''),
        nullif(r.secuencial, ''), nullif(r.clave_acceso, ''), r.fecha_emision
      );
    end loop;
  end if;

  return jsonb_build_object('id', v_id, 'duplicado', false,
    'numero_documento', (select numero_documento from public.comprobantes_compra where id = v_id));
end;
$fn$;

create or replace function public.anular_comprobante_compra_v58(
  p_comprobante_id uuid,
  p_motivo text
) returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare c public.comprobantes_compra%rowtype;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control puede anular un comprobante de compra';
  end if;
  if not public.usuario_tiene_capacidad_v68('compras.tributario') then
    raise exception 'Tu plan no incluye comprobantes de compra y retenciones. Contacta a soporte para actualizarlo.';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'La anulacion requiere un motivo de al menos 10 caracteres';
  end if;
  select * into c from public.comprobantes_compra where id = p_comprobante_id for update;
  if not found then raise exception 'El comprobante no existe'; end if;
  if c.estado = 'anulado' then raise exception 'Ese comprobante ya estaba anulado'; end if;

  update public.comprobantes_compra
  set estado = 'anulado', motivo_anulacion = btrim(p_motivo),
      anulado_por = auth.uid(), anulado_at = now()
  where id = c.id;
end;
$fn$;

-- ------------------------------------------------------------
-- 7. Panel: matriz plan x capacidad, y capacidades del cliente actual
-- ------------------------------------------------------------
create or replace view public.vista_matriz_planes_v68
with (security_invoker = true) as
select
  p.codigo as plan_codigo, p.nombre as plan_nombre, p.orden as plan_orden,
  cs.codigo as capacidad_codigo, cs.modulo, cs.nombre as capacidad_nombre,
  cs.descripcion, cs.orden as capacidad_orden,
  coalesce(pc.incluida, false) as incluida
from public.planes p
cross join public.capacidades_sistema cs
left join public.plan_capacidades pc
  on pc.plan_codigo = p.codigo and pc.capacidad_codigo = cs.codigo
where p.activo and cs.activo;

-- Lo que puede consultar cualquier usuario autenticado: su propio plan y
-- capacidades, para que la interfaz decida que mostrar sin exponer la matriz
-- completa de todos los clientes.
--
-- Es una FUNCION y no una vista, a proposito. planes/plan_capacidades/
-- capacidades_sistema tienen RLS solo para admin (ver seccion 8): una vista
-- con security_invoker=true habria corrido esos JOIN con los permisos del
-- usuario que consulta, y a un usuario normal esas tablas le devuelven cero
-- filas por su propio RLS -la vista habria salido vacia para quien mas la
-- necesita. Mismo problema, y misma solucion, que permisos_usuario_actual_v35
-- ya resolvio para permisos_sistema/rol_permisos: una funcion security definer
-- que se salta el RLS de las tablas de catalogo, y el propio auth.uid() adentro
-- es lo que evita que se use para ver el plan de otro.
create or replace function public.mi_plan_v68()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'grupo_id', g.id,
    'grupo_nombre', g.nombre,
    'plan_codigo', g.plan_codigo,
    'plan_nombre', pl.nombre,
    'capacidades', coalesce(
      (select array_agg(cs.codigo order by cs.orden)
       from public.plan_capacidades pc
       join public.capacidades_sistema cs on cs.codigo = pc.capacidad_codigo and cs.activo
       where pc.plan_codigo = g.plan_codigo and pc.incluida),
      array[]::text[]
    )
  )
  from public.perfiles p
  join public.grupos_economicos g on g.id = p.grupo_id
  join public.planes pl on pl.codigo = g.plan_codigo
  where p.id = auth.uid() and p.activo;
$fn$;

-- ------------------------------------------------------------
-- 8. Seguridad y privilegios
-- ------------------------------------------------------------
alter table public.planes enable row level security;
alter table public.capacidades_sistema enable row level security;
alter table public.plan_capacidades enable row level security;
alter table public.plan_cambios_eventos enable row level security;

-- El catalogo completo y la matriz de otros clientes son de Administracion,
-- igual que permisos_sistema/rol_permisos. Un usuario normal ve su propio
-- plan a traves de mi_plan_v68(), no la tabla cruda.
drop policy if exists "admin_leer_planes_v68" on public.planes;
create policy "admin_leer_planes_v68" on public.planes
for select to authenticated using (public.rol_usuario_actual() = 'admin');
drop policy if exists "admin_leer_capacidades_v68" on public.capacidades_sistema;
create policy "admin_leer_capacidades_v68" on public.capacidades_sistema
for select to authenticated using (public.rol_usuario_actual() = 'admin');
drop policy if exists "admin_leer_plan_capacidades_v68" on public.plan_capacidades;
create policy "admin_leer_plan_capacidades_v68" on public.plan_capacidades
for select to authenticated using (public.rol_usuario_actual() = 'admin');
drop policy if exists "admin_leer_plan_cambios_v68" on public.plan_cambios_eventos;
create policy "admin_leer_plan_cambios_v68" on public.plan_cambios_eventos
for select to authenticated using (public.rol_usuario_actual() = 'admin');

revoke all on public.planes from public, anon;
revoke all on public.capacidades_sistema from public, anon;
revoke all on public.plan_capacidades from public, anon;
revoke all on public.plan_cambios_eventos from public, anon;
revoke insert, update, delete on public.planes from authenticated;
revoke insert, update, delete on public.capacidades_sistema from authenticated;
revoke insert, update, delete on public.plan_capacidades from authenticated;
revoke insert, update, delete on public.plan_cambios_eventos from authenticated;
grant select on public.planes to authenticated;
grant select on public.capacidades_sistema to authenticated;
grant select on public.plan_capacidades to authenticated;
grant select on public.plan_cambios_eventos to authenticated;

revoke all on public.vista_matriz_planes_v68 from public, anon;
grant select on public.vista_matriz_planes_v68 to authenticated;

alter function public.grupo_tiene_capacidad_v68(uuid, text) owner to postgres;
alter function public.usuario_tiene_capacidad_v68(text) owner to postgres;
alter function public.mi_plan_v68() owner to postgres;
alter function public.admin_cambiar_plan_grupo_v68(uuid, text, text) owner to postgres;
alter function public.registrar_comprobante_compra_v58(jsonb, jsonb, jsonb, uuid) owner to postgres;
alter function public.anular_comprobante_compra_v58(uuid, text) owner to postgres;

revoke execute on function public.admin_cambiar_plan_grupo_v68(uuid, text, text) from public, anon;
revoke execute on function public.mi_plan_v68() from public, anon;
grant execute on function public.admin_cambiar_plan_grupo_v68(uuid, text, text) to authenticated;
grant execute on function public.mi_plan_v68() to authenticated;
grant execute on function public.grupo_tiene_capacidad_v68(uuid, text) to authenticated;
grant execute on function public.usuario_tiene_capacidad_v68(text) to authenticated;

notify pgrst, 'reload schema';
