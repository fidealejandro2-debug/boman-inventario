-- ============================================================
-- v140 - Recuperar adicionales ubicados en extra.Adicionales
-- Ejecutar despues de v139 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v140', 0));

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta v134: no existe el registro formal de migraciones';
  end if;
  if to_regclass('public.contratos') is null
     or to_regclass('public.bomansport_contratos') is null then
    raise exception 'Faltan v79/v90: no existen las fuentes de contratos';
  end if;
end;
$requisitos$;

-- AppScript conserva el encabezado original de Sheets dentro de `extra`, por
-- lo que el campo real de muchos contratos es `extra.Adicionales`. v139 solo
-- revisaba la raíz y no alcanzó esas filas.
with origen as (
  select b.numero, encontrado.valor as adicionales
  from public.bomansport_contratos b
  left join lateral (
    select candidato.valor
    from (values
      (1, b.datos -> 'adicionales'),
      (2, b.datos -> 'Adicionales'),
      (3, b.datos #> '{extra,adicionales}'),
      (4, b.datos #> '{extra,Adicionales}')
    ) as candidato(prioridad, valor)
    where candidato.valor is not null
      and candidato.valor not in (
        '{}'::jsonb, '""'::jsonb, 'null'::jsonb,
        '"{}"'::jsonb, '"null"'::jsonb
      )
    order by candidato.prioridad
    limit 1
  ) encontrado on true
), recuperables as (
  select numero, adicionales
  from origen
  where adicionales is not null
    and adicionales not in ('{}'::jsonb, '""'::jsonb, 'null'::jsonb)
)
update public.contratos c
set adicionales = r.adicionales,
    updated_at = now()
from recuperables r
where c.numero = r.numero
  and (
    c.adicionales is null
    or c.adicionales in ('{}'::jsonb, 'null'::jsonb, '""'::jsonb, '"{}"'::jsonb)
    or (
      jsonb_typeof(c.adicionales) = 'object'
      and coalesce(c.adicionales -> 'items', '[]'::jsonb) = '[]'::jsonb
      and btrim(coalesce(c.adicionales ->> 'detalle', '')) = ''
      and btrim(coalesce(c.adicionales ->> 'medidas_bandera', '')) = ''
    )
  );

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v140', 140, 'v140_recuperar_adicionales_extra_appscript.sql',
  'Recupera adicionales guardados por AppScript en datos.extra.Adicionales.'
)
on conflict (id) do nothing;

notify pgrst, 'reload schema';
commit;
