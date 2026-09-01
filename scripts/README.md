# Verificadores estáticos

Cruzan la interfaz contra el SQL sin conectarse a la base. Se ejecutan desde la
raíz del proyecto:

```bash
node scripts/verificar-referencias.js        # RPC y vistas que la UI usa y no existen
node scripts/verificar-revocadas.js          # RPC revocadas a authenticated que la UI sigue llamando
node scripts/verificar-parametros-rpc.js     # parámetros p_* que la función no declara
node scripts/verificar-pantallas-sin-datos.js # pantallas que dependen de una asignación del perfil
node scripts/verificar-estados.js            # comparaciones de estado contra valores que el esquema no admite
```

Cada uno nació de un error real que llegó a producción:

- **referencias** y **revocadas**: `/importar` seguía llamando `importar_stock`
  después de que v12 la revocara. Una migración quita el permiso y la pantalla
  que la usaba queda muerta sin que nada avise.
- **parámetros**: al reemplazar una RPC por su versión siguiente es fácil
  cambiarle la firma. Postgres responde *function does not exist*, que en el
  navegador se ve como un error genérico imposible de rastrear.
- **pantallas sin datos**: el panel de franquicia dejaba a Admin y Control
  frente a un aviso de "no estás asignado a ningún local", porque resolvía el
  local por el almacén del perfil y ellos no tienen ninguno. El permiso les
  abría la puerta a un cuarto vacío.
- **estados**: las ventas válidas aparecían anuladas porque la interfaz
  comparaba contra `vigente` (el estado de caja) y la tabla usa `registrada`.
  Nunca falla en ejecución: simplemente muestra cero para siempre.

Los dos últimos marcan candidatos, no culpables: revisa cada señalado a mano.
Un `estado` local de la interfaz o un `entidad_id` que solo aparece dentro del
nombre de una clave foránea son falsos positivos normales.
