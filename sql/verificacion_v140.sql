-- v140 debe quedar registrada y ningún contrato con adicionales heredados
-- puede continuar vacío en la tabla normalizada.
select exists (
  select 1 from public.schema_migrations_boman where id = 'v140'
) as migracion_v140_registrada;

select count(*) as adicionales_legacy_aun_vacios_debe_ser_cero
from public.bomansport_contratos b
join public.contratos c on c.numero = b.numero
where (
    c.adicionales is null
    or c.adicionales in ('{}'::jsonb, 'null'::jsonb, '""'::jsonb, '"{}"'::jsonb)
    or (
      jsonb_typeof(c.adicionales) = 'object'
      and coalesce(c.adicionales -> 'items', '[]'::jsonb) = '[]'::jsonb
      and btrim(coalesce(c.adicionales ->> 'detalle', '')) = ''
      and btrim(coalesce(c.adicionales ->> 'medidas_bandera', '')) = ''
    )
  )
  and exists (
    select 1
    from (values
      (b.datos -> 'adicionales'),
      (b.datos -> 'Adicionales'),
      (b.datos #> '{extra,adicionales}'),
      (b.datos #> '{extra,Adicionales}')
    ) as candidato(valor)
    where candidato.valor is not null
      and candidato.valor not in (
        '{}'::jsonb, '""'::jsonb, 'null'::jsonb,
        '"{}"'::jsonb, '"null"'::jsonb
      )
  );

select numero, adicionales
from public.contratos
where numero = 'BOM-2026-1142';
