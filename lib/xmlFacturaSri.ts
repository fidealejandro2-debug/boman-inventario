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

export type LineaCompraSri = LineaFacturaSri & {
  tarifaIva: number;
  valorIva: number;
};

export type FacturaCompraSri = Omit<FacturaSri, "lineas"> & {
  compradorRuc: string;
  baseCero: number;
  baseGravada: number;
  tarifaGravada: number;
  baseNoObjeto: number;
  baseExenta: number;
  montoIva: number;
  montoIce: number;
  propina: number;
  formaPago: string | null;
  lineas: LineaCompraSri[];
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

function redondear(valor: number) {
  return Math.round((valor + Number.EPSILON) * 100) / 100;
}

export function parsearFacturaCompraSri(contenido: string): FacturaCompraSri {
  const comun = parsearFacturaSri(contenido);
  const exterior = documentoXml(contenido, "El archivo");
  const autorizacion = Array.from(exterior.querySelectorAll("*")).find(
    (nodo) => nodo.localName === "autorizacion"
  );
  const comprobanteTexto = autorizacion ? texto(hijo(autorizacion, "comprobante")) : null;
  const interior = comprobanteTexto ? documentoXml(comprobanteTexto, "El comprobante interno") : exterior;
  const factura = Array.from(interior.querySelectorAll("*")).find((nodo) => nodo.localName === "factura")
    ?? (interior.documentElement.localName === "factura" ? interior.documentElement : null);
  const info = factura ? hijo(factura, "infoFactura") : null;
  const detalles = factura ? hijo(factura, "detalles") : null;
  if (!factura || !info || !detalles) throw new Error("La factura de compra no contiene cabecera o detalle.");

  const compradorRuc = (texto(hijo(info, "identificacionComprador")) ?? "").replace(/\D/g, "");
  if (!/^\d{13}$/.test(compradorRuc)) {
    throw new Error("La identificación del comprador debe ser el RUC de 13 dígitos de una empresa configurada.");
  }

  let baseCero = 0;
  let baseGravada = 0;
  let baseNoObjeto = 0;
  let baseExenta = 0;
  let montoIva = 0;
  let montoIce = 0;
  const tarifasPositivas: number[] = [];
  const totalConImpuestos = hijo(info, "totalConImpuestos");
  const impuestosTotales = totalConImpuestos
    ? hijos(totalConImpuestos).filter((nodo) => nodo.localName === "totalImpuesto")
    : [];
  impuestosTotales.forEach((impuesto) => {
    const codigo = texto(hijo(impuesto, "codigo")) ?? "";
    const codigoPorcentaje = texto(hijo(impuesto, "codigoPorcentaje")) ?? "";
    const base = numero(hijo(impuesto, "baseImponible"), "base imponible");
    const valor = numero(hijo(impuesto, "valor"), "valor de impuesto");
    const tarifaTexto = texto(hijo(impuesto, "tarifa"));
    const tarifaDeclarada = tarifaTexto === null ? null : Number(tarifaTexto);
    const tarifa = tarifaDeclarada !== null && Number.isFinite(tarifaDeclarada)
      ? tarifaDeclarada
      : base > 0 ? redondear(valor * 100 / base) : 0;
    if (codigo === "2") {
      montoIva += valor;
      if (codigoPorcentaje === "6") baseNoObjeto += base;
      else if (codigoPorcentaje === "7") baseExenta += base;
      else if (tarifa > 0 || valor > 0) {
        baseGravada += base;
        if (tarifa > 0) tarifasPositivas.push(tarifa);
      } else baseCero += base;
    } else if (codigo === "3") {
      montoIce += valor;
    }
  });

  const totalSinImpuestos = numero(hijo(info, "totalSinImpuestos"), "total sin impuestos");
  const basesIdentificadas = redondear(baseCero + baseGravada + baseNoObjeto + baseExenta);
  const diferenciaBase = redondear(totalSinImpuestos - basesIdentificadas);
  if (Math.abs(diferenciaBase) <= 0.02) baseCero = redondear(baseCero + diferenciaBase);
  else if (!impuestosTotales.length) baseCero = redondear(totalSinImpuestos);
  else throw new Error("Las bases tributarias del XML no cuadran con el total sin impuestos.");

  const nodosDetalle = hijos(detalles).filter((nodo) => nodo.localName === "detalle");
  const lineas = comun.lineas.map((linea, indice) => {
    const nodo = nodosDetalle[indice];
    const impuestos = nodo ? hijo(nodo, "impuestos") : null;
    const iva = impuestos
      ? hijos(impuestos).filter((item) => item.localName === "impuesto").find(
          (item) => texto(hijo(item, "codigo")) === "2"
        )
      : null;
    const valor = iva ? Number(texto(hijo(iva, "valor")) ?? 0) : 0;
    const base = iva ? Number(texto(hijo(iva, "baseImponible")) ?? linea.totalSinImpuesto) : 0;
    const tarifaTexto = iva ? texto(hijo(iva, "tarifa")) : null;
    const tarifaDeclarada = tarifaTexto === null ? null : Number(tarifaTexto);
    const tarifa = tarifaDeclarada !== null && Number.isFinite(tarifaDeclarada)
      ? tarifaDeclarada
      : base > 0 ? redondear(valor * 100 / base) : 0;
    if (!Number.isFinite(base) || !Number.isFinite(tarifa) || !Number.isFinite(valor)) {
      throw new Error(`La línea ${linea.numeroLinea} contiene un IVA inválido.`);
    }
    return { ...linea, tarifaIva: tarifa, valorIva: redondear(valor) };
  });

  const propinaTexto = texto(hijo(info, "propina"));
  const propina = propinaTexto === null ? 0 : Number(propinaTexto);
  const totalCalculado = redondear(
    baseCero + baseGravada + baseNoObjeto + baseExenta + montoIva + montoIce + propina
  );
  if (!Number.isFinite(propina) || Math.abs(totalCalculado - redondear(comun.importeTotal)) > 0.02) {
    throw new Error("El total del XML no cuadra con sus bases, impuestos y propina.");
  }
  const pagos = hijo(info, "pagos");
  const primerPago = pagos ? hijos(pagos).find((nodo) => nodo.localName === "pago") : null;

  return {
    ...comun,
    compradorRuc,
    baseCero: redondear(baseCero),
    baseGravada: redondear(baseGravada),
    tarifaGravada: tarifasPositivas[0] ?? 0,
    baseNoObjeto: redondear(baseNoObjeto),
    baseExenta: redondear(baseExenta),
    montoIva: redondear(montoIva),
    montoIce: redondear(montoIce),
    propina: redondear(propina),
    formaPago: primerPago ? texto(hijo(primerPago, "formaPago")) : null,
    lineas,
  };
}

export async function calcularHashXml(contenido: string) {
  const bytes = new TextEncoder().encode(contenido);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
