# BOMAN · Sistema de Inventario

Contexto del proyecto para retomar el desarrollo. Lee esto antes de tocar código.

---

## Qué es

App web de inventario de prendas terminadas para **Boman Sport** (Ambato, Ecuador; textil/deportivo).
Reemplaza a AppSheet (se descartó por costo: $5/usuario/mes). Corre en el tier gratuito de Vercel + Supabase: **$0/mes**.

**Usuarios:** ~6 personas. **Catálogo:** 545 productos. **Ubicaciones:** 7.

- **Producción:** https://boman-inventario.vercel.app
- **Vercel:** https://vercel.com/fidel-altamirano-s-projects/boman-inventario
- **Supabase ref:** `fpztguulwecbvkdokkef` → `https://fpztguulwecbvkdokkef.supabase.co`

Deploy: push a GitHub → Vercel redespliega solo.

---

## Stack

| | |
|---|---|
| Framework | Next.js 14.2.35 (App Router) |
| Backend | Supabase (Postgres + Auth + RLS) |
| Auth | `@supabase/ssr` — cookies, middleware refresca sesión |
| Excel | SheetJS (`xlsx` ^0.18.5) — lectura en el navegador |
| Estilos | CSS plano en `app/globals.css`. **Sin Tailwind, sin librería de componentes.** |

### Variables de entorno

```
NEXT_PUBLIC_SUPABASE_URL=https://fpztguulwecbvkdokkef.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon key>
```

⚠️ La URL va **limpia**, sin `/rest/v1` al final. Ese sufijo ya rompió el login una vez.

---

## Estructura

```
app/
  login/page.tsx                    signInWithPassword
  dashboard/  page.tsx + DashboardCliente.tsx    KPIs, alertas, actividad
  inventario/ page.tsx + StockCliente.tsx        stock con búsqueda y filtros
  movimientos/page.tsx + MovimientosCliente.tsx  registro + historial + anular
  productos/  page.tsx + ProductosCliente.tsx    catálogo, edición en línea (admin)
  reportes/   page.tsx + ReportesCliente.tsx     5 pestañas (admin/gerencia)
  importar/   page.tsx + ImportarCliente.tsx     toma física (admin/bodega)
  globals.css
components/Navbar.tsx               navegación según rol
lib/
  supabase/client.ts | server.ts
  getPerfil.ts                      usuario + perfil; redirige a /login
  utils.ts                          exportarCSV, fecha, ETIQUETA_TIPO
middleware.ts                       protege rutas
sql/
  schema.sql                 base inicial
  v2_upgrade.sql             arregla RLS, stock_minimo, índices, vista_stock
  v3_anular.sql              grupo_id, cantidad_anterior, anular v1
  v4_anulacion_logica.sql    anulación lógica (reemplaza v3)
  v5_importar_stock.sql      importar_stock()
```

**Patrón:** `page.tsx` es Server Component (valida rol, redirige) y delega a un `*Cliente.tsx` con `"use client"` que hace las consultas y maneja filtros en memoria. Los volúmenes son chicos; no hace falta paginación en servidor.

---

## Base de datos

### Tablas

- **almacenes** — `id, nombre, tipo ('bodega'|'tienda'), activo`
  Bodega Central + Shopping Ambato, Mariano Egüez, Puyo, Riobamba, Guayaquil, Santo Domingo.
- **perfiles** — `id (=auth.users.id), nombre_completo, rol, entidad_id, activo`
  Roles: `admin`, `bodega`, `logistica`, `gerencia`. `entidad_id` NULL = ve todos los almacenes.
- **productos** — `id, sku (único), nombre, categoria, talla, color, stock_minimo, precio, activo`
- **inventario** — `producto_id + entidad_id` (único), `cantidad`
- **movimientos** — bitácora inmutable (ver abajo)

### `movimientos` — ojo con esto

Tipos: `entrada`, `salida`, `transferencia_envio`, `transferencia_recibo`, `ajuste`.

**Tiene relaciones DUPLICADAS. Toda consulta con embed necesita hint explícito de FK o falla.**

Dos FK a `almacenes`: `entidad_id`, `entidad_destino_id`.
Dos FK a `perfiles`: `usuario_id`, `anulado_por`.

```ts
// ✅ correcto
.select(`
  id, tipo, cantidad, nota, created_at, grupo_id,
  anulado, anulado_at, motivo_anulacion,
  productos(nombre, sku),
  almacenes!movimientos_entidad_id_fkey(nombre),
  almacen_destino:almacenes!movimientos_entidad_destino_id_fkey(nombre),
  perfiles!movimientos_usuario_id_fkey(nombre_completo),
  anulador:perfiles!movimientos_anulado_por_fkey(nombre_completo)
`)

// ❌ "Could not embed because more than one relationship was found"
.select("..., almacenes(nombre), perfiles(nombre_completo)")
```

Otras columnas: `grupo_id` (une despacho ↔ recepción), `cantidad_anterior` (stock previo a un ajuste, para revertirlo).

### Vista `vista_stock`

Une inventario + productos + almacenes y calcula `bajo_minimo`. Es la fuente de Stock, Dashboard y Reportes. Si agregas campos a `productos` que se muestren en esas pantallas, hay que recrear la vista.

### Funciones RPC (todas `security definer set search_path = public`)

| Función | Qué hace |
|---|---|
| `registrar_movimiento(...)` | Inserta movimiento + actualiza stock atómicamente. En `transferencia_envio` genera la recepción espejo con el mismo `grupo_id`. En `ajuste` guarda `cantidad_anterior`. |
| `anular_movimiento(p_movimiento_id, p_motivo)` | Revierte el stock y **marca** `anulado=true` con motivo, autor y fecha. Motivo obligatorio. Anular un despacho anula también su recepción. |
| `importar_stock(p_entidad_id, p_items jsonb, p_nota, p_cerrar_faltantes)` | Toma física. Cada cambio se graba como `ajuste` con `cantidad_anterior`. Devuelve `{actualizados, sin_cambio, cerrados, desconocidos[]}`. |

---

## Decisiones de diseño (no revertir sin hablarlo)

**Los movimientos NO se borran.** `DELETE` está revocado a nivel de base de datos. Solo anulación lógica: el registro queda visible tachado, con etiqueta ANULADO, motivo, quién y cuándo. Boman está construyendo su SGC ISO 9001:2015 y la trazabilidad es requisito, no adorno.

**La importación de stock genera ajustes, no sobrescribe en silencio.** Por eso cada línea de una toma física es individualmente anulable y aparece en el kardex del producto.

**RLS con `entidad_id IS NULL`.** Un perfil sin almacén asignado ve todo. Sin esto, un usuario `bodega` sin `entidad_id` no veía **nada** y parecía que la app estaba rota. Fue un bug real; no lo reintroduzcas.

**Los errores de carga se muestran en pantalla.** Nada de tragarse el error y renderizar "sin resultados" — eso mandó a buscar el problema en los filtros cuando estaba en la consulta.

---

## Funcionalidad actual

- **Búsqueda de texto libre** en Stock, Productos y Movimientos: nombre, SKU, categoría, talla, color simultáneamente.
- **Filtros:** categoría, almacén, tipo, rango de fechas, solo bajo mínimo, ocultar sin stock, mostrar anulados.
- **Autocompletado de producto** al registrar movimientos (545 productos en un `<select>` era inusable).
- **Alertas de reposición** vía `stock_minimo` por producto.
- **Reportes:** por almacén · por categoría · stock bajo · matriz producto×almacén · kardex.
- **Exportación CSV** en cada pantalla (separador `;`, BOM UTF-8 para que Excel respete los acentos).
- **Importar stock** con vista previa comparativa antes de aplicar.

---

## Pendientes

- [ ] Cargar precios (el Excel origen los traía en 0 → el KPI "Valor inventario" da $0)
- [ ] Asignar roles a los 5 usuarios restantes en `perfiles`:
      Jonathan Guaygua y Tatiana Sánchez → `bodega` / Bodega Central ·
      Alicia Tigse → `logistica` · Diego Bonilla → `gerencia`
- [ ] Categorizar 38 productos que quedaron sin categoría
- [ ] Los 13 ítems `CTR-*` (contratos de maquila) se excluyeron del catálogo — confirmar si deben entrar

### Ideas para más adelante
Fotos de producto · escaneo de código de barras · alertas por correo al caer bajo mínimo · reporte de rotación · cierre de período.

---

## Personas

| Nombre | Rol |
|---|---|
| Fidel Altamirano | Jefe Contable y Administrativo — dueño del proyecto, `admin` |
| Diego Bonilla | Gerente General — `gerencia` |
| Jonathan Guaygua | Jefe de Bodega |
| Tatiana Sánchez | Auxiliar de Bodega |
| Alicia Tigse | Auxiliar de Logística |

**Todo en español.** Nombres de variables, mensajes de UI, mensajes de error de Postgres. Fidel comunica directo y en frases cortas; espera razonamiento contextual, no seguimiento mecánico de reglas.

---

## Trabajar con esto

1. Ejecuta los SQL **en orden** (`schema` → `v2` → `v3` → `v4` → `v5`). Son incrementales; v4 reemplaza la función de v3.
2. Antes de escribir un `.select()` sobre `movimientos`, revisa la sección de relaciones duplicadas.
3. `npm run build` antes de dar algo por terminado — el build detecta los errores de tipos.
4. Cambios de esquema → SQL numerado nuevo en `sql/`, nunca editar uno ya ejecutado.
