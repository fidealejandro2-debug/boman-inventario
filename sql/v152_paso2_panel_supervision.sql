-- ============================================================
-- BOMAN INVENTARIO - v152 paso 2
-- Rol Supervisor y panel diario consolidado de Caja por local.
-- Ejecutar despues de v152_paso1_rol_supervisor.sql.
-- ============================================================

begin;
select pg_advisory_xact_lock(1522026);

do $$
begin
  if not exists (
    select 1 from pg_enum e
    join pg_type t on t.oid=e.enumtypid
    where t.typname='rol_usuario' and e.enumlabel='supervisor'
  ) then
    raise exception 'Ejecuta primero v152_paso1_rol_supervisor.sql';
  end if;
  if to_regclass('public.franquicia_caja_movimientos') is null
     or to_regclass('public.franquicia_caja_cierres') is null
     or to_regclass('public.caja_depositos_v87') is null
     or to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Faltan Caja unificada, depositos v87 o el registro de migraciones';
  end if;
end $$;

insert into public.permisos_sistema as p(
  codigo,modulo,nombre,descripcion,orden,es_boman_especifico
) values (
  'supervision.acceder','Supervision','Panel de supervision',
  'Consulta cierres, ingresos, egresos, diferencias y depositos de todos los locales.',
  6,false
)
on conflict(codigo) do update set
  modulo=excluded.modulo,nombre=excluded.nombre,descripcion=excluded.descripcion,
  orden=excluded.orden,activo=true,es_boman_especifico=false,updated_at=now();

-- Completa la matriz para el rol nuevo y para el permiso nuevo.
insert into public.rol_permisos(rol,permiso_codigo,permitido)
select 'supervisor'::public.rol_usuario,p.codigo,false
from public.permisos_sistema p where p.activo
on conflict(rol,permiso_codigo) do nothing;

insert into public.rol_permisos(rol,permiso_codigo,permitido)
select r.rol,p.codigo,false
from unnest(enum_range(null::public.rol_usuario)) r(rol)
cross join public.permisos_sistema p
where r.rol::text<>'admin' and p.codigo='supervision.acceder'
on conflict(rol,permiso_codigo) do nothing;

-- Supervisor recibe solo lectura. El ultimo permiso se activa si v150 ya
-- existe; si todavia no se instalo, este UPDATE simplemente no encuentra fila.
update public.rol_permisos set permitido=true,updated_at=now()
where rol::text='supervisor' and permiso_codigo in (
  'supervision.acceder','reportes.acceder','inventario.acceder',
  'franquicia.consolidado','notificaciones.acceder',
  'franquicia.comprobantes.auditar_todo'
);

create or replace function public.panel_supervision_v152(
  p_desde date default current_date - 6,
  p_hasta date default current_date,
  p_almacen_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $fn$
declare
  v_desde date:=coalesce(p_desde,current_date-6);
  v_hasta date:=coalesce(p_hasta,current_date);
  v_resultado jsonb;
begin
  if auth.uid() is null or not public.usuario_tiene_permiso_v35('supervision.acceder') then
    raise exception 'No tienes permiso para consultar el panel de supervision';
  end if;
  if v_desde>v_hasta then raise exception 'La fecha inicial no puede superar la final'; end if;
  if v_hasta>current_date then raise exception 'No se pueden supervisar fechas futuras'; end if;
  if v_hasta-v_desde>92 then raise exception 'El periodo maximo es de 93 dias'; end if;

  with locales as (
    select a.id,a.codigo,a.nombre,
      case when f.id is null then 'Tienda propia' else 'Franquicia' end as clase
    from public.almacenes a
    left join public.franquicias f on f.almacen_id=a.id and f.activo
    where a.activo and a.tipo='tienda'
      and (p_almacen_id is null or a.id=p_almacen_id)
  ), dias as (
    select d::date as fecha from generate_series(v_desde,v_hasta,interval '1 day') d
  ), movimientos as (
    select m.almacen_id,m.fecha,
      round(coalesce(sum(m.monto) filter(where m.tipo='ingreso'),0),2) ingresos,
      round(coalesce(sum(m.monto) filter(where m.tipo='egreso'),0),2) egresos,
      round(coalesce(sum(m.monto) filter(where m.tipo='ingreso' and m.medio_pago='efectivo'),0),2) efectivo,
      round(coalesce(sum(m.monto) filter(where m.tipo='ingreso' and m.medio_pago='transferencia'),0),2) transferencias,
      round(coalesce(sum(m.monto) filter(where m.tipo='ingreso' and m.medio_pago='tarjeta'),0),2) tarjetas,
      count(*) filter(where m.tipo='ingreso')::integer operaciones_ingreso,
      count(*) filter(where m.tipo='egreso')::integer operaciones_egreso,
      max(m.created_at) ultimo_registro,
      (array_agg(m.creado_por order by m.created_at desc))[1] ultimo_usuario_id
    from public.franquicia_caja_movimientos m
    where m.estado='vigente' and m.fecha between v_desde and v_hasta
      and (p_almacen_id is null or m.almacen_id=p_almacen_id)
    group by m.almacen_id,m.fecha
  ), depositos as (
    select d.cierre_id,
      round(coalesce(sum(d.monto) filter(where d.estado<>'anulado'),0),2) depositado,
      count(*) filter(where d.estado='registrado')::integer pendientes,
      count(*) filter(where d.estado='confirmado')::integer confirmados
    from public.caja_depositos_v87 d
    group by d.cierre_id
  ), detalle as (
    select l.id almacen_id,l.codigo,l.nombre,l.clase,di.fecha,
      c.id cierre_id,c.estado cierre_estado,c.cerrado_at,c.nota cierre_nota,
      pc.nombre_completo cierre_responsable,
      coalesce(m.ingresos,0)::numeric ingresos,
      coalesce(m.egresos,0)::numeric egresos,
      (coalesce(m.ingresos,0)-coalesce(m.egresos,0))::numeric resultado,
      coalesce(m.efectivo,0)::numeric efectivo,
      coalesce(m.transferencias,0)::numeric transferencias,
      coalesce(m.tarjetas,0)::numeric tarjetas,
      coalesce(m.operaciones_ingreso,0) operaciones_ingreso,
      coalesce(m.operaciones_egreso,0) operaciones_egreso,
      m.ultimo_registro,pm.nombre_completo ultimo_responsable,
      c.saldo_inicial_efectivo,c.saldo_esperado_efectivo,c.efectivo_contado,c.diferencia,
      coalesce(dp.depositado,0)::numeric depositado,
      coalesce(dp.pendientes,0) depositos_pendientes,
      coalesce(dp.confirmados,0) depositos_confirmados,
      case
        when c.estado='reabierto' then 'reabierto'
        when c.estado='cerrado' and abs(c.diferencia)>0.01 then 'descuadre'
        when c.estado='cerrado' then 'cerrado'
        when coalesce(m.operaciones_ingreso,0)+coalesce(m.operaciones_egreso,0)>0
          and di.fecha=current_date then 'abierto_hoy'
        when coalesce(m.operaciones_ingreso,0)+coalesce(m.operaciones_egreso,0)>0 then 'pendiente'
        else 'sin_actividad'
      end estado_supervision
    from locales l cross join dias di
    left join movimientos m on m.almacen_id=l.id and m.fecha=di.fecha
    left join public.franquicia_caja_cierres c on c.almacen_id=l.id and c.fecha=di.fecha
    left join public.perfiles pc on pc.id=c.cerrado_por
    left join public.perfiles pm on pm.id=m.ultimo_usuario_id
    left join depositos dp on dp.cierre_id=c.id
  ), resumen as (
    select count(distinct almacen_id)::integer locales,
      count(*) filter(where estado_supervision<>'sin_actividad')::integer jornadas,
      round(coalesce(sum(ingresos),0),2) ingresos,
      round(coalesce(sum(egresos),0),2) egresos,
      round(coalesce(sum(resultado),0),2) resultado,
      round(coalesce(sum(efectivo),0),2) efectivo,
      round(coalesce(sum(transferencias),0),2) transferencias,
      round(coalesce(sum(tarjetas),0),2) tarjetas,
      count(*) filter(where estado_supervision='cerrado')::integer cierres_cuadrados,
      count(*) filter(where estado_supervision='pendiente')::integer cierres_pendientes,
      count(*) filter(where estado_supervision='abierto_hoy')::integer abiertos_hoy,
      count(*) filter(where estado_supervision='descuadre')::integer descuadres,
      count(*) filter(where estado_supervision='reabierto')::integer reabiertos,
      round(coalesce(sum(abs(diferencia)) filter(where estado_supervision='descuadre'),0),2) diferencia_absoluta,
      round(coalesce(sum(depositado),0),2) depositado,
      coalesce(sum(depositos_pendientes),0)::integer depositos_pendientes
    from detalle
  )
  select jsonb_build_object(
    'desde',v_desde,'hasta',v_hasta,'generado_en',now(),
    'resumen',to_jsonb(r),
    'locales',coalesce((select jsonb_agg(x order by x->>'nombre') from (
      select jsonb_build_object('id',id,'codigo',codigo,'nombre',nombre,'clase',clase) x
      from locales
    ) q),'[]'::jsonb),
    'filas',coalesce((select jsonb_agg(to_jsonb(d) order by d.fecha desc,d.nombre) from detalle d),'[]'::jsonb)
  ) into v_resultado from resumen r;

  return v_resultado;
end;
$fn$;

comment on function public.panel_supervision_v152(date,date,uuid) is
  'Resumen diario de Caja para supervision: todos los locales, cierres, diferencias, medios de pago y depositos.';
revoke all on function public.panel_supervision_v152(date,date,uuid) from public,anon;
grant execute on function public.panel_supervision_v152(date,date,uuid) to authenticated;
alter function public.panel_supervision_v152(date,date,uuid) owner to postgres;

insert into public.schema_migrations_boman(id,version,archivo,notas)
values('v152','152','v152_paso2_panel_supervision.sql',
  'Rol Supervisor y panel diario consolidado de Caja por local')
on conflict(id) do update set version=excluded.version,archivo=excluded.archivo,
  notas=excluded.notas,aplicada_at=now();

commit;
notify pgrst,'reload schema';
