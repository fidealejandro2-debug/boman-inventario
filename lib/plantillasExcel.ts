import type { Cell, DataValidation, Worksheet } from "exceljs";

export type ReglaPlantilla =
  | { tipo: "lista"; valores: string[] }
  | { tipo: "entero"; minimo?: number; maximo?: number }
  | { tipo: "decimal"; minimo?: number; maximo?: number }
  | { tipo: "fecha"; desde?: string; hasta?: string }
  | { tipo: "longitud"; maximo: number };

export type ColumnaPlantilla = {
  encabezado: string;
  ancho?: number;
  obligatoria?: boolean;
  ayuda: string;
  regla?: ReglaPlantilla;
};

export type InstruccionPlantilla = {
  campo: string;
  regla: string;
  ejemplo?: string;
};

type ConfiguracionPlantilla = {
  archivo: string;
  titulo: string;
  descripcion: string;
  columnas: ColumnaPlantilla[];
  ejemplos: Record<string, string | number | null>[];
  instrucciones: InstruccionPlantilla[];
  filasDisponibles?: number;
};

const AZUL = "FF1F4E78";
const AZUL_CLARO = "FFDCE6F1";
const AMARILLO = "FFFFF2CC";
const BLANCO = "FFFFFFFF";
const GRIS = "FF667085";

function fechaExcel(valor: string) {
  const [anio, mes, dia] = valor.split("-").map(Number);
  return new Date(anio, mes - 1, dia);
}

function aplicarRegla(
  celda: Cell,
  columna: ColumnaPlantilla,
  formulaCatalogo?: string,
) {
  const comun = {
    allowBlank: !columna.obligatoria,
    showErrorMessage: true,
    errorStyle: "stop" as const,
    errorTitle: "Valor no permitido",
    error: columna.ayuda.slice(0, 225),
    showInputMessage: true,
    promptTitle: columna.encabezado,
    prompt: columna.ayuda.slice(0, 225),
  };
  let validacion: DataValidation | undefined;
  if (columna.regla?.tipo === "lista" && formulaCatalogo) {
    validacion = { ...comun, type: "list", formulae: [formulaCatalogo] };
  } else if (columna.regla?.tipo === "entero") {
    validacion = {
      ...comun,
      type: "whole",
      operator: "between",
      formulae: [columna.regla.minimo ?? 0, columna.regla.maximo ?? 999999999],
    };
  } else if (columna.regla?.tipo === "decimal") {
    validacion = {
      ...comun,
      type: "decimal",
      operator: "between",
      formulae: [columna.regla.minimo ?? 0, columna.regla.maximo ?? 999999999],
    };
  } else if (columna.regla?.tipo === "fecha") {
    validacion = {
      ...comun,
      type: "date",
      operator: "between",
      formulae: [
        fechaExcel(columna.regla.desde ?? "2000-01-01"),
        fechaExcel(columna.regla.hasta ?? "2100-12-31"),
      ],
    };
  } else if (columna.regla?.tipo === "longitud") {
    validacion = {
      ...comun,
      type: "textLength",
      operator: "lessThanOrEqual",
      formulae: [columna.regla.maximo],
    };
  }
  if (validacion) celda.dataValidation = validacion;
}

function ajustarHoja(hoja: Worksheet, columnas: ColumnaPlantilla[]) {
  hoja.views = [{ state: "frozen", ySplit: 1 }];
  hoja.autoFilter = {
    from: { row: 1, column: 1 },
    to: { row: 1, column: columnas.length },
  };
  hoja.columns = columnas.map((columna) => ({
    key: columna.encabezado,
    width: columna.ancho ?? Math.max(14, columna.encabezado.length + 3),
  }));
  const encabezado = hoja.getRow(1);
  encabezado.height = 28;
  encabezado.eachCell((celda, numero) => {
    celda.font = { bold: true, color: { argb: BLANCO } };
    celda.fill = { type: "pattern", pattern: "solid", fgColor: { argb: AZUL } };
    celda.alignment = { vertical: "middle", horizontal: "center", wrapText: true };
    celda.note = columnas[numero - 1].ayuda;
  });
}

export async function descargarPlantillaExcel(config: ConfiguracionPlantilla) {
  const { Workbook } = await import("exceljs");
  const libro = new Workbook();
  libro.creator = "Boman Gestión Empresarial";
  libro.created = new Date();
  libro.modified = new Date();
  libro.title = config.titulo;
  libro.subject = config.descripcion;

  const carga = libro.addWorksheet("CARGA", {
    properties: { defaultRowHeight: 20 },
  });
  ajustarHoja(carga, config.columnas);
  config.ejemplos.forEach((ejemplo) => carga.addRow(ejemplo));

  const catalogos = libro.addWorksheet("CATALOGOS");
  const columnasCatalogo = config.columnas.filter(
    (columna) => columna.regla?.tipo === "lista" && columna.regla.valores.length,
  );
  columnasCatalogo.forEach((columna, indice) => {
    const numero = indice + 1;
    catalogos.getCell(1, numero).value = columna.encabezado;
    catalogos.getCell(1, numero).font = { bold: true, color: { argb: BLANCO } };
    catalogos.getCell(1, numero).fill = {
      type: "pattern",
      pattern: "solid",
      fgColor: { argb: AZUL },
    };
    columna.regla!.tipo === "lista" && columna.regla!.valores.forEach((valor, fila) => {
      catalogos.getCell(fila + 2, numero).value = valor;
    });
    catalogos.getColumn(numero).width = Math.max(
      18,
      columna.encabezado.length + 3,
      ...((columna.regla!.tipo === "lista" ? columna.regla!.valores : []).map((v) => v.length + 2)),
    );
  });
  catalogos.views = [{ state: "frozen", ySplit: 1 }];

  const formulaPorCampo = new Map<string, string>();
  columnasCatalogo.forEach((columna, indice) => {
    const letra = catalogos.getColumn(indice + 1).letter;
    const total = columna.regla!.tipo === "lista" ? columna.regla!.valores.length : 0;
    formulaPorCampo.set(columna.encabezado, `'CATALOGOS'!$${letra}$2:$${letra}$${total + 1}`);
  });

  const limite = Math.max(config.filasDisponibles ?? 5000, config.ejemplos.length + 1);
  config.columnas.forEach((columna, indice) => {
    const numeroColumna = indice + 1;
    for (let fila = 2; fila <= limite + 1; fila++) {
      const celda = carga.getCell(fila, numeroColumna);
      aplicarRegla(celda, columna, formulaPorCampo.get(columna.encabezado));
      if (columna.regla?.tipo === "fecha") celda.numFmt = "yyyy-mm-dd";
      if (columna.regla?.tipo === "decimal") celda.numFmt = "0.00";
      if (columna.encabezado.includes("IDENTIFICACION") || columna.encabezado.includes("RUC")) {
        celda.numFmt = "@";
      }
    }
  });

  const instrucciones = libro.addWorksheet("INSTRUCCIONES");
  instrucciones.columns = [
    { key: "campo", width: 24 },
    { key: "regla", width: 85 },
    { key: "ejemplo", width: 32 },
  ];
  instrucciones.addRow([config.titulo, config.descripcion, ""]);
  instrucciones.mergeCells("A1:C1");
  instrucciones.getCell("A1").font = { bold: true, size: 16, color: { argb: BLANCO } };
  instrucciones.getCell("A1").fill = { type: "pattern", pattern: "solid", fgColor: { argb: AZUL } };
  instrucciones.getCell("A1").alignment = { vertical: "middle" };
  instrucciones.getRow(1).height = 30;
  instrucciones.addRow(["Antes de cargar", config.descripcion, ""]);
  instrucciones.getRow(2).font = { italic: true, color: { argb: GRIS } };
  instrucciones.addRow(["CAMPO", "REGLA", "EJEMPLO"]);
  const filaCabecera = instrucciones.getRow(3);
  filaCabecera.eachCell((celda) => {
    celda.font = { bold: true };
    celda.fill = { type: "pattern", pattern: "solid", fgColor: { argb: AZUL_CLARO } };
  });
  config.instrucciones.forEach((item) => {
    instrucciones.addRow([item.campo, item.regla, item.ejemplo ?? ""]);
  });
  instrucciones.addRow([
    "IMPORTANTE",
    "Las listas y mensajes de Excel previenen errores comunes. El sistema volverá a validar cada fila antes de guardar.",
    "No cambies los encabezados.",
  ]);
  const ultima = instrucciones.lastRow;
  if (ultima) {
    ultima.font = { bold: true };
    ultima.fill = { type: "pattern", pattern: "solid", fgColor: { argb: AMARILLO } };
  }
  instrucciones.views = [{ state: "frozen", ySplit: 3 }];
  instrucciones.eachRow((fila) => {
    fila.alignment = { vertical: "top", wrapText: true };
  });

  const contenido = await libro.xlsx.writeBuffer();
  const blob = new Blob([contenido as BlobPart], {
    type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  });
  const enlace = document.createElement("a");
  enlace.href = URL.createObjectURL(blob);
  enlace.download = config.archivo.endsWith(".xlsx") ? config.archivo : `${config.archivo}.xlsx`;
  enlace.click();
  setTimeout(() => URL.revokeObjectURL(enlace.href), 1000);
}
