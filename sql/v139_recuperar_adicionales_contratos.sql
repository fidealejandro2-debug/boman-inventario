-- ============================================================
-- v139 - Recuperar adicionales de contratos migrados
-- Ejecutar despues de v138 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v139', 0));

do $requisitos$
begin
  if to_regclass('public.schema_migrations_boman') is null then
    raise exception 'Falta v134: no existe el registro formal de migraciones';
  end if;
  if to_regclass('public.contratos') is null
     or to_regclass('public.bomansport_contratos') is null then
    raise exception 'Faltan v79/v90: no existen las fuentes de contratos para recuperar adicionales';
  end if;
end;
$requisitos$;

-- En bomansport_contratos.datos el AppScript guardó `adicionales` como un
-- string JSON. Esta función tolera filas vacías o dañadas para que una sola no
-- interrumpa la recuperación del resto.
create or replace function public.jsonb_seguro_v139(p_valor jsonb)
returns jsonb
language plpgsql immutable
set search_path = ''
as $v139$
begin
  if p_valor is null then return '{}'::jsonb; end if;
  if jsonb_typeof(p_valor) = 'object' then return p_valor; end if;
  if jsonb_typeof(p_valor) = 'string' then
    begin
      return (p_valor #>> '{}')::jsonb;
    exception when others then
      return '{}'::jsonb;
    end;
  end if;
  return '{}'::jsonb;
end;
$v139$;

with origen as (
  select b.numero, public.jsonb_seguro_v139(b.datos -> 'adicionales') as adicionales
  from public.bomansport_contratos b
), recuperables as (
  select numero, adicionales
  from origen
  where jsonb_typeof(adicionales) = 'object' and adicionales <> '{}'::jsonb
)
update public.contratos c
set adicionales = r.adicionales,
    updated_at = now()
from recuperables r
where c.numero = r.numero
  and coalesce(c.adicionales, '{}'::jsonb) = '{}'::jsonb;

drop function public.jsonb_seguro_v139(jsonb);

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v139', 139, 'v139_recuperar_adicionales_contratos.sql',
  'Recupera medias, polainas, banderas, bolsos y otros adicionales omitidos al migrar desde AppScript.'
)
on conflict (id) do nothing;

notify pgrst, 'reload schema';
commit;
