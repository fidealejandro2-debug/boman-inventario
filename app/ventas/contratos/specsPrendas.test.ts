// Audita, prenda por prenda, que los ids de FICHAS_PRENDA (specsPrendas.ts)
// coincidan con los campos que Codigo.gs REALMENTE recolecta (getTecConfig,
// collect() de cada prenda en BomanSport/index.html).
//
// El bug real que motivó esto: FICHAS_PRENDA declaraba ids "razonables" a
// simple vista (ej. "botones", "punos", "tipo") que nunca calzaban con la
// forma real y anidada de los datos del legado (ej. cuello.botones.tiene,
// puno.tipo, bolsillos.tipo) — más de 20 campos entre 8 prendas se perdían
// en filas genéricas mal etiquetadas o quedaban en blanco. Ver v145.
//
// Las formas de abajo son transcripción literal de collect() en index.html
// (getTecConfig, líneas ~4177-4324 al momento de escribir esto). Si
// Codigo.gs cambia esas formas, esta prueba queda desactualizada — por
// diseño: es una foto de la correspondencia acordada, no un espejo en vivo.

import { test } from "node:test";
import assert from "node:assert/strict";
import { aplanarSpec } from "../../../lib/briefContrato.ts";
import { FICHAS_PRENDA } from "./specsPrendas.ts";

const COLLECT: Record<string, Record<string, unknown>> = {
  camiseta: {
    corte: "x",
    cuello: { tipo: "x", forma: "x", falso: "x", material: "x", tecnica: "x", botones: { tiene: "x", cantidad: "x" } },
    punos: { tipo: "x", tecnica: "x" },
    vivos: "x", vivosDonde: "x", basta: { tipo: "x" },
    empanada: "x", babero: "x", vinchas: "x",
    pieDeCuello: { tiene: "x", color: "x" },
    reata: { tipo: "x", color: "x" },
    tallaOrigen: "x", tallaMarca: "x",
    observacion: "x", observacionArquero: "x",
  },
  camisetaPolo: {
    corte: "x",
    cuello: { tipo: "x", forma: "x", falso: "x", material: "x", tecnica: "x", botones: { tiene: "x", cantidad: "x" } },
    punos: { tipo: "x", tecnica: "x" },
    vivos: "x", vivosDonde: "x", basta: { tipo: "x" },
    empanada: "x", babero: "x", vinchas: "x",
    pieDeCuello: { tiene: "x", color: "x" },
    reata: { tipo: "x", color: "x" },
    tallaOrigen: "x", tallaMarca: "x",
    observacion: "x", observacionArquero: "x",
  },
  retro: {
    tela: "x", union: "x", cierre: "x", capucha: "x", reataCapucha: "x",
    puno: "x", fajas: "x", cuello: "x",
    bolsillos: { tiene: "x", detalle: "x" },
    observacion: "x",
  },
  deportiva: {
    tela: "x", union: "x", cierre: "x", capucha: "x", reataCapucha: "x",
    puno: "x", fajas: "x", cuello: "x",
    bolsillos: { tiene: "x", detalle: "x" },
    observacion: "x",
  },
  pantaloneta: {
    tipo: "x", basta: "x",
    cordon: "x", elastico: "x",
    vivos: "x", vivosColor: "x",
    tallaOrigen: "x", tallaMarca: "x",
    franjasSublimadas: "x",
    franjasAdidas: { tiene: "x", cantidad: 1 },
    observacion: "x",
  },
  chompa: {
    modelo: "x",
    estilo: "x", cierreEstampado: "x",
    capucha: "x", cierre: "x",
    capuchaReata: { tiene: "x", medida: "x" },
    ruedo: "x", punos: { tipo: "x", forma: "x" }, tirasAdidas: "x",
    bolsillos: { tiene: "x", tipo: "x", velcro: "x" },
    velcro: { tiene: "x", descripcion: "x" },
    observacion: "x",
  },
  chompaFrio: {
    tela: "x", cierre: "x", capucha: "x",
    punos: { tipo: "x" },
    bolsillos: { tiene: "x", tipo: "x" },
    observacion: "x",
  },
  chompaFrio34: {
    tela: "x", cierre: "x", capucha: "x",
    punos: { tipo: "x" },
    bolsillos: { tiene: "x", tipo: "x" },
    observacion: "x",
  },
  rompevientos: {
    capucha: "x", capa: "x", cierre: "x",
    cierreFalso: { tiene: "x", donde: "x" },
    cierreEstampado: "x", basta: "x",
    bolsillos: { tiene: "x", tipo: "x" },
    observacion: "x",
  },
  pantalon: {
    puno: { tipo: "x" },
    basta: "x", bastaDetalle: "x",
    bolsillo: "x", franja: "x",
    tirasAdidas: "x", cordon: "x",
    vivos: "x", vivosDonde: "x",
    observacion: "x",
  },
  bermuda: {
    cordon: "x", cierre: "x", elastico: "x",
    vivos: "x", basta: "x",
    bolsillos: { tiene: "x", tipo: "x" },
    franjasSublimadas: { tiene: "x" },
    franjasAdidas: { tiene: "x", cantidad: 1 },
    tallaOrigen: "x", tallaMarca: "x",
    observacion: "x",
  },
  faldaShort: {
    cordon: "x", cierre: "x", elastico: "x",
    vivos: "x", basta: "x",
    bolsillos: { tiene: "x", tipo: "x" },
    franjasSublimadas: { tiene: "x" },
    franjasAdidas: { tiene: "x", cantidad: 1 },
    tallaOrigen: "x", tallaMarca: "x",
    observacion: "x",
  },
  licra: {
    puno: { tiene: "x", tipo: "x" },
    basta: "x", bastaDetalle: "x",
    bolsillo: "x", tirasAdidas: "x",
    velcro: { tiene: "x", descripcion: "x" },
    observacion: "x",
  },
  chaleco: { color: "x", reversible: "x", observacion: "x" },
  bolso: { material: "x", detalles: "x" },
  bvds: { detalle: "x" },
  buzoComp: { color: "x", observacion: "x" },
};

/** Mismo criterio de resolución que valorDeCampo (lib/briefContrato.ts) y el
 * `valorDe` de BloqueSpecs en IngresoContratoCliente.tsx: un id de ficha
 * también resuelve vía "<id>_tipo" o "<id>_tiene". */
const aliasesDe = (id: string) => [id, `${id}_tipo`, `${id}_tiene`];

for (const ficha of FICHAS_PRENDA) {
  test(`${ficha.clave}: todo lo que Codigo.gs recolecta tiene dónde imprimirse, y viceversa`, () => {
    const shape = COLLECT[ficha.clave];
    assert.ok(shape, `Falta la forma de collect() para "${ficha.clave}" en este test (o la clave ya no existe en Codigo.gs)`);
    const flatKeys = Object.keys(aplanarSpec(shape));
    const idsFicha = ficha.campos.map((c) => c.id).filter((id) => id !== "observacion");

    const huerfanos = flatKeys.filter((fk) => !idsFicha.some((id) => aliasesDe(id).includes(fk)));
    assert.deepEqual(huerfanos, [],
      `Codigo.gs llena estos campos pero ningún id de FICHAS_PRENDA["${ficha.clave}"] los reclama -salen como fila genérica al final, mal etiquetados.`);

    const vacios = idsFicha.filter((id) => !aliasesDe(id).some((a) => flatKeys.includes(a)));
    assert.deepEqual(vacios, [],
      `FICHAS_PRENDA["${ficha.clave}"] declara estos ids pero Codigo.gs nunca produce esa clave -la fila sale siempre vacía para un contrato migrado.`);
  });
}
