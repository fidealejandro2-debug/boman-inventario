import { createHash } from "crypto";

/** Formato "BOM-<año>-<NNNN...>" que genera siguienteNumeroContrato_ en Codigo.gs. */
export const REGEX_NUMERO_CONTRATO = /^BOM-\d{4}-\d{4,}$/;

/** Forma cruda de un contrato tal cual lo arma datosContratosApi_() en Codigo.gs. */
export type ContratoCrudo = Record<string, unknown> & {
  numero?: unknown;
  extra?: Record<string, unknown>;
};

export type ContratoTipado = {
  numero: string;
  cliente: string;
  vendedor: string;
  vendedor_responsable: string;
  canal: string;
  estado: string;
  prioridad: string;
  calidad: string;
  prendas_incluidas: string;
  total_prendas: number;
  presupuesto_usd: number | null;
  abono_usd: number | null;
  fecha_ingreso: string | null;
  fecha_inicio_produccion: string | null;
  fecha_salida_produccion: string | null;
  fecha_entrega: string | null;
  fecha_posible_inicio: string | null;
  fecha_posible_entrega: string | null;
  fecha_autorizacion_produccion: string | null;
  tipo_contrato: string;
  reposicion: boolean;
  email_ingresante: string | null;
  datos: ContratoCrudo;
  fila_hash: string;
};

/** Ordena las claves de objetos (recursivo) para que el hash no dependa del
 * orden en que Apps Script serializó el JSON. */
function canonicalizar(valor: unknown): unknown {
  if (Array.isArray(valor)) return valor.map(canonicalizar);
  if (valor && typeof valor === "object") {
    const entrada = valor as Record<string, unknown>;
    return Object.keys(entrada)
      .sort()
      .reduce<Record<string, unknown>>((acc, clave) => {
        acc[clave] = canonicalizar(entrada[clave]);
        return acc;
      }, {});
  }
  return valor;
}

export function hashContrato(crudo: ContratoCrudo): string {
  return createHash("sha256").update(JSON.stringify(canonicalizar(crudo))).digest("hex");
}

/** "" y valores no numéricos se vuelven null en vez de 0 -que 0 sea un 0 real. */
function numeroONull(valor: unknown): number | null {
  if (valor === "" || valor === null || valor === undefined) return null;
  const n = Number(valor);
  return Number.isFinite(n) ? n : null;
}

function texto(valor: unknown): string {
  return valor === null || valor === undefined ? "" : String(valor).trim();
}

/** Codigo.gs ya manda fechas como texto "yyyy-MM-dd" (nunca Date crudo).
 * Se valida el formato en vez de confiar ciegamente: una fecha rota ahí no
 * debe tumbar la fila completa, solo esa fecha queda en null. */
function fechaONull(valor: unknown): string | null {
  const s = texto(valor);
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null;
}

export type ResultadoMapeo =
  | { ok: true; contrato: ContratoTipado }
  | { ok: false; numero: string; mensaje: string };

/** Convierte un contrato crudo de la API de Apps Script en las columnas
 * tipadas para el upsert. Nunca lanza: una fila mal formada se reporta como
 * error y se salta, sin abortar el resto del lote. */
export function mapearContrato(crudo: ContratoCrudo): ResultadoMapeo {
  const numero = texto(crudo.numero);
  if (!REGEX_NUMERO_CONTRATO.test(numero)) {
    return { ok: false, numero: numero || "(sin número)", mensaje: `Número de contrato con formato inválido: "${numero}"` };
  }
  try {
    const contrato: ContratoTipado = {
      numero,
      cliente: texto(crudo.cliente),
      vendedor: texto(crudo.vendedor),
      vendedor_responsable: texto(crudo.vendedorResponsable),
      canal: texto(crudo.canal),
      estado: texto(crudo.estado) || "Ingresado",
      prioridad: texto(crudo.prioridad),
      calidad: texto(crudo.calidad),
      prendas_incluidas: texto(crudo.prendasIncluidas),
      total_prendas: Math.max(0, Math.trunc(numeroONull(crudo.totalPrendas) ?? 0)),
      presupuesto_usd: numeroONull(crudo.presupuestoUsd),
      abono_usd: numeroONull(crudo.abonoUsd),
      fecha_ingreso: fechaONull(crudo.fechaIngreso),
      fecha_inicio_produccion: fechaONull(crudo.fechaInicioProduccion),
      fecha_salida_produccion: fechaONull(crudo.fechaSalidaProduccion),
      fecha_entrega: fechaONull(crudo.fechaEntrega),
      fecha_posible_inicio: fechaONull(crudo.fechaPosibleInicio),
      fecha_posible_entrega: fechaONull(crudo.fechaPosibleEntrega),
      fecha_autorizacion_produccion: fechaONull(crudo.fechaAutorizacionProduccion),
      tipo_contrato: texto(crudo.tipoContrato) || "Normal",
      reposicion: texto(crudo.reposicion).toLowerCase() === "sí" || texto(crudo.reposicion).toLowerCase() === "si",
      email_ingresante: texto(crudo.emailIngresante) || null,
      datos: crudo,
      fila_hash: hashContrato(crudo),
    };
    return { ok: true, contrato };
  } catch (e) {
    return { ok: false, numero, mensaje: e instanceof Error ? e.message : "Error inesperado al mapear el contrato" };
  }
}
