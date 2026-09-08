// Parseo de las hojas de BomanSport hacia las tablas de v79 (contratos,
// contrato_prendas, contrato_jugadores, contrato_archivos, contrato_specs,
// contrato_facturacion, contrato_etapas, contrato_eventos). Funciones puras:
// nunca lanzan, una linea rota se ignora y sigue con el resto, igual que
// lib/bomansportContratos.ts (v90).

function texto(valor: unknown): string {
  return valor === null || valor === undefined ? "" : String(valor).trim();
}

function numeroONull(valor: unknown): number | null {
  if (valor === "" || valor === null || valor === undefined) return null;
  const n = Number(valor);
  return Number.isFinite(n) ? n : null;
}

/** Codigo.gs manda las fechas de las 4 hojas de produccion como texto ISO
 * completo ("yyyy-MM-ddTHH:mm:ss"); si viene vacia o corrupta, usa "ahora". */
function fechaHoraOAhora(valor: unknown): string {
  const s = texto(valor);
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(s) ? s : new Date().toISOString();
}

/** Mismo criterio que extraerFileIdDrive_ en Codigo.gs. */
function driveIdDeUrl(url: string): string | null {
  const m =
    url.match(/\/file\/d\/([a-zA-Z0-9_-]+)/) ||
    url.match(/[?&]id=([a-zA-Z0-9_-]+)/) ||
    url.match(/uc\?id=([a-zA-Z0-9_-]+)/);
  return m ? m[1] : null;
}

function parsearArray(raw: unknown): Record<string, unknown>[] {
  if (Array.isArray(raw)) return raw as Record<string, unknown>[];
  if (typeof raw !== "string" || !raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function parsearObjeto(raw: unknown): Record<string, unknown> {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) return raw as Record<string, unknown>;
  if (typeof raw !== "string" || !raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

// ─── contrato_prendas ────────────────────────────────────────────────────

export type FilaPrenda = {
  prenda: string;
  calidad: string;
  detalle: string;
  genero: "H" | "M" | "N";
  talla: string;
  cantidad: number;
};

/** datosTallasJson: array de {prenda,calidad,detalle,adultos:{talla:{H,M}},ninos:{talla:N}}.
 * Se expande a una fila por prenda-calidad-detalle-genero-talla, solo cantidad > 0
 * (contrato_prendas exige cantidad > 0). */
export function prendasDesdeTallas(datosTallasJson: unknown): FilaPrenda[] {
  const filas: FilaPrenda[] = [];
  for (const linea of parsearArray(datosTallasJson)) {
    const prenda = texto(linea.prenda);
    if (!prenda) continue;
    const calidad = texto(linea.calidad);
    const detalle = texto(linea.detalle);
    const adultos = (linea.adultos && typeof linea.adultos === "object" ? linea.adultos : {}) as Record<
      string,
      { H?: unknown; M?: unknown }
    >;
    for (const talla of Object.keys(adultos)) {
      const h = numeroONull(adultos[talla]?.H) ?? 0;
      const m = numeroONull(adultos[talla]?.M) ?? 0;
      if (h > 0) filas.push({ prenda, calidad, detalle, genero: "H", talla, cantidad: h });
      if (m > 0) filas.push({ prenda, calidad, detalle, genero: "M", talla, cantidad: m });
    }
    const ninos = (linea.ninos && typeof linea.ninos === "object" ? linea.ninos : {}) as Record<string, unknown>;
    for (const talla of Object.keys(ninos)) {
      const n = numeroONull(ninos[talla]) ?? 0;
      if (n > 0) filas.push({ prenda, calidad, detalle, genero: "N", talla, cantidad: n });
    }
  }
  return filas;
}

// ─── contrato_jugadores ──────────────────────────────────────────────────

const CATEGORIAS_JUGADOR = ["Hombre", "Mujer", "Niño", "Niña"] as const;
type CategoriaJugador = (typeof CATEGORIAS_JUGADOR)[number];

export type FilaJugador = {
  orden: number;
  nombre: string;
  numero: string;
  categoria: CategoriaJugador;
  talla_superior: string | null;
  talla_inferior: string | null;
  manga: "Corta" | "Larga" | null;
  calidad: string | null;
  modelo_arquero: string | null;
  tipo_uniforme: string | null;
  detalle: string | null;
  mockup: string | null;
};

/** jugadoresJson: array de {nombre,numero,tipo,genero,talla,tallaCam,tallaPant,
 * arquero,calidad,manga,tipoUniforme,detalle,mockup}. "tipo"/"genero" del
 * formulario en realidad guardan la categoria (Hombre/Mujer/Niño). */
export function jugadoresDesde(jugadoresJson: unknown): FilaJugador[] {
  return parsearArray(jugadoresJson).map((j, orden) => {
    const categoria = texto(j.tipo || j.genero);
    const manga = texto(j.manga);
    return {
      orden,
      nombre: texto(j.nombre),
      numero: texto(j.numero),
      categoria: (CATEGORIAS_JUGADOR as readonly string[]).includes(categoria)
        ? (categoria as CategoriaJugador)
        : "Hombre",
      talla_superior: texto(j.tallaCam || j.talla) || null,
      talla_inferior: texto(j.tallaPant) || null,
      manga: manga === "Corta" || manga === "Larga" ? manga : null,
      calidad: texto(j.calidad) || null,
      modelo_arquero: texto(j.arquero) || null,
      tipo_uniforme: texto(j.tipoUniforme) || null,
      detalle: texto(j.detalle) || null,
      mockup: texto(j.mockup) || null,
    };
  });
}

// ─── contrato_archivos (mockups y logos) ────────────────────────────────

export type FilaArchivo = {
  tipo: "mockup" | "logo";
  orden: number;
  descripcion: string;
  url: string;
  drive_id: string | null;
  color: string | null;
  prenda: string | null;
  posicion: string | null;
  tecnica: string | null;
  calidad_aplicable: string | null;
  observacion: string | null;
};

/** linkMockupJson: array de {descripcion,url}. Contratos viejos lo guardan
 * como una URL suelta en vez de JSON (mismo fallback que primerMockupDe_
 * en Codigo.gs). */
export function mockupsDesde(linkMockupJson: unknown): FilaArchivo[] {
  let lista = parsearArray(linkMockupJson);
  if (!lista.length) {
    const suelta = texto(linkMockupJson);
    if (suelta) lista = [{ descripcion: "Mockup", url: suelta }];
  }
  return lista
    .filter((m) => texto(m.url))
    .map((m, orden) => {
      const url = texto(m.url);
      return {
        tipo: "mockup" as const,
        orden,
        descripcion: texto(m.descripcion) || "Mockup",
        url,
        drive_id: driveIdDeUrl(url),
        color: null,
        prenda: null,
        posicion: null,
        tecnica: null,
        calidad_aplicable: null,
        observacion: null,
      };
    });
}

/** logosDriveJson: array de {nombre,posicion,prenda,url,observacion,tecnica,calidadAplicable}. */
export function logosDesde(logosDriveJson: unknown): FilaArchivo[] {
  return parsearArray(logosDriveJson)
    .filter((l) => texto(l.url))
    .map((l, orden) => {
      const url = texto(l.url);
      return {
        tipo: "logo" as const,
        orden,
        descripcion: texto(l.nombre) || "Logo",
        url,
        drive_id: driveIdDeUrl(url),
        color: null,
        prenda: texto(l.prenda) || null,
        posicion: texto(l.posicion) || null,
        tecnica: texto(l.tecnica) || null,
        calidad_aplicable: texto(l.calidadAplicable) || null,
        observacion: texto(l.observacion) || null,
      };
    });
}

// ─── contrato_specs ──────────────────────────────────────────────────────

export type FilaSpec = {
  prenda_clave: string;
  orden: number;
  variante_mockup: string | null;
  variante_calidad: string | null;
  variante_otro: string | null;
  spec: Record<string, unknown>;
};

/** Mismo criterio que _varMk_/_varCal_/_varOtro_ en Codigo.gs: soporta tanto
 * el formato nuevo {mockup,calidad,otro} como el legado {tipo,valor}. */
function variante(v: Record<string, unknown>, campo: "mockup" | "calidad" | "otro"): string | null {
  const e = (v.variante && typeof v.variante === "object" ? v.variante : {}) as Record<string, unknown>;
  const directo = texto(e[campo]);
  if (directo) return directo;
  if (texto(e.tipo) === campo) return texto(e.valor) || null;
  return null;
}

/** datosTecnicosCalidadJson: objeto {prenda_clave: variante | variante[]}.
 * El formato viejo es un objeto suelto; el nuevo, un arreglo (_arrVar_ en
 * Codigo.gs normaliza igual). spec se guarda tal cual, sin recortar nada:
 * v79 solo lo lee entero para el brief. */
export function specsDesde(datosTecnicosCalidadJson: unknown): FilaSpec[] {
  const raiz = parsearObjeto(datosTecnicosCalidadJson);
  const filas: FilaSpec[] = [];
  for (const prendaClave of Object.keys(raiz)) {
    const valor = raiz[prendaClave];
    const variantes = Array.isArray(valor) ? valor : valor ? [valor] : [];
    variantes.forEach((v, orden) => {
      if (!v || typeof v !== "object") return;
      const spec = v as Record<string, unknown>;
      filas.push({
        prenda_clave: prendaClave,
        orden,
        variante_mockup: variante(spec, "mockup"),
        variante_calidad: variante(spec, "calidad"),
        variante_otro: variante(spec, "otro"),
        spec,
      });
    });
  }
  return filas;
}

// ─── contrato_facturacion ────────────────────────────────────────────────

export type FilaFacturacion = {
  orden: number;
  concepto: string;
  calidad: string | null;
  cantidad: number;
  obsequio: boolean;
};

/** detalleFacturacionJson: array de {concepto,calidad,cantidad,obsequio}.
 * Solo cantidad > 0 (contrato_facturacion lo exige). */
export function facturacionDesde(detalleFacturacionJson: unknown): FilaFacturacion[] {
  const filas: FilaFacturacion[] = [];
  parsearArray(detalleFacturacionJson).forEach((f, orden) => {
    const concepto = texto(f.concepto);
    const cantidad = numeroONull(f.cantidad) ?? 0;
    if (!concepto || cantidad <= 0) return;
    filas.push({ orden, concepto, calidad: texto(f.calidad) || null, cantidad, obsequio: !!f.obsequio });
  });
  return filas;
}

// ─── Hojas de produccion (?api=produccion): agrupar por numero ─────────

export type AsignacionCruda = {
  numero: string;
  fecha: string;
  disenador: string;
  asigno: string;
  estado: string;
  autorMockup: string;
};
export type ObservacionCruda = { numero: string; fecha: string; observacion: string; quien: string };
export type MaquilaCruda = { numero: string; fecha: string; maquila: string; quien: string };
export type TrazabilidadCruda = {
  numero: string;
  fecha: string;
  area: string;
  etapa: string;
  operario: string;
  etapaAnterior: string;
};

export function agruparPorNumero<T extends { numero: string }>(filas: T[]): Map<string, T[]> {
  const mapa = new Map<string, T[]>();
  for (const fila of filas) {
    const lista = mapa.get(fila.numero);
    if (lista) lista.push(fila);
    else mapa.set(fila.numero, [fila]);
  }
  return mapa;
}

export type FilaEtapa = {
  area: string;
  etapa: string;
  etapa_anterior: string | null;
  operario: string;
  marcado_en: string;
};

/** Bitacora append-only: cada fila de Trazabilidad de ese contrato es un
 * evento propio, no solo "la ultima". */
export function etapasDesde(filas: TrazabilidadCruda[]): FilaEtapa[] {
  return filas
    .filter((f) => texto(f.area) && texto(f.etapa))
    .map((f) => ({
      area: texto(f.area),
      etapa: texto(f.etapa),
      etapa_anterior: texto(f.etapaAnterior) || null,
      operario: texto(f.operario),
      marcado_en: fechaHoraOAhora(f.fecha),
    }));
}

export type FilaEvento = {
  campo: string;
  valor_nuevo: string | null;
  quien: string;
  created_at: string;
};

export function eventosDesdeAsignaciones(filas: AsignacionCruda[]): FilaEvento[] {
  return filas
    .filter((f) => texto(f.disenador))
    .map((f) => ({
      campo: "disenador",
      valor_nuevo: texto(f.disenador),
      quien: texto(f.asigno),
      created_at: fechaHoraOAhora(f.fecha),
    }));
}

export function eventosDesdeObservaciones(filas: ObservacionCruda[]): FilaEvento[] {
  return filas
    .filter((f) => texto(f.observacion))
    .map((f) => ({
      campo: "observacion",
      valor_nuevo: texto(f.observacion),
      quien: texto(f.quien),
      created_at: fechaHoraOAhora(f.fecha),
    }));
}

/** Valor vigente = ultima fila 'Activa' (append-only: reasignar marca la
 * anterior 'Reasignada' y agrega una fila nueva). Mismo criterio que
 * asignacionesActivas_() en Codigo.gs. */
export function asignacionVigente(filas: AsignacionCruda[]): { disenador: string; autorMockup: string } | null {
  for (let i = filas.length - 1; i >= 0; i--) {
    if (texto(filas[i].estado) === "Activa") {
      return { disenador: texto(filas[i].disenador), autorMockup: texto(filas[i].autorMockup) };
    }
  }
  return null;
}

export function observacionVigente(filas: ObservacionCruda[]): string | null {
  const ultima = filas[filas.length - 1];
  return ultima ? texto(ultima.observacion) || null : null;
}

export function maquilaVigente(filas: MaquilaCruda[]): string | null {
  const ultima = filas[filas.length - 1];
  return ultima ? texto(ultima.maquila) || null : null;
}
