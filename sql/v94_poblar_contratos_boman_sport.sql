-- ============================================================
-- BOMAN INVENTARIO - v94: poblar el esquema de contratos (v79) desde
-- BomanSport
--
-- v79 creo el esquema normalizado (contratos, contrato_prendas, etc.) pero
-- nunca tuvo "el importador aparte" que su propio comentario menciona. v95
-- (dashboard), v97 (expedientes) y v99 (gestion) ya se construyeron encima
-- de ese esquema y hoy muestran cero datos en produccion porque nadie lo
-- llena. Este archivo es SOLO el log de esa carga: la transformacion en si
-- (bomansport_contratos + ?api=produccion -> contratos/contrato_prendas/...)
-- vive en Next.js (lib/bomansportProduccion.ts), igual que v90 no puso
-- logica de sincronizacion en SQL.
--
-- Ejecutar despues de v79 y v90.
-- ============================================================

begin;

do $requisitos$
begin
  if to_regclass('public.contratos') is null
     or to_regclass('public.contrato_prendas') is null
     or to_regclass('public.contrato_etapas') is null then
    raise exception 'Falta instalar v79 antes de v94';
  end if;
  if to_regclass('public.bomansport_contratos') is null then
    raise exception 'Falta instalar v90 antes de v94';
  end if;
end;
$requisitos$;

create table if not exists public.bomansport_produccion_importaciones (
  id uuid primary key default gen_random_uuid(),
  origen text not null check (origen in ('cron', 'manual')),
  ejecutado_por uuid references public.perfiles(id) on delete restrict,
  estado text not null default 'en_curso' check (estado in ('en_curso', 'ok', 'error')),
  mensaje_error text,
  contratos_procesados integer not null default 0,
  etapas_nuevas integer not null default 0,
  eventos_nuevos integer not null default 0,
  con_error integer not null default 0,
  errores jsonb not null default '[]'::jsonb,
  -- Ultima fila de la hoja Trazabilidad ya incorporada: la siguiente corrida
  -- la reenvia a ?api=produccion como desdeFilaTraza para no releer una hoja
  -- que "crece sin limite" (mismo criterio que Codigo.gs).
  ultima_fila_trazabilidad bigint not null default 0,
  duracion_ms integer,
  iniciado_en timestamptz not null default now(),
  finalizado_en timestamptz,
  check ((origen = 'manual') = (ejecutado_por is not null))
);

create index if not exists idx_bomansport_produccion_importaciones_iniciado
  on public.bomansport_produccion_importaciones(iniciado_en desc);

alter table public.bomansport_produccion_importaciones enable row level security;

drop policy if exists "admin_lee_bomansport_produccion_importaciones" on public.bomansport_produccion_importaciones;
create policy "admin_lee_bomansport_produccion_importaciones" on public.bomansport_produccion_importaciones
for select to authenticated using (public.rol_usuario_actual() = 'admin');

alter table public.bomansport_produccion_importaciones owner to postgres;
revoke all on public.bomansport_produccion_importaciones from public, anon;
revoke insert, update, delete on public.bomansport_produccion_importaciones from authenticated;
grant select on public.bomansport_produccion_importaciones to authenticated;

comment on table public.bomansport_produccion_importaciones is
  'Log de cada corrida que transforma bomansport_contratos + ?api=produccion (Asignaciones/Observaciones/Maquila/Trazabilidad) hacia el esquema de v79 (contratos, contrato_prendas, contrato_etapas, etc.).';

commit;

notify pgrst, 'reload schema';
