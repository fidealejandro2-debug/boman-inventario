-- ============================================================
-- v157 - Corrige permisos faltantes en venta_rapida_v148 y afines.
--
-- Bug real de v148: "revoke all ... from public, anon, authenticated"
-- (sql/v148_venta_rapida_tienda.sql:549-551) le quito el SELECT a
-- 'authenticated' sobre venta_rapida_v148 / _lineas / _pagos, y nunca se lo
-- devolvio con un "grant select" -solo se otorgo EXECUTE sobre las RPCs,
-- no el privilegio base sobre las tablas. Una politica RLS de solo lectura
-- no alcanza sin ese privilegio: Postgres rechaza con "permission denied
-- for table venta_rapida_v148" antes de evaluar la politica.
--
-- venta_comprobantes_pendientes_v148 se deja SIN grant a proposito (nunca
-- se lee directo; solo la tocan las funciones security definer).
--
-- Ejecutar despues de v148 y sin migraciones en paralelo.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v157', 0));

do $requisitos$
begin
  if to_regclass('public.venta_rapida_v148') is null
     or to_regclass('public.venta_rapida_lineas_v148') is null
     or to_regclass('public.venta_rapida_pagos_v148') is null then
    raise exception 'Falta v148: instala primero la venta rapida de tienda propia';
  end if;
end;
$requisitos$;

grant select on public.venta_rapida_v148,
  public.venta_rapida_lineas_v148,
  public.venta_rapida_pagos_v148
  to authenticated;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v157', 157, 'v157_fix_grants_venta_rapida.sql',
  'Corrige v148: authenticated se quedo sin SELECT (revoke all sin grant de vuelta) en venta_rapida_v148/_lineas/_pagos.'
)
on conflict (id) do update set version=excluded.version, archivo=excluded.archivo,
  notas=excluded.notas, aplicada_at=now();

notify pgrst, 'reload schema';
commit;
