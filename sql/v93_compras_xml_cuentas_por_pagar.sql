-- ============================================================
-- BOMAN INVENTARIO - v93
-- Integracion Compras XML -> Cuentas por pagar
--
-- Registra en una sola transaccion el comprobante homologado y su obligacion,
-- dejando definidos la compania pagadora y el vencimiento antes de cerrar el
-- XML. La relacion queda trazable y no puede duplicarse por reintentos.
-- Ejecutar despues de v92 y antes de verificacion_v93.sql.
-- ============================================================

begin;

do $$
begin
  if to_regprocedure('public.procesar_compra_xml_v65(uuid,text,text,uuid)') is null
     or to_regclass('public.cuentas_por_pagar') is null
     or to_regclass('public.tesoreria_configuracion') is null then
    raise exception 'Faltan v65 o v73. Instalalas antes de v93';
  end if;
end $$;

create table if not exists public.compras_xml_cuentas_pagar_v93 (
  importacion_id uuid primary key
    references public.compras_xml_importaciones(id) on delete restrict,
  grupo_id uuid not null references public.grupos_economicos(id) on delete restrict,
  comprobante_id uuid not null unique
    references public.comprobantes_compra(id) on delete restrict,
  cuenta_id uuid not null unique
    references public.cuentas_por_pagar(id) on delete restrict,
  empresa_pagadora_id_inicial uuid not null
    references public.empresas(id) on delete restrict,
  fecha_vencimiento_inicial date not null,
  origen text not null default 'v93' check (origen in ('v93', 'historico')),
  registrado_por uuid references public.perfiles(id) on delete restrict,
  idempotency_key uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_compras_xml_cxp_pagadora_v93
  on public.compras_xml_cuentas_pagar_v93(
    empresa_pagadora_id_inicial, fecha_vencimiento_inicial
  );

-- Los XML procesados antes de v93 se enlazan sin alterar sus condiciones.
insert into public.compras_xml_cuentas_pagar_v93 (
  importacion_id, grupo_id, comprobante_id, cuenta_id,
  empresa_pagadora_id_inicial, fecha_vencimiento_inicial, origen,
  registrado_por, idempotency_key, created_at
)
select
  i.id, i.grupo_id, i.comprobante_id, c.id,
  c.empresa_pagadora_id, c.fecha_vencimiento, 'historico',
  coalesce(i.procesado_por, i.cargado_por), gen_random_uuid(),
  coalesce(i.procesado_at, i.created_at)
from public.compras_xml_importaciones i
join public.cuentas_por_pagar c on c.comprobante_id = i.comprobante_id
where i.estado = 'procesado' and i.comprobante_id is not null
on conflict (importacion_id) do nothing;

create or replace function public.procesar_compra_xml_cxp_v93(
  p_importacion_id uuid,
  p_sustento_codigo text,
  p_empresa_pagadora_id uuid,
  p_fecha_vencimiento date,
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
  v_import public.compras_xml_importaciones%rowtype;
  v_cuenta public.cuentas_por_pagar%rowtype;
  v_resultado jsonb;
  v_vinculo public.compras_xml_cuentas_pagar_v93%rowtype;
begin
  if v_uid is null then
    raise exception 'Debes iniciar sesion para registrar la compra';
  end if;
  if v_rol not in ('admin', 'control', 'gerencia')
     or not public.usuario_tiene_permiso_v35('compras.acceder') then
    raise exception 'No tienes permiso para registrar compras XML';
  end if;
  if p_idempotency_key is null then
    raise exception 'La clave de idempotencia es obligatoria';
  end if;

  select * into v_vinculo
  from public.compras_xml_cuentas_pagar_v93
  where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'duplicado', true,
      'importacion_id', v_vinculo.importacion_id,
      'comprobante_id', v_vinculo.comprobante_id,
      'cuenta_id', v_vinculo.cuenta_id,
      'empresa_pagadora_id', v_vinculo.empresa_pagadora_id_inicial,
      'fecha_vencimiento', v_vinculo.fecha_vencimiento_inicial
    );
  end if;

  select * into v_import
  from public.compras_xml_importaciones
  where id = p_importacion_id
  for update;
  if not found then raise exception 'La importacion XML no existe'; end if;
  if not public.usuario_puede_compra_xml_v65(v_import.empresa_id, true) then
    raise exception 'No tienes permiso sobre la empresa receptora';
  end if;
  if v_import.estado not in ('listo', 'procesado') then
    raise exception 'Homologa todas las lineas y el proveedor antes de registrar la compra';
  end if;
  if p_empresa_pagadora_id is null or not exists (
    select 1 from public.empresas e
    where e.id = p_empresa_pagadora_id
      and e.grupo_id = v_import.grupo_id and e.activo
  ) then
    raise exception 'Selecciona una compania pagadora activa del mismo grupo economico';
  end if;
  if p_fecha_vencimiento is null or p_fecha_vencimiento < v_import.fecha_emision then
    raise exception 'El vencimiento no puede ser anterior a la fecha de emision';
  end if;
  if length(btrim(coalesce(p_nota, ''))) < 5 then
    raise exception 'Indica una nota de registro de al menos 5 caracteres';
  end if;

  select * into v_vinculo
  from public.compras_xml_cuentas_pagar_v93
  where importacion_id = v_import.id;
  if found then
    return jsonb_build_object(
      'duplicado', true,
      'importacion_id', v_vinculo.importacion_id,
      'comprobante_id', v_vinculo.comprobante_id,
      'cuenta_id', v_vinculo.cuenta_id,
      'empresa_pagadora_id', v_vinculo.empresa_pagadora_id_inicial,
      'fecha_vencimiento', v_vinculo.fecha_vencimiento_inicial
    );
  end if;

  -- v65 registra el libro de compras. El trigger de v73 crea la obligacion
  -- base; inmediatamente se fijan aqui sus condiciones definitivas.
  select public.procesar_compra_xml_v65(
    v_import.id, p_sustento_codigo, btrim(p_nota), p_idempotency_key
  ) into v_resultado;

  select * into v_import
  from public.compras_xml_importaciones where id = v_import.id;
  if v_import.comprobante_id is null then
    raise exception 'El XML no genero el comprobante de compra esperado';
  end if;

  select * into v_cuenta
  from public.cuentas_por_pagar
  where comprobante_id = v_import.comprobante_id
  for update;
  if not found then
    raise exception 'El comprobante se registro, pero no genero su cuenta por pagar';
  end if;
  if exists (
    select 1 from public.cuentas_por_pagar_pagos p
    where p.cuenta_id = v_cuenta.id and p.estado <> 'anulado'
  ) and (
    v_cuenta.empresa_pagadora_id <> p_empresa_pagadora_id
    or v_cuenta.fecha_vencimiento <> p_fecha_vencimiento
  ) then
    raise exception 'La cuenta ya tiene pagos o compromisos y sus condiciones no pueden cambiarse';
  end if;

  update public.cuentas_por_pagar
  set empresa_pagadora_id = p_empresa_pagadora_id,
      fecha_vencimiento = p_fecha_vencimiento,
      nota = 'Generada desde XML ' ||
        v_import.establecimiento || '-' || v_import.punto_emision || '-' || v_import.secuencial ||
        '. ' || btrim(p_nota),
      actualizado_por = v_uid,
      updated_at = now()
  where id = v_cuenta.id
  returning * into v_cuenta;

  insert into public.compras_xml_cuentas_pagar_v93 (
    importacion_id, grupo_id, comprobante_id, cuenta_id,
    empresa_pagadora_id_inicial, fecha_vencimiento_inicial, origen,
    registrado_por, idempotency_key
  ) values (
    v_import.id, v_import.grupo_id, v_import.comprobante_id, v_cuenta.id,
    p_empresa_pagadora_id, p_fecha_vencimiento, 'v93',
    v_uid, p_idempotency_key
  ) returning * into v_vinculo;

  insert into public.cuentas_por_pagar_eventos (
    grupo_id, cuenta_id, tipo, detalle, datos, usuario_id, idempotency_key
  ) values (
    v_import.grupo_id, v_cuenta.id, 'creada_desde_xml',
    'Cuenta generada al registrar la compra XML',
    jsonb_build_object(
      'importacion_id', v_import.id,
      'comprobante_id', v_import.comprobante_id,
      'empresa_pagadora_id', p_empresa_pagadora_id,
      'fecha_vencimiento', p_fecha_vencimiento
    ),
    v_uid, p_idempotency_key
  );

  return coalesce(v_resultado, '{}'::jsonb) || jsonb_build_object(
    'duplicado', false,
    'importacion_id', v_import.id,
    'comprobante_id', v_import.comprobante_id,
    'cuenta_id', v_cuenta.id,
    'empresa_pagadora_id', p_empresa_pagadora_id,
    'fecha_vencimiento', p_fecha_vencimiento
  );
end;
$fn$;

create or replace view public.vista_compras_xml_cxp_v93
with (security_invoker = true) as
select
  x.importacion_id, x.grupo_id, x.comprobante_id, x.cuenta_id,
  i.establecimiento || '-' || i.punto_emision || '-' || i.secuencial
    as numero_documento,
  i.fecha_emision, i.total, i.proveedor_ruc,
  i.proveedor_razon_social,
  i.empresa_id as empresa_receptora_id,
  er.codigo as empresa_receptora_codigo,
  c.empresa_pagadora_id, ep.codigo as empresa_pagadora_codigo,
  ep.razon_social as empresa_pagadora,
  c.fecha_vencimiento,
  x.empresa_pagadora_id_inicial,
  epi.codigo as empresa_pagadora_inicial_codigo,
  x.fecha_vencimiento_inicial,
  c.estado_registro,
  x.origen, x.registrado_por, x.created_at
from public.compras_xml_cuentas_pagar_v93 x
join public.compras_xml_importaciones i on i.id = x.importacion_id
join public.cuentas_por_pagar c on c.id = x.cuenta_id
join public.empresas er on er.id = i.empresa_id
join public.empresas ep on ep.id = c.empresa_pagadora_id
join public.empresas epi on epi.id = x.empresa_pagadora_id_inicial;

alter table public.compras_xml_cuentas_pagar_v93 enable row level security;

drop policy if exists "leer_compras_xml_cxp_v93"
  on public.compras_xml_cuentas_pagar_v93;
create policy "leer_compras_xml_cxp_v93"
on public.compras_xml_cuentas_pagar_v93
for select to authenticated
using (
  public.usuario_puede_tesoreria_v73(grupo_id, false)
  or exists (
    select 1 from public.compras_xml_importaciones i
    where i.id = importacion_id
      and public.usuario_puede_compra_xml_v65(i.empresa_id, false)
  )
);

alter function public.procesar_compra_xml_cxp_v93(
  uuid,text,uuid,date,text,uuid
) owner to postgres;
alter view public.vista_compras_xml_cxp_v93 owner to postgres;

revoke all on public.compras_xml_cuentas_pagar_v93 from public, anon;
revoke insert, update, delete on public.compras_xml_cuentas_pagar_v93
  from authenticated;
grant select on public.compras_xml_cuentas_pagar_v93 to authenticated;

revoke all on public.vista_compras_xml_cxp_v93 from public, anon;
grant select on public.vista_compras_xml_cxp_v93 to authenticated;

revoke all on function public.procesar_compra_xml_cxp_v93(
  uuid,text,uuid,date,text,uuid
) from public, anon;
grant execute on function public.procesar_compra_xml_cxp_v93(
  uuid,text,uuid,date,text,uuid
) to authenticated;

-- Desde v93 la bandeja debe usar la operacion atomica. Se conserva la RPC
-- antigua para compatibilidad interna, pero ya no puede invocarse por API.
revoke execute on function public.procesar_compra_xml_v65(uuid,text,text,uuid)
  from authenticated;

commit;

notify pgrst, 'reload schema';
