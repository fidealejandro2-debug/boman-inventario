-- ============================================================
-- BOMAN INVENTARIO - Establecimientos y puntos de emision v19
-- Jerarquia: grupo -> empresa/RUC -> establecimiento SRI -> almacen.
-- Ejecutar una sola vez DESPUES de v18.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Establecimientos legales y puntos de emision
-- ------------------------------------------------------------
create table if not exists public.empresa_establecimientos (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  codigo text not null check (codigo ~ '^[0-9]{3}$'),
  nombre text not null check (btrim(nombre) <> ''),
  almacen_id uuid references public.almacenes(id) on delete restrict,
  direccion text,
  es_matriz boolean not null default false,
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id),
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (empresa_id, codigo)
);

create unique index if not exists uq_empresa_establecimiento_matriz
  on public.empresa_establecimientos(empresa_id)
  where es_matriz and activo;

create table if not exists public.empresa_puntos_emision (
  id uuid primary key default gen_random_uuid(),
  establecimiento_id uuid not null references public.empresa_establecimientos(id) on delete restrict,
  codigo text not null check (codigo ~ '^[0-9]{3}$'),
  nombre text,
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id),
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (establecimiento_id, codigo)
);

-- Conserva equivalencias temporales cuando un facturador externo emite una
-- combinacion distinta a la registrada legalmente. Ejemplo:
-- XML 001-006 -> establecimiento real 006 / punto real 100.
create table if not exists public.empresa_equivalencias_facturacion (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  establecimiento_id uuid not null references public.empresa_establecimientos(id) on delete restrict,
  punto_emision_id uuid not null references public.empresa_puntos_emision(id) on delete restrict,
  establecimiento_xml text not null check (establecimiento_xml ~ '^[0-9]{3}$'),
  punto_emision_xml text not null check (punto_emision_xml ~ '^[0-9]{3}$'),
  motivo text not null check (btrim(motivo) <> ''),
  activo boolean not null default true,
  creado_por uuid references public.perfiles(id),
  actualizado_por uuid references public.perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (empresa_id, establecimiento_xml, punto_emision_xml)
);

create index if not exists idx_empresa_establecimientos_almacen
  on public.empresa_establecimientos(almacen_id, empresa_id);
create index if not exists idx_empresa_puntos_establecimiento
  on public.empresa_puntos_emision(establecimiento_id, activo, codigo);
create index if not exists idx_empresa_equivalencias_destino
  on public.empresa_equivalencias_facturacion(establecimiento_id, punto_emision_id, activo);

-- Conserva la compatibilidad con el mapeo aprendido por Ventas XML v13.
alter table public.establecimiento_almacen_facturacion
  add column if not exists empresa_establecimiento_id uuid
    references public.empresa_establecimientos(id) on delete restrict,
  add column if not exists empresa_punto_emision_id uuid
    references public.empresa_puntos_emision(id) on delete restrict,
  add column if not exists empresa_equivalencia_id uuid
    references public.empresa_equivalencias_facturacion(id) on delete restrict;

alter table public.documentos_venta_xml
  add column if not exists empresa_establecimiento_id uuid
    references public.empresa_establecimientos(id) on delete restrict,
  add column if not exists empresa_punto_emision_id uuid
    references public.empresa_puntos_emision(id) on delete restrict,
  add column if not exists empresa_equivalencia_id uuid
    references public.empresa_equivalencias_facturacion(id) on delete restrict,
  add column if not exists codigo_facturacion_no_estandar boolean not null default false,
  add column if not exists codigo_facturacion_confirmado_por uuid references public.perfiles(id),
  add column if not exists codigo_facturacion_confirmado_at timestamptz,
  add column if not exists codigo_facturacion_nota text;

create index if not exists idx_establecimiento_facturacion_empresa
  on public.establecimiento_almacen_facturacion(empresa_establecimiento_id, empresa_punto_emision_id);
create index if not exists idx_establecimiento_facturacion_equivalencia
  on public.establecimiento_almacen_facturacion(empresa_equivalencia_id);
create index if not exists idx_documentos_venta_xml_establecimiento
  on public.documentos_venta_xml(empresa_establecimiento_id, fecha_emision desc);

-- ------------------------------------------------------------
-- 2. Acceso y RLS
-- ------------------------------------------------------------
alter table public.empresa_establecimientos enable row level security;
alter table public.empresa_puntos_emision enable row level security;
alter table public.empresa_equivalencias_facturacion enable row level security;

drop policy if exists "leer_empresa_establecimientos" on public.empresa_establecimientos;
create policy "leer_empresa_establecimientos"
on public.empresa_establecimientos for select to authenticated using (
  public.usuario_puede_empresa(empresa_id, false)
  or public.usuario_puede_almacen(almacen_id, false)
);

drop policy if exists "leer_empresa_puntos_emision" on public.empresa_puntos_emision;
create policy "leer_empresa_puntos_emision"
on public.empresa_puntos_emision for select to authenticated using (
  exists (
    select 1
    from public.empresa_establecimientos ee
    where ee.id = establecimiento_id
      and (
        public.usuario_puede_empresa(ee.empresa_id, false)
        or public.usuario_puede_almacen(ee.almacen_id, false)
      )
  )
);

drop policy if exists "leer_empresa_equivalencias_facturacion"
  on public.empresa_equivalencias_facturacion;
create policy "leer_empresa_equivalencias_facturacion"
on public.empresa_equivalencias_facturacion for select to authenticated using (
  public.usuario_puede_empresa(empresa_id, false)
);

-- ------------------------------------------------------------
-- 3. Sincronizacion con los mapeos XML existentes y futuros
-- ------------------------------------------------------------
create or replace function public.sincronizar_establecimiento_facturacion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empresa_id uuid;
  v_establecimiento_id uuid;
  v_punto_id uuid;
  v_equivalencia_id uuid;
begin
  select ef.empresa_id into v_empresa_id
  from public.emisores_facturacion ef
  join public.empresas e on e.id = ef.empresa_id and e.activo
  where ef.ruc = new.emisor_ruc and ef.activo;

  -- El emisor puede seguir pendiente de clasificacion en una instalacion
  -- historica. En ese caso v13 continua funcionando sin inventar empresa.
  if v_empresa_id is null then return new; end if;

  -- Primero busca una equivalencia declarada. El codigo original del XML no
  -- se modifica, pero se relaciona con la estructura legal confirmada.
  select eq.establecimiento_id, eq.punto_emision_id, eq.id
  into v_establecimiento_id, v_punto_id, v_equivalencia_id
  from public.empresa_equivalencias_facturacion eq
  join public.empresa_establecimientos ee
    on ee.id = eq.establecimiento_id and ee.activo
  join public.empresa_puntos_emision pe
    on pe.id = eq.punto_emision_id and pe.activo
  where eq.empresa_id = v_empresa_id and eq.activo
    and eq.establecimiento_xml = new.establecimiento
    and eq.punto_emision_xml = new.punto_emision
    and ee.almacen_id = new.almacen_id;

  if not found then
    -- Si coincide exactamente con la estructura oficial, no es novedad.
    select ee.id, pe.id
    into v_establecimiento_id, v_punto_id
    from public.empresa_establecimientos ee
    join public.empresa_puntos_emision pe
      on pe.establecimiento_id = ee.id and pe.activo
    where ee.empresa_id = v_empresa_id and ee.activo
      and ee.codigo = new.establecimiento
      and pe.codigo = new.punto_emision
      and ee.almacen_id = new.almacen_id;
    v_equivalencia_id := null;
  end if;

  new.empresa_establecimiento_id := v_establecimiento_id;
  new.empresa_punto_emision_id := v_punto_id;
  new.empresa_equivalencia_id := v_equivalencia_id;
  return new;
end;
$$;

drop trigger if exists trg_sincronizar_establecimiento_facturacion
  on public.establecimiento_almacen_facturacion;
create trigger trg_sincronizar_establecimiento_facturacion
before insert or update of emisor_ruc, establecimiento, punto_emision, almacen_id
on public.establecimiento_almacen_facturacion
for each row execute function public.sincronizar_establecimiento_facturacion();

-- Los mapeos historicos de v13 conservan su almacen, pero no se convierten
-- automaticamente en establecimientos legales. Administracion debe confirmar
-- si cada codigo es oficial o una equivalencia temporal para evitar registrar
-- como legal una numeracion incorrecta del facturador.

create or replace function public.clasificar_establecimiento_venta_xml()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select m.empresa_establecimiento_id, m.empresa_punto_emision_id,
         m.empresa_equivalencia_id
  into new.empresa_establecimiento_id, new.empresa_punto_emision_id,
       new.empresa_equivalencia_id
  from public.establecimiento_almacen_facturacion m
  where m.emisor_ruc = new.emisor_ruc
    and m.establecimiento = new.establecimiento
    and m.punto_emision = new.punto_emision;
  new.codigo_facturacion_no_estandar := new.empresa_equivalencia_id is not null
    or new.empresa_establecimiento_id is null;
  return new;
end;
$$;

drop trigger if exists trg_clasificar_establecimiento_venta_xml
  on public.documentos_venta_xml;
create trigger trg_clasificar_establecimiento_venta_xml
before insert on public.documentos_venta_xml
for each row execute function public.clasificar_establecimiento_venta_xml();

update public.documentos_venta_xml d
set empresa_establecimiento_id = m.empresa_establecimiento_id,
    empresa_punto_emision_id = m.empresa_punto_emision_id,
    empresa_equivalencia_id = m.empresa_equivalencia_id,
    codigo_facturacion_no_estandar = m.empresa_equivalencia_id is not null
      or m.empresa_establecimiento_id is null
from public.establecimiento_almacen_facturacion m
where m.emisor_ruc = d.emisor_ruc
  and m.establecimiento = d.establecimiento
  and m.punto_emision = d.punto_emision
  and d.empresa_establecimiento_id is null;

-- ------------------------------------------------------------
-- 4. Administracion auditada
-- ------------------------------------------------------------
create or replace function public.admin_guardar_establecimientos_empresa(
  p_empresa_id uuid,
  p_items jsonb
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  it record;
  eq record;
  v_establecimiento_id uuid;
  v_punto_id uuid;
  v_equivalencia_id uuid;
  v_total integer := 0;
  v_ruc text;
  v_razon_social text;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede configurar establecimientos';
  end if;
  select ruc, razon_social into v_ruc, v_razon_social
  from public.empresas where id = p_empresa_id;
  if not found then
    raise exception 'La empresa no existe';
  end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    raise exception 'La lista de establecimientos no es valida';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      codigo text, nombre text, almacen_id uuid, direccion text,
      es_matriz boolean, activo boolean, puntos_emision jsonb,
      equivalencias_xml jsonb
    )
    left join public.almacenes a on a.id = x.almacen_id and a.activo
    where coalesce(x.codigo, '') !~ '^[0-9]{3}$'
       or btrim(coalesce(x.nombre, '')) = ''
       or (x.almacen_id is not null and a.id is null)
       or (x.almacen_id is not null and not exists (
         select 1
         from public.empresa_almacenes ea
         where ea.empresa_id = p_empresa_id and ea.almacen_id = x.almacen_id
       ))
       or jsonb_typeof(coalesce(x.puntos_emision, '[]'::jsonb)) <> 'array'
       or jsonb_typeof(coalesce(x.equivalencias_xml, '[]'::jsonb)) <> 'array'
  ) then raise exception 'Existe un establecimiento con datos invalidos'; end if;
  if exists (
    select codigo
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(codigo text)
    group by codigo having count(*) > 1
  ) then raise exception 'La lista contiene codigos de establecimiento repetidos'; end if;
  if (
    select count(*)
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(es_matriz boolean, activo boolean)
    where coalesce(x.es_matriz, false) and coalesce(x.activo, true)
  ) > 1 then raise exception 'Una empresa solo puede tener una matriz activa'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(puntos_emision jsonb)
    cross join lateral jsonb_array_elements_text(coalesce(x.puntos_emision, '[]'::jsonb)) p(codigo)
    where p.codigo !~ '^[0-9]{3}$'
  ) then raise exception 'Los puntos de emision deben tener tres digitos'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      puntos_emision jsonb, equivalencias_xml jsonb
    )
    cross join lateral jsonb_to_recordset(coalesce(x.equivalencias_xml, '[]'::jsonb)) q(
      establecimiento_xml text, punto_emision_xml text,
      punto_emision_oficial text, motivo text
    )
    where coalesce(q.establecimiento_xml, '') !~ '^[0-9]{3}$'
       or coalesce(q.punto_emision_xml, '') !~ '^[0-9]{3}$'
       or coalesce(q.punto_emision_oficial, '') !~ '^[0-9]{3}$'
       or btrim(coalesce(q.motivo, '')) = ''
       or not exists (
         select 1
         from jsonb_array_elements_text(coalesce(x.puntos_emision, '[]'::jsonb)) p(codigo)
         where p.codigo = q.punto_emision_oficial
       )
  ) then
    raise exception 'Una equivalencia XML es invalida o no apunta a un punto de emision oficial';
  end if;
  if exists (
    select establecimiento_xml, punto_emision_xml
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(equivalencias_xml jsonb)
    cross join lateral jsonb_to_recordset(coalesce(x.equivalencias_xml, '[]'::jsonb)) q(
      establecimiento_xml text, punto_emision_xml text
    )
    group by establecimiento_xml, punto_emision_xml
    having count(*) > 1
  ) then raise exception 'La lista contiene una equivalencia XML repetida'; end if;

  -- Al configurar al menos un establecimiento, el RUC queda habilitado como
  -- emisor de Ventas XML. Esto permite preparar toda la estructura antes de
  -- importar la primera factura del RUC.
  if jsonb_array_length(coalesce(p_items, '[]'::jsonb)) > 0 then
    insert into public.emisores_facturacion as ef (
      ruc, razon_social, activo, creado_por, empresa_id
    ) values (
      v_ruc, v_razon_social, true, auth.uid(), p_empresa_id
    )
    on conflict (ruc) do update
    set razon_social = excluded.razon_social,
        activo = true,
        empresa_id = p_empresa_id,
        updated_at = now();
  end if;

  -- No elimina historia: desactiva lo que ya no venga en la configuracion.
  update public.empresa_establecimientos
  set activo = false, es_matriz = false,
      actualizado_por = auth.uid(), updated_at = now()
  where empresa_id = p_empresa_id;

  update public.empresa_equivalencias_facturacion
  set activo = false, actualizado_por = auth.uid(), updated_at = now()
  where empresa_id = p_empresa_id;

  for it in
    select *
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) x(
      codigo text, nombre text, almacen_id uuid, direccion text,
      es_matriz boolean, activo boolean, puntos_emision jsonb,
      equivalencias_xml jsonb
    )
  loop
    insert into public.empresa_establecimientos as ee (
      empresa_id, codigo, nombre, almacen_id, direccion, es_matriz, activo,
      creado_por, actualizado_por
    ) values (
      p_empresa_id, it.codigo, btrim(it.nombre), it.almacen_id,
      nullif(btrim(it.direccion), ''),
      coalesce(it.es_matriz, false) and coalesce(it.activo, true),
      coalesce(it.activo, true), auth.uid(), auth.uid()
    )
    on conflict (empresa_id, codigo) do update
    set nombre = excluded.nombre,
        almacen_id = excluded.almacen_id,
        direccion = excluded.direccion,
        es_matriz = excluded.es_matriz,
        activo = excluded.activo,
        actualizado_por = auth.uid(),
        updated_at = now()
    returning id into v_establecimiento_id;

    update public.empresa_puntos_emision
    set activo = false, actualizado_por = auth.uid(), updated_at = now()
    where establecimiento_id = v_establecimiento_id;

    insert into public.empresa_puntos_emision as pe (
      establecimiento_id, codigo, nombre, activo, creado_por, actualizado_por
    )
    select v_establecimiento_id, p.codigo,
           'Punto de emision ' || p.codigo, true, auth.uid(), auth.uid()
    from (
      select distinct value as codigo
      from jsonb_array_elements_text(coalesce(it.puntos_emision, '[]'::jsonb)) value
    ) p
    on conflict (establecimiento_id, codigo) do update
    set activo = true, actualizado_por = auth.uid(), updated_at = now();

    -- Si tiene ubicacion fisica, cada punto queda listo para que v13 ubique
    -- automaticamente el XML en el almacen correcto.
    if it.almacen_id is not null then
      insert into public.establecimiento_almacen_facturacion as m (
        emisor_ruc, establecimiento, punto_emision, almacen_id, actualizado_por
      )
      select v_ruc, it.codigo, pe.codigo, it.almacen_id, auth.uid()
      from public.empresa_puntos_emision pe
      where pe.establecimiento_id = v_establecimiento_id and pe.activo
      on conflict (emisor_ruc, establecimiento, punto_emision) do update
      set almacen_id = excluded.almacen_id,
          actualizado_por = auth.uid(),
          updated_at = now();
    end if;

    -- Registra las numeraciones no estandar sin alterar el codigo original
    -- del XML ni confundirlo con la estructura legal del RUC.
    for eq in
      select *
      from jsonb_to_recordset(coalesce(it.equivalencias_xml, '[]'::jsonb)) q(
        establecimiento_xml text, punto_emision_xml text,
        punto_emision_oficial text, motivo text
      )
    loop
      select id into v_punto_id
      from public.empresa_puntos_emision
      where establecimiento_id = v_establecimiento_id
        and codigo = eq.punto_emision_oficial and activo;
      if not found then
        raise exception 'El punto oficial % no pertenece al establecimiento %',
          eq.punto_emision_oficial, it.codigo;
      end if;

      insert into public.empresa_equivalencias_facturacion as ef (
        empresa_id, establecimiento_id, punto_emision_id,
        establecimiento_xml, punto_emision_xml, motivo, activo,
        creado_por, actualizado_por
      ) values (
        p_empresa_id, v_establecimiento_id, v_punto_id,
        eq.establecimiento_xml, eq.punto_emision_xml, btrim(eq.motivo), true,
        auth.uid(), auth.uid()
      )
      on conflict (empresa_id, establecimiento_xml, punto_emision_xml) do update
      set establecimiento_id = excluded.establecimiento_id,
          punto_emision_id = excluded.punto_emision_id,
          motivo = excluded.motivo,
          activo = true,
          actualizado_por = auth.uid(),
          updated_at = now()
      returning id into v_equivalencia_id;

      if it.almacen_id is not null then
        insert into public.establecimiento_almacen_facturacion as m (
          emisor_ruc, establecimiento, punto_emision, almacen_id,
          actualizado_por, empresa_establecimiento_id,
          empresa_punto_emision_id, empresa_equivalencia_id
        ) values (
          v_ruc, eq.establecimiento_xml, eq.punto_emision_xml, it.almacen_id,
          auth.uid(), v_establecimiento_id, v_punto_id, v_equivalencia_id
        )
        on conflict (emisor_ruc, establecimiento, punto_emision) do update
        set almacen_id = excluded.almacen_id,
            actualizado_por = auth.uid(),
            empresa_establecimiento_id = excluded.empresa_establecimiento_id,
            empresa_punto_emision_id = excluded.empresa_punto_emision_id,
            empresa_equivalencia_id = excluded.empresa_equivalencia_id,
            updated_at = now();
      end if;
    end loop;

    v_total := v_total + 1;
  end loop;

  -- Reevalua mapeos de equivalencias que fueron desactivadas. Se conserva su
  -- ruta historica de almacen, pero deja de presentarse como validada.
  update public.establecimiento_almacen_facturacion m
  set almacen_id = m.almacen_id, actualizado_por = auth.uid(), updated_at = now()
  where m.empresa_equivalencia_id in (
    select ef.id from public.empresa_equivalencias_facturacion ef
    where ef.empresa_id = p_empresa_id and not ef.activo
  );

  -- Actualiza los mapeos XML que coincidan con la estructura confirmada.
  update public.establecimiento_almacen_facturacion m
  set empresa_establecimiento_id = ee.id,
      empresa_punto_emision_id = pe.id,
      empresa_equivalencia_id = null,
      almacen_id = coalesce(ee.almacen_id, m.almacen_id),
      actualizado_por = auth.uid(),
      updated_at = now()
  from public.emisores_facturacion ef,
       public.empresa_establecimientos ee,
       public.empresa_puntos_emision pe
  where ef.ruc = m.emisor_ruc and ef.empresa_id = p_empresa_id
    and m.empresa_equivalencia_id is null
    and ee.empresa_id = p_empresa_id and ee.codigo = m.establecimiento
    and pe.establecimiento_id = ee.id and pe.codigo = m.punto_emision;

  -- Normaliza tambien facturas historicas, conservando los codigos originales.
  update public.documentos_venta_xml d
  set empresa_establecimiento_id = m.empresa_establecimiento_id,
      empresa_punto_emision_id = m.empresa_punto_emision_id,
      empresa_equivalencia_id = m.empresa_equivalencia_id,
      codigo_facturacion_no_estandar = m.empresa_equivalencia_id is not null
        or m.empresa_establecimiento_id is null
  from public.establecimiento_almacen_facturacion m
  where d.emisor_ruc = v_ruc
    and m.emisor_ruc = d.emisor_ruc
    and m.establecimiento = d.establecimiento
    and m.punto_emision = d.punto_emision;

  insert into public.configuracion_multiempresa_eventos
    (tipo, empresa_id, detalle, usuario_id)
  values (
    'establecimientos_asignados', p_empresa_id,
    jsonb_build_object('establecimientos', coalesce(p_items, '[]'::jsonb)), auth.uid()
  );
  return v_total;
end;
$$;

-- v18 restringe los tipos de auditoria; se amplian sin recrear la tabla.
alter table public.configuracion_multiempresa_eventos
  drop constraint if exists configuracion_multiempresa_eventos_tipo_check;
alter table public.configuracion_multiempresa_eventos
  add constraint configuracion_multiempresa_eventos_tipo_check check (tipo in (
    'empresa_creada', 'empresa_actualizada', 'almacenes_asignados',
    'usuarios_asignados', 'clasificacion_automatica', 'establecimientos_asignados'
  ));

create or replace function public.admin_guardar_empresa_completa_v19(
  p_empresa_id uuid,
  p_grupo_id uuid,
  p_codigo text,
  p_ruc text,
  p_razon_social text,
  p_nombre_comercial text,
  p_tipo text,
  p_obligado_contabilidad boolean,
  p_activo boolean,
  p_almacenes jsonb,
  p_establecimientos jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := public.admin_guardar_empresa_completa(
    p_empresa_id, p_grupo_id, p_codigo, p_ruc, p_razon_social,
    p_nombre_comercial, p_tipo, p_obligado_contabilidad, p_activo, p_almacenes
  );
  perform public.admin_guardar_establecimientos_empresa(v_id, p_establecimientos);
  return v_id;
end;
$$;

-- Aplica la factura usando el motor atomico de v13 y deja evidencia cuando
-- la numeracion recibida no coincide con la estructura legal configurada.
create or replace function public.aplicar_factura_venta_xml_v19(
  p_documento jsonb,
  p_almacen_id uuid,
  p_asignaciones jsonb,
  p_nota text default null,
  p_confirmar_codigo_no_estandar boolean default false,
  p_codigo_nota text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ruc text := nullif(btrim(p_documento->>'emisor_ruc'), '');
  v_establecimiento text := nullif(btrim(p_documento->>'establecimiento'), '');
  v_punto text := nullif(btrim(p_documento->>'punto_emision'), '');
  v_equivalencia_id uuid;
  v_establecimiento_id uuid;
  v_punto_id uuid;
  v_motivo_equivalencia text;
  v_no_estandar boolean;
  v_resultado jsonb;
  v_documento_id uuid;
  v_nota_confirmacion text;
begin
  select m.empresa_establecimiento_id, m.empresa_punto_emision_id,
         m.empresa_equivalencia_id, ef.motivo
  into v_establecimiento_id, v_punto_id, v_equivalencia_id,
       v_motivo_equivalencia
  from public.establecimiento_almacen_facturacion m
  left join public.empresa_equivalencias_facturacion ef
    on ef.id = m.empresa_equivalencia_id and ef.activo
  where m.emisor_ruc = v_ruc
    and m.establecimiento = v_establecimiento
    and m.punto_emision = v_punto;

  v_no_estandar := v_equivalencia_id is not null
    or v_establecimiento_id is null or v_punto_id is null;

  if v_no_estandar and not coalesce(p_confirmar_codigo_no_estandar, false) then
    raise exception 'La numeracion del XML requiere validacion antes de aplicar la factura';
  end if;
  if v_no_estandar
     and btrim(coalesce(p_codigo_nota, v_motivo_equivalencia, '')) = '' then
    raise exception 'Describe la novedad de numeracion antes de continuar';
  end if;

  v_nota_confirmacion := nullif(btrim(coalesce(
    p_codigo_nota, v_motivo_equivalencia
  )), '');

  v_resultado := public.aplicar_factura_venta_xml(
    p_documento, p_almacen_id, p_asignaciones, p_nota
  );
  v_documento_id := nullif(v_resultado->>'id', '')::uuid;

  if v_documento_id is not null
     and not coalesce((v_resultado->>'duplicado')::boolean, false) then
    -- Se vuelve a leer el mapeo porque v13 puede haberlo creado en esta misma
    -- transaccion cuando era un codigo todavia desconocido.
    select m.empresa_establecimiento_id, m.empresa_punto_emision_id,
           m.empresa_equivalencia_id
    into v_establecimiento_id, v_punto_id, v_equivalencia_id
    from public.establecimiento_almacen_facturacion m
    where m.emisor_ruc = v_ruc
      and m.establecimiento = v_establecimiento
      and m.punto_emision = v_punto;

    update public.documentos_venta_xml
    set empresa_establecimiento_id = v_establecimiento_id,
        empresa_punto_emision_id = v_punto_id,
        empresa_equivalencia_id = v_equivalencia_id,
        codigo_facturacion_no_estandar = v_no_estandar,
        codigo_facturacion_confirmado_por = case when v_no_estandar then auth.uid() end,
        codigo_facturacion_confirmado_at = case when v_no_estandar then now() end,
        codigo_facturacion_nota = case when v_no_estandar then v_nota_confirmacion end
    where id = v_documento_id;
  end if;

  return v_resultado || jsonb_build_object(
    'codigo_no_estandar', v_no_estandar,
    'codigo_confirmado', v_no_estandar and coalesce(p_confirmar_codigo_no_estandar, false)
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Vista administrativa
-- ------------------------------------------------------------
create or replace view public.vista_establecimientos_empresa
with (security_invoker = true) as
select
  ee.id,
  ee.empresa_id,
  e.ruc,
  e.razon_social,
  ee.codigo,
  ee.nombre,
  ee.almacen_id,
  a.nombre as almacen,
  ee.direccion,
  ee.es_matriz,
  ee.activo,
  coalesce(array_agg(pe.codigo order by pe.codigo)
    filter (where pe.id is not null and pe.activo), array[]::text[]) as puntos_emision,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', eq.id,
      'establecimiento_xml', eq.establecimiento_xml,
      'punto_emision_xml', eq.punto_emision_xml,
      'punto_emision_oficial', po.codigo,
      'motivo', eq.motivo
    ) order by eq.establecimiento_xml, eq.punto_emision_xml)
    from public.empresa_equivalencias_facturacion eq
    join public.empresa_puntos_emision po on po.id = eq.punto_emision_id
    where eq.establecimiento_id = ee.id and eq.activo
  ), '[]'::jsonb) as equivalencias_xml
from public.empresa_establecimientos ee
join public.empresas e on e.id = ee.empresa_id
left join public.almacenes a on a.id = ee.almacen_id
left join public.empresa_puntos_emision pe on pe.establecimiento_id = ee.id
group by ee.id, e.id, a.id;

create or replace view public.vista_equivalencias_facturacion
with (security_invoker = true) as
select
  eq.id,
  e.ruc as emisor_ruc,
  eq.establecimiento_xml,
  eq.punto_emision_xml,
  ee.id as empresa_establecimiento_id,
  ee.codigo as establecimiento_oficial,
  ee.nombre as establecimiento_nombre,
  pe.id as empresa_punto_emision_id,
  pe.codigo as punto_emision_oficial,
  ee.almacen_id,
  a.nombre as almacen,
  eq.motivo,
  eq.activo
from public.empresa_equivalencias_facturacion eq
join public.empresas e on e.id = eq.empresa_id
join public.empresa_establecimientos ee on ee.id = eq.establecimiento_id
join public.empresa_puntos_emision pe on pe.id = eq.punto_emision_id
left join public.almacenes a on a.id = ee.almacen_id;

-- ------------------------------------------------------------
-- 6. Propiedad y privilegios
-- ------------------------------------------------------------
alter function public.sincronizar_establecimiento_facturacion() owner to postgres;
alter function public.clasificar_establecimiento_venta_xml() owner to postgres;
alter function public.admin_guardar_establecimientos_empresa(uuid, jsonb) owner to postgres;
alter function public.admin_guardar_empresa_completa_v19(uuid, uuid, text, text, text, text, text, boolean, boolean, jsonb, jsonb) owner to postgres;
alter function public.aplicar_factura_venta_xml_v19(jsonb, uuid, jsonb, text, boolean, text) owner to postgres;

revoke all on public.empresa_establecimientos from public, anon;
revoke all on public.empresa_puntos_emision from public, anon;
revoke all on public.empresa_equivalencias_facturacion from public, anon;
revoke insert, update, delete on public.empresa_establecimientos from authenticated;
revoke insert, update, delete on public.empresa_puntos_emision from authenticated;
revoke insert, update, delete on public.empresa_equivalencias_facturacion from authenticated;
grant select on public.empresa_establecimientos to authenticated;
grant select on public.empresa_puntos_emision to authenticated;
grant select on public.empresa_equivalencias_facturacion to authenticated;
grant select on public.vista_establecimientos_empresa to authenticated;
grant select on public.vista_equivalencias_facturacion to authenticated;

revoke execute on function public.sincronizar_establecimiento_facturacion()
  from public, anon, authenticated;
revoke execute on function public.clasificar_establecimiento_venta_xml()
  from public, anon, authenticated;
revoke execute on function public.admin_guardar_establecimientos_empresa(uuid, jsonb)
  from public, anon;
revoke execute on function public.admin_guardar_empresa_completa_v19(uuid, uuid, text, text, text, text, text, boolean, boolean, jsonb, jsonb)
  from public, anon;
revoke execute on function public.aplicar_factura_venta_xml_v19(jsonb, uuid, jsonb, text, boolean, text)
  from public, anon;
grant execute on function public.admin_guardar_establecimientos_empresa(uuid, jsonb)
  to authenticated;
grant execute on function public.admin_guardar_empresa_completa_v19(uuid, uuid, text, text, text, text, text, boolean, boolean, jsonb, jsonb)
  to authenticated;
grant execute on function public.aplicar_factura_venta_xml_v19(jsonb, uuid, jsonb, text, boolean, text)
  to authenticated;

notify pgrst, 'reload schema';
