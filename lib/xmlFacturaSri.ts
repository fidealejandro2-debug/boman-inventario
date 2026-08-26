export type LineaFacturaSri = {
  numeroLinea: number;
  codigoPrincipal: string | null;
  codigoAuxiliar: string | null;
  descripcion: string;
  cantidad: number;
  precioUnitario: number;
  descuento: number;
  totalSinImpuesto: number;
};

export type FacturaSri = {
  estadoSri: string;
  claveAcceso: string;
  numeroAutorizacion: string | null;
  fechaAutorizacion: string | null;
  emisorRuc: string;
  razonSocialEmisor: string;
  establecimiento: string;
  puntoEmision: string;
  secuencial: string;
  numeroDocumento: string;
  fechaEmision: string;
  importeTotal: number;
  lineas: LineaFacturaSri[];
};

function hijos(elemento: Element) {
  return Array.from(elemento.children);
}

function hijo(elemento: Element, nombre: string) {
  return hijos(elemento).find((nodo) => nodo.localName === nombre) ?? null;
}

function descendiente(elemento: ParentNode, nombre: string) {
  return Array.from(elemento.querySelectorAll("*")).find((nodo) => nodo.localName === nombre) ?? null;
}

function texto(elemento: Element | null) {
  const valor = elemento?.textContent?.trim();
  return valor || null;
}

function numero(elemento: Element | null, campo: string) {
  const valor = Number(texto(elemento));
  if (!Number.isFinite(valor)) throw new Error(`El XML contiene un valor inválido en ${campo}.`);
  return valor;
}

function documentoXml(contenido: string, etiqueta: string) {
  const documento = new DOMParser().parseFromString(contenido, "application/xml");
  if (documento.querySelector("parsererror")) {
    throw new Error(`${etiqueta} no contiene un XML válido.`);
  }
  return documento;
}

function fechaSriAIso(valor: string | null) {
  if (!valor) throw new Error("El XML no contiene la fecha de emisión.");
  const partes = valor.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (!partes) throw new Error("La fecha de emisión del XML no tiene el formato esperado.");
  return `${partes[3]}-${partes[2]}-${partes[1]}`;
}

function fechaHoraAIso(valor: string | null) {
  if (!valor) return null;
  const fecha = new Date(valor);
  return Number.isNaN(fecha.getTime()) ? null : fecha.toISOString();
}

export function parsearFacturaSri(contenido: string): FacturaSri {
  if (contenido.length > 5_000_000) {
    throw new Error("El XML supera el límite permitido de 5 MB.");
  }

  const exterior = documentoXml(contenido, "El archivo");
  const autorizacion = Array.from(exterior.querySelectorAll("*")).find(
    (nodo) => nodo.localName === "autorizacion"
  );

  const estadoSri = autorizacion
    ? (texto(hijo(autorizacion, "estado")) ?? "").toUpperCase()
    : "AUTORIZADO";
  if (estadoSri !== "AUTORIZADO") {
    throw new Error(`El comprobante está en estado ${estadoSri || "DESCONOCIDO"}; solo se aceptan XML AUTORIZADOS.`);
  }

  const comprobanteTexto = autorizacion ? texto(hijo(autorizacion, "comprobante")) : null;
  const interior = comprobanteTexto ? documentoXml(comprobanteTexto, "El comprobante interno") : exterior;
  const factura = Array.from(interior.querySelectorAll("*")).find((nodo) => nodo.localName === "factura")
    ?? (interior.documentElement.localName === "factura" ? interior.documentElement : null);
  if (!factura) throw new Error("El XML no contiene una factura electrónica del SRI.");

  const tributaria = hijo(factura, "infoTributaria");
  const facturaInfo = hijo(factura, "infoFactura");
  const detalles = hijo(factura, "detalles");
  if (!tributaria || !facturaInfo || !detalles) {
    throw new Error("La factura no contiene su información tributaria, cabecera o detalle.");
  }

  const claveAcceso = texto(hijo(tributaria, "claveAcceso"))
    ?? texto(descendiente(exterior, "claveAccesoConsultada"))
    ?? "";
  const emisorRuc = texto(hijo(tributaria, "ruc")) ?? "";
  const razonSocialEmisor = texto(hijo(tributaria, "razonSocial")) ?? "";
  const establecimiento = texto(hijo(tributaria, "estab")) ?? "";
  const puntoEmision = texto(hijo(tributaria, "ptoEmi")) ?? "";
  const secuencial = texto(hijo(tributaria, "secuencial")) ?? "";

  if (!/^\d{49}$/.test(claveAcceso)) throw new Error("La clave de acceso de la factura no es válida.");
  if (!/^\d{13}$/.test(emisorRuc)) throw new Error("El RUC emisor de la factura no es válido.");
  if (!razonSocialEmisor) throw new Error("La factura no contiene la razón social del emisor.");
  if (!/^\d{3}$/.test(establecimiento) || !/^\d{3}$/.test(puntoEmision) || !/^\d{9}$/.test(secuencial)) {
    throw new Error("La numeración de la factura no es válida.");
  }

  const nodosDetalle = hijos(detalles).filter((nodo) => nodo.localName === "detalle");
  if (!nodosDetalle.length) throw new Error("La factura no contiene productos o servicios.");
  const lineas = nodosDetalle.map((detalle, indice) => {
    const descripcion = texto(hijo(detalle, "descripcion")) ?? "";
    if (!descripcion) throw new Error(`La línea ${indice + 1} no contiene descripción.`);
    const cantidad = numero(hijo(detalle, "cantidad"), `cantidad de la línea ${indice + 1}`);
    if (cantidad <= 0) throw new Error(`La cantidad de la línea ${indice + 1} debe ser mayor que cero.`);
    return {
      numeroLinea: indice + 1,
      codigoPrincipal: texto(hijo(detalle, "codigoPrincipal")),
      codigoAuxiliar: texto(hijo(detalle, "codigoAuxiliar")),
      descripcion,
      cantidad,
      precioUnitario: numero(hijo(detalle, "precioUnitario"), `precio de la línea ${indice + 1}`),
      descuento: numero(hijo(detalle, "descuento"), `descuento de la línea ${indice + 1}`),
      totalSinImpuesto: numero(hijo(detalle, "precioTotalSinImpuesto"), `total de la línea ${indice + 1}`),
    };
  });

  const importeTotal = numero(hijo(facturaInfo, "importeTotal"), "importe total");
  return {
    estadoSri,
    claveAcceso,
    numeroAutorizacion: autorizacion ? texto(hijo(autorizacion, "numeroAutorizacion")) : claveAcceso,
    fechaAutorizacion: autorizacion ? fechaHoraAIso(texto(hijo(autorizacion, "fechaAutorizacion"))) : null,
    emisorRuc,
    razonSocialEmisor,
    establecimiento,
    puntoEmision,
    secuencial,
    numeroDocumento: `${establecimiento}-${puntoEmision}-${secuencial}`,
    fechaEmision: fechaSriAIso(texto(hijo(facturaInfo, "fechaEmision"))),
    importeTotal,
    lineas,
  };
}

export async function calcularHashXml(contenido: string) {
  const bytes = new TextEncoder().encode(contenido);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
