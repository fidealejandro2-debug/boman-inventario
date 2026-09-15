// Reglas del brief de producción que no dependen de React ni del DOM.
//
// Viven aquí y no dentro de IngresoContratoCliente.tsx por una razón concreta:
// son las que más veces se han roto en silencio (specs que dejaban de
// imprimirse, jugadores en el orden equivocado, una banda invisible) y un
// componente cliente de 1.500 líneas con imports de CSS no se puede probar.
// Aquí sí: ver briefContrato.test.ts, que se corre con `npm test`.

export const texto = (v: unknown) => String(v ?? "").trim();

export type AdicionalContrato = { tipo: string; valor: string; cantidad: number };
export type AdicionalesContrato = {
  detalle: string;
  items: AdicionalContrato[];
  medidas_bandera: string;
};

function objetoAdicionales(valor: unknown): Record<string, unknown> {
  if (valor && typeof valor === "object" && !Array.isArray(valor)) return valor as Record<string, unknown>;
  if (typeof valor !== "string" || !valor.trim()) return {};
  try {
    const parsed = JSON.parse(valor);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {};
  } catch {
    return { detalle: valor };
  }
}

/**
 * Convierte el JSON de adicionales del AppScript y la forma nueva de Supabase
 * a una sola estructura. El importador histórico dejó el JSON viejo sin
 * transformar; por eso un contrato podía tener "Incluye medias" en la hoja y
 * perder el recuadro al imprimirlo desde el sistema nuevo.
 */
export function normalizarAdicionalesContrato(valor: unknown): AdicionalesContrato {
  const ad = objetoAdicionales(valor);
  if (Array.isArray(ad.items)) {
    const items = ad.items.flatMap((item): AdicionalContrato[] => {
      if (!item || typeof item !== "object") return [];
      const fila = item as Record<string, unknown>;
      const tipo = texto(fila.tipo), valorItem = texto(fila.valor);
      if (!tipo || !valorItem) return [];
      return [{ tipo, valor: valorItem, cantidad: Math.max(0, Number(fila.cantidad) || 0) }];
    });
    return {
      detalle: texto(ad.detalle),
      items,
      medidas_bandera: texto(ad.medidas_bandera) || texto(ad.medidas),
    };
  }

  const items: AdicionalContrato[] = [];
  const agregar = (tipo: string, valorItem: unknown, cantidad: unknown, valorVacio: string) => {
    const valorTexto = texto(valorItem);
    if (!valorTexto || valorTexto.toLocaleLowerCase("es").normalize("NFD").replace(/[\u0300-\u036f]/g, "")
      === valorVacio.toLocaleLowerCase("es").normalize("NFD").replace(/[\u0300-\u036f]/g, "")) return;
    items.push({ tipo, valor: valorTexto, cantidad: Math.max(0, Number(cantidad) || 0) });
  };

  const medias = texto(ad.medias);
  const cantidadMedias = ad.cantidadMedias;
  if (["Incluye medias", "Incluye personalizadas"].includes(medias)) {
    agregar("Medias", medias, cantidadMedias, "No incluye medias");
  }
  const polainasDesdeMedias = medias === "Incluye polainas";
  if (polainasDesdeMedias || texto(ad.polainas) === "Incluye polainas") {
    agregar("Polainas", "Incluye polainas", polainasDesdeMedias ? cantidadMedias : ad.cantidadPolainas, "No incluye polainas");
  }
  const antidesDesdeMedias = medias === "Incluye antideslizantes";
  if (antidesDesdeMedias || texto(ad.antideslizantes) === "Incluye antideslizantes") {
    agregar("Medias antideslizantes", "Incluye antideslizantes", antidesDesdeMedias ? cantidadMedias : ad.cantidadAntideslizantes, "No incluye antideslizantes");
  }
  agregar("Banda de Capitán", ad.bandaCapitan ?? ad.banda_capitan, ad.cantidadBandas, "Sin banda de capitán");
  agregar("Banderín", ad.banderin, ad.cantidadBanderines, "Sin banderín");
  agregar("Bandera", ad.bandera, ad.cantidadBanderas, "Sin bandera");
  agregar("Bolsos", ad.bolsos, ad.cantidadBolsos, "Sin bolsos");

  return {
    detalle: texto(ad.detalle) || texto(ad.otros),
    items,
    medidas_bandera: texto(ad.medidas_bandera) || texto(ad.medidas),
  };
}

/**
 * La API histórica de AppScript ha enviado este campo en dos lugares:
 * `adicionales` en la raíz y `extra.Adicionales` con el nombre original de
 * la columna de Sheets. Centralizar la búsqueda evita que una sincronización
 * correcta vuelva a vaciar los adicionales del contrato normalizado.
 */
export function adicionalesDesdeDatosContrato(datos: unknown): AdicionalesContrato {
  if (!datos || typeof datos !== "object" || Array.isArray(datos)) {
    return normalizarAdicionalesContrato(undefined);
  }
  const raiz = datos as Record<string, unknown>;
  const extra = raiz.extra && typeof raiz.extra === "object" && !Array.isArray(raiz.extra)
    ? raiz.extra as Record<string, unknown>
    : {};
  const candidatos = [raiz.adicionales, raiz.Adicionales, extra.adicionales, extra.Adicionales]
    .map(normalizarAdicionalesContrato);
  return candidatos.find((ad) => ad.items.length > 0 || Boolean(ad.detalle) || Boolean(ad.medidas_bandera))
    ?? normalizarAdicionalesContrato(undefined);
}

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
    // "variante" es metadata (mockup/calidad/otro) que solo etiqueta el título de
    // la sección — igual que _etqVar_ en Codigo.gs, nunca se imprime como fila.
    // Se guarda tal cual en el spec (bomansportProduccion.ts lo deja sin recortar),
    // así que sin este skip aparecía como "Variante mockup / calidad / otro".
    if (!prefijo && (k === "observacion" || k === "indicaciones" || k === "variante")) continue;
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
