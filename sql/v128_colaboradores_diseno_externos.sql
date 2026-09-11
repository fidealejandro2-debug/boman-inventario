-- ============================================================
-- BOMAN INVENTARIO - v128
-- Diseñadores y autores de mockups externos
-- Ejecutar después de v127.
-- ============================================================

begin;
select pg_advisory_xact_lock(12809112026);

do $v128_requisitos$
begin
  if to_regprocedure('public.listar_personal_diseno_v127()') is null
     or to_regprocedure('public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid)') is null then
    raise exception 'Falta instalar v127 antes de v128';
  end if;
end
$v128_requisitos$;

create table if not exists public.colaboradores_diseno_v128 (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (length(btrim(nombre)) >= 3),
  contacto text,
  es_disenador boolean not null default true,
  es_mockup boolean not null default false,
  activo boolean not null default true,
  motivo_alta text not null check (length(btrim(motivo_alta)) >= 10),
  creado_por uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (es_disenador or es_mockup)
);

create unique index if not exists uq_colaborador_diseno_v128_nombre_activo
  on public.colaboradores_diseno_v128(
    public.normalizar_persona_v127(nombre)
  ) where activo;

alter table public.colaboradores_diseno_v128 enable row level security;
revoke all on public.colaboradores_diseno_v128 from public, anon, authenticated;

alter table public.contratos
  add column if not exists disenador_externo_id uuid,
  add column if not exists autor_mockup_externo_id uuid;

do $v128_fks$
begin
  if not exists (select 1 from pg_constraint where conrelid='public.contratos'::regclass and conname='contratos_disenador_externo_v128_fkey') then
    alter table public.contratos add constraint contratos_disenador_externo_v128_fkey
      foreign key (disenador_externo_id) references public.colaboradores_diseno_v128(id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.contratos'::regclass and conname='contratos_autor_mockup_externo_v128_fkey') then
    alter table public.contratos add constraint contratos_autor_mockup_externo_v128_fkey
      foreign key (autor_mockup_externo_id) references public.colaboradores_diseno_v128(id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.contratos'::regclass and conname='contratos_un_origen_disenador_v128_check') then
    alter table public.contratos add constraint contratos_un_origen_disenador_v128_check
      check (num_nonnulls(disenador_empleado_id, disenador_externo_id) <= 1);
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.contratos'::regclass and conname='contratos_un_origen_mockup_v128_check') then
    alter table public.contratos add constraint contratos_un_origen_mockup_v128_check
      check (num_nonnulls(autor_mockup_empleado_id, autor_mockup_externo_id) <= 1);
  end if;
end
$v128_fks$;

create index if not exists idx_contratos_disenador_externo_v128
  on public.contratos(disenador_externo_id) where disenador_externo_id is not null;
create index if not exists idx_contratos_autor_mockup_externo_v128
  on public.contratos(autor_mockup_externo_id) where autor_mockup_externo_id is not null;

create or replace function public.crear_colaborador_diseno_v128(
  p_nombre text,
  p_es_disenador boolean,
  p_es_mockup boolean,
  p_contacto text,
  p_motivo text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $v128_crear$
declare
  v_uid uuid := auth.uid();
  v_fila public.colaboradores_diseno_v128%rowtype;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if not public.usuario_tiene_permiso_v35('contratos.editar') then
    raise exception 'No tienes permiso para registrar colaboradores externos';
  end if;
  if length(btrim(coalesce(p_nombre,''))) < 3 then raise exception 'Escribe el nombre completo'; end if;
  if not coalesce(p_es_disenador,false) and not coalesce(p_es_mockup,false) then
    raise exception 'Selecciona diseño, mockups o ambas funciones';
  end if;
  if length(btrim(coalesce(p_motivo,''))) < 10 then raise exception 'El motivo debe tener al menos 10 caracteres'; end if;
  if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,128));
  select * into v_fila from public.colaboradores_diseno_v128 where idempotency_key=p_idempotency_key;
  if found then
    return jsonb_build_object('id',v_fila.id,'nombre',v_fila.nombre,'cargo','Colaborador externo',
      'departamento',coalesce(v_fila.contacto,''),'disenador',v_fila.es_disenador,
      'mockup',v_fila.es_mockup,'origen','externo');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(public.normalizar_persona_v127(p_nombre),128));
  if exists (select 1 from public.colaboradores_diseno_v128 x where x.activo and public.normalizar_persona_v127(x.nombre)=public.normalizar_persona_v127(p_nombre)) then
    raise exception 'Ya existe un colaborador externo activo con ese nombre';
  end if;

  insert into public.colaboradores_diseno_v128(
    nombre,contacto,es_disenador,es_mockup,motivo_alta,creado_por,idempotency_key
  ) values (
    btrim(p_nombre),nullif(btrim(coalesce(p_contacto,'')),''),coalesce(p_es_disenador,false),
    coalesce(p_es_mockup,false),btrim(p_motivo),v_uid,p_idempotency_key
  ) returning * into v_fila;

  return jsonb_build_object('id',v_fila.id,'nombre',v_fila.nombre,'cargo','Colaborador externo',
    'departamento',coalesce(v_fila.contacto,''),'disenador',v_fila.es_disenador,
    'mockup',v_fila.es_mockup,'origen','externo');
end
$v128_crear$;

create or replace function public.listar_personal_diseno_v127()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $v128_lista$
declare v_resultado jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesion para consultar el personal de diseño'; end if;
  if not (public.usuario_tiene_permiso_v35('contratos.acceder') or public.usuario_tiene_permiso_v35('contratos.editar') or public.usuario_tiene_permiso_v35('produccion.acceder')) then
    raise exception 'No tienes permiso para consultar el personal de diseño';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.origen desc,x.nombre),'[]'::jsonb) into v_resultado
  from (
    select e.id,concat_ws(' ',nullif(btrim(e.nombres),''),nullif(btrim(e.apellidos),'')) nombre,
      e.cargo,coalesce(d.nombre,e.area,'') departamento,
      public.normalizar_persona_v127(concat_ws(' ',e.cargo,e.area,d.nombre))~'(disen|design|arte|graf)' disenador,
      public.normalizar_persona_v127(concat_ws(' ',e.cargo,e.area,d.nombre))~'(mockup|disen|design|arte|graf)' mockup,
      'nomina'::text origen
    from public.empleados e left join public.departamentos_nomina d on d.id=e.departamento_id
    where e.estado='activo' and e.fecha_salida is null
    union all
    select c.id,c.nombre,'Colaborador externo',coalesce(c.contacto,''),c.es_disenador,c.es_mockup,'externo'::text
    from public.colaboradores_diseno_v128 c where c.activo
  ) x;
  return v_resultado;
end
$v128_lista$;

create or replace function public.sincronizar_personal_diseno_v127()
returns trigger language plpgsql set search_path='' as $v128_sync$
declare v_nombre text;
begin
  if new.disenador_empleado_id is not null and new.disenador_externo_id is not null then raise exception 'El diseñador no puede ser interno y externo a la vez'; end if;
  if new.autor_mockup_empleado_id is not null and new.autor_mockup_externo_id is not null then raise exception 'El autor del mockup no puede ser interno y externo a la vez'; end if;
  if new.disenador_empleado_id is distinct from old.disenador_empleado_id or new.disenador_externo_id is distinct from old.disenador_externo_id then
    if new.disenador_empleado_id is not null then select concat_ws(' ',e.nombres,e.apellidos) into strict v_nombre from public.empleados e where e.id=new.disenador_empleado_id;
    elsif new.disenador_externo_id is not null then select c.nombre into strict v_nombre from public.colaboradores_diseno_v128 c where c.id=new.disenador_externo_id;
    else v_nombre:=null; end if;
    new.disenador:=v_nombre;
  elsif new.disenador is distinct from old.disenador and (new.disenador_empleado_id is not null or new.disenador_externo_id is not null) then
    new.disenador_empleado_id:=null;new.disenador_externo_id:=null;
  end if;
  if new.autor_mockup_empleado_id is distinct from old.autor_mockup_empleado_id or new.autor_mockup_externo_id is distinct from old.autor_mockup_externo_id then
    if new.autor_mockup_empleado_id is not null then select concat_ws(' ',e.nombres,e.apellidos) into strict v_nombre from public.empleados e where e.id=new.autor_mockup_empleado_id;
    elsif new.autor_mockup_externo_id is not null then select c.nombre into strict v_nombre from public.colaboradores_diseno_v128 c where c.id=new.autor_mockup_externo_id;
    else v_nombre:=null; end if;
    new.autor_mockup:=v_nombre;
  elsif new.autor_mockup is distinct from old.autor_mockup and (new.autor_mockup_empleado_id is not null or new.autor_mockup_externo_id is not null) then
    new.autor_mockup_empleado_id:=null;new.autor_mockup_externo_id:=null;
  end if;
  return new;
end
$v128_sync$;

drop trigger if exists trg_sincronizar_personal_diseno_v127 on public.contratos;
create trigger trg_sincronizar_personal_diseno_v127 before update of disenador,disenador_empleado_id,disenador_externo_id,autor_mockup,autor_mockup_empleado_id,autor_mockup_externo_id on public.contratos for each row execute function public.sincronizar_personal_diseno_v127();

create or replace function public.asignar_personal_diseno_v127(p_contrato_id uuid,p_tipo text,p_empleado_id uuid,p_motivo text,p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path='' as $v128_asignar$
declare
 v_uid uuid:=auth.uid();v_contrato public.contratos%rowtype;v_nombre text;v_origen text;
 v_empleado_id uuid;v_externo_id uuid;v_anterior text;v_anterior_empleado uuid;v_anterior_externo uuid;
 v_operacion_id uuid;v_resultado jsonb;v_quien text;v_solicitados jsonb;v_aplicados jsonb;
begin
 if v_uid is null then raise exception 'Debes iniciar sesion para asignar personal';end if;
 if not public.usuario_tiene_permiso_v35('contratos.editar')then raise exception 'No tienes permiso para asignar responsables de diseño';end if;
 if p_contrato_id is null then raise exception 'Selecciona un contrato';end if;
 if p_tipo not in('disenador','mockup')then raise exception 'El tipo de responsable no es valido';end if;
 if p_idempotency_key is null then raise exception 'La clave de idempotencia es obligatoria';end if;
 if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'El motivo debe tener al menos 10 caracteres';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,128));
 select resultado into v_resultado from public.contrato_gestion_operaciones_v99 where idempotency_key=p_idempotency_key;
 if found then return v_resultado;end if;
 select * into v_contrato from public.contratos where id=p_contrato_id for update;
 if not found then raise exception 'El contrato no existe';end if;
 if p_empleado_id is not null then
  select concat_ws(' ',nullif(btrim(e.nombres),''),nullif(btrim(e.apellidos),'')),e.id into v_nombre,v_empleado_id from public.empleados e where e.id=p_empleado_id and e.estado='activo' and e.fecha_salida is null;
  if not found then
   select c.nombre,c.id into v_nombre,v_externo_id from public.colaboradores_diseno_v128 c where c.id=p_empleado_id and c.activo and case when p_tipo='disenador' then c.es_disenador else c.es_mockup end;
   if not found then raise exception 'La persona no existe, no esta activa o no cumple esa funcion';end if;
   v_origen:='externo';
  else v_origen:='nomina';end if;
 end if;
 if p_tipo='disenador' then v_anterior:=v_contrato.disenador;v_anterior_empleado:=v_contrato.disenador_empleado_id;v_anterior_externo:=v_contrato.disenador_externo_id;
 else v_anterior:=v_contrato.autor_mockup;v_anterior_empleado:=v_contrato.autor_mockup_empleado_id;v_anterior_externo:=v_contrato.autor_mockup_externo_id;end if;
 if v_anterior_empleado is not distinct from v_empleado_id and v_anterior_externo is not distinct from v_externo_id and v_anterior is not distinct from v_nombre then raise exception 'La persona seleccionada ya es la responsable';end if;
 v_solicitados:=jsonb_build_object('tipo',p_tipo,'persona_id',p_empleado_id,'origen',v_origen);
 v_aplicados:=v_solicitados||jsonb_build_object(case when p_tipo='disenador' then 'disenador' else 'autor_mockup' end,v_nombre);
 insert into public.contrato_gestion_operaciones_v99(contrato_id,cambios_solicitados,cambios_aplicados,motivo,usuario_id,idempotency_key) values(p_contrato_id,v_solicitados,v_aplicados,btrim(p_motivo),v_uid,p_idempotency_key) returning id into v_operacion_id;
 if p_tipo='disenador' then update public.contratos set disenador_empleado_id=v_empleado_id,disenador_externo_id=v_externo_id,disenador=v_nombre,actualizado_por=v_uid where id=p_contrato_id;
 else update public.contratos set autor_mockup_empleado_id=v_empleado_id,autor_mockup_externo_id=v_externo_id,autor_mockup=v_nombre,actualizado_por=v_uid where id=p_contrato_id;end if;
 select coalesce(p.nombre_completo,v_uid::text) into v_quien from public.perfiles p where p.id=v_uid;
 insert into public.contrato_eventos(contrato_id,campo,valor_anterior,valor_nuevo,quien,perfil_id,gestion_operacion_id,motivo_gestion_v99) values(p_contrato_id,case when p_tipo='disenador' then 'disenador' else 'autor_mockup' end,v_anterior,v_nombre,coalesce(v_quien,v_uid::text),v_uid,v_operacion_id,btrim(p_motivo));
 v_resultado:=jsonb_build_object('duplicado',false,'operacion_id',v_operacion_id,'contrato_id',p_contrato_id,'tipo',p_tipo,'persona_id',p_empleado_id,'origen',v_origen,'nombre',v_nombre);
 update public.contrato_gestion_operaciones_v99 set resultado=v_resultado where id=v_operacion_id;
 return v_resultado;
end
$v128_asignar$;

alter function public.crear_colaborador_diseno_v128(text,boolean,boolean,text,text,uuid) owner to postgres;
alter function public.listar_personal_diseno_v127() owner to postgres;
alter function public.sincronizar_personal_diseno_v127() owner to postgres;
alter function public.asignar_personal_diseno_v127(uuid,text,uuid,text,uuid) owner to postgres;
revoke all on function public.crear_colaborador_diseno_v128(text,boolean,boolean,text,text,uuid) from public,anon;
grant execute on function public.crear_colaborador_diseno_v128(text,boolean,boolean,text,text,uuid) to authenticated;

commit;
notify pgrst,'reload schema';
