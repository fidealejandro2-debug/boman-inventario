-- ============================================================
-- BOMAN INVENTARIO - v90: importacion de contratos BomanSport
--
-- Replica de solo lectura de la hoja "Contratos" de BomanSport (Google
-- Apps Script + Sheets, sistema externo). La hoja sigue siendo la fuente
-- de verdad donde se crean/editan contratos; esto solo trae una copia
-- consultable a Supabase para que otras pantallas del ERP (v92 en
-- adelante) puedan construir sobre ella sin llamar a Apps Script cada vez.
--
-- Deliberadamente SIN funciones de escritura: el unico escritor es el
-- route handler de Next.js (app/api/bomansport/importar-contratos), que
-- usa el cliente de service role. La autorizacion (secreto de cron o
-- sesion admin) ya se resuelve en Next.js antes de tocar Postgres, asi
-- que no hay logica de negocio que deba vivir protegida en una funcion.
--
-- Ejecutar una sola vez.
-- ============================================================

begin;

create table if not exists public.bomansport_contratos (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique check (numero ~ '^BOM-[0-9]{4}-[0-9]{4,}$'),
  cliente text not null default '',
  vendedor text not null default '',
  vendedor_responsable text not null default '',
  canal text not null default '',
  estado text not null default 'Ingresado',
  prioridad text not null default '',
  calidad text not null default '',
  prendas_incluidas text not null default '',
  total_prendas integer not null default 0 check (total_prendas >= 0),
  presupuesto_usd numeric(12,2) check (presupuesto_usd is null or presupuesto_usd >= 0),
  abono_usd numeric(12,2) check (abono_usd is null or abono_usd >= 0),
  fecha_ingreso date,
  fecha_inicio_produccion date,
  fecha_inicio_produccion_estimada date,
  fecha_salida_produccion date,
  fecha_entrega date,
  fecha_posible_inicio date,
  fecha_posible_entrega date,
  fecha_autorizacion_produccion date,
  tipo_contrato text not null default 'Normal',
  reposicion boolean not null default false,
  email_ingresante text,
  -- Objeto crudo completo tal cual lo devuelve Codigo.gs (?api=contratos):
  -- tallas, jugadores, logos, mockups, datos tecnicos, y cualquier columna
  -- que asegurarColumnasBomanV5_ agregue a futuro y que las columnas
  -- tipadas de arriba todavia no nombren (queda en datos->>'extra').
  datos jsonb not null default '{}'::jsonb,
  fila_hash text not null check (fila_hash ~ '^[0-9a-f]{64}$'),
  primera_importacion_en timestamptz not null default now(),
  ultima_sincronizacion_en timestamptz not null default now(),
  ultimo_cambio_en timestamptz not null default now(),
  ultima_importacion_id uuid
);

create index if not exists idx_bomansport_contratos_estado
  on public.bomansport_contratos(estado);

create table if not exists public.bomansport_importaciones (
  id uuid primary key default gen_random_uuid(),
  origen text not null check (origen in ('cron', 'manual')),
  ejecutado_por uuid references public.perfiles(id) on delete restrict,
  estado text not null default 'en_curso' check (estado in ('en_curso', 'ok', 'error')),
  mensaje_error text,
  total_filas_origen integer not null default 0,
  creados integer not null default 0,
  actualizados integer not null default 0,
  sin_cambio integer not null default 0,
  con_error integer not null default 0,
  errores jsonb not null default '[]'::jsonb,
  duracion_ms integer,
  iniciado_en timestamptz not null default now(),
  finalizado_en timestamptz,
  check ((origen = 'manual') = (ejecutado_por is not null))
);

create index if not exists idx_bomansport_importaciones_iniciado
  on public.bomansport_importaciones(iniciado_en desc);

alter table public.bomansport_contratos
  drop constraint if exists bomansport_contratos_ultima_importacion_fkey;
alter table public.bomansport_contratos
  add constraint bomansport_contratos_ultima_importacion_fkey
  foreign key (ultima_importacion_id) references public.bomansport_importaciones(id);

create table if not exists public.bomansport_contratos_historial (
  id uuid primary key default gen_random_uuid(),
  numero_contrato text not null references public.bomansport_contratos(numero) on delete cascade,
  fila_hash_anterior text,
  fila_hash_nuevo text not null,
  datos_anterior jsonb,
  datos_nuevo jsonb not null,
  importacion_id uuid not null references public.bomansport_importaciones(id) on delete restrict,
  detectado_en timestamptz not null default now()
);

create index if not exists idx_bomansport_historial_numero
  on public.bomansport_contratos_historial(numero_contrato, detectado_en desc);

-- ------------------------------------------------------------
-- RLS: solo lectura para admin. El service role (route handler) no pasa
-- por RLS, asi que no necesita politica de escritura.
-- ------------------------------------------------------------
alter table public.bomansport_contratos enable row level security;
alter table public.bomansport_importaciones enable row level security;
alter table public.bomansport_contratos_historial enable row level security;

drop policy if exists "admin_lee_bomansport_contratos" on public.bomansport_contratos;
create policy "admin_lee_bomansport_contratos" on public.bomansport_contratos
for select to authenticated using (public.rol_usuario_actual() = 'admin');

drop policy if exists "admin_lee_bomansport_importaciones" on public.bomansport_importaciones;
create policy "admin_lee_bomansport_importaciones" on public.bomansport_importaciones
for select to authenticated using (public.rol_usuario_actual() = 'admin');

drop policy if exists "admin_lee_bomansport_historial" on public.bomansport_contratos_historial;
create policy "admin_lee_bomansport_historial" on public.bomansport_contratos_historial
for select to authenticated using (public.rol_usuario_actual() = 'admin');

alter table public.bomansport_contratos owner to postgres;
alter table public.bomansport_importaciones owner to postgres;
alter table public.bomansport_contratos_historial owner to postgres;

revoke all on public.bomansport_contratos from public, anon;
revoke all on public.bomansport_importaciones from public, anon;
revoke all on public.bomansport_contratos_historial from public, anon;
revoke insert, update, delete on public.bomansport_contratos from authenticated;
revoke insert, update, delete on public.bomansport_importaciones from authenticated;
revoke insert, update, delete on public.bomansport_contratos_historial from authenticated;
grant select on public.bomansport_contratos to authenticated;
grant select on public.bomansport_importaciones to authenticated;
grant select on public.bomansport_contratos_historial to authenticated;

comment on table public.bomansport_contratos is
  'Replica de solo lectura de la hoja "Contratos" de BomanSport (Apps Script). La hoja sigue siendo la fuente de verdad; se sincroniza via app/api/bomansport/importar-contratos.';
comment on table public.bomansport_importaciones is
  'Log de cada corrida de sincronizacion (cron diario o boton manual).';
comment on table public.bomansport_contratos_historial is
  'Snapshot antes/despues de cada cambio real detectado (fila_hash distinto) en un contrato ya importado.';

commit;

notify pgrst, 'reload schema';
