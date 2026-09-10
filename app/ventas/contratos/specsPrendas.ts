// Fichas técnicas por prenda, copiadas de BomanSport/index.html (getTecConfig +
// los _buildXHtml). Es la fuente de verdad del taller: los nombres de campo y
// las opciones deben coincidir literalmente, porque el brief las imprime tal
// cual y la migración v94 las guarda en contrato_specs.spec.
//
// "alta" = calidad Competición o Profesional. Varias opciones cambian según la
// calidad elegida (por eso el legado obliga a elegirla primero): cuando un
// campo tiene optsAlta, esas son las opciones para calidad alta y opts las de
// calidad estándar.

export type CampoSpec = {
  id: string;
  label: string;
  /** undefined = campo de texto libre */
  opts?: string[];
  /** Opciones cuando la calidad es Competición o Profesional. */
  optsAlta?: string[];
};

export type FichaPrenda = {
  clave: string;
  label: string;
  icon: string;
  /** Prendas del paso 3 que activan esta ficha. */
  prendas: string[];
  calAware: boolean;
  campos: CampoSpec[];
};

export const CALIDADES_ALTAS = ["Competición", "Profesional"];
export const esCalidadAlta = (c: string) => CALIDADES_ALTAS.includes(c);

const BASTA_FUTBOL = ["Futbol normal", "Futbol casita", "Especial", "Cosida aparte", "Cosida aparte sublimada", "Cosida aparte tela"];
const BASTA_BASQUET = ["Basquet normal", "Basquet casita", "Especial", "Cosida aparte", "Cosida aparte sublimada", "Cosida aparte tela"];

/** Basta de pantaloneta: depende del tipo (Fútbol o Básquet), no de la calidad. */
export const bastaPantaloneta = (tipo: string) => (tipo === "Futbol" ? BASTA_FUTBOL : BASTA_BASQUET);

const CAMPOS_CAMISETA: CampoSpec[] = [
  { id: "corte", label: "Corte", opts: ["Ranglan", "Recta", "Corte especial"] },
  { id: "cuello_tipo", label: "Tipo cuello", opts: ["Normal", "Polo", "Chino", "Especial"] },
  { id: "cuello_forma", label: "Forma cuello", opts: ["Normal", "Redondo", "En V", "Cruzado", "Personalizado"] },
  { id: "cuello_falso", label: "Cuello falso", opts: ["No", "Sí", "En V", "Redondo"] },
  { id: "cuello_material", label: "Material cuello", opts: ["Tela"], optsAlta: ["Rib", "Tejido rib", "Tejido licra", "Tela"] },
  { id: "cuello_tecnica", label: "Técnica cuello", opts: ["Llano", "Sublimado"], optsAlta: ["Llano", "Estampado", "Sublimado", "Personalizado"] },
  { id: "botones", label: "¿Botones?", opts: ["No", "Sí", "Combinado"] },
  { id: "punos_tipo", label: "Tipo puños", opts: ["No aplica"], optsAlta: ["Integrado", "Aparte tela", "Aparte tejido", "Aparte rib", "Combinado"] },
  { id: "punos_tecnica", label: "Técnica puños", opts: ["No aplica"], optsAlta: ["Sublimado", "Estampado", "Sublimado y estampado", "Llano", "Personalizado"] },
  { id: "basta", label: "Basta", opts: ["Normal"], optsAlta: ["Con casita", "Normal", "Falso", "Cola de pato"] },
  { id: "empanada", label: "Empanada", opts: ["No aplica", "Triangular", "Cuadrada", "Hexagonal"] },
  { id: "babero", label: "Babero", opts: ["No", "Sí", "Apuntado", "Especial", "No aplica"] },
  { id: "vinchas", label: "Vinchas", opts: ["No", "Tela"], optsAlta: ["No", "Tela", "Tejido", "Rib"] },
  { id: "vivos", label: "Vivos", opts: ["No aplica"], optsAlta: ["No", "Sí"] },
  { id: "vivos_donde", label: "¿Dónde van los vivos?" },
  { id: "pie_de_cuello", label: "Pie de cuello", opts: ["No", "Sí"] },
  { id: "pie_de_cuello_color", label: "Color pie de cuello" },
  { id: "reata", label: "Reata", opts: ["No", "Tela"], optsAlta: ["No", "Pro", "Tela", "Sesgo", "Pro sin Boman"] },
  { id: "reata_color", label: "Color reata" },
  { id: "talla_origen", label: "Origen talla", opts: ["Nacional", "Importada"] },
  { id: "talla_marca", label: "Marca talla", opts: ["Con Boman", "Sin Boman"], optsAlta: ["Con Boman", "Sin Boman", "Personalizada"] },
  { id: "observacion", label: "Observación" },
];

// El polo es la misma ficha con el cuello fijo en "Polo" (esPolo en el legado).
const CAMPOS_POLO: CampoSpec[] = CAMPOS_CAMISETA.map((c) =>
  c.id === "cuello_tipo" ? { ...c, opts: ["Polo"], optsAlta: undefined } : c
);

const CAMPOS_BERMUDA_FALDA: CampoSpec[] = [
  { id: "tipo", label: "Tipo", opts: ["Con cierre", "Sin cierre", "Cargo"] },
  { id: "basta", label: "Basta", opts: ["Basquet normal", "Basquet casita", "Fútbol normal", "Fútbol casita"] },
  { id: "cordon", label: "Cordón", opts: ["Unitario", "Metreado"] },
  { id: "elastico", label: "Elástico", opts: ["Boman", "Normal"] },
  { id: "cierre", label: "Cierre", opts: ["No", "Sí"] },
  { id: "vivos", label: "Vivos", opts: ["No", "Sí"] },
  { id: "talla_origen", label: "Origen talla", opts: ["Nacional", "Importada", "Personalizada"] },
  { id: "talla_marca", label: "Marca talla", opts: ["Con Boman", "Sin Boman"] },
  { id: "observacion", label: "Observación" },
];

const CAMPOS_CHOMPA_FRIO: CampoSpec[] = [
  { id: "tela", label: "Tela", opts: ["Plumón cosido", "Plumón integrado"] },
  { id: "cierre", label: "Cierre", opts: ["Sin cierre", "Medio", "Bajo", "Completo"] },
  { id: "capucha", label: "Capucha", opts: ["Con capucha", "Sin capucha"] },
  { id: "punos", label: "Puño", opts: ["Rib", "Normal", "Aparte"] },
  { id: "bolsillos", label: "Tipo de bolsillo", opts: ["Con cierre", "Sin cierre", "Con velcro"] },
  { id: "observacion", label: "Observación" },
];

const CAMPOS_RETRO_DEPORTIVA: CampoSpec[] = [
  { id: "tela", label: "Tela", opts: ["Algodón", "Especial", "Exterior poliéster"] },
  { id: "union", label: "Unión central", opts: ["Cierre", "Botones", "Broches"] },
  { id: "cierre", label: "Cierre", opts: ["Sin cierre", "Medio", "Bajo", "Completo"] },
  { id: "reata_capucha", label: "Reata capucha", opts: ["No", "Sí"] },
  { id: "punos", label: "Puño", opts: ["Rib", "Tejido", "Normal"] },
  { id: "fajas", label: "Fajas", opts: ["Rib", "Tejido", "Normal"] },
  { id: "cuello", label: "Cuello", opts: ["Rib", "Tejido", "Normal"] },
  { id: "observacion", label: "Observación" },
];

export const FICHAS_PRENDA: FichaPrenda[] = [
  { clave: "camiseta", label: "CAMISETA", icon: "👕", calAware: true,
    prendas: ["Camiseta Jugador", "Camiseta Jugador M/L", "Camiseta Arquero", "Camiseta Arquero M/L", "Uniformes Completos", "Arquero Completo"],
    campos: CAMPOS_CAMISETA },
  { clave: "camisetaPolo", label: "CAMISETA POLO", icon: "👔", calAware: true,
    prendas: ["Camiseta Polo", "Camiseta Polo M/L"], campos: CAMPOS_POLO },
  { clave: "pantaloneta", label: "PANTALONETA", icon: "🩳", calAware: true,
    prendas: ["Pantaloneta Jugador", "Pantaloneta Arquero", "Uniformes Completos", "Arquero Completo"],
    campos: [
      { id: "tipo", label: "Tipo", opts: ["Basquet", "Futbol"] },
      { id: "basta", label: "Basta", opts: BASTA_BASQUET },
      { id: "cordon", label: "Cordón", opts: ["Metreado"], optsAlta: ["Unitario"] },
      { id: "elastico", label: "Elástico", opts: ["Normal"], optsAlta: ["Boman", "Normal"] },
      { id: "vivos", label: "Vivos", opts: ["No", "Sí"] },
      { id: "vivos_color", label: "Vivos: color / dónde" },
      { id: "talla_origen", label: "Origen talla", opts: ["Nacional", "Importada"] },
      { id: "talla_marca", label: "Marca talla", opts: ["Con Boman", "Sin Boman"], optsAlta: ["Con Boman", "Sin Boman", "Personalizada"] },
      { id: "franjas_sublimadas", label: "Franjas sublimadas", opts: ["No aplica", "Sí"] },
      { id: "franjas_adidas", label: "Franjas Adidas", opts: ["No aplica", "1", "2", "3", "4"] },
      { id: "observacion", label: "Observación" },
    ] },
  { clave: "chompa", label: "CHOMPA", icon: "🧥", calAware: false, prendas: ["Chompa", "Exterior Completo", "Hoodie"],
    campos: [
      { id: "modelo", label: "Prenda (título del brief)", opts: ["Exterior", "Rompevientos", "Chompa de Frío", "Buzo", "Retro", "Hoodie"] },
      { id: "estilo", label: "Estilo", opts: ["Normal", "Retro (Escolar)"] },
      { id: "tipo", label: "Tipo", opts: ["Con cierre", "Sin cierre", "Canguro"] },
      { id: "cierre", label: "Cierre", opts: ["Sin cierre", "Medio", "Bajo", "Completo"] },
      { id: "cierre_estampado", label: "Cierre estampado", opts: ["No", "Sí"] },
      { id: "capucha", label: "Capucha", opts: ["Sin capucha", "Normal", "Desmontable"] },
      { id: "basta", label: "Basta inferior", opts: ["Faja", "Basta suelta"] },
      { id: "punos_tipo", label: "Tipo puño", opts: ["Con elástico boman", "Sin elástico", "Elástico normal", "Sesgo", "Combinado"] },
      { id: "punos_forma", label: "Forma puño", opts: ["Puño normal", "Puño guante"] },
      { id: "tiras_adidas", label: "Tira Adidas", opts: ["Sin tira", "1 tira", "2 tiras", "3 tiras", "4 tiras"] },
      { id: "velcro", label: "Velcro", opts: ["No", "Sí"] },
      { id: "observacion", label: "Observación" },
    ] },
  { clave: "chompaFrio", label: "CHOMPA DE FRÍO", icon: "🥶", calAware: false, prendas: ["Chompa de Frío"], campos: CAMPOS_CHOMPA_FRIO },
  { clave: "chompaFrio34", label: "CHOMPA FRÍO 3/4", icon: "🥶", calAware: false, prendas: ["Chompa Frío 3/4"], campos: CAMPOS_CHOMPA_FRIO },
  { clave: "rompevientos", label: "CHOMPA DE LLUVIA", icon: "🌧️", calAware: false, prendas: ["Rompevientos"],
    campos: [
      { id: "capucha", label: "Capucha", opts: ["Con capucha", "Sin capucha"] },
      { id: "capa", label: "Capa", opts: ["Con capa", "Sin capa"] },
      { id: "cierre", label: "Cierre", opts: ["Sin cierre", "Medio", "Bajo", "Completo"] },
      { id: "cierre_estampado", label: "Cierre estampado", opts: ["No", "Sí"] },
      { id: "basta", label: "Basta", opts: ["Normal", "Redondeada"] },
      { id: "bolsillos", label: "Tipo de bolsillo", opts: ["Con cierre", "Sin cierre"] },
      { id: "observacion", label: "Observación" },
    ] },
  { clave: "retro", label: "CHOMPA RETRO", icon: "🎽", calAware: false, prendas: ["Chompas Retro"], campos: CAMPOS_RETRO_DEPORTIVA },
  { clave: "deportiva", label: "CHOMPA DEPORTIVA", icon: "🧥", calAware: false, prendas: ["Chompa Deportiva"], campos: CAMPOS_RETRO_DEPORTIVA },
  { clave: "pantalon", label: "PANTALÓN", icon: "👖", calAware: false, prendas: ["Pantalón", "Exterior Completo"],
    campos: [
      { id: "punos", label: "Tipo puño", opts: ["Rib", "Tela", "Elástico normal", "Especial"] },
      { id: "basta_detalle", label: "Basta cierre", opts: ["Con cierre", "Sin cierre"] },
      { id: "bolsillo", label: "Bolsillos", opts: ["No tiene", "Con cierre", "Sin cierre"] },
      { id: "franja", label: "Franja de tela", opts: ["No aplica", "Sublimada"] },
      { id: "tiras_adidas", label: "Tira Adidas", opts: ["No", "1", "2", "3"] },
      { id: "cordon", label: "Cordón", opts: ["Unitario", "Metreado"] },
      { id: "vivos_donde", label: "Vivos: ¿cómo y dónde?" },
      { id: "observacion", label: "Observación" },
    ] },
  { clave: "bermuda", label: "BERMUDA", icon: "🩳", calAware: false, prendas: ["Bermudas"], campos: CAMPOS_BERMUDA_FALDA },
  { clave: "faldaShort", label: "FALDA SHORT", icon: "👗", calAware: false, prendas: ["Falda Short"], campos: CAMPOS_BERMUDA_FALDA },
  { clave: "licra", label: "LICRA", icon: "👖", calAware: false, prendas: ["Licra"],
    campos: [
      { id: "punos", label: "Tipo puño", opts: ["Con elástico boman", "Sin elástico", "Elástico normal", "Sesgo", "Combinado"] },
      { id: "basta_tipo", label: "Tipo basta", opts: ["Tubo", "Semitubo", "Recto"] },
      { id: "basta_detalle", label: "Detalle basta", opts: ["Con cierre", "Sin cierre"] },
      { id: "bolsillo", label: "Bolsillo", opts: ["No aplica", "Con cierre", "Sin cierre"] },
      { id: "tiras_adidas", label: "Tira Adidas", opts: ["Sin tira", "1 tira", "2 tiras", "3 tiras", "4 tiras"] },
      { id: "observacion", label: "Observación" },
    ] },
  { clave: "chaleco", label: "CHALECO", icon: "🦺", calAware: false, prendas: ["Chaleco"],
    campos: [
      { id: "color", label: "Color" },
      { id: "reversible", label: "¿Reversible?", opts: ["No", "Sí"] },
      { id: "observacion", label: "Observación" },
    ] },
  { clave: "buzoComp", label: "BUZO DE COMPRESIÓN", icon: "🏋️", calAware: false, prendas: ["Buzo de Compresión"],
    campos: [{ id: "color", label: "Color" }, { id: "observacion", label: "Observación" }] },
  { clave: "bolso", label: "BOLSO", icon: "🎒", calAware: false, prendas: ["Bolsos"],
    campos: [{ id: "material", label: "Material" }, { id: "detalles", label: "Detalles" }] },
  { clave: "bvds", label: "BVDS", icon: "🎽", calAware: false, prendas: ["BVDS"],
    campos: [{ id: "detalle", label: "Detalle" }] },
];

/** Fichas que corresponden a las prendas elegidas en el paso 3. */
export function fichasDePrendas(prendasSel: string[]): FichaPrenda[] {
  return FICHAS_PRENDA.filter((f) => f.prendas.some((p) => prendasSel.includes(p)));
}

/** Opciones de un campo según la calidad elegida (y el tipo, en pantaloneta). */
export function opcionesCampo(ficha: FichaPrenda, campo: CampoSpec, calidad: string, valores: Record<string, string>): string[] | undefined {
  if (!campo.opts) return undefined;
  if (ficha.clave === "pantaloneta" && campo.id === "basta") return bastaPantaloneta(valores.tipo || "Basquet");
  return campo.optsAlta && esCalidadAlta(calidad) ? campo.optsAlta : campo.opts;
}
