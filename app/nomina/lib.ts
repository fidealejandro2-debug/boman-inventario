// Utilidades compartidas por las pestañas de Nómina.

export const dinero = (v: number | null | undefined) =>
  v === null || v === undefined
    ? "—"
    : Number(v).toLocaleString("es-EC", { style: "currency", currency: "USD" });

export const soloFecha = (v: string | null | undefined) =>
  v ? new Date(v + "T00:00:00").toLocaleDateString("es-EC") : "—";

export const hoyISO = () => new Date().toISOString().slice(0, 10);

export type Empleado = {
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  estado: string;
  afiliado: boolean | null;
  empresa_afiliacion_id: string | null;
  empresa_pagadora_id: string | null;
};

export type Empresa = { id: string; razon_social: string; ruc: string; activo: boolean };

export const ETIQUETA_AUSENCIA: Record<string, string> = {
  vacaciones: "Vacaciones",
  enfermedad_iess: "Enfermedad IESS",
  enfermedad_particular: "Enfermedad particular",
  permiso_con_sueldo: "Permiso con sueldo",
  permiso_sin_sueldo: "Permiso sin sueldo",
  maternidad: "Maternidad",
  paternidad: "Paternidad",
  lactancia: "Lactancia",
  calamidad_domestica: "Calamidad doméstica",
  falta_injustificada: "Falta injustificada",
  suspension_disciplinaria: "Suspensión disciplinaria",
};

export const ETIQUETA_NOVEDAD: Record<string, string> = {
  llamado_atencion: "Llamado de atención",
  amonestacion_escrita: "Amonestación escrita",
  memorando: "Memorando",
  acta_compromiso: "Acta de compromiso",
  felicitacion: "Felicitación",
  sancion_economica: "Sanción económica",
  solicitud_visto_bueno: "Solicitud de visto bueno",
};

export const ETIQUETA_ORIGEN_DESCUENTO: Record<string, string> = {
  anticipo: "Anticipo",
  prestamo_iess: "Préstamo IESS",
  prestamo_quirografario: "Quirografario",
  prestamo_hipotecario: "Hipotecario",
  prestamo_empresa: "Préstamo de la empresa",
  multa: "Multa",
  judicial: "Retención judicial",
  uniforme: "Uniforme",
  consumo_interno: "Consumo interno",
  otro: "Otro",
};

// Traduce el error crudo de Postgres a algo legible. Los RPC de nómina ya
// devuelven mensajes en español; esto solo limpia el prefijo del driver.
export function mensajeError(e: { message?: string } | null): string {
  const raw = e?.message ?? "Error desconocido";
  return raw.replace(/^.*?violates row-level security.*$/i, "No tienes permiso para esta acción.");
}
