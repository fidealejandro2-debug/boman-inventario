-- ============================================================
-- BOMAN INVENTARIO - v103: cierre controlado de BomanSport
-- Diagnostico, checklist, cambio de fuente principal y auditoria.
-- No elimina datos ni secretos automaticamente.
-- Ejecutar despues de v102 (es compatible si v102 aun no esta instalada,
-- pero el diagnostico impedira cerrar mientras falte paridad).
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.bomansport_contratos') is null
     or to_regclass('public.bomansport_importaciones') is null
     or to_regclass('public.contratos') is null then
    raise exception 'Faltan v79 o v90 antes de v103';
  end if;
end $$;

create table if not exists public.bomansport_cierre_migracion_v103 (
  id boolean primary key default true check (id),
  modo text not null default 'paralelo' check (modo in (
    'paralelo', 'supabase_principal', 'cerrado'
  )),
  checklist jsonb not null default jsonb_build_object(
    'respaldo_confirmado', false,
    'paridad_confirmada', false,
    'usuarios_validados', false,
    'operacion_capacitada', false,
    'apps_script_solo_lectura', false
  ) check (jsonb_typeof(checklist) = 'object'),
  supabase_principal_desde timestamptz,
  cerrado_at timestamptz,
  actualizado_por uuid references public.perfiles(id) on delete restrict,
  updated_at timestamptz not null default now()
);

insert into public.bomansport_cierre_migracion_v103(id)
values(true) on conflict(id) do nothing;

create table if not exists public.bomansport_cierre_eventos_v103 (
  id uuid primary key default gen_random_uuid(),
  modo_anterior text not null,
  modo_nuevo text not null,
  checklist_anterior jsonb not null,
  checklist_nuevo jsonb not null,
  diagnostico jsonb not null,
  motivo text not null check(length(btrim(motivo))>=10),
  usuario_id uuid not null references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  resultado jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.bomansport_cierre_migracion_v103 enable row level security;
alter table public.bomansport_cierre_eventos_v103 enable row level security;
drop policy if exists "admin_lee_cierre_bomansport_v103" on public.bomansport_cierre_migracion_v103;
create policy "admin_lee_cierre_bomansport_v103" on public.bomansport_cierre_migracion_v103
for select to authenticated using(public.rol_usuario_actual()='admin');
drop policy if exists "admin_lee_eventos_cierre_bomansport_v103" on public.bomansport_cierre_eventos_v103;
create policy "admin_lee_eventos_cierre_bomansport_v103" on public.bomansport_cierre_eventos_v103
for select to authenticated using(public.rol_usuario_actual()='admin');
revoke all on public.bomansport_cierre_migracion_v103 from public,anon,authenticated;
revoke all on public.bomansport_cierre_eventos_v103 from public,anon,authenticated;
grant select on public.bomansport_cierre_migracion_v103 to authenticated;
grant select on public.bomansport_cierre_eventos_v103 to authenticated;

create or replace function public.diagnostico_cierre_bomansport_v103()
returns jsonb language plpgsql stable security definer set search_path=''
as $fn$
declare v_resultado jsonb;
begin
  if auth.uid() is null or public.rol_usuario_actual()<>'admin' then
    raise exception 'Solo un administrador puede revisar el cierre';
  end if;
  with ultima as (
    select * from public.bomansport_importaciones order by iniciado_en desc limit 1
  ), metricas as (
    select
      (select count(*) from public.bomansport_contratos)::integer legacy_total,
      (select count(*) from public.contratos)::integer normalizados_total,
      (select count(*) from public.bomansport_contratos b join public.contratos c on c.numero=b.numero)::integer coincidentes,
      (select count(*) from public.bomansport_contratos b left join public.contratos c on c.numero=b.numero where c.id is null)::integer legacy_sin_normalizar,
      (select count(*) from public.contratos c where btrim(coalesce(c.cliente,''))='' or c.total_prendas<0 or c.presupuesto<0)::integer contratos_invalidos,
      (select count(*) from public.contratos c where lower(c.estado)<>'entregado' and c.fecha_entrega is null)::integer activos_sin_entrega
  )
  select jsonb_build_object(
    'configuracion',(select to_jsonb(x) from public.bomansport_cierre_migracion_v103 x where id),
    'metricas',to_jsonb(m),
    'ultima_importacion',coalesce((select jsonb_build_object('id',u.id,'estado',u.estado,'iniciado_en',u.iniciado_en,'finalizado_en',u.finalizado_en,'total_filas_origen',u.total_filas_origen,'con_error',u.con_error,'mensaje_error',u.mensaje_error) from ultima u),'null'::jsonb),
    'controles',jsonb_build_array(
      jsonb_build_object('codigo','importacion_exitosa','nombre','Ultima sincronizacion terminada sin errores','ok',coalesce((select estado='ok' and con_error=0 from ultima),false),'bloqueante',true),
      jsonb_build_object('codigo','paridad_contratos','nombre','Todos los contratos heredados existen en Supabase','ok',m.legacy_total>0 and m.legacy_sin_normalizar=0,'bloqueante',true,'detalle',m.legacy_sin_normalizar||' pendiente(s)'),
      jsonb_build_object('codigo','datos_criticos','nombre','Contratos sin errores estructurales','ok',m.contratos_invalidos=0,'bloqueante',true,'detalle',m.contratos_invalidos||' invalido(s)'),
      jsonb_build_object('codigo','fechas_operativas','nombre','Contratos activos con fecha de entrega','ok',m.activos_sin_entrega=0,'bloqueante',false,'detalle',m.activos_sin_entrega||' sin fecha')
    ),
    'bloqueos',
      (case when coalesce((select estado='ok' and con_error=0 from ultima),false) then 0 else 1 end)
      +(case when m.legacy_total>0 and m.legacy_sin_normalizar=0 then 0 else 1 end)
      +(case when m.contratos_invalidos=0 then 0 else 1 end)
  ) into v_resultado from metricas m;
  return v_resultado;
end;
$fn$;

create or replace function public.admin_cambiar_cierre_bomansport_v103(
  p_modo text, p_checklist jsonb, p_motivo text, p_idempotency_key uuid
) returns jsonb language plpgsql volatile security definer set search_path=''
as $fn$
declare
  v_uid uuid:=auth.uid(); v_actual public.bomansport_cierre_migracion_v103%rowtype;
  v_diag jsonb; v_resultado jsonb; v_clave text;
  v_claves text[]:=array['respaldo_confirmado','paridad_confirmada','usuarios_validados','operacion_capacitada','apps_script_solo_lectura'];
begin
  if v_uid is null or public.rol_usuario_actual()<>'admin' then raise exception 'Solo un administrador puede cerrar la migracion'; end if;
  if p_modo not in ('paralelo','supabase_principal','cerrado') then raise exception 'El modo no es valido'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo,'')))<10 then raise exception 'El motivo debe tener al menos 10 caracteres'; end if;
  if jsonb_typeof(coalesce(p_checklist,'null'::jsonb))<>'object' then raise exception 'El checklist no es valido'; end if;
  foreach v_clave in array v_claves loop
    if not p_checklist ? v_clave or jsonb_typeof(p_checklist->v_clave)<>'boolean' then
      raise exception 'Falta confirmar correctamente %',v_clave;
    end if;
  end loop;
  if exists(select 1 from jsonb_object_keys(p_checklist) k(clave) where not(clave=any(v_claves))) then raise exception 'El checklist contiene campos desconocidos'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,103));
  select resultado into v_resultado from public.bomansport_cierre_eventos_v103 where idempotency_key=p_idempotency_key;
  if found then return v_resultado; end if;
  select * into v_actual from public.bomansport_cierre_migracion_v103 where id for update;
  v_diag:=public.diagnostico_cierre_bomansport_v103();
  if p_modo in ('supabase_principal','cerrado') and exists(select 1 from unnest(v_claves) k(clave) where coalesce((p_checklist->>clave)::boolean,false)=false) then
    raise exception 'Confirma todo el checklist antes de cambiar la fuente principal';
  end if;
  if p_modo in ('supabase_principal','cerrado') and (v_diag->>'bloqueos')::integer>0 then
    raise exception 'El diagnostico tiene % bloqueo(s). Corrigelos antes del cierre',v_diag->>'bloqueos';
  end if;
  if p_modo='cerrado' and v_actual.modo<>'supabase_principal' then
    raise exception 'Primero opera en modo Supabase principal; no se puede cerrar directamente';
  end if;
  update public.bomansport_cierre_migracion_v103 set
    modo=p_modo,checklist=p_checklist,actualizado_por=v_uid,updated_at=now(),
    supabase_principal_desde=case when p_modo='supabase_principal' then coalesce(supabase_principal_desde,now()) when p_modo='paralelo' then null else supabase_principal_desde end,
    cerrado_at=case when p_modo='cerrado' then now() else null end
  where id;
  v_resultado:=jsonb_build_object('modo',p_modo,'updated_at',now(),'diagnostico',v_diag);
  insert into public.bomansport_cierre_eventos_v103(modo_anterior,modo_nuevo,checklist_anterior,checklist_nuevo,diagnostico,motivo,usuario_id,idempotency_key,resultado)
  values(v_actual.modo,p_modo,v_actual.checklist,p_checklist,v_diag,btrim(p_motivo),v_uid,p_idempotency_key,v_resultado);
  return v_resultado;
end;
$fn$;

alter table public.bomansport_cierre_migracion_v103 owner to postgres;
alter table public.bomansport_cierre_eventos_v103 owner to postgres;
alter function public.diagnostico_cierre_bomansport_v103() owner to postgres;
alter function public.admin_cambiar_cierre_bomansport_v103(text,jsonb,text,uuid) owner to postgres;
revoke all on function public.diagnostico_cierre_bomansport_v103() from public,anon;
revoke all on function public.admin_cambiar_cierre_bomansport_v103(text,jsonb,text,uuid) from public,anon;
grant execute on function public.diagnostico_cierre_bomansport_v103() to authenticated;
grant execute on function public.admin_cambiar_cierre_bomansport_v103(text,jsonb,text,uuid) to authenticated;

comment on table public.bomansport_cierre_migracion_v103 is
  'Interruptor auditable del legado BomanSport. paralelo permite importar; supabase_principal y cerrado bloquean nuevas importaciones heredadas.';

commit;
notify pgrst,'reload schema';
