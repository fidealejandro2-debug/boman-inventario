-- ============================================================
-- BOMAN INVENTARIO - Permisos y calidad de nomina v35
-- Matriz de acceso a modulos administrada desde el ERP, edicion justificada
-- de personal y reduccion del ruido de auditoria. Las asignaciones de
-- almacenes/empresas y las reglas de segregacion critica siguen vigentes.
-- Ejecutar una sola vez DESPUES de v34.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Catalogo de permisos y matriz por rol
-- ------------------------------------------------------------
create table if not exists public.permisos_sistema (
  codigo text primary key check (codigo ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  modulo text not null check (btrim(modulo) <> ''),
  nombre text not null check (btrim(nombre) <> ''),
  descripcion text not null check (btrim(descripcion) <> ''),
  orden integer not null default 0,
  activo boolean not null default true,
  created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.rol_permisos (
  rol public.rol_usuario not null,
  permiso_codigo text not null references public.permisos_sistema(codigo) on delete restrict,
  permitido boolean not null default false,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (rol, permiso_codigo)
);

create table if not exists public.permisos_roles_eventos (
  id uuid primary key default gen_random_uuid(),
  rol public.rol_usuario not null,
  permisos_anteriores jsonb not null,
  permisos_nuevos jsonb not null,
  detalle text not null check (btrim(detalle) <> ''),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_rol_permisos_permiso_v35
  on public.rol_permisos(permiso_codigo, rol) where permitido;
create index if not exists idx_permisos_roles_eventos_v35
  on public.permisos_roles_eventos(rol, created_at desc);

insert into public.permisos_sistema as p (
  codigo, modulo, nombre, descripcion, orden
) values
  ('inventario.acceder', 'Inventario', 'Stock por almacen',
   'Abre la consulta de existencias; solo muestra los almacenes asignados.', 10),
  ('operaciones.acceder', 'Inventario', 'Solicitudes y transferencias',
   'Abre solicitudes, preparacion, despacho y recepcion.', 20),
  ('conteos.acceder', 'Inventario', 'Conteos fisicos',
   'Abre conteos y reconteos; la aprobacion propia sigue bloqueada.', 30),
  ('movimientos.acceder', 'Inventario', 'Movimientos y kardex',
   'Abre entradas, salidas y trazabilidad de movimientos.', 40),
  ('ventas.acceder', 'Ventas', 'Ventas XML',
   'Abre facturas XML y conciliacion de ventas.', 50),
  ('compras.acceder', 'Compras', 'Compras',
   'Abre proveedores, ordenes y recepciones de compra.', 60),
  ('produccion.acceder', 'Produccion', 'Produccion',
   'Abre formulas, ordenes, rutas, etapas, lotes y costos.', 70),
  ('control.acceder', 'Control', 'Centro de Control',
   'Abre aprobaciones, incidencias y auditoria operativa.', 80),
  ('reportes.acceder', 'Reportes', 'Reportes y analisis',
   'Abre reportes consolidados, operativos y avanzados.', 90),
  ('nomina.acceder', 'Nomina', 'Consultar nomina',
   'Permite consultar personal, expedientes, roles y reportes de nomina.', 100),
  ('nomina.editar', 'Nomina', 'Gestionar nomina',
   'Permite registrar y modificar personal, novedades, roles y configuracion.', 110)
on conflict (codigo) do update set
  modulo = excluded.modulo,
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  orden = excluded.orden,
  activo = true,
  updated_at = now();

-- Replica exactamente el acceso visible anterior a v35. Administrador no
-- necesita filas: tiene todos los permisos de forma inmutable en la funcion.
with predeterminados(rol, permiso_codigo) as (
  values
    ('bodega', 'inventario.acceder'),
    ('bodega', 'operaciones.acceder'),
    ('bodega', 'conteos.acceder'),
    ('bodega', 'movimientos.acceder'),
    ('bodega', 'ventas.acceder'),
    ('bodega', 'compras.acceder'),
    ('bodega', 'produccion.acceder'),

    ('logistica', 'inventario.acceder'),
    ('logistica', 'operaciones.acceder'),
    ('logistica', 'movimientos.acceder'),
    ('logistica', 'produccion.acceder'),

    ('gerencia', 'inventario.acceder'),
    ('gerencia', 'operaciones.acceder'),
    ('gerencia', 'conteos.acceder'),
    ('gerencia', 'movimientos.acceder'),
    ('gerencia', 'ventas.acceder'),
    ('gerencia', 'compras.acceder'),
    ('gerencia', 'produccion.acceder'),
    ('gerencia', 'control.acceder'),
    ('gerencia', 'reportes.acceder'),
    ('gerencia', 'nomina.acceder'),

    ('tienda', 'inventario.acceder'),
    ('tienda', 'operaciones.acceder'),
    ('tienda', 'conteos.acceder'),
    ('tienda', 'movimientos.acceder'),
    ('tienda', 'ventas.acceder'),

    ('control', 'inventario.acceder'),
    ('control', 'operaciones.acceder'),
    ('control', 'conteos.acceder'),
    ('control', 'movimientos.acceder'),
    ('control', 'ventas.acceder'),
    ('control', 'compras.acceder'),
    ('control', 'produccion.acceder'),
    ('control', 'control.acceder'),
    ('control', 'reportes.acceder'),

    ('nomina', 'inventario.acceder'),
    ('nomina', 'operaciones.acceder'),
    ('nomina', 'conteos.acceder'),
    ('nomina', 'movimientos.acceder'),
    ('nomina', 'nomina.acceder'),
    ('nomina', 'nomina.editar')
)
insert into public.rol_permisos (rol, permiso_codigo, permitido)
select p.rol::public.rol_usuario, p.permiso_codigo, true
from predeterminados p
on conflict (rol, permiso_codigo) do nothing;

-- Crea tambien las filas false: simplifica la matriz y hace explicito todo
-- cambio futuro de permisos.
insert into public.rol_permisos (rol, permiso_codigo, permitido)
select r.rol::public.rol_usuario, p.codigo, false
from (values
  ('bodega'), ('logistica'), ('gerencia'), ('tienda'), ('control'), ('nomina')
) r(rol)
cross join public.permisos_sistema p
where p.activo
on conflict (rol, permiso_codigo) do nothing;

-- ------------------------------------------------------------
-- 2. Evaluacion efectiva
-- ------------------------------------------------------------
create or replace function public.usuario_tiene_permiso_v35(p_permiso_codigo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text = 'admin'
        or exists (
          select 1
          from public.rol_permisos rp
          join public.permisos_sistema ps
            on ps.codigo = rp.permiso_codigo and ps.activo
          where rp.rol = p.rol
            and rp.permiso_codigo = p_permiso_codigo
            and rp.permitido
        )
      )
  );
$$;

create or replace function public.permisos_usuario_actual_v35()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(x.codigo order by x.orden), array[]::text[])
  from (
    select ps.codigo, ps.orden
    from public.perfiles p
    join public.permisos_sistema ps on ps.activo
    left join public.rol_permisos rp
      on rp.rol = p.rol and rp.permiso_codigo = ps.codigo
    where p.id = auth.uid() and p.activo
      and (p.rol::text = 'admin' or coalesce(rp.permitido, false))
  ) x;
$$;

-- Nomina queda protegida tambien en la base, no solamente en los botones.
create or replace function public.usuario_puede_nomina(
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.usuario_tiene_permiso_v35(
    case when p_escritura then 'nomina.editar' else 'nomina.acceder' end
  );
$$;

-- ------------------------------------------------------------
-- 3. Administracion atomica y auditada de la matriz
-- ------------------------------------------------------------
create or replace function public.admin_guardar_permisos_rol_v35(
  p_rol text,
  p_items jsonb,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rol public.rol_usuario;
  v_antes jsonb;
  v_despues jsonb;
  v_evento_id uuid;
begin
  if public.rol_usuario_actual() <> 'admin' then
    raise exception 'Solo Administracion puede cambiar permisos de roles';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo del cambio es obligatorio';
  end if;
  if jsonb_typeof(coalesce(p_items, 'null'::jsonb)) <> 'array' then
    raise exception 'La matriz de permisos no es valida';
  end if;

  begin
    v_rol := p_rol::public.rol_usuario;
  exception when invalid_text_representation then
    raise exception 'El rol indicado no existe';
  end;
  if v_rol::text = 'admin' then
    raise exception 'Los permisos del rol Administrador son inmutables para evitar bloqueos del sistema';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 35)
  );
  select id into v_evento_id
  from public.permisos_roles_eventos
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'id', v_evento_id, 'duplicado', true,
      'mensaje', 'Los permisos ya habian sido guardados'
    );
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) x(permiso_codigo text, permitido boolean)
    left join public.permisos_sistema ps
      on ps.codigo = x.permiso_codigo and ps.activo
    where x.permiso_codigo is null or x.permitido is null or ps.codigo is null
  ) then
    raise exception 'La lista contiene un permiso inexistente o incompleto';
  end if;
  if exists (
    select permiso_codigo
    from jsonb_to_recordset(p_items) x(permiso_codigo text, permitido boolean)
    group by permiso_codigo having count(*) > 1
  ) then
    raise exception 'La lista contiene permisos repetidos';
  end if;
  if (
    select count(*) from jsonb_to_recordset(p_items)
      x(permiso_codigo text, permitido boolean)
  ) <> (select count(*) from public.permisos_sistema where activo) then
    raise exception 'Debes enviar la configuracion completa del rol';
  end if;

  select coalesce(jsonb_object_agg(rp.permiso_codigo, rp.permitido), '{}'::jsonb)
  into v_antes
  from public.rol_permisos rp where rp.rol = v_rol;

  insert into public.rol_permisos as rp (
    rol, permiso_codigo, permitido, actualizado_por
  )
  select v_rol, x.permiso_codigo, x.permitido, auth.uid()
  from jsonb_to_recordset(p_items) x(permiso_codigo text, permitido boolean)
  on conflict (rol, permiso_codigo) do update
  set permitido = excluded.permitido,
      actualizado_por = auth.uid(),
      updated_at = now();

  select coalesce(jsonb_object_agg(rp.permiso_codigo, rp.permitido), '{}'::jsonb)
  into v_despues
  from public.rol_permisos rp where rp.rol = v_rol;

  insert into public.permisos_roles_eventos (
    rol, permisos_anteriores, permisos_nuevos, detalle,
    usuario_id, idempotency_key
  ) values (
    v_rol, v_antes, v_despues, btrim(p_motivo),
    auth.uid(), p_idempotency_key
  ) returning id into v_evento_id;

  return jsonb_build_object(
    'id', v_evento_id, 'duplicado', false,
    'mensaje', 'Permisos del rol actualizados correctamente'
  );
end;
$$;

-- ------------------------------------------------------------
-- 4. Vista administrativa
-- ------------------------------------------------------------
create or replace view public.vista_matriz_permisos_v35
with (security_invoker = true) as
select
  r.rol,
  ps.codigo as permiso_codigo,
  ps.modulo,
  ps.nombre,
  ps.descripcion,
  ps.orden,
  case when r.rol = 'admin' then true else coalesce(rp.permitido, false) end
    as permitido,
  r.rol <> 'admin' as configurable,
  rp.updated_at
from (values
  ('admin'), ('bodega'), ('logistica'), ('gerencia'),
  ('tienda'), ('control'), ('nomina')
) r(rol)
cross join public.permisos_sistema ps
left join public.rol_permisos rp
  on rp.rol::text = r.rol and rp.permiso_codigo = ps.codigo
where ps.activo;

-- ------------------------------------------------------------
-- 5. Edicion justificada y auditoria util del personal
-- ------------------------------------------------------------
-- v26 permitia actualizar, pero no recibia motivo. Se conserva como motor
-- interno para las altas v34 y se expone esta version auditada para editar.
create or replace function public.guardar_empleado_v35(
  p_empleado_id uuid,
  p_datos jsonb,
  p_departamento_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_empleado public.empleados%rowtype;
  v_departamento public.departamentos_nomina%rowtype;
  v_evento public.nomina_eventos%rowtype;
begin
  if not public.usuario_puede_nomina(true) then
    raise exception 'No tienes permiso para editar personal';
  end if;
  if p_empleado_id is null then raise exception 'Debes indicar la persona'; end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;
  if coalesce(jsonb_typeof(p_datos), 'null') <> 'object' then
    raise exception 'Los datos de la persona no tienen el formato esperado';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'El motivo de la modificacion es obligatorio';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 35)
  );
  select * into v_evento
  from public.nomina_eventos where idempotency_key = p_idempotency_key;
  if found then
    if v_evento.entidad <> 'empleado'
       or v_evento.entidad_id is distinct from p_empleado_id
       or v_evento.tipo <> 'datos_personales_actualizados' then
      raise exception 'La clave de idempotencia ya fue utilizada en otra operacion';
    end if;
    return jsonb_build_object(
      'id', p_empleado_id, 'duplicado', true,
      'mensaje', 'Los datos ya habian sido actualizados'
    );
  end if;

  select * into v_empleado
  from public.empleados where id = p_empleado_id for update;
  if not found then raise exception 'La persona no existe'; end if;
  if nullif(p_datos ->> 'fecha_ingreso_real', '')::date
     is distinct from v_empleado.fecha_ingreso_real then
    raise exception 'La fecha de ingreso no se edita como dato personal; usa el flujo laboral controlado';
  end if;

  select * into v_departamento
  from public.departamentos_nomina
  where id = p_departamento_id;
  if not found then raise exception 'El departamento no existe'; end if;
  if v_departamento.grupo_id <> v_empleado.grupo_id then
    raise exception 'El departamento no pertenece al grupo economico de la persona';
  end if;
  if not v_departamento.activo
     and p_departamento_id is distinct from v_empleado.departamento_id then
    raise exception 'No se puede asignar un departamento inactivo';
  end if;

  -- El trigger v32 recoge este valor para todos los campos que cambien en la
  -- transaccion, incluidos departamento y cuenta bancaria.
  perform set_config('nomina.motivo', btrim(p_motivo), true);

  perform public.guardar_empleado_v26(
    p_empleado_id,
    v_empleado.grupo_id,
    p_datos ->> 'tipo_identificacion',
    p_datos ->> 'identificacion',
    p_datos ->> 'nombres',
    p_datos ->> 'apellidos',
    nullif(p_datos ->> 'fecha_ingreso_real', '')::date,
    p_datos ->> 'cargo',
    nullif(p_datos ->> 'fecha_nacimiento', '')::date,
    nullif(p_datos ->> 'estado_civil', ''),
    nullif(p_datos ->> 'direccion', ''),
    nullif(p_datos ->> 'telefono', ''),
    nullif(p_datos ->> 'email', ''),
    nullif(p_datos ->> 'contacto_emergencia_nombre', ''),
    nullif(p_datos ->> 'contacto_emergencia_telefono', ''),
    v_departamento.nombre,
    coalesce(nullif(p_datos ->> 'tipo_contrato', ''), 'indefinido'),
    coalesce(nullif(p_datos ->> 'forma_pago', ''), 'transferencia'),
    nullif(p_datos ->> 'banco', ''),
    nullif(p_datos ->> 'tipo_cuenta', ''),
    nullif(p_datos ->> 'numero_cuenta', ''),
    nullif(p_datos ->> 'observacion', '')
  );

  update public.empleados
  set departamento_id = p_departamento_id,
      actualizado_por = auth.uid(),
      updated_at = now()
  where id = p_empleado_id
    and departamento_id is distinct from p_departamento_id;

  insert into public.nomina_eventos (
    entidad, entidad_id, empleado_id, tipo, detalle, usuario_id,
    datos, idempotency_key
  ) values (
    'empleado', p_empleado_id, p_empleado_id,
    'datos_personales_actualizados', btrim(p_motivo), auth.uid(),
    jsonb_build_object('departamento_id', p_departamento_id),
    p_idempotency_key
  );

  return jsonb_build_object(
    'id', p_empleado_id, 'duplicado', false,
    'mensaje', 'Datos personales actualizados correctamente'
  );
end;
$$;

-- Una alta se resume en una sola fila. Las modificaciones siguen quedando
-- campo por campo, que es donde el valor anterior y el motivo son utiles.
create or replace function public.auditar_cambios_nomina_v32()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  v_new jsonb := to_jsonb(new);
  v_registro_id uuid;
  v_empleado_id uuid;
  v_motivo text;
  v_campo text;
begin
  if tg_table_name = 'nomina_parametros' then
    v_registro_id := ('00000000-0000-0000-0000-' ||
      lpad((v_new ->> 'anio'), 12, '0'))::uuid;
  else
    v_registro_id := (v_new ->> 'id')::uuid;
  end if;

  v_empleado_id := case
    when tg_table_name = 'empleados' then (v_new ->> 'id')::uuid
    else nullif(v_new ->> 'empleado_id', '')::uuid
  end;
  v_motivo := coalesce(
    nullif(btrim(v_new ->> 'motivo'), ''),
    nullif(btrim(coalesce(current_setting('nomina.motivo', true), '')), '')
  );

  if tg_op = 'INSERT' then
    insert into public.nomina_cambios (
      tabla, registro_id, empleado_id, operacion, campo,
      valor_anterior, valor_nuevo, sensible, motivo, usuario_id
    ) values (
      tg_table_name, v_registro_id, v_empleado_id, 'alta', '(alta)',
      null,
      (v_new - array[
        'id', 'created_at', 'updated_at', 'creado_por', 'actualizado_por',
        'registrado_por', 'idempotency_key'
      ])::text,
      false, v_motivo, auth.uid()
    );
    return new;
  end if;

  for v_campo in select jsonb_object_keys(v_new) loop
    if public.campo_auditable_nomina_v32(v_campo)
       and (v_old -> v_campo) is distinct from (v_new -> v_campo) then
      insert into public.nomina_cambios (
        tabla, registro_id, empleado_id, operacion, campo,
        valor_anterior, valor_nuevo, sensible, motivo, usuario_id
      ) values (
        tg_table_name, v_registro_id, v_empleado_id, 'modificacion', v_campo,
        v_old ->> v_campo, v_new ->> v_campo,
        public.campo_sensible_nomina_v32(v_campo),
        v_motivo, auth.uid()
      );
    end if;
  end loop;
  return new;
end;
$$;

comment on table public.nomina_cambios is
  'Bitacora laboral inmutable. Conservacion indefinida hasta aprobar una politica legal de archivo; no se purga automaticamente.';

-- ------------------------------------------------------------
-- 6. Seguridad y privilegios
-- ------------------------------------------------------------
alter table public.permisos_sistema enable row level security;
alter table public.rol_permisos enable row level security;
alter table public.permisos_roles_eventos enable row level security;

drop policy if exists "admin_leer_permisos_sistema_v35" on public.permisos_sistema;
create policy "admin_leer_permisos_sistema_v35"
on public.permisos_sistema for select to authenticated using (
  public.rol_usuario_actual() = 'admin'
);
drop policy if exists "admin_leer_rol_permisos_v35" on public.rol_permisos;
create policy "admin_leer_rol_permisos_v35"
on public.rol_permisos for select to authenticated using (
  public.rol_usuario_actual() = 'admin'
);
drop policy if exists "admin_leer_eventos_permisos_v35" on public.permisos_roles_eventos;
create policy "admin_leer_eventos_permisos_v35"
on public.permisos_roles_eventos for select to authenticated using (
  public.rol_usuario_actual() = 'admin'
);

alter function public.usuario_tiene_permiso_v35(text) owner to postgres;
alter function public.permisos_usuario_actual_v35() owner to postgres;
alter function public.usuario_puede_nomina(boolean) owner to postgres;
alter function public.admin_guardar_permisos_rol_v35(text, jsonb, text, uuid) owner to postgres;
alter function public.guardar_empleado_v35(uuid, jsonb, uuid, text, uuid) owner to postgres;
alter function public.auditar_cambios_nomina_v32() owner to postgres;

revoke all on public.permisos_sistema from public, anon;
revoke all on public.rol_permisos from public, anon;
revoke all on public.permisos_roles_eventos from public, anon;
revoke insert, update, delete on public.permisos_sistema from authenticated;
revoke insert, update, delete on public.rol_permisos from authenticated;
revoke insert, update, delete on public.permisos_roles_eventos from authenticated;
grant select on public.permisos_sistema to authenticated;
grant select on public.rol_permisos to authenticated;
grant select on public.permisos_roles_eventos to authenticated;
grant select on public.vista_matriz_permisos_v35 to authenticated;

revoke execute on function public.usuario_tiene_permiso_v35(text) from public, anon;
revoke execute on function public.permisos_usuario_actual_v35() from public, anon;
revoke execute on function public.usuario_puede_nomina(boolean) from public, anon;
revoke execute on function public.guardar_empleado_v26(uuid, uuid, text, text, text, text, date, text, date, text, text, text, text, text, text, text, text, text, text, text, text, text)
  from public, anon, authenticated;
revoke execute on function public.guardar_empleado_v35(uuid, jsonb, uuid, text, uuid)
  from public, anon;
revoke execute on function public.auditar_cambios_nomina_v32()
  from public, anon, authenticated;
revoke execute on function public.admin_guardar_permisos_rol_v35(text, jsonb, text, uuid)
  from public, anon;
grant execute on function public.usuario_tiene_permiso_v35(text) to authenticated;
grant execute on function public.permisos_usuario_actual_v35() to authenticated;
grant execute on function public.usuario_puede_nomina(boolean) to authenticated;
grant execute on function public.guardar_empleado_v35(uuid, jsonb, uuid, text, uuid)
  to authenticated;
grant execute on function public.admin_guardar_permisos_rol_v35(text, jsonb, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';
