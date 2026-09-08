-- ============================================================
-- BOMAN INVENTARIO - v102: sincronizacion definitiva BomanSport
-- Supabase sirve el tablero operativo, conserva la procedencia de cada
-- contrato y protege las finanzas ya gestionadas en Vercel.
-- Ejecutar despues de v100. v94 puede instalarse antes o despues.
-- ============================================================
begin;
do $$ begin
 if to_regclass('public.contratos') is null or to_regclass('public.bomansport_contratos') is null
 or to_regclass('public.contrato_etapas') is null or to_regclass('public.contrato_archivos') is null
 or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='contratos' and column_name='finanzas_gestionadas_v100') then
  raise exception 'Faltan v79, v90 o v100 antes de v102';
 end if;
end $$;

alter table public.contratos add column if not exists fuente_v102 text not null default 'supabase'
 check(fuente_v102 in('bomansport','supabase'));
alter table public.contratos add column if not exists origen_hash_v102 text;
alter table public.contratos add column if not exists sincronizado_at_v102 timestamptz;
create index if not exists idx_contratos_fuente_v102 on public.contratos(fuente_v102,sincronizado_at_v102 desc);

update public.contratos c set fuente_v102='bomansport',origen_hash_v102=b.fila_hash,
 sincronizado_at_v102=b.ultima_sincronizacion_en
from public.bomansport_contratos b where b.numero=c.numero;

-- Si la replica heredada cambia, conserva la marca de procedencia en el
-- contrato normalizado. La carga profunda de prendas/etapas sigue en v94.
create or replace function public.marcar_origen_bomansport_v102()
returns trigger language plpgsql security definer set search_path='' as $fn$
begin
 update public.contratos set fuente_v102='bomansport',origen_hash_v102=new.fila_hash,
 sincronizado_at_v102=new.ultima_sincronizacion_en where numero=new.numero;
 return new;
end;$fn$;
drop trigger if exists trg_marcar_origen_bomansport_v102 on public.bomansport_contratos;
create trigger trg_marcar_origen_bomansport_v102 after insert or update of fila_hash,ultima_sincronizacion_en
on public.bomansport_contratos for each row execute function public.marcar_origen_bomansport_v102();

-- La importacion profunda crea primero la replica y luego el contrato. Este
-- segundo trigger cubre ese orden y evita que una alta nueva quede marcada
-- por error como nativa de Supabase.
create or replace function public.resolver_origen_contrato_v102()
returns trigger language plpgsql security definer set search_path='' as $fn$
declare v_hash text;v_fecha timestamptz;
begin
 select b.fila_hash,b.ultima_sincronizacion_en into v_hash,v_fecha
 from public.bomansport_contratos b where b.numero=new.numero;
 if found then
  new.fuente_v102:='bomansport';new.origen_hash_v102:=v_hash;
  new.sincronizado_at_v102:=v_fecha;
 end if;
 return new;
end;$fn$;
drop trigger if exists trg_resolver_origen_contrato_v102 on public.contratos;
create trigger trg_resolver_origen_contrato_v102 before insert or update
on public.contratos for each row execute function public.resolver_origen_contrato_v102();

-- Un upsert heredado puede actualizar datos operativos, pero no puede pisar
-- presupuesto/abonos una vez que Vercel registro el primer movimiento.
create or replace function public.proteger_finanzas_contrato_v102()
returns trigger language plpgsql set search_path='' as $fn$
begin
 if old.finanzas_gestionadas_v100
 and coalesce(current_setting('boman.finanzas_v100',true),'')<>'autorizado' then
  new.presupuesto:=old.presupuesto;new.abono:=old.abono;
  new.abono_inicial_v100:=old.abono_inicial_v100;
  new.finanzas_gestionadas_v100:=true;
 end if;
 return new;
end;$fn$;
drop trigger if exists trg_proteger_finanzas_contrato_v102 on public.contratos;
create trigger trg_proteger_finanzas_contrato_v102 before update of presupuesto,abono,abono_inicial_v100
on public.contratos for each row execute function public.proteger_finanzas_contrato_v102();

-- Tablero leido exclusivamente desde Supabase. Mantiene el contrato JSON que
-- ya consume TableroCliente para que el cambio de fuente sea transparente.
create or replace function public.tablero_produccion_v102()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_resultado jsonb;
begin
 if auth.uid() is null or not public.usuario_tiene_permiso_v35('produccion.acceder') then raise exception 'No tienes permiso para consultar produccion';end if;
 with etapas(orden,nombre,etiqueta,emoji,bg,fg) as(values
 (1,'Ingresado','Ingresado','📥','#BDD7EE','#1F4E78'),(2,'Por imprimir','Por imprimir','🖨️','#FFE599','#7A5C00'),
 (3,'Impreso','Impreso','📄','#FFD966','#7A4F00'),(4,'Sublimación','Sublimado','🎨','#EA9999','#7B1E1E'),
 (5,'Cortado','Cortado','✂️','#F9CB9C','#783F04'),(6,'En costura o maquila','Costura','🧵','#D9D2E9','#4A1870'),
 (7,'Estampado','Estampado','🏷️','#C9DAF8','#1C4587'),(8,'Terminado','Terminado','✅','#A4C2F4','#1E3A8A'),
 (9,'Estampado final','Estampado final','🔖','#EAD1DC','#741B47'),(10,'Pendiente entrega','Por entregar','📦','#B6D7A8','#1A4731'),
 (11,'Entregado','Entregado','🚚','#E2EFDA','#365F23')
 ), activos as materialized(select c.*,case c.estado when'Ingresado'then 1 when'Por imprimir'then 2 when'Impreso'then 3 when'Sublimación'then 4 when'Cortado'then 5 when'En costura o maquila'then 6 when'Estampado'then 7 when'Terminado'then 8 when'Estampado final'then 9 when'Pendiente entrega'then 10 when'Entregado'then 11 else 0 end rango from public.contratos c where lower(c.estado)<>'entregado'),
 etapas_json as(select jsonb_agg(jsonb_build_object('nombre',e.nombre,'etiqueta',e.etiqueta,'emoji',e.emoji,'bg',e.bg,'fg',e.fg,'area','','sub','','hechos',(select count(*) from activos a where a.rango>=e.orden or exists(select 1 from public.contrato_etapas ce where ce.contrato_id=a.id and ce.etapa=e.nombre)))order by e.orden) valor from etapas e),
 filas as(select jsonb_build_object('numero',a.numero,'corto',right(a.numero,4),'cliente',a.cliente,'vendedor',a.vendedor,'mks',coalesce((select jsonb_agg(jsonb_build_object('i',ca.drive_id,'d',ca.descripcion)order by ca.orden)from public.contrato_archivos ca where ca.contrato_id=a.id and ca.tipo='mockup' and ca.drive_id is not null),'[]'::jsonb),'prendas',a.total_prendas,'prendasTxt',coalesce(a.prendas_txt,''),'calidad',coalesce((select jsonb_agg(q.calidad order by q.calidad)from(select distinct cp.calidad from public.contrato_prendas cp where cp.contrato_id=a.id and btrim(cp.calidad)<>'')q),'[]'::jsonb),'urgente',lower(a.prioridad)='urgente','atrasado',a.fecha_entrega<(now()at time zone'America/Guayaquil')::date,'esExterior',lower(coalesce(a.prendas_txt,''))~'(chompa|rompeviento)','ingreso',to_char(a.fecha_ingreso at time zone'America/Guayaquil','DD/MM'),'entrega',to_char(a.fecha_entrega,'DD/MM'),'entregaMs',coalesce(extract(epoch from a.fecha_entrega::timestamp)*1000,0),'inicio',to_char(a.fecha_inicio_produccion,'DD/MM'),'disenador',coalesce(a.disenador,''),'autorMockup',coalesce(a.autor_mockup,''),'fabrica',case when lower(coalesce(a.disenador,''))like'%marco%'then 2 else 1 end,'obs',coalesce(a.observacion,''),'maquila',coalesce(a.maquila,''),'marca',coalesce((select ce.operario||' · '||to_char(ce.marcado_en at time zone'America/Guayaquil','DD/MM HH24:MI')from public.contrato_etapas ce where ce.contrato_id=a.id order by ce.marcado_en desc limit 1),''),'muestras',jsonb_build_object('tpu',a.muestras_tpu_faltan,'dtf',a.muestras_dtf_faltan),'hechas',(select jsonb_agg((a.rango>=e.orden or exists(select 1 from public.contrato_etapas ce where ce.contrato_id=a.id and ce.etapa=e.nombre))order by e.orden)from etapas e))fila,a.fecha_entrega,a.numero from activos a)
 select jsonb_build_object('etapas',(select valor from etapas_json),'filas',coalesce((select jsonb_agg(fila order by fecha_entrega nulls last,numero)from filas),'[]'::jsonb),'total',(select count(*)from activos),'hora',to_char(now()at time zone'America/Guayaquil','DD/MM/YYYY HH24:MI'))into v_resultado;
 return v_resultado;
end;$fn$;

create or replace function public.resumen_sincronizacion_v102()
returns jsonb language plpgsql stable security definer set search_path='' as $fn$
declare v_corridas integer:=0;v_resultado jsonb;
begin
 if auth.uid() is null or public.rol_usuario_actual()<>'admin' then raise exception 'Solo un administrador puede revisar la sincronizacion';end if;
 if to_regclass('public.bomansport_produccion_importaciones') is not null then execute 'select count(*) from public.bomansport_produccion_importaciones where estado=''ok''' into v_corridas;end if;
 select jsonb_build_object('legacy',(select count(*)from public.bomansport_contratos),'normalizados',(select count(*)from public.contratos),'coincidentes',(select count(*)from public.bomansport_contratos b join public.contratos c on c.numero=b.numero),'pendientes',(select count(*)from public.bomansport_contratos b left join public.contratos c on c.numero=b.numero where c.id is null),'con_prendas',(select count(distinct contrato_id)from public.contrato_prendas),'con_etapas',(select count(distinct contrato_id)from public.contrato_etapas),'finanzas_protegidas',(select count(*)from public.contratos where finanzas_gestionadas_v100),'corridas_profundas',v_corridas,'ultima_marca',(select max(sincronizado_at_v102)from public.contratos))into v_resultado;
 return v_resultado;
end;$fn$;

alter function public.marcar_origen_bomansport_v102() owner to postgres;alter function public.resolver_origen_contrato_v102() owner to postgres;alter function public.proteger_finanzas_contrato_v102() owner to postgres;alter function public.tablero_produccion_v102() owner to postgres;alter function public.resumen_sincronizacion_v102() owner to postgres;
revoke all on function public.marcar_origen_bomansport_v102() from public,anon,authenticated;revoke all on function public.resolver_origen_contrato_v102() from public,anon,authenticated;revoke all on function public.proteger_finanzas_contrato_v102() from public,anon,authenticated;
revoke all on function public.tablero_produccion_v102() from public,anon;revoke all on function public.resumen_sincronizacion_v102() from public,anon;
grant execute on function public.tablero_produccion_v102() to authenticated;grant execute on function public.resumen_sincronizacion_v102() to authenticated;
commit;notify pgrst,'reload schema';
