# Boman Sport — Inventario de Producto Terminado

App interna para 6 usuarios (bodega, logística, admin, gerencia) con roles y stock separado
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
   `v5_importar_stock.sql` y `v6_seguridad_consistencia.sql`.
   La migración v6 es obligatoria: corrige permisos, ajustes a cero, anulaciones,
   importaciones por almacén y agrega auditoría de cambios de notas.
5. Ve a **Project Settings → API**. Copia dos valores, los vas a necesitar:
   - **Project URL**
   - **anon public key**

## 2. Crear los 6 usuarios en Supabase

1. En Supabase, ve a **Authentication → Users → Add user**.
2. Crea uno por cada persona (correo + contraseña temporal). Al crearse, el trigger de la base de
   datos les asigna automáticamente el rol `bodega` por defecto.
3. Para ajustar el rol y la entidad de cada quien: ve a **Table Editor → perfiles** y edita la fila
   de cada usuario:
   - `rol`: `admin`, `bodega`, `logistica` o `gerencia`
   - `entidad_id`: copia el `id` de la tienda o bodega asignada desde la tabla `almacenes`
     (déjalo vacío/null para admin y gerencia, así ven todos los almacenes)

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
3. En **Environment Variables**, agrega las mismas dos variables de `.env.local`:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
4. Clic en **Deploy**. En ~2 minutos tienes una URL pública (ej: `boman-inventario.vercel.app`)
   que pueden abrir desde el celular o computador.

## 5. Uso diario

- **Bodega**: entra a "Movimientos" → registra entradas (producción terminada que llega) y salidas
  (ventas/despachos). El stock se actualiza solo.
- **Logística**: usa "Movimientos" con tipo "Transferencia" cuando mueva producto de un almacén
  a otro. El despacho y la recepción se registran automáticamente como un solo grupo auditable.
- **Admin (tú)**: da de alta productos nuevos en "Productos", y tienes acceso total.
- **Gerencia (Diego)**: solo ve "Stock" y "Reportes", sin poder editar nada.

## Estado de la Fase 0

- Compilación de producción verificada.
- Movimientos e importaciones protegidos mediante funciones atómicas de Supabase.
- Acceso restringido por usuario activo y almacén asignado.
- Ajustes de stock a cero y anulaciones posteriores corregidos.
- Historial y kardex completos mediante paginación; exportación a Excel actualizada.
- Repositorio Git inicializado.

Pendiente operativo: aplicar `sql/v6_seguridad_consistencia.sql` en el proyecto real de
Supabase y probar con un usuario de cada rol. Next.js 14 quedó marcado para una migración
separada a una versión LTS, ya que implica también actualizar React y adaptar APIs asíncronas.
