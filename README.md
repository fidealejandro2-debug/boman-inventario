# Boman Sport — Inventario de Producto Terminado

App interna para bodega, tiendas, logística, control, administración y gerencia, con stock separado
por almacén: **Bodega Central** + 5 tiendas (Shopping Ambato, Mariano Egüez Ambato, Puyo,
Riobamba, Guayaquil). Bodega despacha hacia cada tienda vía "Transferencia" y el stock se
mueve automáticamente de un lado a otro.

Costo mensual esperado: **$0** (dentro de los free tiers de Supabase y Vercel para este tamaño de equipo).

---

## 1. Crear el proyecto en Supabase (tú, ~5 min)

1. Ve a https://supabase.com y crea una cuenta gratis (con tu correo o Google).
2. Clic en **New Project**. Ponle nombre `boman-inventario`, elige una contraseña de base de datos
   (guárdala, no la volverás a ver) y la región más cercana (US East suele ser la más rápida desde Ecuador).
3. Cuando el proyecto esté listo, ve a **SQL Editor** (menú izquierdo) → **New query**.
4. Ejecuta en orden, uno por uno, los archivos de la carpeta `sql`:
   `schema.sql`, `v2_upgrade.sql`, `v3_anular.sql`, `v4_anulacion_logica.sql`,
   `v5_importar_stock.sql`, `v6_seguridad_consistencia.sql`,
   `v7_administracion_usuarios.sql`, `v8_estado_productos.sql`,
   `v9_reparar_estado_productos.sql`, `v10_categorias_subcategorias.sql` y
   `v11_importar_catalogo_productos.sql`, `v12_fase_erp_operativa.sql`,
   `v13_ventas_xml.sql`, `v14_anulacion_ventas_xml.sql`,
   `v15_admin_aprueba_conteo_propio.sql`, `v16_incidencias_transferencia_sgc.sql`
   y `v17_rectificacion_recepciones.sql`.
   La migración v6 es obligatoria: corrige permisos, ajustes a cero, anulaciones,
   importaciones por almacén y agrega auditoría de cambios de notas.
5. Ve a **Project Settings → API**. Copia dos valores, los vas a necesitar:
   - **Project URL**
   - **anon public key**

## 2. Crear los 6 usuarios en Supabase

1. En Supabase, ve a **Authentication → Users → Add user**.
2. Crea o invita a cada persona desde **Administración → Usuarios** dentro de la app.
3. Asigna su rol y uno o varios almacenes:
   - `admin`: usuarios, catálogo y supervisión general.
   - `control`: conteos, diferencias, anulaciones y políticas de stock.
   - `bodega`: entradas/salidas manuales, picking y despacho.
   - `logistica`: seguimiento del transporte.
   - `tienda`: solicitud de reposición, recepción y conteo de su tienda.
   - `gerencia`: consulta global sin operación.

   Sugerencia según tu equipo:
   - Tú (Fidel) → `admin`
   - Jonathan Guaygua, Tatiana Sánchez → `bodega`
   - Alicia Tigse → `logistica`
   - Diego Bonilla → `gerencia`

## 3. Correr el proyecto en tu computador (opcional, para probar antes de publicar)

```bash
npm install
cp .env.local.example .env.local
# pega tu Project URL y anon key en .env.local
npm run dev
```

Abre http://localhost:3000

## 4. Publicar en Vercel (tú, ~5 min)

1. Sube esta carpeta a un repositorio de GitHub (crea el repo desde github.com, gratis).
2. Ve a https://vercel.com, crea cuenta gratis con GitHub, clic en **Add New → Project** y elige
   el repositorio.
3. En **Environment Variables**, agrega las variables de `.env.local`:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - `NEXT_PUBLIC_SITE_URL` (por ejemplo, `https://boman-inventario.vercel.app`)
   - `SUPABASE_SECRET_KEY` (Secret key del servidor; no uses el prefijo `NEXT_PUBLIC_`)
4. Clic en **Deploy**. En ~2 minutos tienes una URL pública (ej: `boman-inventario.vercel.app`)
   que pueden abrir desde el celular o computador.

Para las invitaciones, agrega en **Supabase → Authentication → URL Configuration** la URL
`https://tu-dominio.vercel.app/auth/callback` dentro de las Redirect URLs permitidas.

## 5. Uso diario

- **Tienda**: solicita reposición, recibe físicamente cada transferencia y realiza conteos ciegos.
- **Bodega**: aprueba solicitudes, prepara picking, despacha, y registra entradas/salidas excepcionales con referencia.
- **Logística**: marca la mercadería en tránsito y consulta la ruta documental.
- **Control**: realiza segundo conteo, investiga no conformidades, registra disposiciones y anula movimientos manuales.
- **Admin**: administra catálogo, usuarios y configuraciones; no sustituye la recepción física de tienda.
- **Gerencia**: consulta stock físico/disponible/en tránsito, documentos y reportes.

## Estado de la Fase ERP operativa (v16)

- Compilación de producción verificada.
- Movimientos e importaciones protegidos mediante funciones atómicas de Supabase.
- Acceso restringido por usuario activo y almacén asignado.
- Ajustes de stock a cero y anulaciones posteriores corregidos.
- Historial y kardex completos mediante paginación; exportación a Excel actualizada.
- Repositorio Git inicializado.
- Panel de administración para invitar, editar, asignar y desactivar usuarios.
- Desactivación de productos auditada y bloqueada mientras exista stock.
- Catálogo administrable de categorías y subcategorías para productos.
- Categorías y subcategorías integradas en Stock, Movimientos, Dashboard, Reportes y exportaciones.
- Clasificación masiva de productos desde los resultados filtrados.
- Importación auditada del catálogo maestro desde Excel/CSV: altas, categorías, precios y mínimos sin alterar stock.
- Solicitudes de reposición y transferencias multilínea con número de documento.
- Picking, despacho, tránsito y recepción real; el destino solo aumenta al confirmar lo recibido.
- Recepción con clasificación total: conforme, no conforme o no recibida.
- No conformes bloqueados en cuarentena y faltantes visibles como tránsito con incidencia.
- Investigación, disposición parcial/final, causa raíz y acción correctiva auditadas; solo Admin reconoce pérdidas.
- Rectificación administrativa de recepciones erróneas mediante movimientos compensatorios, sin borrar el registro original.
- Conteos ciegos totales o parciales, segundo conteo y aplicación aprobada al kardex.
- Stock físico, reservado, disponible y en tránsito por tienda y bodega.
- Mínimos, máximos, seguridad, punto de reposición y ubicación por producto/almacén.
- Asignación de uno o varios almacenes por usuario y roles `tienda`/`control`.
- Auditoría de documentos, catálogo y anulaciones; reportes operativos exportables.
- Captura masiva por pegado de SKU/cantidad, guías imprimibles y aviso de conexión. No incluye código de barras todavía.

### Puesta en marcha de esta fase

Si la base real ya tiene v11, ejecuta **una sola vez y en orden** las migraciones v12 a v17.
Después de cada una ejecuta su archivo `sql/verificacion_vNN.sql`. Instala v16 antes de publicar
la interfaz actual: las pantallas de Operaciones, Control y Stock consultan sus nuevas columnas.
