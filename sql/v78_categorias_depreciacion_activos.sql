-- ============================================================
-- BOMAN INVENTARIO - v78: muebles y enseres, computo y tasa de depreciacion
--
-- Faltaba la categoria "muebles y enseres" en los activos, y ademas equipo de
-- computo estaba metido dentro de "equipo", que para efectos tributarios es
-- otra cosa: se deprecian a ritmos muy distintos.
--
-- BASE LEGAL: los porcentajes salen del Reglamento para la Aplicacion de la
-- Ley de Regimen Tributario Interno (RALRTI), Art. 28, numeral 6, literal a),
-- que fija los topes de depreciacion deducible:
--
--   "(I)   Inmuebles (excepto terrenos), naves, aeronaves, barcazas y
--          similares 5% anual.
--    (II)  Instalaciones, maquinarias, equipos y muebles 10% anual.
--    (III) Vehiculos, equipos de transporte y equipo caminero movil 20% anual.
--    (IV)  Equipos de computo y software 33% anual."
--
-- OJO: son TOPES ("no podra superar"), no valores obligatorios. Por eso el
-- porcentaje queda editable por activo y el valor por categoria es solo el
-- punto de partida. La depreciacion en si se calculara despues; aqui solo se
-- deja el dato clasificado.
--
-- Ejecutar despues de v77.
-- ============================================================

begin;

-- Esta migracion toma locks exclusivos (alter table + drop view) sobre objetos
-- que la aplicacion esta leyendo al mismo tiempo. Si se van tomando de a poco,
-- un lector puede quedarse con la vista mientras nosotros tenemos la tabla, y
-- al revés: eso es un deadlock (ocurrio en la primera corrida).
--
-- Se toma el lock mas fuerte PRIMERO y de una sola vez: cualquier lector espera
-- su turno y no hay adquisicion incremental que se pueda cruzar. El
-- lock_timeout evita quedarse colgado si algo mas lo retiene: falla rapido y
-- con mensaje claro, y como todo va en una transaccion, revierte entero.
set local lock_timeout = '15s';
lock table public.activos_mantenimiento in access exclusive mode;

do $$
begin
  if to_regclass('public.activos_mantenimiento') is null then
    raise exception 'Falta v54. Instalalo antes de v78';
  end if;
end $$;

-- ------------------------------------------------------------
-- 1. Categorias nuevas
-- ------------------------------------------------------------
alter table public.activos_mantenimiento
  drop constraint if exists activos_mantenimiento_categoria_check;
alter table public.activos_mantenimiento
  add constraint activos_mantenimiento_categoria_check
  check (categoria in (
    'maquinaria', 'vehiculo', 'equipo', 'equipo_computo', 'herramienta',
    'muebles_enseres', 'infraestructura', 'otro'
  ));

-- ------------------------------------------------------------
-- 2. Tasa de depreciacion anual
-- ------------------------------------------------------------
alter table public.activos_mantenimiento
  add column if not exists porcentaje_depreciacion_anual numeric(5,2)
    check (porcentaje_depreciacion_anual is null
           or (porcentaje_depreciacion_anual > 0 and porcentaje_depreciacion_anual <= 100));

comment on column public.activos_mantenimiento.porcentaje_depreciacion_anual is
  'Tope RALRTI Art. 28 num. 6 lit. a): 5 inmuebles, 10 instalaciones/maquinaria/equipos/muebles, 20 vehiculos, 33 computo y software. Editable porque el reglamento fija un maximo, no un valor unico.';

-- Sugerencia por categoria para los activos que ya existen. Solo rellena los
-- que estan en null: si alguien ya puso una tasa a mano, no se pisa.
create or replace function public.depreciacion_sugerida_v78(p_categoria text)
returns numeric
language sql
immutable
as $fn$
  select case p_categoria
    when 'infraestructura' then 5.00
    when 'maquinaria'      then 10.00
    when 'equipo'          then 10.00
    when 'herramienta'     then 10.00
    when 'muebles_enseres' then 10.00
    when 'vehiculo'        then 20.00
    when 'equipo_computo'  then 33.00
    else null
  end::numeric;
$fn$;

comment on function public.depreciacion_sugerida_v78(text) is
  'Tope anual de depreciacion por categoria segun RALRTI Art. 28 num. 6 lit. a). Devuelve null para "otro": esa categoria se define a mano.';

update public.activos_mantenimiento
set porcentaje_depreciacion_anual = public.depreciacion_sugerida_v78(categoria)
where porcentaje_depreciacion_anual is null
  and public.depreciacion_sugerida_v78(categoria) is not null;

-- ------------------------------------------------------------
-- 3. La vista se recrea porque usa a.* y el conjunto de columnas cambio
-- ------------------------------------------------------------
-- create or replace view no admite cambiar el conjunto de columnas, y al
-- agregar porcentaje_depreciacion_anual el "a.*" trae una mas.
drop view if exists public.vista_activos_mantenimiento_v54;

create view public.vista_activos_mantenimiento_v54
with (security_invoker = true) as
select
  a.*,
  e.codigo as empresa_codigo,
  e.razon_social as empresa,
  al.nombre as almacen,
  p.nombre_completo as responsable,
  case
    when not a.activo or a.estado = 'baja' then 'inactivo'
    when a.proximo_mantenimiento_fecha < (now() at time zone 'America/Guayaquil')::date
      or (a.proxima_lectura_mantenimiento is not null
        and a.lectura_actual >= a.proxima_lectura_mantenimiento) then 'vencido'
    when a.proximo_mantenimiento_fecha <= (now() at time zone 'America/Guayaquil')::date + 30
      or (a.proxima_lectura_mantenimiento is not null
        and a.lectura_actual >= a.proxima_lectura_mantenimiento * 0.9) then 'proximo'
    when a.proximo_mantenimiento_fecha is null
      and a.proxima_lectura_mantenimiento is null then 'sin_plan'
    else 'al_dia'
  end as estado_plan,
  (select count(*)
   from public.ordenes_mantenimiento o
   where o.activo_id = a.id
     and o.estado in ('solicitada', 'programada', 'en_proceso', 'en_espera')
  ) as ordenes_abiertas,
  (select count(*)
   from public.activo_licencias l
   where l.activo_id = a.id and l.estado = 'vigente'
     and l.fecha_vencimiento <= (now() at time zone 'America/Guayaquil')::date + l.dias_aviso
  ) as licencias_por_vencer
from public.activos_mantenimiento a
left join public.empresas e on e.id = a.empresa_id
left join public.almacenes al on al.id = a.almacen_id
left join public.perfiles p on p.id = a.responsable_id;

alter view public.vista_activos_mantenimiento_v54 owner to postgres;
revoke all on public.vista_activos_mantenimiento_v54 from public, anon;
grant select on public.vista_activos_mantenimiento_v54 to authenticated;

-- ------------------------------------------------------------
-- 4. El RPC de guardado tiene que persistir la tasa
-- ------------------------------------------------------------
-- guardar_activo_mantenimiento_v54 es de v54 y no conoce la columna nueva: sin
-- esto el formulario mandaria el porcentaje y se guardaria en null en silencio.
-- Se parchea el texto de la funcion (mismo criterio que v41 y v76) en vez de
-- reescribir sus ~140 lineas, para no arrastrar cambios no relacionados.
do $migra$
declare
  v_oid oid;
  v_def text;
  v_nuevo text;
  -- Los tres anclajes son de UNA sola linea a proposito. Un anclaje que abarque
  -- dos lineas unidas con \n no calza si la funcion se guardo con finales de
  -- linea de Windows (\r\n), que es lo que pasa al pegar el archivo desde el
  -- editor de Supabase: la primera version de v78 fallo exactamente por eso.
  v_col_vieja text := '      fecha_adquisicion, valor_adquisicion, garantia_hasta, tipo_medidor,';
  v_col_nueva text := '      fecha_adquisicion, valor_adquisicion, garantia_hasta, porcentaje_depreciacion_anual, tipo_medidor,';
  v_val_vieja text := '      coalesce(p_datos->>''tipo_medidor'', ''ninguno''),';
  v_val_nueva text := '      nullif(p_datos->>''porcentaje_depreciacion_anual'', '''')::numeric,' || chr(10) ||
                      '      coalesce(p_datos->>''tipo_medidor'', ''ninguno''),';
  v_upd_vieja text := '      garantia_hasta = nullif(p_datos->>''garantia_hasta'', '''')::date,';
  v_upd_nueva text := '      garantia_hasta = nullif(p_datos->>''garantia_hasta'', '''')::date,' || chr(10) ||
                      '      porcentaje_depreciacion_anual = nullif(p_datos->>''porcentaje_depreciacion_anual'', '''')::numeric,';
begin
  select p.oid into v_oid
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'guardar_activo_mantenimiento_v54'
  order by p.oid desc limit 1;
  if v_oid is null then
    raise exception 'No existe guardar_activo_mantenimiento_v54; instala v54 antes de v78';
  end if;

  v_def := pg_catalog.pg_get_functiondef(v_oid);
  -- Si la funcion se instalo pegando el archivo desde Windows, el cuerpo puede
  -- venir con \r\n y ningun anclaje calzaria. Se normaliza antes de comparar;
  -- la funcion se vuelve a crear con finales de linea Unix, que es indistinto.
  v_def := replace(v_def, chr(13) || chr(10), chr(10));

  if position('porcentaje_depreciacion_anual' in v_def) > 0 then
    raise notice 'v78 ya habia parcheado guardar_activo_mantenimiento_v54';
  else
    if position(v_col_vieja in v_def) = 0
       or position(v_val_vieja in v_def) = 0
       or position(v_upd_vieja in v_def) = 0 then
      raise exception
        'v78: no se pudo agregar la tasa de depreciacion a guardar_activo_mantenimiento_v54. Anclajes encontrados -> columnas:% valores:% update:%. El que salga 0 es el que cambio de forma.',
        position(v_col_vieja in v_def), position(v_val_vieja in v_def),
        position(v_upd_vieja in v_def);
    end if;
    v_nuevo := replace(v_def, v_col_vieja, v_col_nueva);
    v_nuevo := replace(v_nuevo, v_val_vieja, v_val_nueva);
    v_nuevo := replace(v_nuevo, v_upd_vieja, v_upd_nueva);
    execute v_nuevo;
  end if;
end;
$migra$;

alter function public.depreciacion_sugerida_v78(text) owner to postgres;
revoke execute on function public.depreciacion_sugerida_v78(text) from public, anon;
grant execute on function public.depreciacion_sugerida_v78(text) to authenticated;

commit;

notify pgrst, 'reload schema';
