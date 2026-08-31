-- ============================================================
-- BOMAN INVENTARIO - El rol nomina puede leer las empresas v39
--
-- usuario_puede_empresa se escribio en v18, antes de que existiera el rol
-- 'nomina' (creado en v26). Como nunca se lo agrego, un usuario de nomina no
-- ve NINGUNA empresa, y de ahi salen varios fallos que parecen no tener
-- relacion entre si:
--
--   * el selector de empresa acreedora en Descuentos sale vacio
--   * el alta de personal no puede elegir quien paga
--   * el grupo economico no se resuelve, y con el se quedaba colgado el
--     calendario de feriados
--
-- Se concede solo LECTURA: nomina necesita elegir empresas, no editarlas.
-- La escritura sigue reservada a admin, control y a los perfiles con
-- perfil_empresas.puede_operar.
--
-- Ejecutar una sola vez DESPUES de v38.
-- ============================================================

create or replace function public.usuario_puede_empresa(
  p_empresa_id uuid,
  p_escritura boolean default false
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_empresa_id is not null and exists (
    select 1
    from public.perfiles p
    where p.id = auth.uid() and p.activo
      and (
        p.rol::text in ('admin', 'control')
        -- gerencia y nomina consultan, no editan.
        or (not p_escritura and p.rol::text in ('gerencia', 'nomina'))
        or exists (
          select 1
          from public.perfil_empresas pe
          where pe.perfil_id = p.id
            and pe.empresa_id = p_empresa_id
            and (not p_escritura or pe.puede_operar)
        )
        or exists (
          select 1
          from public.empresa_almacenes ea
          where ea.empresa_id = p_empresa_id
            and public.usuario_puede_almacen(ea.almacen_id, p_escritura)
        )
      )
  );
$$;

alter function public.usuario_puede_empresa(uuid, boolean) owner to postgres;
revoke execute on function public.usuario_puede_empresa(uuid, boolean) from public, anon;
grant execute on function public.usuario_puede_empresa(uuid, boolean) to authenticated;

comment on function public.usuario_puede_empresa(uuid, boolean) is
  'Acceso por empresa. admin y control operan; gerencia y nomina solo consultan; el resto segun perfil_empresas o los almacenes que operan.';

notify pgrst, 'reload schema';
