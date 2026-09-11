-- ============================================================
-- BOMAN INVENTARIO - v133: cheques sin factura, con control de cuales regularizar
--
-- El caso real: se le paga a un proveedor que no emite factura. v104 ya
-- separaba el cheque del comprobante -registrar_cheque_v104 no pide factura ni
-- proveedor- pero ninguna pantalla llamaba a esa funcion, asi que en la
-- practica un cheque solo podia nacer colgado de una cuenta por pagar, y esas
-- SI exigen comprobante (cuentas_por_pagar.comprobante_id es not null).
--
-- Lo que faltaba en la base es distinguir dos cosas que no son iguales:
--
--   * un cheque que va a quedarse sin comprobante a proposito (gasto no
--     deducible asumido), y
--   * un cheque que espera una liquidacion de compra que todavia no se emite.
--
-- Sin esa distincion, los dos se ven igual y el segundo se olvida. Por eso el
-- estado es explicito y obligatorio al registrar: quien firma el cheque decide
-- en ese momento, no despues.
--
-- Ejecutar despues de v104.
-- ============================================================
begin;
select pg_advisory_xact_lock(1331142026);

do $$begin
  if to_regclass('public.tesoreria_instrumentos_pago') is null
     or to_regprocedure('public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid)') is null then
    raise exception 'Falta v104_instrumentos_tesoreria_migracion.sql antes de v133';
  end if;
end$$;

-- 'no_aplica'    = no lleva comprobante y no se espera ninguno.
-- 'pendiente'    = falta la liquidacion de compra (o la factura) por emitir.
-- 'regularizado' = ya tiene su comprobante enlazado.
--
-- Por defecto 'no_aplica' para que las filas historicas -las que vinieron de la
-- importacion de Excel y las que nacen de una cuenta por pagar, que ya tiene su
-- comprobante- no aparezcan de golpe como deuda documental que nadie contrajo.
alter table public.tesoreria_instrumentos_pago
  add column if not exists comprobante_estado text not null default 'no_aplica'
    check (comprobante_estado in ('no_aplica','pendiente','regularizado'));
alter table public.tesoreria_instrumentos_pago
  add column if not exists comprobante_id uuid
    references public.comprobantes_compra(id) on delete restrict;

-- Un instrumento regularizado sin comprobante enlazado seria mentira.
do $$begin
  begin
    alter table public.tesoreria_instrumentos_pago
      add constraint tesoreria_instrumento_comprobante_v133
      check (comprobante_estado <> 'regularizado' or comprobante_id is not null);
  exception when duplicate_object then null;
  end;
end$$;

create index if not exists idx_instrumentos_comprobante_pendiente_v133
  on public.tesoreria_instrumentos_pago(grupo_id, fecha_compromiso)
  where comprobante_estado = 'pendiente';

-- ------------------------------------------------------------
-- Registrar el cheque
-- ------------------------------------------------------------

-- OJO CON LA FIRMA: no se puede agregar el parametro con un create or replace.
-- Una funcion con parametro por defecto responde TAMBIEN a la llamada con los
-- argumentos viejos, asi que convivirian dos candidatas y Postgres rechazaria
-- la llamada por ambigua. Se borra la version anterior primero; es seguro
-- porque ninguna pantalla la llamaba todavia.
drop function if exists public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid);

create or replace function public.registrar_cheque_v104(
  p_cuenta_bancaria_id uuid,p_proveedor_id uuid,p_beneficiario text,
  p_numero_cheque text,p_monto numeric,p_fecha_emision date,
  p_fecha_compromiso date,p_estado text,p_nota text,p_idempotency_key uuid,
  p_comprobante_estado text default 'no_aplica'
) returns uuid language plpgsql security definer set search_path=''
as $v133$
declare v_uid uuid:=auth.uid(); v_cb public.tesoreria_cuentas_bancarias%rowtype; v_id uuid;
  v_comp text:=coalesce(nullif(btrim(p_comprobante_estado),''),'no_aplica');
begin
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  select id into v_id from public.tesoreria_instrumentos_pago where idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  select * into v_cb from public.tesoreria_cuentas_bancarias where id=p_cuenta_bancaria_id and activa;
  if not found then raise exception 'La cuenta bancaria no existe o esta inactiva'; end if;
  if not public.usuario_puede_tesoreria_v73(v_cb.grupo_id,true) then raise exception 'No tienes permiso para registrar cheques'; end if;
  if p_proveedor_id is not null and not exists(select 1 from public.proveedores where id=p_proveedor_id and grupo_id=v_cb.grupo_id) then raise exception 'El proveedor no pertenece al grupo'; end if;
  if length(btrim(coalesce(p_beneficiario,'')))<2 then raise exception 'Indica el beneficiario'; end if;
  if length(btrim(coalesce(p_numero_cheque,'')))<1 then raise exception 'Indica el numero de cheque'; end if;
  if p_monto is null or p_monto<=0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_fecha_compromiso is null then raise exception 'Indica la fecha prevista de debito'; end if;
  if p_fecha_emision is not null and p_fecha_compromiso<p_fecha_emision then raise exception 'La fecha prevista no puede ser anterior a la emision'; end if;
  if p_estado not in('borrador','programado','emitido','entregado') then raise exception 'El estado inicial no es valido'; end if;
  if length(btrim(coalesce(p_nota,'')))<5 then raise exception 'Indica una referencia de al menos 5 caracteres'; end if;
  -- v133: nace sin comprobante, asi que 'regularizado' no es un estado inicial
  -- posible. Se llega a el por regularizar_cheque_v133, con el documento en la mano.
  if v_comp not in('no_aplica','pendiente') then
    raise exception 'Al registrar, el comprobante solo puede quedar como "no_aplica" o "pendiente"';
  end if;

  insert into public.tesoreria_instrumentos_pago(grupo_id,cuenta_bancaria_id,empresa_pagadora_id,proveedor_id,beneficiario,medio,numero_instrumento,monto,fecha_emision,fecha_compromiso,estado,origen,nota,comprobante_estado,creado_por,actualizado_por,idempotency_key)
  values(v_cb.grupo_id,v_cb.id,v_cb.empresa_titular_id,p_proveedor_id,btrim(p_beneficiario),'cheque',btrim(p_numero_cheque),round(p_monto,2),p_fecha_emision,p_fecha_compromiso,p_estado,'manual',btrim(p_nota),v_comp,v_uid,v_uid,p_idempotency_key) returning id into v_id;
  insert into public.tesoreria_instrumento_eventos(grupo_id,instrumento_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_cb.grupo_id,v_id,'creado',btrim(p_nota),jsonb_build_object('estado',p_estado,'monto',round(p_monto,2),'fecha_compromiso',p_fecha_compromiso,'comprobante_estado',v_comp),v_uid,gen_random_uuid());
  return v_id;
end;$v133$;

-- ------------------------------------------------------------
-- Regularizar: enlazar el comprobante cuando se emite
-- ------------------------------------------------------------
create or replace function public.regularizar_cheque_v133(
  p_instrumento_id uuid, p_comprobante_id uuid, p_motivo text, p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path=''
as $v133$
declare v_uid uuid:=auth.uid(); v_i public.tesoreria_instrumentos_pago%rowtype;
  v_c public.comprobantes_compra%rowtype;
begin
  if v_uid is null then raise exception 'Debes iniciar sesion'; end if;
  if p_idempotency_key is null then raise exception 'La idempotencia es obligatoria'; end if;
  if length(btrim(coalesce(p_motivo,'')))<5 then raise exception 'Indica una referencia de al menos 5 caracteres'; end if;
  if exists(select 1 from public.tesoreria_instrumento_eventos where idempotency_key=p_idempotency_key) then
    return jsonb_build_object('ok',true,'duplicado',true);
  end if;

  select * into v_i from public.tesoreria_instrumentos_pago where id=p_instrumento_id for update;
  if not found then raise exception 'El instrumento no existe'; end if;
  if not public.usuario_puede_tesoreria_v73(v_i.grupo_id,true) then raise exception 'No tienes permiso para regularizar cheques'; end if;

  select * into v_c from public.comprobantes_compra where id=p_comprobante_id;
  if not found then raise exception 'El comprobante no existe'; end if;
  -- El comprobante tiene que ser del mismo proveedor al que se le pago; si no,
  -- se estaria justificando un pago con el documento de otro.
  if v_i.proveedor_id is not null and v_c.proveedor_id <> v_i.proveedor_id then
    raise exception 'Ese comprobante es de otro proveedor';
  end if;

  update public.tesoreria_instrumentos_pago
     set comprobante_id=p_comprobante_id, comprobante_estado='regularizado',
         actualizado_por=v_uid, updated_at=now()
   where id=p_instrumento_id;

  insert into public.tesoreria_instrumento_eventos(grupo_id,instrumento_id,tipo,detalle,datos,usuario_id,idempotency_key)
  values(v_i.grupo_id,p_instrumento_id,'comprobante_regularizado',btrim(p_motivo),
         jsonb_build_object('comprobante_id',p_comprobante_id,'numero',v_c.numero_documento,'tipo',v_c.tipo),
         v_uid,p_idempotency_key);
  return jsonb_build_object('ok',true,'duplicado',false,'numero',v_c.numero_documento);
end;$v133$;

-- La vista agrega las columnas nuevas. Copia de v104 con eso mas.
create or replace view public.vista_instrumentos_tesoreria_v104
with(security_invoker = true) as
select i.id, i.grupo_id, i.cuenta_bancaria_id,
  cb.alias as cuenta_alias, cb.banco, cb.numero_cuenta,
  i.empresa_pagadora_id, e.codigo as empresa_pagadora_codigo,
  e.razon_social as empresa_pagadora, i.proveedor_id,
  coalesce(p.razon_social,i.beneficiario) as beneficiario,
  i.medio, i.numero_instrumento, i.monto, i.fecha_emision,
  i.fecha_compromiso, i.fecha_efectiva, i.estado, i.origen,
  coalesce(a.monto_aplicado,0)::numeric(16,2) as monto_aplicado,
  greatest(i.monto-coalesce(a.monto_aplicado,0),0)::numeric(16,2) as monto_sin_asignar,
  i.pago_v73_id, i.importacion_linea_id, i.reemplaza_instrumento_id,
  i.nota, i.created_at, i.updated_at,
  -- Las tres nuevas van AL FINAL y no junto a lo que se parece. No es estetica:
  -- create or replace view solo admite AGREGAR columnas al final. Ponerlas en
  -- medio significa renombrar las que venian despues, y Postgres lo rechaza con
  -- "cannot change name of view column". Borrar la vista tampoco vale:
  -- vista_resumen_compromisos_v104 depende de esta.
  i.comprobante_estado, i.comprobante_id, c.numero_documento as comprobante_numero
from public.tesoreria_instrumentos_pago i
left join public.tesoreria_cuentas_bancarias cb on cb.id=i.cuenta_bancaria_id
join public.empresas e on e.id=i.empresa_pagadora_id
left join public.proveedores p on p.id=i.proveedor_id
left join public.comprobantes_compra c on c.id=i.comprobante_id
left join lateral(
  select sum(x.monto) monto_aplicado
  from public.tesoreria_instrumento_aplicaciones x where x.instrumento_id=i.id
) a on true;

alter function public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid,text) owner to postgres;
alter function public.regularizar_cheque_v133(uuid,uuid,text,uuid) owner to postgres;
revoke all on function public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid,text) from public, anon;
revoke all on function public.regularizar_cheque_v133(uuid,uuid,text,uuid) from public, anon;
grant execute on function public.registrar_cheque_v104(uuid,uuid,text,text,numeric,date,date,text,text,uuid,text) to authenticated;
grant execute on function public.regularizar_cheque_v133(uuid,uuid,text,uuid) to authenticated;

comment on column public.tesoreria_instrumentos_pago.comprobante_estado is
  'no_aplica = gasto sin comprobante asumido · pendiente = espera liquidacion de compra o factura · regularizado = ya tiene comprobante enlazado.';

commit;
