-- ============================================================
-- BOMAN INVENTARIO - v110: cupo de produccion por dia
--
-- El formulario legado (BomanSport/index.html + Codigo.gs) no deja cerrar un
-- contrato sin comprobar cuanta carga ya tiene el dia de inicio de produccion:
--   CAPACIDAD_DIARIA = {total:900, Normal:600, Equipo Profesional:100,
--                       Mercadería:150, Emergente:50}
-- y verificarCapacidadDia_ suma las prendas de los contratos de ese dia. El
-- ingreso nativo en Vercel mostraba esos numeros como texto decorativo, sin
-- comprobar nada: se podia cargar el taller muy por encima del cupo.
--
-- Se resuelve con una RPC de solo lectura que devuelve el uso agregado del dia.
-- Es security definer a proposito: quien puede CREAR un contrato
-- (contratos.editar) debe poder ver el cupo aunque no tenga permiso para leer
-- el detalle de los contratos ajenos (contratos.acceder). Solo devuelve
-- totales, nunca filas de contrato.
--
-- Ejecutar despues de v79.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regprocedure('public.usuario_tiene_permiso_v35(text)') is null then
    raise exception 'Faltan v79 o v35. Instalalas antes de v110';
  end if;
end;
$requisitos$;

create or replace function public.capacidad_dia_produccion_v110(
  p_fecha date,
  p_excluir_contrato uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_resultado jsonb;
begin
  if auth.uid() is null
     or not (public.usuario_tiene_permiso_v35('contratos.editar')
             or public.usuario_tiene_permiso_v35('contratos.acceder')) then
    raise exception 'No tienes permiso para consultar el cupo de produccion';
  end if;
  if p_fecha is null then
    raise exception 'Indica la fecha de inicio de produccion';
  end if;

  -- Los topes viven aqui y no en el cliente para que una pantalla nueva no
  -- pueda "inventarse" un cupo distinto al que respeta el taller.
  with topes(tipo, tope) as (
    values ('Normal', 600), ('Equipo Profesional', 100),
           ('Mercadería', 150), ('Emergente', 50)
  ),
  uso as (
    select c.tipo_contrato as tipo, coalesce(sum(c.total_prendas), 0)::integer as prendas
    from public.contratos c
    where c.fecha_inicio_produccion = p_fecha
      and (p_excluir_contrato is null or c.id <> p_excluir_contrato)
      and lower(c.estado) <> 'entregado'
    group by c.tipo_contrato
  )
  select jsonb_build_object(
    'fecha', p_fecha,
    'tope_total', 900,
    'usado_total', coalesce((select sum(prendas) from uso), 0),
    'por_tipo', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', t.tipo,
        'tope', t.tope,
        'usado', coalesce(u.prendas, 0)
      ) order by t.tipo)
      from topes t left join uso u on u.tipo = t.tipo
    ), '[]'::jsonb)
  ) into v_resultado;

  return v_resultado;
end;
$fn$;

alter function public.capacidad_dia_produccion_v110(date, uuid) owner to postgres;
revoke all on function public.capacidad_dia_produccion_v110(date, uuid) from public, anon;
grant execute on function public.capacidad_dia_produccion_v110(date, uuid) to authenticated;

comment on function public.capacidad_dia_produccion_v110(date, uuid) is
  'Cupo de produccion de un dia: tope y prendas ya comprometidas, total y por tipo de contrato. Replica verificarCapacidadDia_ del sistema legado.';

commit;

notify pgrst, 'reload schema';
