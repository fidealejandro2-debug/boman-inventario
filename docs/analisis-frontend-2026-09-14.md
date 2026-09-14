# Análisis de interfaz y experiencia de Boman

Fecha: 14 de septiembre de 2026.

## Conclusión

Boman ha crecido hasta funcionar como un ERP. La mejora principal consiste en reducir el esfuerzo para encontrar una tarea, entender un registro y continuar el trabajo entre pantallas. Hay una base útil: navegación por rol, favoritos, búsqueda de accesos, tablas paginadas en varios módulos, diálogos comunes y un asistente de contratos con borrador automático.

La prioridad propuesta es comodidad operativa: formularios comprensibles, contexto persistente, información esencial visible y acciones previsibles. El acabado visual debe acompañar esos cambios.

## Alcance y límites

- Inventario estructural de 48 archivos de ruta `page.tsx` y 135 archivos TSX en `app`, incluidos componentes y documentos imprimibles. Estos números no equivalen a 48 flujos probados.
- Revisión de navegación, estilos globales, componentes compartidos y código de las principales familias de pantallas. Las recomendaciones por módulo combinan observaciones directas y propuestas de diseño; no representan pruebas exhaustivas de cada operación.
- No fue posible inspeccionar la aplicación renderizada: el navegador disponible devolvió una lista vacía. Quedan pendientes escritorio, móvil, tema oscuro, teclado y pruebas con sesión por rol.
- No se ejecutaron operaciones sobre datos ni se modificó la aplicación. Se conserva el cambio previo en `app/ventas/contratos/IngresoContrato.module.css`.

## Hallazgos con evidencia

### 1. Clientes requiere conocer un formato técnico — prioridad alta

En `app/ventas/clientes/ClientesCliente.tsx`, el formulario pide «Contactos (tipo|valor|etiqueta)» y «Direcciones (dirección|etiqueta)». El guardado separa las líneas por `|` y descarta contactos sin segundo segmento. Una persona puede escribir un teléfono de forma natural y que ese contacto no llegue al envío.

**Cambio:** filas editables con Tipo, Teléfono/correo, Etiqueta y botones Agregar/Quitar. Direcciones con campos separados. Validar cada fila e indicar dónde corregir, manteniendo el motivo auditable existente.

**Aceptación:** crear dos contactos y una dirección sin aprender delimitadores; ninguna fila incompleta se descarta silenciosamente.

También existe un `div` de acciones masivas directamente dentro de `table`: corregir esa estructura y situar la barra antes de la tabla. Su efecto visual requiere validación en navegador.

### 2. Se pierde contexto al cambiar de pantalla — prioridad alta

`StockCliente.tsx` inicia local, búsqueda, filtros y página con estado local. `NominaCliente.tsx` inicia siempre en Personal y `OperacionesCliente.tsx` en Solicitudes. No se observa persistencia de estos estados en los componentes revisados.

**Cambio:** parámetros de URL para filtros, pestaña y paginación; recordar el último local autorizado como preferencia cuando corresponda. Validar siempre el ámbito frente a los permisos actuales.

**Aceptación:** abrir una ficha y volver conserva búsqueda, local, página y pestaña; Atrás funciona de forma previsible. Un local que ya no está autorizado nunca se recupera como contexto válido.

### 3. Existencias exige comparar demasiadas columnas — prioridad alta

`StockCliente.tsx:269` presenta 11 columnas. «Seguimiento» suma tránsito con incidencia y cuarentena, que son situaciones distintas. «Reserv.» abrevia un concepto que puede requerir explicación.

**Cambio:** vista habitual con Producto/SKU, Variante, Disponible, Estado y acceso a detalle. Ofrecer vista completa para control, con físico, reservado, tránsito, cuarentena y ubicación separados. Mantener todas las magnitudes y la exportación.

**Aceptación:** consultar disponibilidad sin desplazamiento horizontal en la vista móvil resumida; la vista completa conserva todos los datos. Diferenciar «sin resultados», «sin existencias» y «no se pudo cargar».

### 4. La portada dedica mucho espacio a presentación — prioridad media

`Dashboard.module.css` define una portada de al menos 410 px, saludo de hasta 58 px y rótulos de indicadores de 8 px. `DashboardCliente.tsx` añade accesos rápidos, catálogo de módulos y otra columna de pendientes, además del menú lateral.

**Cambio:** cabecera breve con fecha y ámbito, pendientes accionables primero, indicadores y accesos frecuentes después. Mantener identidad Boman con logo, color y detalles discretos. Dejar el catálogo completo en segundo plano.

**Aceptación:** en un portátil se puede identificar una tarea pendiente y ejecutarla desde la primera vista. Medirlo con datos y resolución reales.

### 5. Un estado de error puede acompañarse de un mensaje tranquilizador — prioridad alta

En `DashboardCliente.tsx`, cuando no existe `prioridad`, se renderiza «Sin bloqueos críticos» incluso si el resumen sigue cargando o hay error. El título y descripción sí contemplan esas condiciones, pero ese indicador final no.

**Cambio:** mostrar «Consultando» o «Estado no disponible» cuando corresponda; reservar «Sin bloqueos críticos» para una consulta válida que lo confirme.

**Aceptación:** simular carga y error del resumen nunca presenta ausencia de bloqueos como un hecho comprobado.

### 6. Legibilidad y temas necesitan una base uniforme — prioridad media

`globals.css` usa controles de 13 px y etiquetas de 12 px, junto con numerosos rótulos de 9–11 px. El tablero contiene textos de 9,5–10 px. Existen tokens de tema y foco visible, pero también colores en línea y reglas que los corrigen mediante selectores sobre `style` e `!important`.

**Cambio:** tamaño habitual de lectura de 14–16 px según contexto, textos secundarios legibles y altura cómoda de controles; densidad compacta opcional para tablas especializadas. Migrar colores hacia tokens semánticos y componentes compartidos. Separar estilos de impresión y de operación.

**Aceptación:** comprobar contraste, zoom al 200 %, tema claro/oscuro y controles táctiles en cada familia de pantalla. No se afirma que hoy todas las combinaciones fallen: falta medición visual.

### 7. Los diálogos no completan la gestión de foco — prioridad alta

`components/Dialogo.tsx` declara `role="dialog"` y `aria-modal`, y permite Escape. Solo enfoca el textarea de motivos; no contiene Tab dentro del diálogo, no devuelve el foco al disparador y no vincula el título mediante `aria-labelledby`. También hay modales propios en pantallas como Existencias.

**Cambio:** completar el componente común y reutilizarlo para los modales operativos. Foco inicial adecuado, Tab/Shift+Tab contenido, título y descripción asociados, retorno de foco y control del scroll del fondo.

**Aceptación:** completar o cancelar confirmaciones con teclado sin activar controles detrás del modal. Mantener `mostrarAvisoDialogo`, `confirmarDialogo` y `pedirMotivoDialogo`, como exige `AGENTS.md`.

### 8. Contratos ya tiene un flujo guiado que conviene refinar — prioridad media

`IngresoContratoCliente.tsx` contiene siete pasos, validación por paso, revisión y borrador automático para contratos nuevos. Los pasos completados se indican mediante `i < paso`, que representa posición, no necesariamente validez. La edición excluye expresamente el guardado de borrador local.

**Cambio:** marcar completitud por validación, mostrar resumen persistente de cliente/prendas/fecha/importe y llevar al primer campo pendiente tras cerrar el aviso. Mostrar estado real del borrador y proteger la salida de una edición con cambios sin guardar. Evaluar navegación y acciones fijas sin tapar contenido.

**Aceptación:** volver a un paso y vaciar un campo requerido actualiza su estado; el usuario distingue borrador, archivo pendiente y contrato registrado. No confundir la preservación de datos con recuperación de archivos locales aún no subidos.

### 9. La terminología dificulta anticipar el destino — prioridad media

`Navbar.tsx` usa «Análisis» para reportes, «Cartera y cheques» bajo Tesorería y varias entradas relacionadas con contratos distribuidas entre Ventas y Producción. La búsqueda y los accesos por rol ya existen y deben conservarse.

**Cambio:** aclarar etiquetas como «Cuentas por pagar» y «Reportes y análisis»; mantener una ficha de contrato como punto común de consulta con enlaces a producción, entregas y cobros según permisos. Evitar duplicar formularios o reglas de negocio.

**Aceptación:** una persona de cada rol encuentra sus tres tareas frecuentes sin asistencia; las acciones repetidas conservan permisos, validaciones y mensajes.

## Propuesta por familia de pantallas

| Área | Conservar | Mejora propuesta |
|---|---|---|
| Inicio y navegación | Favoritos, búsqueda y accesos por rol | Pendientes primero; nombres claros y ubicación actual visible |
| Existencias y productos | Separación por local, imágenes y exportación | Vista resumida/completa, filtros persistentes y ficha lateral o página de detalle |
| Operaciones | Solicitudes, transferencias y recepción clasificada | Bandejas por tarea pendiente y siguiente acción destacada por documento |
| Conteos y control | Guardar avance, revisión y trazabilidad | Separar trabajo pendiente de historial; facilitar captura de cantidades en móvil |
| Compras y XML | Homologación y recepción por línea | Resumen de líneas listas, pendientes y bloqueadas; conservar progreso y mostrar paso siguiente |
| Clientes | Ficha integral e historial | Contactos estructurados y fusión en un flujo secundario claramente identificado |
| Contratos | Asistente, borrador, revisión y brief | Completitud real, resumen persistente y protección de edición |
| Seguimiento y entregas | Gestión parcial y evidencias | Contexto visible del contrato, cantidades pendientes y acceso de regreso a la lista |
| Producción y tablero | Matriz por etapas y columnas fijas existentes | Vista personal «Mi trabajo» y vista general; estados legibles con siguiente acción |
| Cronograma y costos | Capacidad y rentabilidad | Separar planificación y consulta económica mediante vistas claras |
| Cobros y tesorería | Calendario de efectivo y estados de pago | Fecha, saldo y próxima acción primero; distinguir cobros de pagos en títulos y accesos |
| Tiendas y franquicias | Reutilización de componentes de caja | Priorizar venta/cobro/cierre; controles táctiles y retorno al contexto del turno |
| Nómina | Cuatro áreas que ya agrupan las 13 pestañas | Mantener área/pestaña y contexto de empresa, empleado y período |
| Reportes | Tablas y exportaciones | Filtros comunes, período y ámbito visibles; resúmenes antes del detalle |
| Mantenimiento y avisos | Estados, evidencias y pendientes | Bandeja por responsable/vencimiento y acceso directo a resolver |
| Administración | Permisos por rol/persona y empresas | Separar configuración habitual de migración/sincronización; explicar alcance antes de guardar |
| Acceso y brief público | Separación de rutas públicas | Validar móvil, errores, teclado y legibilidad del brief; pendiente inspección visual |

Estas propuestas requieren contrastar frecuencia de uso con el equipo; no presuponen que todos los usuarios necesiten todos los módulos.

## Orden de ejecución recomendado

1. **Corregir fricciones verificables:** formulario de Clientes, estados del dashboard y foco de diálogos. Cambios acotados con beneficio directo.
2. **Mejorar el trabajo diario:** conservar contexto, simplificar Existencias y ajustar etiquetas de navegación.
3. **Unificar presentación:** cabeceras, filtros, botones, estados, tablas, formularios y modales compartidos. Aplicar primero a una pantalla representativa y validar antes de extenderlo.
4. **Refinar flujos complejos:** Contratos, entregas, recepciones, conteos, caja y nómina. Conservar las reglas actuales de permisos y auditoría.
5. **Validar con tareas reales:** localizar un SKU, recuperar una búsqueda, registrar un contrato, recibir parcialmente, retomar un conteo y consultar un rol de pago.

## Verificación antes de publicar

- Probar escritorio de 1366 px y móvil de 390 px, además de zoom y ambos temas. Son tamaños de prueba propuestos, no resultados obtenidos.
- Comprobar teclado, foco, mensajes de error y recuperación tras fallo de carga.
- Usar datos de prueba para formularios y operaciones; verificar que no hay pérdida de entradas al navegar.
- Medir tiempo, clics y errores en las tareas anteriores antes y después. Fijar objetivos tras obtener la línea base, sin inventar porcentajes de mejora.
- Ejecutar verificaciones técnicas adecuadas a los cambios implementados. Este informe no cambia código ejecutable y no constituye una compilación ni una prueba funcional.
