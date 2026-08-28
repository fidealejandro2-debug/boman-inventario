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
| Excel | SheetJS (`xlsx` 0.20.3 oficial) — lectura en el navegador |
| Estilos | CSS plano en `app/globals.css`. **Sin Tailwind, sin librería de componentes.** |

### Variables de entorno

```
NEXT_PUBLIC_SUPABASE_URL=https://fpztguulwecbvkdokkef.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon key>
NEXT_PUBLIC_SITE_URL=https://boman-inventario.vercel.app
SUPABASE_SECRET_KEY=<secret key; solo servidor, nunca NEXT_PUBLIC_>
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
  operaciones/                              solicitudes, picking, despacho, recepción
  ventas/                                   carga y conciliación de facturas XML SRI
  conteos/                                  conteo ciego y envío a Control
  control/                                  aprobaciones, diferencias y auditoría
  configuracion/inventario/                 mínimos/ubicaciones por almacén
  importar/                                 redirige al flujo seguro de conteos
  administracion/usuarios/                       gestión de usuarios (admin)
  auth/callback/                                 procesa invitaciones
  establecer-clave/                             contraseña inicial
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
  v6_seguridad_consistencia.sql  seguridad, consistencia y auditoría
  v7_administracion_usuarios.sql administración auditada de perfiles
  v8_estado_productos.sql    activación/desactivación auditada; exige stock cero
  v9_reparar_estado_productos.sql corrige propietario/permisos de la RPC de estado
  v10_categorias_subcategorias.sql catálogo jerárquico para productos
  v11_importar_catalogo_productos.sql importación atómica y auditada del catálogo maestro
  v12_fase_erp_operativa.sql documentos, recepción, conteos, roles y stock operativo
  verificacion_v12.sql       comprobaciones de instalación y prueba de aceptación
  v13_ventas_xml.sql         facturas SRI, equivalencias de SKU y ventas contra inventario
  verificacion_v13.sql       comprobaciones de instalación de Ventas XML
  v14_anulacion_ventas_xml.sql reversión auditada de facturas XML exclusiva de admin
  verificacion_v14.sql       comprobaciones de instalación de la anulación administrativa
  v15_admin_aprueba_conteo_propio.sql excepción auditada para que admin resuelva su propio conteo
  verificacion_v15.sql       comprueba la excepción exclusiva de admin
  v16_incidencias_transferencia_sgc.sql clasificación total, cuarentena y disposición de diferencias
  verificacion_v16.sql       comprueba trazabilidad, seguridad y saldos de incidencias
  v17_rectificacion_recepciones.sql reversión compensatoria y auditada exclusiva de admin
  verificacion_v17.sql       comprueba seguridad e integridad de las rectificaciones
  actualizacion_completa_v9_a_v11.sql paquete único para una base que ya llegó hasta v8
```

**Patrón:** `page.tsx` es Server Component (valida rol, redirige) y delega a un `*Cliente.tsx` con `"use client"` que hace las consultas y maneja filtros en memoria. Los volúmenes son chicos; no hace falta paginación en servidor.

---

## Base de datos

### Tablas

- **almacenes** — `id, nombre, tipo ('bodega'|'tienda'), activo`
  Bodega Central + Shopping Ambato, Mariano Egüez, Puyo, Riobamba, Guayaquil, Santo Domingo.
- **perfiles / perfil_almacenes** — perfil, rol y uno o varios almacenes explícitos.
  Roles: `admin`, `control`, `bodega`, `logistica`, `tienda`, `gerencia`.
- **productos** — `id, sku (único), nombre, categoria/categoria_id, subcategoria/subcategoria_id, talla, color, stock_minimo, precio, activo`
- **categorias_productos / subcategorias_productos** — catálogo jerárquico administrable; se desactiva en lugar de borrar
- **inventario** — `producto_id + entidad_id` (único), `cantidad`
- **producto_almacen_config** — mínimo/máximo/seguridad/reposición/ubicación por almacén
- **documentos_inventario + líneas + eventos** — solicitudes, transferencias y conteos multilínea
- **movimientos** — bitácora inmutable (ver abajo)
- **documentos_venta_xml + líneas + asignaciones** — facturas autorizadas ya aplicadas y reparto de cada línea externa entre SKU internos
- **producto_codigos_facturacion** — equivalencias aprendidas entre códigos del facturador y productos internos

### `movimientos` — ojo con esto

Tipos: `entrada`, `salida`, `transferencia_envio`, `transferencia_recibo`, `ajuste`, `venta_xml`.

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

### Vista `vista_stock_operativo`

Expone stock físico, reservado, disponible, tránsito de entrada/salida y reposición sugerida por ubicación.

### Funciones RPC (todas `security definer set search_path = public`)

| Función | Qué hace |
|---|---|
| `crear_solicitud_reposicion / resolver_solicitud_reposicion` | Solicitud y aprobación que genera transferencia. |
| `crear_transferencia_directa / guardar_preparacion_transferencia / despachar_transferencia` | Reserva, picking y salida de origen. |
| `recibir_transferencia` | Suma al destino únicamente la cantidad físicamente recibida. |
| `crear_conteo_inventario / guardar_conteo_inventario / resolver_conteo_inventario` | Conteo ciego, segundo conteo y ajuste aprobado. |
| `registrar_movimiento_manual` | Solo entradas/salidas excepcionales con referencia. |
| `control_anular_movimiento` | Anulación segregada y auditada por Control. |
| `admin_importar_catalogo_productos(p_items, p_nota)` | Crea/actualiza el catálogo maestro, categorías, precios y mínimos en una transacción auditada. No modifica stock. |
| `aplicar_factura_venta_xml(p_documento, p_almacen_id, p_asignaciones, p_nota)` | Valida una factura SRI autorizada, evita duplicados, aprende equivalencias y descuenta stock atómicamente. |
| `admin_anular_factura_venta_xml(p_documento_id, p_motivo)` | Solo admin: reintegra el stock y marca factura/movimientos como anulados sin borrar evidencia. |

---

## Decisiones de diseño (no revertir sin hablarlo)

**El grupo económico opera consolidado, pero cada RUC conserva identidad legal.** Desde v18 el catálogo y el inventario físico continúan compartidos; `empresas`, `empresa_almacenes` y `perfil_empresas` identifican qué CIA, SAS, persona natural o establecimiento responde por cada operación. Una tienda puede relacionarse con varios RUC, pero solo tiene una operadora principal para la clasificación automática. Esta atribución operativa no debe confundirse con la propiedad contable de las unidades.

**No inventar titularidad histórica de inventario.** Los movimientos anteriores a v18 que no puedan relacionarse inequívocamente con un RUC permanecen visibles como pendientes de clasificación en `vista_pendientes_multiempresa`. La titularidad, cesiones intercompañía y eliminaciones para estados consolidados deben implementarse en un libro separado, sin partir ni sobrescribir `inventario`.

**Los movimientos NO se borran.** `DELETE` está revocado a nivel de base de datos. Solo anulación lógica: el registro queda visible tachado, con etiqueta ANULADO, motivo, quién y cuándo. Boman está construyendo su SGC ISO 9001:2015 y la trazabilidad es requisito, no adorno.

**La importación de stock genera ajustes, no sobrescribe en silencio.** Por eso cada línea de una toma física es individualmente anulable y aparece en el kardex del producto.

**Almacenes explícitos.** Los roles operativos deben tener al menos un almacén en `perfil_almacenes`.
Solo admin/control ven y operan globalmente; gerencia tiene lectura global.

**Los errores de carga se muestran en pantalla.** Nada de tragarse el error y renderizar "sin resultados" — eso mandó a buscar el problema en los filtros cuando estaba en la consulta.

**Ventas XML no sustituye al facturador.** El XML autorizado se interpreta en el navegador. La base conserva la clave de acceso, huella SHA-256, cabecera operativa, líneas y asignaciones; no guarda el XML completo ni datos personales del cliente. Una factura solo puede descontar inventario una vez.

**Tienda y Bodega pueden cargar XML, pero no anularlos.** Los usuarios `tienda` y `bodega` importan únicamente contra sus almacenes asignados. La anulación de la aplicación en inventario exige rol `admin`, motivo y conserva responsable/fecha. Tampoco anula el comprobante en el facturador ni ante el SRI.

**Admin puede resolver su propio conteo como excepción explícita.** El rol `control` conserva la separación entre quien cuenta y quien revisa. Cuando `admin` registra el segundo conteo o aprueba uno creado por sí mismo, el evento y los ajustes lo identifican como `Excepción Admin`.

---

## Funcionalidad actual

- **Búsqueda de texto libre** en Stock, Productos y Movimientos: nombre, SKU, categoría, subcategoría, talla y color simultáneamente.
- **Filtros:** categoría/subcategoría, almacén, tipo, rango de fechas, solo bajo mínimo, ocultar sin stock, mostrar anulados.
- **Autocompletado de producto** al registrar movimientos (545 productos en un `<select>` era inusable).
- **Clasificación masiva de productos:** selección individual o de todos los resultados filtrados para asignar categoría/subcategoría por lotes.
- **Importación de catálogo maestro:** Excel/CSV con vista previa, validación, altas/actualizaciones y últimas importaciones.
- **Alertas de reposición** vía `stock_minimo` por producto.
- **Reportes:** por almacén · por categoría/subcategoría · stock bajo · matriz producto×almacén · kardex.
- **Exportación CSV** en cada pantalla (separador `;`, BOM UTF-8 para que Excel respete los acentos).
- **Importar stock** con vista previa comparativa antes de aplicar.
- **Ventas desde XML SRI:** carga local, validación de autorización, asignación de líneas genéricas entre varios SKU, memoria de equivalencias, control de stock e historial.
- **No conformidades de transferencia:** toda unidad despachada se clasifica como conforme, no conforme o no recibida; lo no conforme queda en cuarentena y lo faltante continúa bajo seguimiento hasta su disposición documentada.
- **Rectificación de recepción:** Admin puede revertir una recepción mal digitada y devolverla a tránsito; se bloquea si existen movimientos, conteos o disposiciones posteriores.

---

## Pendientes

- [ ] Cargar los precios reales usando la importación del catálogo maestro (hasta entonces el KPI "Valor inventario" seguirá en $0)
- [ ] Ejecutar v12 en producción y asignar roles/almacenes desde Administración → Usuarios.
- [ ] Realizar la prueba de aceptación de `sql/verificacion_v12.sql` con usuarios distintos de Bodega, Tienda y Control.
- [ ] Después de aprobar v12, ejecutar `sql/v13_ventas_xml.sql` y luego `sql/verificacion_v13.sql`.
- [ ] Después de validar v13, ejecutar `sql/v14_anulacion_ventas_xml.sql` y luego `sql/verificacion_v14.sql`.
- [ ] Ejecutar `sql/v15_admin_aprueba_conteo_propio.sql` y validar con `sql/verificacion_v15.sql`.
- [ ] Ejecutar `sql/v16_incidencias_transferencia_sgc.sql` y validar con `sql/verificacion_v16.sql` antes de desplegar la interfaz v16.
- [ ] Ejecutar `sql/v17_rectificacion_recepciones.sql`, validar con `sql/verificacion_v17.sql` y después desplegar la interfaz.
- [ ] Ejecutar `sql/v18_grupo_economico_multiempresa.sql`, validar con `sql/verificacion_v18.sql` y registrar todos los RUC antes de activar titularidad contable o documentos intercompañía.
- [ ] Probar v13 con una factura real primero en un almacén de prueba y confirmar la distribución por talla/color antes de aplicarla.
- [ ] Asignar roles a los usuarios restantes:
      Jonathan Guaygua y Tatiana Sánchez → `bodega` / Bodega Central ·
      Alicia Tigse → `logistica` · Diego Bonilla → `gerencia`
- [ ] Categorizar 38 productos que quedaron sin categoría
- [ ] Los 13 ítems `CTR-*` (contratos de maquila) se excluyeron del catálogo — confirmar si deben entrar

### Ideas para más adelante
Fotos de producto · código de barras · alertas por correo · costos/valoración contable · cierre de período.

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

1. Ejecuta los SQL **en orden** hasta `v18`. Si producción ya está en v11, ejecuta y valida sucesivamente v12, v13, v14, v15, v16, v17 y v18.
2. Antes de escribir un `.select()` sobre `movimientos`, revisa la sección de relaciones duplicadas.
3. `npm run build` antes de dar algo por terminado — el build detecta los errores de tipos.
4. Cambios de esquema → SQL numerado nuevo en `sql/`, nunca editar uno ya ejecutado.
