// Utilidades del panel de franquicia.

export const dinero = (v: number | null | undefined) =>
  v === null || v === undefined
    ? "—"
    : Number(v).toLocaleString("es-EC", { style: "currency", currency: "USD" });

/**
 * Fecha de hoy en la zona del navegador.
 *
 * No usa toISOString: eso convierte a UTC y en Ecuador (UTC-5) devuelve el día
 * siguiente a partir de las 19:00, con lo que una venta de la tarde quedaría
 * fechada mañana y la base la rechazaría por futura.
 */
export const hoyLocalISO = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
    d.getDate()
  ).padStart(2, "0")}`;
};

export const MEDIOS_PAGO = [
  { valor: "efectivo", etiqueta: "Efectivo" },
  { valor: "transferencia", etiqueta: "Transferencia" },
  { valor: "tarjeta", etiqueta: "Tarjeta" },
  { valor: "mixto", etiqueta: "Mixto" },
  { valor: "otro", etiqueta: "Otro" },
];

export const CATEGORIAS_CAJA = [
  { valor: "venta", etiqueta: "Venta", tipo: "ingreso" },
  { valor: "cobro_pendiente", etiqueta: "Cobro pendiente", tipo: "ingreso" },
  { valor: "aporte_socio", etiqueta: "Aporte del socio", tipo: "ingreso" },
  { valor: "otro_ingreso", etiqueta: "Otro ingreso", tipo: "ingreso" },
  { valor: "arriendo", etiqueta: "Arriendo", tipo: "egreso" },
  { valor: "servicios", etiqueta: "Servicios básicos", tipo: "egreso" },
  { valor: "sueldos", etiqueta: "Sueldos", tipo: "egreso" },
  { valor: "transporte", etiqueta: "Transporte", tipo: "egreso" },
  { valor: "suministros", etiqueta: "Suministros", tipo: "egreso" },
  { valor: "deposito_banco", etiqueta: "Depósito bancario", tipo: "egreso" },
  { valor: "otro_egreso", etiqueta: "Otro egreso", tipo: "egreso" },
];

export function mensajeError(e: { message?: string } | null): string {
  const raw = e?.message ?? "Error desconocido";
  // PostgREST responde "Could not find the function ... in the schema cache"
  // cuando falta ejecutar la migración que la crea. El mensaje crudo hace
  // pensar en un fallo de la interfaz y no en un paso de instalación pendiente.
  const falta = raw.match(/Could not find the function public\.([a-z0-9_]+)/i);
  if (falta) {
    const version = falta[1].match(/_v(\d+)$/);
    return (
      `Falta instalar en la base la función ${falta[1]}` +
      (version ? `, que viene en la migración v${version[1]}.` : ".") +
      " Ejecuta los archivos pendientes de sql/ en orden y vuelve a intentar."
    );
  }
  return raw.replace(
    /^.*?violates row-level security.*$/i,
    "No tienes permiso para esta acción en este local."
  );
}
