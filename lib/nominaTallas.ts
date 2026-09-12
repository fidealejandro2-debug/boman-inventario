// Comparar la nómina de jugadores contra la tabla de tallas.
//
// Las dos describen lo mismo desde dos lados, y pueden separarse sin que nadie
// lo note: se importa la nómina por Excel y luego alguien corrige una talla en
// la matriz, o se edita un jugador después de haber cuadrado las tallas. El
// total sigue dando igual —10 y 10— pero son 10 tallas M contra 10 tallas L, y
// el taller corta lo que dice la matriz.
//
// Ese es el caso que un control de totales NO detecta, y es justo el que
// importa. Por eso la comparación es por prenda + calidad + talla + género.
//
// Deliberadamente NO bloquea: hay contratos donde la diferencia es correcta
// (una prenda de repuesto, un jugador que no lleva uniforme completo y se
// captura a mano). Avisa, dice exactamente dónde, y deja decidir.

export type LineaTallas = {
  prenda: string;
  calidad: string;
  adultos: Record<string, { H: number; M: number } | undefined>;
  ninos: Record<string, number | undefined>;
  espA: { nombre: string; H: number; M: number }[];
  espN: { nombre: string; N: number }[];
};

export type Diferencia = {
  prenda: string; calidad: string; talla: string; genero: "H" | "M" | "N";
  nomina: number; matriz: number;
};

export type ResultadoNomina = {
  /** true = la matriz coincide exactamente con lo que implica la nómina. */
  coincide: boolean;
  diferencias: Diferencia[];
  totalNomina: number;
  totalMatriz: number;
  /** El caso traicionero: mismo total, tallas distintas. */
  mismoTotal: boolean;
};

const SEP = "␟";
const ETQ_GENERO: Record<string, string> = { H: "hombre", M: "mujer", N: "niño" };

/** Una sola cuenta por prenda + calidad + talla + género. */
export function aplanarLineas(lineas: LineaTallas[]): Map<string, number> {
  const out = new Map<string, number>();
  const sumar = (prenda: string, calidad: string, talla: string, genero: string, n: number) => {
    if (!talla || !n) return;
    const k = [prenda, calidad, talla, genero].join(SEP);
    out.set(k, (out.get(k) ?? 0) + n);
  };
  for (const l of lineas ?? []) {
    for (const [talla, c] of Object.entries(l.adultos ?? {})) {
      sumar(l.prenda, l.calidad, talla, "H", c?.H ?? 0);
      sumar(l.prenda, l.calidad, talla, "M", c?.M ?? 0);
    }
    for (const [talla, n] of Object.entries(l.ninos ?? {})) {
      sumar(l.prenda, l.calidad, talla, "N", n ?? 0);
    }
    // Las tallas especiales las nombra el vendedor a mano; una sin nombre es un
    // hueco vacío de la matriz, no una talla.
    for (const e of l.espA ?? []) {
      sumar(l.prenda, l.calidad, (e.nombre ?? "").trim(), "H", e.H ?? 0);
      sumar(l.prenda, l.calidad, (e.nombre ?? "").trim(), "M", e.M ?? 0);
    }
    for (const e of l.espN ?? []) {
      sumar(l.prenda, l.calidad, (e.nombre ?? "").trim(), "N", e.N ?? 0);
    }
  }
  return out;
}

export function compararNominaTallas(desdeNomina: LineaTallas[], enMatriz: LineaTallas[]): ResultadoNomina {
  const a = aplanarLineas(desdeNomina), b = aplanarLineas(enMatriz);
  const diferencias: Diferencia[] = [];
  for (const k of new Set([...a.keys(), ...b.keys()])) {
    const nomina = a.get(k) ?? 0, matriz = b.get(k) ?? 0;
    if (nomina === matriz) continue;
    const [prenda, calidad, talla, genero] = k.split(SEP);
    diferencias.push({ prenda, calidad, talla, genero: genero as "H" | "M" | "N", nomina, matriz });
  }
  // Se ordena por prenda y talla para que el aviso se lea como la tabla, no en
  // el orden arbitrario de un Set.
  diferencias.sort((x, y) =>
    x.prenda.localeCompare(y.prenda, "es") || x.calidad.localeCompare(y.calidad, "es")
    || x.talla.localeCompare(y.talla, "es") || x.genero.localeCompare(y.genero));
  const suma = (m: Map<string, number>) => Array.from(m.values()).reduce((s, n) => s + n, 0);
  const totalNomina = suma(a), totalMatriz = suma(b);
  return {
    coincide: diferencias.length === 0,
    diferencias,
    totalNomina,
    totalMatriz,
    mismoTotal: totalNomina === totalMatriz && diferencias.length > 0,
  };
}

/**
 * El texto del aviso. Se corta a `maximo` líneas: con veinte diferencias nadie
 * lee el detalle, y un diálogo de cincuenta renglones se cierra sin mirarlo.
 */
export function textoDiferencias(r: ResultadoNomina, maximo = 8): string {
  if (r.coincide) return "";
  const lineas = r.diferencias.slice(0, maximo).map((d) =>
    `• ${d.prenda}${d.calidad ? ` · ${d.calidad}` : ""} · talla ${d.talla} (${ETQ_GENERO[d.genero] ?? d.genero}): `
    + `jugadores ${d.nomina}, subtotal ${d.matriz}`);
  const resto = r.diferencias.length - lineas.length;
  if (resto > 0) lineas.push(`• …y ${resto} diferencia(s) más.`);
  const cabecera = r.mismoTotal
    // Este es el caso que hay que explicar, porque el vendedor ve dos totales
    // iguales y cree que está cuadrado.
    ? `Los totales coinciden (${r.totalNomina} prendas en ambos lados) pero las TALLAS no:`
    : `La lista de jugadores implica ${r.totalNomina} prenda(s) y el subtotal de tallas contiene ${r.totalMatriz}:`;
  return `${cabecera}\n\n${lineas.join("\n")}\n\nProducción utilizará el subtotal de la tabla de tallas. ¿Seguro quieres continuar?`;
}
