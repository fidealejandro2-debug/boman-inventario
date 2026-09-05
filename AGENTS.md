# Reglas de interfaz

- Los errores y bloqueos producidos por una acción del usuario deben mostrarse con `mostrarAvisoDialogo` de `components/Dialogo.tsx`; no deben quedar como una franja roja distante en la parte superior de la página.
- Las acciones que necesiten confirmación deben usar `confirmarDialogo`; no se deben usar `window.alert`, `window.confirm` ni `window.prompt`.
- Los motivos auditables deben solicitarse con `pedirMotivoDialogo`. Los mensajes de éxito sí pueden mostrarse dentro de la pantalla.
- Una misma operación expuesta en más de un menú debe conservar las mismas validaciones, permisos y mensajes en todas sus pantallas.
