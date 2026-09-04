-- ============================================================
-- BOMAN INVENTARIO - v79: contratos de produccion (migracion desde Sheets)
--
-- Trae el sistema de contratos de Boman Sport (hoy en Apps Script + una hoja
-- de calculo de 76 columnas) a Postgres. Este archivo es SOLO el esquema: sin
-- RPCs y sin datos. Los RPC de escritura llegan con cada pantalla, y la carga
-- inicial la hace el importador aparte.
--
-- TRES DECISIONES QUE EXPLICAN LA FORMA DE ESTAS TABLAS
--
-- 1. Se descartan ~20 columnas de la hoja. Las columnas 20-42, 62-66 y 68-69
--    (ruedo chompa, puno, basta pantalon, tipo corte, cuellos tecnica, los 8
--    colores sueltos...) son el sistema VIEJO de especificaciones: quedaron
--    superadas por la columna 70 (JSON por prenda) y hoy el brief ya lee de
--    ahi. Migrarlas seria arrastrar campos muertos a una base nueva.
--
-- 2. Las tallas se NORMALIZAN. En la hoja son un JSON anidado
--    {prenda, calidad, adultos:{talla:{H,M}}, ninos:{talla:n}} que obliga a
--    recorrer todos los contratos en memoria para responder "cuantas
--    camisetas M se cortan el martes". Esa pregunta es el reporte de
--    produccion diario, asi que pasa a una fila por prenda-calidad-genero-
--    talla y se responde con un group by.
--
-- 3. Las especificaciones tecnicas se quedan como jsonb. Son un arbol
--    profundo (cuello.botones.cantidad, franjas_adidas.cantidad...) que SOLO
--    se lee entero para pintar el brief; nunca se filtra ni se agrega por un
--    campo suelto. Normalizarlas serian 40 tablas para no ganar una sola
--    consulta.
--
-- Ejecutar despues de v78.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Contrato
-- ------------------------------------------------------------
create table if not exists public.contratos (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique check (btrim(numero) <> ''),

  -- Fechas. fecha_entrega es la comprometida con el cliente; las de
  -- produccion las asigna el taller y pueden estar vacias al ingresar.
  fecha_ingreso timestamptz not null default now(),
  fecha_inicio_produccion date,
  fecha_salida_produccion date,
  fecha_entrega date,

  vendedor text not null default '',
  vendedor_responsable text not null default '',
  canal text,
  cliente text not null default '' check (btrim(cliente) <> ''),
  telefono text,
  whatsapp text,
  email text,

  prioridad text not null default 'Normal' check (prioridad in ('Normal', 'Urgente')),
  -- Define el cupo diario de produccion (v. CAPACIDAD_DIARIA en Apps Script).
  tipo_contrato text not null default 'Normal'
    check (tipo_contrato in ('Normal', 'Equipo Profesional', 'Mercadería', 'Emergente')),
  reposicion boolean not null default false,

  prendas_txt text,
  total_prendas integer not null default 0 check (total_prendas >= 0),
  arqueros integer not null default 0 check (arqueros >= 0),

  -- Etapa actual. El detalle de que area marco que y cuando vive en
  -- contrato_etapas: esta columna es el resumen para listar y colorear.
  estado text not null default 'Ingresado',
  estado_mockup text,
  aprobo_mockup boolean not null default false,
  nombre_aprueba text,
  firma_digital text,

  presupuesto numeric(14,2) not null default 0 check (presupuesto >= 0),
  abono numeric(14,2) not null default 0 check (abono >= 0),
  forma_entrega text,
  direccion text,
  instrucciones text,

  autorizacion_produccion text,
  fecha_autorizacion timestamptz,
  observaciones_lili text,

  -- Tecnicas globales del contrato (nombre y numero del jugador, TPU, bordado).
  nombre_tecnica text,
  numero_tecnica text,
  sellos_tpu text,
  ubicacion_tpu text,
  bordado text,

  -- Bloques que solo se leen enteros.
  colores_generales jsonb not null default '[]'::jsonb,
  adicionales jsonb not null default '{}'::jsonb,

  -- Asignacion. En la hoja son pestanas append-only donde gana la ultima
  -- fila; aqui son el valor vigente y el historial va en contrato_eventos.
  disenador text,
  autor_mockup text,
  observacion text,
  maquila text,
  muestras_tpu_faltan boolean not null default false,
  muestras_dtf_faltan boolean not null default false,

  -- Prioridad manual dentro del dia de produccion (columna 75 de la hoja).
  orden_dia numeric(10,2),

  email_ingresante text,
  creado_por uuid references public.perfiles(id) on delete set null,
  actualizado_por uuid references public.perfiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (abono <= presupuesto or presupuesto = 0),
  check (fecha_entrega is null or fecha_inicio_produccion is null
         or fecha_entrega >= fecha_inicio_produccion)
);

comment on table public.contratos is
  'Contrato de produccion de Boman Sport. Migrado desde la hoja Contratos; se descartaron las columnas 20-42, 62-66 y 68-69 (sistema viejo de especificaciones, reemplazado por contrato_specs).';

create index if not exists idx_contratos_entrega on public.contratos (fecha_entrega);
create index if not exists idx_contratos_inicio on public.contratos (fecha_inicio_produccion);
create index if not exists idx_contratos_estado on public.contratos (estado);
create index if not exists idx_contratos_disenador on public.contratos (disenador);
create index if not exists idx_contratos_cliente on public.contratos (lower(cliente));

-- ------------------------------------------------------------
-- 2. Prendas por talla  (la normalizacion que hace util la base)
-- ------------------------------------------------------------
create table if not exists public.contrato_prendas (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  prenda text not null check (btrim(prenda) <> ''),
  -- Puede venir vacia: rompevientos y buzos no varian por calidad.
  calidad text not null default '',
  -- Variante libre del vendedor ("cuello fucsia"), parte de la identidad de
  -- la linea: dos lineas de la misma prenda y calidad se distinguen por esto.
  detalle text not null default '',
  genero text not null check (genero in ('H', 'M', 'N')),
  -- 'General' para lo que no lleva talla (bolsos); asi suma igual sin
  -- necesitar una tabla aparte ni un caso especial en cada consulta.
  talla text not null check (btrim(talla) <> ''),
  cantidad integer not null check (cantidad > 0),
  unique (contrato_id, prenda, calidad, detalle, genero, talla)
);

comment on table public.contrato_prendas is
  'Una fila por prenda-calidad-genero-talla. Reemplaza el JSON anidado de la columna 59: el reporte de produccion por dia se resuelve con un group by en vez de recorrer todos los contratos en memoria.';

create index if not exists idx_contrato_prendas_contrato on public.contrato_prendas (contrato_id);
create index if not exists idx_contrato_prendas_prenda on public.contrato_prendas (prenda);

-- ------------------------------------------------------------
-- 3. Jugadores
-- ------------------------------------------------------------
create table if not exists public.contrato_jugadores (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  orden integer not null default 0,
  nombre text not null default '',
  numero text,
  -- Categoria del jugador, no genero gramatical: define de que bloque de
  -- tallas sale ('Nino' usa la tabla de tallas infantiles).
  categoria text not null default 'Hombre' check (categoria in ('Hombre', 'Mujer', 'Niño', 'Niña')),
  talla_superior text,
  talla_inferior text,
  manga text check (manga is null or manga in ('Corta', 'Larga')),
  calidad text,
  modelo_arquero text,
  tipo_uniforme text,
  detalle text,
  -- Etiqueta del mockup al que pertenece; el brief agrupa por esto.
  mockup text
);

create index if not exists idx_contrato_jugadores_contrato on public.contrato_jugadores (contrato_id, orden);

-- ------------------------------------------------------------
-- 4. Archivos: mockups y logos
-- ------------------------------------------------------------
-- Una sola tabla porque tienen la misma forma (archivo de Drive + a que
-- prenda y posicion aplica). Separarlas obligaria a duplicar consultas para
-- no ganar nada.
create table if not exists public.contrato_archivos (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  tipo text not null check (tipo in ('mockup', 'logo')),
  orden integer not null default 0,
  descripcion text not null default '',
  url text not null default '',
  -- Id del archivo en Drive, extraido de la url. Se guarda aparte porque la
  -- miniatura se arma con el id, y volver a parsear la url en cada render es
  -- trabajo repetido.
  drive_id text,
  -- Solo mockups.
  color text,
  -- Solo logos.
  prenda text,
  posicion text,
  tecnica text,
  calidad_aplicable text,
  observacion text
);

create index if not exists idx_contrato_archivos_contrato on public.contrato_archivos (contrato_id, tipo, orden);

-- ------------------------------------------------------------
-- 5. Especificaciones tecnicas
-- ------------------------------------------------------------
create table if not exists public.contrato_specs (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  -- Clave de prenda del formulario: camiseta, camisetaPolo, pantaloneta,
  -- chompa, chompaFrio, rompevientos, pantalon, bermuda, faldaShort, licra,
  -- chaleco, bolso, bvds, buzoComp, retro, deportiva, chompaFrio34.
  prenda_clave text not null check (btrim(prenda_clave) <> ''),
  orden integer not null default 0,
  -- A que aplica esta variante (mockup y/o calidad).
  variante_mockup text,
  variante_calidad text,
  variante_otro text,
  -- El arbol de especificaciones tal cual. Ver decision 3 de la cabecera.
  spec jsonb not null default '{}'::jsonb
);

comment on column public.contrato_specs.spec is
  'Arbol de especificaciones de la prenda. Se guarda entero porque solo se lee entero (brief); no se filtra ni se agrega por campos internos.';

create index if not exists idx_contrato_specs_contrato on public.contrato_specs (contrato_id, prenda_clave, orden);

-- ------------------------------------------------------------
-- 6. Detalle de facturacion
-- ------------------------------------------------------------
create table if not exists public.contrato_facturacion (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  orden integer not null default 0,
  concepto text not null check (btrim(concepto) <> ''),
  calidad text,
  cantidad integer not null check (cantidad > 0),
  obsequio boolean not null default false
);

create index if not exists idx_contrato_facturacion_contrato on public.contrato_facturacion (contrato_id, orden);

-- ------------------------------------------------------------
-- 7. Bitacora de etapas (trazabilidad del taller)
-- ------------------------------------------------------------
create table if not exists public.contrato_etapas (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  -- Area que marco: 'Diseño', 'Corte · Corte superior', 'Sellos · TPU'...
  -- El sufijo tras " · " es la sub-etapa, y por eso no se parte en dos
  -- columnas: hay areas con sub-etapa y otras sin ella.
  area text not null check (btrim(area) <> ''),
  etapa text not null check (btrim(etapa) <> ''),
  etapa_anterior text,
  operario text not null default '',
  -- Corte superior/inferior admiten "no aplica" cuando el contrato no lleva
  -- esa parte: sin esto el contrato nunca se completaria.
  no_aplica boolean not null default false,
  nota text,
  marcado_en timestamptz not null default now()
);

create index if not exists idx_contrato_etapas_contrato on public.contrato_etapas (contrato_id, marcado_en desc);
create index if not exists idx_contrato_etapas_fecha on public.contrato_etapas (marcado_en desc);

-- ------------------------------------------------------------
-- 8. Eventos: historial de asignaciones, observaciones y cambios de fecha
-- ------------------------------------------------------------
create table if not exists public.contrato_eventos (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete cascade,
  campo text not null check (btrim(campo) <> ''),
  valor_anterior text,
  valor_nuevo text,
  quien text not null default '',
  perfil_id uuid references public.perfiles(id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.contrato_eventos is
  'Historial de cambios (diseñador, observacion, fechas, estado). Reemplaza las pestanas append-only Asignaciones y Observaciones, donde el valor vigente era "la ultima fila" y habia que recorrerlas enteras para saberlo.';

create index if not exists idx_contrato_eventos_contrato on public.contrato_eventos (contrato_id, created_at desc);

-- ------------------------------------------------------------
-- 9. updated_at
-- ------------------------------------------------------------
create or replace function public.tocar_contrato_v79()
returns trigger language plpgsql as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;

drop trigger if exists trg_tocar_contrato_v79 on public.contratos;
create trigger trg_tocar_contrato_v79
  before update on public.contratos
  for each row execute function public.tocar_contrato_v79();

-- ------------------------------------------------------------
-- 10. Permisos y RLS
-- ------------------------------------------------------------
insert into public.permisos_sistema (codigo, modulo, nombre, descripcion)
values
  ('contratos.acceder', 'contratos', 'Ver contratos', 'Ver el tablero y los contratos de produccion'),
  ('contratos.editar', 'contratos', 'Editar contratos', 'Crear y modificar contratos'),
  ('contratos.marcar_etapa', 'contratos', 'Marcar etapas', 'Marcar avance de etapas en el taller')
on conflict (codigo) do nothing;

insert into public.rol_permisos (rol, permiso_codigo, permitido)
values
  ('admin', 'contratos.acceder', true),
  ('admin', 'contratos.editar', true),
  ('admin', 'contratos.marcar_etapa', true),
  ('gerencia', 'contratos.acceder', true),
  ('control', 'contratos.acceder', true)
on conflict (rol, permiso_codigo) do update set permitido = true, updated_at = now();

-- Lectura para quien tenga el permiso. La escritura ira por RPC con cada
-- pantalla: sin funciones aun, nadie escribe directo.
do $rls$
declare
  t text;
begin
  foreach t in array array[
    'contratos', 'contrato_prendas', 'contrato_jugadores', 'contrato_archivos',
    'contrato_specs', 'contrato_facturacion', 'contrato_etapas', 'contrato_eventos'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "leer_%s_v79" on public.%I', t, t);
    execute format(
      'create policy "leer_%s_v79" on public.%I for select to authenticated
       using (public.usuario_tiene_permiso_v35(''contratos.acceder''))', t, t);
    execute format('revoke all on public.%I from public, anon', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end;
$rls$;

commit;

notify pgrst, 'reload schema';
