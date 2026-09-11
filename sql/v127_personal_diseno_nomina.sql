-- ============================================================
-- BOMAN INVENTARIO - v127
-- Diseñadores y responsables de mockup conectados con Nómina
-- Ejecutar después de v126.
-- ============================================================

begin;
select pg_advisory_xact_lock(12709102026);

do $v127_requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.empleados') is null
     or to_regclass('public.departamentos_nomina') is null
     or to_regclass('public.contrato_gestion_operaciones_v99') is null then
    raise exception 'Faltan contratos, Nomina v34 o Gestion v99 antes de v127';
  end if;
end
$v127_requisitos$;

alter table public.contratos
  add column if not exists disenador_empleado_id uuid,
  add column if not exists autor_mockup_empleado_id uuid;

do $v127_fks$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.contratos'::regclass
      and conname = 'contratos_disenador_empleado_v127_fkey'
  ) then
    alter table public.contratos
      add constraint contratos_disenador_empleado_v127_fkey
      foreign key (disenador_empleado_id) references public.empleados(id)
      on delete restrict;
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.contratos'::regclass
      and conname = 'contratos_autor_mockup_empleado_v127_fkey'
  ) then
    alter table public.contratos
      add constraint contratos_autor_mockup_empleado_v127_fkey
      foreign key (autor_mockup_empleado_id) references public.empleados(id)
      on delete restrict;
  end if;
end
$v127_fks$;

create index if not exists idx_contratos_disenador_empleado_v127
  on public.contratos(disenador_empleado_id, fecha_entrega)
  where disenador_empleado_id is not null;
create index if not exists idx_contratos_autor_mockup_empleado_v127
  on public.contratos(autor_mockup_empleado_id, fecha_entrega)
  where autor_mockup_empleado_id is not null;

comment on column public.contratos.disenador_empleado_id is
  'Empleado de Nomina responsable del diseño. contratos.disenador conserva el nombre historico.';
comment on column public.contratos.autor_mockup_empleado_id is
  'Empleado de Nomina que elaboro el mockup. contratos.autor_mockup conserva el nombre historico.';

create or replace function public.normalizar_persona_v127(p_texto text)
returns text
language sql
immutable
strict
set search_path = ''
as $v127_normalizar$
  select regexp_replace(
    translate(lower(btrim(p_texto)), 'áéíóúüñ', 'aeiouun'),
    '[^a-z0-9]+', '', 'g'
  )
$v127_normalizar$;

-- Solo se enlazan coincidencias únicas. Un nombre ambiguo permanece como
-- histórico y debe resolverse manualmente desde el tablero.
with coincidencias as (
  select c.id,
         (array_agg(e.id order by e.created_at))[1] empleado_id,
         count(*) total
  from public.contratos c
  join public.empleados e on public.normalizar_persona_v127(c.disenador) in (
    public.normalizar_persona_v127(concat_ws(' ', e.nombres, e.apellidos)),
    public.normalizar_persona_v127(concat_ws(' ', e.apellidos, e.nombres))
  )
  where c.disenador_empleado_id is null
    and nullif(btrim(c.disenador), '') is not null
  group by c.id
)
update public.contratos c
set disenador_empleado_id = x.empleado_id
from coincidencias x
where c.id = x.id and x.total = 1;

with coincidencias as (
  select c.id,
         (array_agg(e.id order by e.created_at))[1] empleado_id,
         count(*) total
  from public.contratos c
  join public.empleados e on public.normalizar_persona_v127(c.autor_mockup) in (
    public.normalizar_persona_v127(concat_ws(' ', e.nombres, e.apellidos)),
    public.normalizar_persona_v127(concat_ws(' ', e.apellidos, e.nombres))
  )
  where c.autor_mockup_empleado_id is null
    and nullif(btrim(c.autor_mockup), '') is not null
  group by c.id
)
update public.contratos c
set autor_mockup_empleado_id = x.empleado_id
from coincidencias x
where c.id = x.id and x.total = 1;

-- Evita vínculos falsos si una integración antigua todavía escribe solamente
-- el nombre textual mediante v99: en ese caso se conserva el texto histórico,
-- pero se limpia el UUID. Cuando cambia el UUID, el nombre se toma de Nómina.
create or replace function public.sincronizar_personal_diseno_v127()
returns trigger
language plpgsql
set search_path = ''
as $v127_sync$
declare
  v_nombre text;
begin
  if new.disenador_empleado_id is distinct from old.disenador_empleado_id then
    if new.disenador_empleado_id is not null then
      select concat_ws(' ', nullif(btrim(e.nombres), ''), nullif(btrim(e.apellidos), ''))
      into strict v_nombre from public.empleados e
      where e.id = new.disenador_empleado_id;
      new.disenador := v_nombre;
    end if;
  elsif new.disenador is distinct from old.disenador
        and new.disenador_empleado_id is not null then
    new.disenador_empleado_id := null;
  end if;

  if new.autor_mockup_empleado_id is distinct from old.autor_mockup_empleado_id then
    if new.autor_mockup_empleado_id is not null then
      select concat_ws(' ', nullif(btrim(e.nombres), ''), nullif(btrim(e.apellidos), ''))
      into strict v_nombre from public.empleados e
      where e.id = new.autor_mockup_empleado_id;
      new.autor_mockup := v_nombre;
    end if;
  elsif new.autor_mockup is distinct from old.autor_mockup
        and new.autor_mockup_empleado_id is not null then
    new.autor_mockup_empleado_id := null;
  end if;
  return new;
end
$v127_sync$;

drop trigger if exists trg_sincronizar_personal_diseno_v127 on public.contratos;
create trigger trg_sincronizar_personal_diseno_v127
before update of disenador, disenador_empleado_id, autor_mockup, autor_mockup_empleado_id
on public.contratos
for each row execute function public.sincronizar_personal_diseno_v127();

create or replace function public.listar_personal_diseno_v127()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $v127_lista$
declare
  v_resultado jsonb;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesion para consultar el personal de diseño';
  end if;
  if not (
    public.usuario_tiene_permiso_v35('contratos.acceder')
    or public.usuario_tiene_permiso_v35('contratos.editar')
    or public.usuario_tiene_permiso_v35('produccion.acceder')
  ) then
    raise exception 'No tienes permiso para consultar el personal de diseño';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'nombre', concat_ws(' ', nullif(btrim(e.nombres), ''), nullif(btrim(e.apellidos), '')),
    'cargo', e.cargo,
    'departamento', coalesce(d.nombre, e.area, ''),
    'disenador', public.normalizar_persona_v127(concat_ws(' ', e.cargo, e.area, d.nombre))
      ~ '(disen|design|arte|graf)',
    'mockup', public.normalizar_persona_v127(concat_ws(' ', e.cargo, e.area, d.nombre))
      ~ '(mockup|disen|design|arte|graf)'
  ) order by e.nombres, e.apellidos), '[]'::jsonb)
  into v_resultado
  from public.empleados e
  left join public.departamentos_nomina d on d.id = e.departamento_id
  where e.estado = 'activo' and e.fecha_salida is null;

  return v_resultado;
end
$v127_lista$;

create or replace function public.asignar_personal_diseno_v127(
  p_contrato_id uuid,
  p_tipo text,
  p_empleado_id uuid,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $v127_asignar$
declare
  v_uid uuid := auth.uid();
  v_contrato public.contratos%rowtype;
  v_nombre text;
  v_anterior text;
  v_anterior_id uuid;
  v_quien text;
  v_operacion_id uuid;
  v_solicitados jsonb;
  v_aplicados jsonb;
  v_resultado jsonb;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion para asignar personal'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar') then
    raise exception 'No tienes permiso para asignar responsables de diseño';
  end if;
  if p_contrato_id is null then raise exception 'Selecciona un contrato'; end if;
  if p_tipo not in ('disenador', 'mockup') then raise exception 'El tipo de responsable no es valido'; end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'El motivo debe tener al menos 10 caracteres';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 127));
  select resultado into v_resultado
  from public.contrato_gestion_operaciones_v99
  where idempotency_key = p_idempotency_key;
  if found then return v_resultado; end if;

  select * into v_contrato from public.contratos
  where id = p_contrato_id for update;
  if not found then raise exception 'El contrato no existe'; end if;

  if p_empleado_id is not null then
    select concat_ws(' ', nullif(btrim(e.nombres), ''), nullif(btrim(e.apellidos), ''))
    into v_nombre
    from public.empleados e
    where e.id = p_empleado_id and e.estado = 'activo' and e.fecha_salida is null;
    if not found then
      raise exception 'La persona no existe en Nomina o ya no esta activa';
    end if;
  end if;

  if p_tipo = 'disenador' then
    v_anterior := v_contrato.disenador;
    v_anterior_id := v_contrato.disenador_empleado_id;
  else
    v_anterior := v_contrato.autor_mockup;
    v_anterior_id := v_contrato.autor_mockup_empleado_id;
  end if;
  if v_anterior_id is not distinct from p_empleado_id
     and (
       (p_empleado_id is null and nullif(btrim(v_anterior), '') is null)
       or (p_empleado_id is not null and v_anterior is not distinct from v_nombre)
     ) then
    raise exception 'La persona seleccionada ya es la responsable';
  end if;

  v_solicitados := jsonb_build_object(
    case when p_tipo = 'disenador' then 'disenador_empleado_id' else 'autor_mockup_empleado_id' end,
    p_empleado_id
  );
  v_aplicados := v_solicitados || jsonb_build_object(
    case when p_tipo = 'disenador' then 'disenador' else 'autor_mockup' end,
    v_nombre
  );

  insert into public.contrato_gestion_operaciones_v99(
    contrato_id, cambios_solicitados, cambios_aplicados, motivo,
    usuario_id, idempotency_key
  ) values (
    p_contrato_id, v_solicitados, v_aplicados, btrim(p_motivo),
    v_uid, p_idempotency_key
  ) returning id into v_operacion_id;

  if p_tipo = 'disenador' then
    update public.contratos set disenador_empleado_id = p_empleado_id,
      disenador = v_nombre, actualizado_por = v_uid
    where id = p_contrato_id;
  else
    update public.contratos set autor_mockup_empleado_id = p_empleado_id,
      autor_mockup = v_nombre, actualizado_por = v_uid
    where id = p_contrato_id;
  end if;

  select coalesce(p.nombre_completo, v_uid::text) into v_quien
  from public.perfiles p where p.id = v_uid;

  insert into public.contrato_eventos(
    contrato_id, campo, valor_anterior, valor_nuevo, quien, perfil_id,
    gestion_operacion_id, motivo_gestion_v99
  ) values (
    p_contrato_id,
    case when p_tipo = 'disenador' then 'disenador' else 'autor_mockup' end,
    v_anterior, v_nombre, coalesce(v_quien, v_uid::text), v_uid,
    v_operacion_id, btrim(p_motivo)
  );

  v_resultado := jsonb_build_object(
    'duplicado', false, 'operacion_id', v_operacion_id,
    'contrato_id', p_contrato_id, 'tipo', p_tipo,
    'empleado_id', p_empleado_id, 'nombre', v_nombre
  );
  update public.contrato_gestion_operaciones_v99
  set resultado = v_resultado where id = v_operacion_id;
  return v_resultado;
end
$v127_asignar$;

alter function public.normalizar_persona_v127(text) owner to postgres;
alter function public.sincronizar_personal_diseno_v127() owner to postgres;
alter function public.listar_personal_diseno_v127() owner to postgres;
alter function public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid) owner to postgres;

revoke all on function public.normalizar_persona_v127(text) from public, anon, authenticated;
revoke all on function public.sincronizar_personal_diseno_v127() from public, anon, authenticated;
revoke all on function public.listar_personal_diseno_v127() from public, anon;
revoke all on function public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid) from public, anon;
grant execute on function public.listar_personal_diseno_v127() to authenticated;
grant execute on function public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
