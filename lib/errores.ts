// Un solo sitio para traducir el error de Supabase a algo que el usuario pueda
// accionar.
//
// El caso que se repetía diecisiete veces, escrito distinto cada vez: cuando
// falta una migración, PostgREST responde "Could not find the function
// public.X in the schema cache". Eso no le dice nada a nadie. Cada pantalla lo
// detectaba con su propio `includes("nombre_de_la_rpc")` y devolvía su propia
// redacción, así que el mismo problema se veía de diecisiete formas y algunas
// pantallas ni lo detectaban: mostraban el texto crudo de PostgREST.
//
// Aquí se reconoce por el patrón, no por el nombre concreto, y el mensaje dice
// qué archivo hay que correr.

type ErrorSupabase = { message?: string; code?: string } | null | undefined;

/** La RPC o la columna no existen todavía: casi siempre, una migración sin correr. */
export function esFaltaMigracion(error: ErrorSupabase) {
  const m = error?.message ?? "";
  return /schema cache|could not find the (function|table|column)|does not exist|no existe la (función|funcion|relación)/i.test(m);
}

/**
 * `migracion` es el archivo de sql/ que hace falta. Si se omite, el mensaje
 * igual avisa que falta una migración, que ya es mucho más útil que el texto
 * de PostgREST.
 */
export function mensajeError(error: ErrorSupabase, migracion?: string): string {
  const m = (error?.message ?? "").trim();
  if (!m) return "No se pudo completar la operación. Vuelve a intentarlo.";
  if (esFaltaMigracion(error)) {
    return migracion
      ? `Esta pantalla necesita una migración que todavía no está en la base. Corre sql/${migracion} en Supabase.`
      : "Esta pantalla necesita una migración que todavía no está en la base. Revisa sql/que_migraciones_faltan.sql.";
  }
  // Errores frecuentes de Postgres con un mensaje que el usuario entiende. El
  // resto se muestra tal cual: inventar una redacción para un error que no
  // conocemos esconde información al que tiene que arreglarlo.
  if (/permission denied|no tienes permiso|row-level security/i.test(m)) {
    return m.includes("permiso") ? m : "Tu cuenta no tiene permiso para esta acción.";
  }
  if (/duplicate key|ya existe|unique constraint/i.test(m)) {
    return "Ese registro ya existe. Actualiza la pantalla antes de volver a intentarlo.";
  }
  if (/foreign key|violates foreign key/i.test(m)) {
    return "No se puede completar: hay otro registro que depende de este.";
  }
  if (/jwt|expired|not authenticated/i.test(m)) {
    return "Tu sesión expiró. Vuelve a iniciar sesión.";
  }
  return m;
}
