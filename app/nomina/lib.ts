// Utilidades compartidas por las pestañas de Nómina.

import { fechaISOEcuador } from "@/lib/utils";
export { fechaISOEcuador } from "@/lib/utils";

export const dinero = (v: number | null | undefined) =>
  v === null || v === undefined
    ? "—"
    : Number(v).toLocaleString("es-EC", { style: "currency", currency: "USD" });

export const soloFecha = (v: string | null | undefined) =>
  v ? new Date(v + "T00:00:00").toLocaleDateString("es-EC") : "—";

// Las fechas laborales usan Ecuador; UTC cambia de día desde las 19:00.
export const hoyISO = () => fechaISOEcuador();

export type EmpleadoEdicion = {
  id: string;
  grupo_id: string;
  tipo_identificacion: string;
  identificacion: string;
  nombres: string;
  apellidos: string;
  fecha_nacimiento: string | null;
  estado_civil: string | null;
  direccion: string | null;
  telefono: string | null;
  email: string | null;
  contacto_emergencia_nombre: string | null;
  contacto_emergencia_telefono: string | null;
  fecha_ingreso_real: string;
  cargo: string;
  departamento_id: string | null;
  tipo_contrato: string;
  forma_pago: string;
  banco: string | null;
  tipo_cuenta: string | null;
  numero_cuenta: string | null;
  observacion: string | null;
};

export type Empleado = {
  empleado_id: string;
  grupo_id: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  departamento_id: string | null;
  departamento_nombre: string | null;
  estado: string;
  afiliado: boolean | null;
  empresa_afiliacion_id: string | null;
  empresa_pagadora_id: string | null;
};

export type Empresa = { id: string; razon_social: string; ruc: string; activo: boolean };

export type Departamento = {
  departamento_id: string;
  grupo_id: string;
  codigo: string;
  nombre: string;
  descripcion: string | null;
  activo: boolean;
  empleados_total: number;
  empleados_activos: number;
};

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

export const ETIQUETA_SALIDA: Record<string, string> = {
  renuncia: "Renuncia",
  despido: "Despido",
  visto_bueno: "Visto bueno",
  fin_contrato: "Fin de contrato",
  abandono: "Abandono",
  mutuo_acuerdo: "Mutuo acuerdo",
};

export const MOTIVOS_SUELDO = [
  { valor: "aumento_desempeno", etiqueta: "Aumento por desempeño" },
  { valor: "ajuste_sbu", etiqueta: "Ajuste por SBU" },
  { valor: "promocion", etiqueta: "Promoción" },
  { valor: "reestructuracion", etiqueta: "Reestructuración" },
  { valor: "acuerdo_partes", etiqueta: "Acuerdo de partes" },
  { valor: "cambio_pagadora", etiqueta: "Cambio de empresa pagadora" },
  { valor: "reduccion_acordada", etiqueta: "Reducción acordada" },
  { valor: "correccion_error", etiqueta: "Corrección de error" },
];

export const MOTIVOS_AFILIACION = [
  { valor: "cambio_ruc", etiqueta: "Cambio de RUC afiliador" },
  { valor: "ajuste_sueldo_declarado", etiqueta: "Ajuste del sueldo declarado" },
  { valor: "desafiliacion", etiqueta: "Desafiliación" },
  { valor: "reafiliacion", etiqueta: "Reafiliación" },
  { valor: "correccion_error", etiqueta: "Corrección de error" },
];

export const ETIQUETA_TABLA_AUDITORIA: Record<string, string> = {
  empleados: "Personal",
  empleado_compensacion: "Sueldo real",
  empleado_afiliaciones: "Afiliación",
  nomina_parametros: "Parámetros",
};

export const ETIQUETA_CAMPO_AUDITORIA: Record<string, string> = {
  "(alta)": "Alta completa",
  numero_cuenta: "Número de cuenta",
  banco: "Banco",
  tipo_cuenta: "Tipo de cuenta",
  forma_pago: "Forma de pago",
  identificacion: "Identificación",
  sueldo_real: "Sueldo real",
  sueldo_declarado: "Sueldo declarado",
  afiliado: "Afiliado",
  empresa_id: "RUC afiliador",
  empresa_pagadora_id: "Empresa pagadora",
  fecha_afiliacion: "Fecha de afiliación",
  fecha_ingreso_real: "Fecha de ingreso",
  fecha_salida: "Fecha de salida",
  estado: "Estado",
  cargo: "Cargo",
  departamento_id: "Departamento",
  salario_basico_unificado: "SBU",
};

// Traduce el error crudo de Postgres a algo legible. Los RPC de nómina ya
// devuelven mensajes en español; esto solo limpia el prefijo del driver.
export function mensajeError(e: { message?: string } | null): string {
  const raw = e?.message ?? "Error desconocido";
  return raw.replace(/^.*?violates row-level security.*$/i, "No tienes permiso para esta acción.");
}
