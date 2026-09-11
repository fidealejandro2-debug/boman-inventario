-- ============================================================
-- v134 - Registro formal de migraciones Boman
-- Ejecutar despues de v133 y antes de verificacion_v134.sql.
-- A partir de esta version cada migracion debe registrar su propia fila.
-- ============================================================

begin;
select pg_advisory_xact_lock(hashtextextended('boman:v134', 0));

create table if not exists public.schema_migrations_boman (
  id text primary key check (id ~ '^(baseline-)?v[0-9]+([_-][a-z0-9_]+)?$'),
  version integer not null check (version > 0),
  archivo text not null check (btrim(archivo) <> ''),
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9a-f]{64}$'),
  es_baseline boolean not null default false,
  notas text,
  aplicada_at timestamptz not null default now(),
  aplicada_por text not null default current_user
);

create unique index if not exists uq_schema_migrations_archivo_boman
  on public.schema_migrations_boman(archivo)
  where not es_baseline;

alter table public.schema_migrations_boman enable row level security;
alter table public.schema_migrations_boman force row level security;
revoke all on public.schema_migrations_boman from public, anon, authenticated;

-- No se inventan 133 filas históricas: antes de v134 no existía un libro de
-- migraciones. Se deja una línea de base explícita y verificable por los
-- testigos de que_migraciones_faltan.sql.
insert into public.schema_migrations_boman(
  id, version, archivo, es_baseline, notas
) values (
  'baseline-v133', 133, 'baseline_hasta_v133', true,
  'Base histórica anterior al registro formal. Validar sus objetos con que_migraciones_faltan.sql.'
)
on conflict (id) do nothing;

insert into public.schema_migrations_boman(id, version, archivo, notas)
values (
  'v134', 134, 'v134_registro_migraciones.sql',
  'Crea el registro formal e inicia la trazabilidad obligatoria desde v134.'
)
on conflict (id) do nothing;

comment on table public.schema_migrations_boman is
  'Libro inmutable de migraciones aplicadas. Las versiones anteriores a v134 se representan mediante una línea de base.';

commit;
