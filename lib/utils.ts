export function exportarCSV(nombreArchivo: string, filas: Record<string, any>[]) {
  if (!filas.length) return;

  const columnas = Object.keys(filas[0]);
  const escapar = (v: any) => {
    if (v === null || v === undefined) return "";
    const s = String(v);
    return /[",\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };

  const csv = [
    columnas.join(";"),
    ...filas.map((f) => columnas.map((c) => escapar(f[c])).join(";")),
  ].join("\n");

  // BOM para que Excel abra bien los acentos
  const blob = new Blob(["\uFEFF" + csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `${nombreArchivo}_${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

export function fecha(v: string) {
  return new Date(v).toLocaleString("es-EC", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export const ETIQUETA_TIPO: Record<string, string> = {
  entrada: "Entrada",
  salida: "Salida",
  transferencia_envio: "Despacho",
  transferencia_recibo: "Recepción",
  transferencia_retorno: "Retorno de transferencia",
  cuarentena_liberacion: "Liberación de cuarentena",
  movimiento_manual_reversa: "Reversa de movimiento manual",
  ajuste: "Ajuste",
  venta_xml: "Venta XML",
  devolucion_venta: "Devolución de venta",
  venta_xml_reversa: "Reversa técnica XML",
  compra_recepcion: "Recepción de compra",
  compra_recepcion_reversa: "Reversa de recepción de compra",
  produccion_salida_material: "Material entregado a producción",
  produccion_retorno_material: "Sobrante retornado de producción",
  produccion_ingreso_terminado: "Ingreso de producción terminada",
};
