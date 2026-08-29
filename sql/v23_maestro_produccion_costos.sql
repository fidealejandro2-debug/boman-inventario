-- ============================================================
-- BOMAN INVENTARIO - Maestro de produccion y costos v23
-- Clasifica productos, normaliza unidades, versiona formulas/BOM y calcula
-- costos estimados por empresa antes de habilitar la ejecucion productiva.
-- Esta version NO modifica stock. Ejecutar una sola vez DESPUES de v22.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Unidades y clasificacion del catalogo
-- ------------------------------------------------------------
create table if not exists public.unidades_medida_produccion (
  codigo text primary key,
  nombre text not null,
  simbolo text not null,
  familia text not null check (familia in ('conteo', 'longitud', 'masa', 'volumen')),
  unidad_base boolean not null default true,
  activo boolean not null default true
);

insert into public.unidades_medida_produccion(codigo, nombre, simbolo, familia)
values
  ('unidad', 'Unidad', 'u', 'conteo'),
  ('par', 'Par', 'par', 'conteo'),
  ('docena', 'Docena', 'doc', 'conteo'),
  ('centimetro', 'Centimetro', 'cm', 'longitud'),
  ('metro', 'Metro', 'm', 'longitud'),
  ('gramo', 'Gramo', 'g', 'masa'),
  ('kilogramo', 'Kilogramo', 'kg', 'masa'),
  ('mililitro', 'Mililitro', 'ml', 'volumen'),
  ('litro', 'Litro', 'l', 'volumen')
on conflict (codigo) do update
set nombre = excluded.nombre, simbolo = excluded.simbolo,
    familia = excluded.familia, activo = true;

alter table public.productos
  add column if not exists tipo_inventario text not null default 'producto_terminado'
    check (tipo_inventario in (
      'producto_terminado', 'materia_prima', 'insumo', 'empaque', 'subproducto'
    )),
  add column if not exists unidad_medida text not null default 'unidad'
    references public.unidades_medida_produccion(codigo),
  add column if not exists costo_estandar numeric(18,6)
    check (costo_estandar is null or costo_estandar >= 0),
  add column if not exists produccion_updated_at timestamptz,
  add column if not exists produccion_updated_by uuid references public.perfiles(id);

create index if not exists idx_productos_tipo_inventario
  on public.productos(tipo_inventario, activo, sku);

create table if not exists public.productos_produccion_eventos (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references public.productos(id) on delete restrict,
  valores_anteriores jsonb not null,
  valores_nuevos jsonb not null,
  motivo text not null check (btrim(motivo) <> ''),
  realizado_por uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_productos_produccion_eventos_producto
  on public.productos_produccion_eventos(producto_id, created_at desc);

-- ------------------------------------------------------------
-- 2. Formulas/BOM compartidas por el grupo economico
-- ------------------------------------------------------------
create table if not exists public.formulas_produccion (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  codigo text not null check (btrim(codigo) <> ''),
  producto_resultado_id uuid not null references public.productos(id) on delete restrict,
  version integer not null check (version > 0),
  rendimiento_base numeric(18,6) not null check (rendimiento_base > 0),
  costo_mano_obra_lote numeric(18,6) not null default 0 check (costo_mano_obra_lote >= 0),
  costo_indirecto_lote numeric(18,6) not null default 0 check (costo_indirecto_lote >= 0),
  estado text not null default 'borrador'
    check (estado in ('borrador', 'activa', 'inactiva')),
  nota text,
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  aprobado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  aprobado_at timestamptz,
  unique (grupo_id, codigo, version),
  unique (grupo_id, producto_resultado_id, version)
);

create unique index if not exists uq_formula_activa_producto_grupo
  on public.formulas_produccion(grupo_id, producto_resultado_id)
  where estado = 'activa';

create table if not exists public.formula_produccion_componentes (
  id uuid primary key default gen_random_uuid(),
  formula_id uuid not null references public.formulas_produccion(id) on delete restrict,
  producto_id uuid not null references public.productos(id) on delete restrict,
  cantidad_base numeric(18,6) not null check (cantidad_base > 0),
  merma_porcentaje numeric(7,4) not null default 0
    check (merma_porcentaje >= 0 and merma_porcentaje <= 100),
  observacion text,
  unique (formula_id, producto_id)
);

create table if not exists public.formula_produccion_eventos (
  id uuid primary key default gen_random_uuid(),
  formula_id uuid not null references public.formulas_produccion(id) on delete restrict,
  tipo text not null check (tipo in ('creada', 'actualizada', 'activada', 'inactivada')),
  estado_anterior text,
  estado_nuevo text not null,
  detalle text,
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_formulas_grupo_producto
  on public.formulas_produccion(grupo_id, producto_resultado_id, version desc);
create index if not exists idx_formula_componentes_producto
  on public.formula_produccion_componentes(producto_id, formula_id);
create index if not exists idx_formula_eventos_fecha
  on public.formula_produccion_eventos(formula_id, created_at desc);

-- ------------------------------------------------------------
-- 3. Acceso y RLS
-- ------------------------------------------------------------
create or replace function public.usuario_puede_grupo_produccion(p_grupo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_grupo_id is not null and exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text in ('admin', 'control', 'gerencia')
        or exists (
          select 1
          from public.empresas e
          where e.grupo_id = p_grupo_id and e.activo
            and public.usuario_puede_empresa(e.id, false)
        )
      )
  );
$$;

create or replace function public.puede_ver_formula_produccion(p_formula_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.formulas_produccion f
    where f.id = p_formula_id
      and public.usuario_puede_grupo_produccion(f.grupo_id)
  );
$$;

alter table public.unidades_medida_produccion enable row level security;
alter table public.productos_produccion_eventos enable row level security;
alter table public.formulas_produccion enable row level security;
alter table public.formula_produccion_componentes enable row level security;
alter table public.formula_produccion_eventos enable row level security;

drop policy if exists "leer_unidades_medida_produccion_v23"
  on public.unidades_medida_produccion;
create policy "leer_unidades_medida_produccion_v23"
on public.unidades_medida_produccion for select to authenticated using (activo);

drop policy if exists "leer_productos_produccion_eventos_v23"
  on public.productos_produccion_eventos;
create policy "leer_productos_produccion_eventos_v23"
on public.productos_produccion_eventos for select to authenticated using (
  public.rol_usuario_actual() in ('admin', 'control', 'gerencia')
);

drop policy if exists "leer_formulas_produccion_v23" on public.formulas_produccion;
create policy "leer_formulas_produccion_v23"
on public.formulas_produccion for select to authenticated using (
  public.usuario_puede_grupo_produccion(grupo_id)
);

drop policy if exists "leer_formula_componentes_v23"
  on public.formula_produccion_componentes;
create policy "leer_formula_componentes_v23"
on public.formula_produccion_componentes for select to authenticated using (
  public.puede_ver_formula_produccion(formula_id)
);

drop policy if exists "leer_formula_eventos_v23" on public.formula_produccion_eventos;
create policy "leer_formula_eventos_v23"
on public.formula_produccion_eventos for select to authenticated using (
  public.puede_ver_formula_produccion(formula_id)
);

-- ------------------------------------------------------------
-- 4. Administracion auditada del maestro productivo
-- ------------------------------------------------------------
create or replace function public.clasificar_productos_produccion_v23(
  p_items jsonb,
  p_motivo text
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  it record;
  p public.productos%rowtype;
  v_total integer := 0;
  v_antes jsonb;
  v_despues jsonb;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden clasificar el maestro productivo';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'No hay productos para clasificar';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then
    raise exception 'Indica el motivo de la clasificacion (minimo 5 caracteres)';
  end if;
  if exists (
    select producto_id
    from jsonb_to_recordset(p_items) x(producto_id uuid)
    group by producto_id having count(*) > 1
  ) then raise exception 'La lista contiene productos repetidos'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_items) x(
      producto_id uuid, tipo_inventario text, unidad_medida text,
      costo_estandar numeric
    )
    left join public.productos p on p.id = x.producto_id and p.activo
    left join public.unidades_medida_produccion u
      on u.codigo = x.unidad_medida and u.activo
    where p.id is null or u.codigo is null
      or x.tipo_inventario not in (
        'producto_terminado', 'materia_prima', 'insumo', 'empaque', 'subproducto'
      )
      or coalesce(x.costo_estandar, 0) < 0
  ) then raise exception 'Existe una clasificacion de producto invalida'; end if;

  for it in
    select *
    from jsonb_to_recordset(p_items) x(
      producto_id uuid, tipo_inventario text, unidad_medida text,
      costo_estandar numeric
    )
    order by producto_id
  loop
    select * into p from public.productos where id = it.producto_id for update;
    v_antes := jsonb_build_object(
      'tipo_inventario', p.tipo_inventario,
      'unidad_medida', p.unidad_medida,
      'costo_estandar', p.costo_estandar
    );
    v_despues := jsonb_build_object(
      'tipo_inventario', it.tipo_inventario,
      'unidad_medida', it.unidad_medida,
      'costo_estandar', it.costo_estandar
    );
    if (p.tipo_inventario is distinct from it.tipo_inventario
        or p.unidad_medida is distinct from it.unidad_medida)
       and exists (
         select 1
         from public.formulas_produccion f
         where f.estado = 'activa'
           and (
             f.producto_resultado_id = p.id
             or exists (
               select 1 from public.formula_produccion_componentes c
               where c.formula_id = f.id and c.producto_id = p.id
             )
           )
       ) then
      raise exception 'El producto % participa en una formula activa. Inactiva la formula antes de cambiar tipo o unidad.', p.sku;
    end if;
    if v_antes is distinct from v_despues then
      update public.productos
      set tipo_inventario = it.tipo_inventario,
          unidad_medida = it.unidad_medida,
          costo_estandar = it.costo_estandar,
          produccion_updated_at = now(),
          produccion_updated_by = auth.uid()
      where id = p.id;
      insert into public.productos_produccion_eventos(
        producto_id, valores_anteriores, valores_nuevos, motivo, realizado_por
      ) values (p.id, v_antes, v_despues, btrim(p_motivo), auth.uid());
      v_total := v_total + 1;
    end if;
  end loop;
  return v_total;
end;
$$;

create or replace function public.guardar_formula_produccion_v23(
  p_formula_id uuid,
  p_grupo_id uuid,
  p_codigo text,
  p_producto_resultado_id uuid,
  p_rendimiento_base numeric,
  p_costo_mano_obra_lote numeric,
  p_costo_indirecto_lote numeric,
  p_nota text,
  p_componentes jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.formulas_produccion%rowtype;
  v_id uuid;
  v_version integer;
  v_tipo_evento text;
begin
  if public.rol_usuario_actual() not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden guardar formulas';
  end if;
  if not exists (select 1 from public.grupos_economicos where id = p_grupo_id and activo) then
    raise exception 'El grupo economico no existe o esta inactivo';
  end if;
  if btrim(coalesce(p_codigo, '')) = '' then raise exception 'El codigo de formula es obligatorio'; end if;
  if coalesce(p_rendimiento_base, 0) <= 0 then raise exception 'El rendimiento debe ser mayor que cero'; end if;
  if coalesce(p_costo_mano_obra_lote, 0) < 0 or coalesce(p_costo_indirecto_lote, 0) < 0 then
    raise exception 'Los costos de conversion no pueden ser negativos';
  end if;
  if not exists (
    select 1 from public.productos
    where id = p_producto_resultado_id and activo
      and tipo_inventario in ('producto_terminado', 'subproducto')
  ) then raise exception 'El resultado debe ser un producto terminado o subproducto activo'; end if;
  if jsonb_typeof(p_componentes) <> 'array' or jsonb_array_length(p_componentes) = 0 then
    raise exception 'La formula debe tener al menos un componente';
  end if;
  if exists (
    select producto_id
    from jsonb_to_recordset(p_componentes) x(producto_id uuid)
    group by producto_id having count(*) > 1
  ) then raise exception 'La formula contiene componentes repetidos'; end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_componentes) x(
      producto_id uuid, cantidad_base numeric,
      merma_porcentaje numeric, observacion text
    )
    left join public.productos p on p.id = x.producto_id and p.activo
    where p.id is null or x.producto_id = p_producto_resultado_id
      or coalesce(x.cantidad_base, 0) <= 0
      or coalesce(x.merma_porcentaje, 0) < 0
      or coalesce(x.merma_porcentaje, 0) > 100
  ) then raise exception 'Existe un componente o cantidad invalida'; end if;

  if p_formula_id is null then
    select coalesce(max(version), 0) + 1 into v_version
    from public.formulas_produccion
    where grupo_id = p_grupo_id and producto_resultado_id = p_producto_resultado_id;
    insert into public.formulas_produccion(
      grupo_id, codigo, producto_resultado_id, version, rendimiento_base,
      costo_mano_obra_lote, costo_indirecto_lote, nota, creado_por
    ) values (
      p_grupo_id, upper(btrim(p_codigo)), p_producto_resultado_id, v_version,
      p_rendimiento_base, coalesce(p_costo_mano_obra_lote, 0),
      coalesce(p_costo_indirecto_lote, 0), nullif(btrim(p_nota), ''), auth.uid()
    ) returning id into v_id;
    v_tipo_evento := 'creada';
  else
    select * into f from public.formulas_produccion
    where id = p_formula_id for update;
    if not found then raise exception 'La formula no existe'; end if;
    if f.estado <> 'borrador' then
      raise exception 'Una formula activa o inactiva no se edita; crea una nueva version';
    end if;
    if f.grupo_id <> p_grupo_id or f.producto_resultado_id <> p_producto_resultado_id then
      raise exception 'El grupo y producto resultado no pueden cambiar en una version existente';
    end if;
    update public.formulas_produccion
    set codigo = upper(btrim(p_codigo)), rendimiento_base = p_rendimiento_base,
        costo_mano_obra_lote = coalesce(p_costo_mano_obra_lote, 0),
        costo_indirecto_lote = coalesce(p_costo_indirecto_lote, 0),
        nota = nullif(btrim(p_nota), ''), updated_at = now()
    where id = f.id returning id into v_id;
    delete from public.formula_produccion_componentes where formula_id = v_id;
    v_tipo_evento := 'actualizada';
  end if;

  insert into public.formula_produccion_componentes(
    formula_id, producto_id, cantidad_base, merma_porcentaje, observacion
  )
  select v_id, x.producto_id, x.cantidad_base,
         coalesce(x.merma_porcentaje, 0), nullif(btrim(x.observacion), '')
  from jsonb_to_recordset(p_componentes) x(
    producto_id uuid, cantidad_base numeric,
    merma_porcentaje numeric, observacion text
  );

  insert into public.formula_produccion_eventos(
    formula_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (
    v_id, v_tipo_evento, 'borrador', 'borrador',
    coalesce(nullif(btrim(p_nota), ''), 'Formula guardada'), auth.uid()
  );
  return v_id;
end;
$$;

create or replace function public.resolver_formula_produccion_v23(
  p_formula_id uuid,
  p_activar boolean,
  p_nota text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.formulas_produccion%rowtype;
  v_rol text := public.rol_usuario_actual();
  v_estado text;
begin
  if v_rol not in ('admin', 'control') then
    raise exception 'Solo Administracion o Control pueden resolver formulas';
  end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'La resolucion requiere una nota de al menos 5 caracteres';
  end if;
  select * into f from public.formulas_produccion where id = p_formula_id for update;
  if not found then raise exception 'La formula no existe'; end if;
  if p_activar and f.estado = 'activa' then raise exception 'La formula ya esta activa'; end if;
  if not p_activar and f.estado <> 'activa' then
    raise exception 'Solo una formula activa puede inactivarse';
  end if;
  if p_activar and f.creado_por = auth.uid() and v_rol <> 'admin' then
    raise exception 'Quien preparo la formula no puede aprobarla; requiere otro revisor';
  end if;
  if p_activar and not exists (
    select 1 from public.formula_produccion_componentes where formula_id = f.id
  ) then raise exception 'La formula no tiene componentes'; end if;
  if p_activar and exists (
    select 1
    from public.formula_produccion_componentes c
    join public.productos p on p.id = c.producto_id
    where c.formula_id = f.id and not p.activo
  ) then raise exception 'La formula contiene un componente inactivo'; end if;

  -- Evita ciclos directos e indirectos entre formulas activas. Si un
  -- componente termina dependiendo del producto resultado, no se activa.
  if p_activar and exists (
    with recursive dependencias(producto_id) as (
      select c.producto_id
      from public.formula_produccion_componentes c
      where c.formula_id = f.id
      union
      select c2.producto_id
      from dependencias d
      join public.formulas_produccion fa
        on fa.grupo_id = f.grupo_id
       and fa.producto_resultado_id = d.producto_id
       and fa.estado = 'activa'
      join public.formula_produccion_componentes c2 on c2.formula_id = fa.id
    )
    select 1 from dependencias where producto_id = f.producto_resultado_id
  ) then raise exception 'La formula genera una dependencia circular'; end if;

  if p_activar then
    insert into public.formula_produccion_eventos(
      formula_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id
    )
    select anterior.id, 'inactivada', 'activa', 'inactiva',
           'Sustituida por la formula ' || f.codigo || ' v' || f.version::text
             || '. ' || btrim(p_nota),
           auth.uid()
    from public.formulas_produccion anterior
    where anterior.grupo_id = f.grupo_id
      and anterior.producto_resultado_id = f.producto_resultado_id
      and anterior.estado = 'activa' and anterior.id <> f.id;

    update public.formulas_produccion
    set estado = 'inactiva', updated_at = now()
    where grupo_id = f.grupo_id and producto_resultado_id = f.producto_resultado_id
      and estado = 'activa' and id <> f.id;
    v_estado := 'activa';
  else
    v_estado := 'inactiva';
  end if;

  update public.formulas_produccion
  set estado = v_estado, aprobado_por = auth.uid(), aprobado_at = now(),
      updated_at = now(), nota = concat_ws(E'\n', nota, btrim(p_nota))
  where id = f.id;

  insert into public.formula_produccion_eventos(
    formula_id, tipo, estado_anterior, estado_nuevo, detalle, usuario_id
  ) values (
    f.id, case when p_activar then 'activada' else 'inactivada' end,
    f.estado, v_estado, btrim(p_nota), auth.uid()
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Costos de referencia y costo teorico por empresa/RUC
-- ------------------------------------------------------------
create or replace view public.vista_costos_producto_empresa_v23
with (security_invoker = true) as
select
  e.id as empresa_id,
  e.grupo_id,
  p.id as producto_id,
  p.sku,
  p.nombre as producto,
  p.tipo_inventario,
  p.unidad_medida,
  p.costo_estandar,
  compras.cantidad_comprada,
  compras.costo_promedio_compras,
  coalesce(compras.costo_promedio_compras, p.costo_estandar, 0) as costo_referencia,
  case
    when compras.costo_promedio_compras is not null then 'compras'
    when p.costo_estandar is not null then 'estandar'
    else 'sin_costo'
  end as fuente_costo
from public.empresas e
cross join public.productos p
left join lateral (
  select
    sum(l.cantidad_conforme)::numeric as cantidad_comprada,
    round(
      sum(l.cantidad_conforme * l.costo_unitario)
        / nullif(sum(l.cantidad_conforme), 0), 6
    ) as costo_promedio_compras
  from public.recepciones_compra r
  join public.recepcion_compra_lineas l on l.recepcion_id = r.id
  where r.empresa_id = e.id and r.estado = 'aplicada'
    and l.producto_id = p.id and l.cantidad_conforme > 0
) compras on true
where e.activo and p.activo;

create or replace view public.vista_formula_costos_empresa_v23
with (security_invoker = true) as
select
  f.id as formula_id,
  f.grupo_id,
  e.id as empresa_id,
  e.codigo as empresa_codigo,
  e.razon_social,
  f.codigo as formula_codigo,
  f.version,
  f.estado,
  f.producto_resultado_id,
  pr.sku as resultado_sku,
  pr.nombre as resultado_producto,
  pr.unidad_medida as resultado_unidad,
  f.rendimiento_base,
  coalesce(c.materiales, 0) as costo_materiales_lote,
  f.costo_mano_obra_lote,
  f.costo_indirecto_lote,
  round(
    (coalesce(c.materiales, 0) + f.costo_mano_obra_lote + f.costo_indirecto_lote)
      / f.rendimiento_base, 6
  ) as costo_unitario_estimado,
  coalesce(c.componentes, 0) as componentes,
  coalesce(c.componentes_sin_costo, 0) as componentes_sin_costo
from public.formulas_produccion f
join public.empresas e on e.grupo_id = f.grupo_id and e.activo
join public.productos pr on pr.id = f.producto_resultado_id
left join lateral (
  select
    count(*)::integer as componentes,
    count(*) filter (where co.costo_referencia <= 0)::integer as componentes_sin_costo,
    round(sum(
      fc.cantidad_base * (1 + fc.merma_porcentaje / 100)
        * co.costo_referencia
    ), 6) as materiales
  from public.formula_produccion_componentes fc
  join public.vista_costos_producto_empresa_v23 co
    on co.empresa_id = e.id and co.producto_id = fc.producto_id
  where fc.formula_id = f.id
) c on true;

-- ------------------------------------------------------------
-- 6. Propiedad y privilegios
-- ------------------------------------------------------------
alter function public.usuario_puede_grupo_produccion(uuid) owner to postgres;
alter function public.puede_ver_formula_produccion(uuid) owner to postgres;
alter function public.clasificar_productos_produccion_v23(jsonb, text) owner to postgres;
alter function public.guardar_formula_produccion_v23(uuid, uuid, text, uuid, numeric, numeric, numeric, text, jsonb)
  owner to postgres;
alter function public.resolver_formula_produccion_v23(uuid, boolean, text) owner to postgres;

revoke all on public.unidades_medida_produccion from public, anon;
revoke all on public.productos_produccion_eventos from public, anon;
revoke all on public.formulas_produccion from public, anon;
revoke all on public.formula_produccion_componentes from public, anon;
revoke all on public.formula_produccion_eventos from public, anon;
revoke insert, update, delete on public.unidades_medida_produccion from authenticated;
revoke insert, update, delete on public.productos_produccion_eventos from authenticated;
revoke insert, update, delete on public.formulas_produccion from authenticated;
revoke insert, update, delete on public.formula_produccion_componentes from authenticated;
revoke insert, update, delete on public.formula_produccion_eventos from authenticated;
grant select on public.unidades_medida_produccion to authenticated;
grant select on public.productos_produccion_eventos to authenticated;
grant select on public.formulas_produccion to authenticated;
grant select on public.formula_produccion_componentes to authenticated;
grant select on public.formula_produccion_eventos to authenticated;
revoke all on public.vista_costos_producto_empresa_v23 from public, anon;
revoke all on public.vista_formula_costos_empresa_v23 from public, anon;
grant select on public.vista_costos_producto_empresa_v23 to authenticated;
grant select on public.vista_formula_costos_empresa_v23 to authenticated;

revoke execute on function public.usuario_puede_grupo_produccion(uuid) from public, anon;
revoke execute on function public.puede_ver_formula_produccion(uuid) from public, anon;
revoke execute on function public.clasificar_productos_produccion_v23(jsonb, text)
  from public, anon;
revoke execute on function public.guardar_formula_produccion_v23(uuid, uuid, text, uuid, numeric, numeric, numeric, text, jsonb)
  from public, anon;
revoke execute on function public.resolver_formula_produccion_v23(uuid, boolean, text)
  from public, anon;
grant execute on function public.usuario_puede_grupo_produccion(uuid) to authenticated;
grant execute on function public.puede_ver_formula_produccion(uuid) to authenticated;
grant execute on function public.clasificar_productos_produccion_v23(jsonb, text)
  to authenticated;
grant execute on function public.guardar_formula_produccion_v23(uuid, uuid, text, uuid, numeric, numeric, numeric, text, jsonb)
  to authenticated;
grant execute on function public.resolver_formula_produccion_v23(uuid, boolean, text)
  to authenticated;

notify pgrst, 'reload schema';
