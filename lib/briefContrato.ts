// Reglas del brief de producción que no dependen de React ni del DOM.
//
// Viven aquí y no dentro de IngresoContratoCliente.tsx por una razón concreta:
// son las que más veces se han roto en silencio (specs que dejaban de
// imprimirse, jugadores en el orden equivocado, una banda invisible) y un
// componente cliente de 1.500 líneas con imports de CSS no se puede probar.
// Aquí sí: ver briefContrato.test.ts, que se corre con `npm test`.

export const texto = (v: unknown) => String(v ?? "").trim();

// ── Especificaciones técnicas ────────────────────────────────────────────

/** camelCase → snake_case, que es como se llaman los campos de FICHAS_PRENDA. */
export const aSnake = (k: string) => k.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();

/**
 * Las specs migradas de BomanSport vienen ANIDADAS:
 *   {"cuello":{"tipo":"Normal","botones":{"tiene":"Sí"}}}
 * Aplanarlas juntando los valores con " · " producía un solo campo "Cuello"
 * con seis valores pegados y un "[object Object]" cuando había otro objeto
 * dentro. Se aplanan a claves compuestas (cuello_tipo, cuello_botones_tiene),
 * que son exactamente los ids que usa la ficha del sistema: así un contrato
 * migrado se imprime con las mismas etiquetas que uno cargado en Vercel.
 */
export function aplanarSpec(o: Record<string, unknown>, prefijo = ""): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(o)) {
    if (!prefijo && (k === "observacion" || k === "indicaciones")) continue;
    if (v === null || v === undefined) continue;
    const id = prefijo ? `${prefijo}_${aSnake(k)}` : aSnake(k);
    if (Array.isArray(v)) {
      const t = v.map(texto).filter(Boolean).join(" · ");
      if (t) out[id] = t;
    } else if (typeof v === "object") {
      Object.assign(out, aplanarSpec(v as Record<string, unknown>, id));
    } else {
      const t = texto(v);
      if (t) out[id] = t;
    }
  }
  return out;
}

/**
 * El jsonb `spec` puede venir con la forma nueva {campos,observacion}, con la
 * vieja {indicaciones:"…"}, anidada, o con cualquier otra. Nunca se vuelca
 * JSON crudo en pantalla — eso era justo lo que el vendedor veía antes.
 */
export function leerSpec(spec: unknown): { campos: Record<string, string>; observacion: string } {
  if (!spec || typeof spec !== "object") return { campos: {}, observacion: texto(spec) };
  const o = spec as Record<string, unknown>;
  const crudo = o.campos && typeof o.campos === "object" ? (o.campos as Record<string, unknown>) : null;
  const observacion = texto(o.observacion) || texto(o.indicaciones);
  return { campos: aplanarSpec(crudo ?? o), observacion };
}

/**
 * El legado guarda {basta:{tipo:"Normal"}} y {pieDeCuello:{tiene:"Sí"}}, que al
 * aplanarse quedan como basta_tipo / pie_de_cuello_tiene, mientras que la ficha
 * llama a esos campos "basta" y "pie_de_cuello" a secas. Devuelve el valor y
 * marca como usada la clave de la que salió, para que no se reimprima suelta.
 */
export function valorDeCampo(campos: Record<string, string>, id: string, usadas: Set<string>): string {
  for (const k of [id, `${id}_tipo`, `${id}_tiene`]) {
    const v = texto(campos[k]);
    if (v) { usadas.add(k); return v }
    if (k in campos) usadas.add(k);
  }
  return "";
}

// ── Jugadores ────────────────────────────────────────────────────────────

export type JugadorBrief = {
  nombre: string; numero: string; categoria: string;
  talla_superior: string; talla_inferior: string;
  manga: string; calidad: string; tipo_uniforme: string;
};

export const TIPO_SOLO_SUPERIOR = new Set(["Solo camiseta", "Solo Polo", "Solo BVD", "Chompa", "Chompa de Frío", "Chaleco"]);
export const TIPO_SOLO_INFERIOR = new Set(["Solo pantaloneta", "Solo Falda Short", "Solo pantalón", "Solo bermuda"]);

/** 0 = uniforme completo · 1 = solo parte superior · 2 = solo parte inferior. */
export const grupoPrendaJugador = (tu: string) =>
  TIPO_SOLO_SUPERIOR.has(tu) ? 1 : TIPO_SOLO_INFERIOR.has(tu) ? 2 : 0;

/**
 * Tipos que NO llevan camiseta de manga. En la columna MANGA va "—", no
 * "corta": decir "corta" de una pantaloneta o de una chompa es información
 * falsa en el papel con el que corta el taller.
 */
export const TIPOS_SIN_MANGA = new Set(["Solo pantaloneta", "Solo Falda Short", "Solo pantalón", "Solo bermuda",
  "Solo BVD", "BVD + Pantaloneta", "BVD con Falda Short", "BVD + Bermuda",
  "Chompa", "Chompa de Frío", "Chompa Retro", "Chaleco", "Exterior completo"]);

/** El tipo se abrevia para que la fila no se parta en dos líneas. */
export const ABREV_TIPO: Record<string, string> = {
  "Uniforme completo": "Completo", "Uniforme completo (Falda Short)": "Completo (Falda)",
  "BVD + Pantaloneta": "BVD+Pant", "BVD con Falda Short": "BVD+Falda", "Polo + Pantaloneta": "Polo+Pant",
  "Camiseta + Exterior": "Cam+Ext", "Polo + Exterior": "Polo+Ext", "Solo Polo": "Polo", "Solo camiseta": "Camiseta",
  "Solo pantaloneta": "Pantaloneta", "Solo Falda Short": "Falda Short", "Solo pantalón": "Pantalón",
  "Solo BVD": "BVD", "Exterior completo": "Exterior", "Arquero completo": "Arquero",
};

/** A quien solo lleva prenda inferior lo ordena su talla de abajo. */
export const tallaQueOrdena = (j: JugadorBrief) =>
  TIPO_SOLO_INFERIOR.has(j.tipo_uniforme)
    ? texto(j.talla_inferior) || texto(j.talla_superior)
    : texto(j.talla_superior) || texto(j.talla_inferior);

/**
 * Mismo orden que compararJugadores_ del legado: calidad → ALCANCE DE PRENDA →
 * género → talla → manga → tipo. El alcance va antes que el género a propósito:
 * agrupa completos, solo-superior y solo-inferior en tramos limpios, que es lo
 * que hace que la sub-banda tenga sentido. Ordenar por tipo alfabéticamente los
 * intercalaba y el mismo grupo abría dos bandas.
 */
export function compararJugadores(
  a: JugadorBrief, b: JugadorBrief,
  orden: { calidad: string[]; genero: Record<string, number>; manga: Record<string, number>; tipo: string[]; talla: (t: string) => number },
) {
  const pos = (arr: string[], v: string) => { const i = arr.indexOf(v); return i < 0 ? arr.length : i };
  return pos(orden.calidad, a.calidad) - pos(orden.calidad, b.calidad)
    || grupoPrendaJugador(a.tipo_uniforme) - grupoPrendaJugador(b.tipo_uniforme)
    || (orden.genero[a.categoria] ?? 9) - (orden.genero[b.categoria] ?? 9)
    || orden.talla(tallaQueOrdena(a)) - orden.talla(tallaQueOrdena(b))
    || (orden.manga[a.manga] ?? 0) - (orden.manga[b.manga] ?? 0)
    || pos(orden.tipo, a.tipo_uniforme) - pos(orden.tipo, b.tipo_uniforme)
    || a.nombre.localeCompare(b.nombre, "es");
}

/**
 * Etiqueta de la sub-banda: si el tramo es de un solo tipo, ese tipo ("Solo
 * camiseta"); si mezcla varios del mismo alcance, la forma genérica.
 */
export function etiquetaGrupo(arr: JugadorBrief[], desde: number) {
  const g = grupoPrendaJugador(arr[desde].tipo_uniforme), cal = arr[desde].calidad;
  const tipos = new Set<string>();
  for (let k = desde; k < arr.length; k++) {
    if (grupoPrendaJugador(arr[k].tipo_uniforme) !== g || arr[k].calidad !== cal) break;
    if (texto(arr[k].tipo_uniforme)) tipos.add(texto(arr[k].tipo_uniforme));
  }
  if (tipos.size === 1) return Array.from(tipos)[0];
  return g === 1 ? "Solo parte superior" : g === 2 ? "Solo parte inferior" : "Uniforme completo";
}

export function cuentaGrupo(arr: JugadorBrief[], desde: number) {
  const g = grupoPrendaJugador(arr[desde].tipo_uniforme), cal = arr[desde].calidad;
  let n = 0;
  for (let k = desde; k < arr.length; k++) {
    if (grupoPrendaJugador(arr[k].tipo_uniforme) !== g || arr[k].calidad !== cal) break;
    n++;
  }
  return n;
}
