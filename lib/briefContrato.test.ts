// Pruebas de las reglas del brief. Se corren con `npm test` (node --test, sin
// ninguna dependencia: Node 24 ejecuta TypeScript directo).
//
// Cada caso de aquí corresponde a un fallo REAL que llegó a producción y que
// nadie detectó hasta que alguien miró un papel impreso. No son ejemplos
// inventados para tener cobertura: son la red que faltaba.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  aplanarSpec, leerSpec, valorDeCampo, grupoPrendaJugador, compararJugadores,
  etiquetaGrupo, cuentaGrupo, tallaQueOrdena, TIPOS_SIN_MANGA, ABREV_TIPO,
  normalizarAdicionalesContrato, adicionalesDesdeDatosContrato,
  type JugadorBrief,
} from "./briefContrato.ts";

const ORDEN = {
  calidad: ["Competición", "Profesional", "Semiprofesional", "Estándar", "Amateur"],
  genero: { Hombre: 0, Mujer: 1, "Niño": 2, "Niña": 2 } as Record<string, number>,
  manga: { Corta: 0, "": 0, Larga: 1 } as Record<string, number>,
  tipo: ["Uniforme completo", "Arquero completo", "Solo camiseta", "Solo pantaloneta"],
  talla: (t: string) => ["XS", "S", "M", "L", "XL"].indexOf(t),
};

const jug = (p: Partial<JugadorBrief>): JugadorBrief => ({
  nombre: "", numero: "", categoria: "Hombre", talla_superior: "M",
  talla_inferior: "", manga: "Corta", calidad: "Amateur", tipo_uniforme: "Uniforme completo", ...p,
});

test("los adicionales del AppScript conservan medias, cantidades y medidas", () => {
  const ad = normalizarAdicionalesContrato(JSON.stringify({
    medias: "Incluye medias", cantidadMedias: "3",
    bandera: "Con bandera", cantidadBanderas: "1",
    medidas: "1,50 × 0,90", otros: "Incluye funda",
  }));
  assert.deepEqual(ad.items, [
    { tipo: "Medias", valor: "Incluye medias", cantidad: 3 },
    { tipo: "Bandera", valor: "Con bandera", cantidad: 1 },
  ]);
  assert.equal(ad.medidas_bandera, "1,50 × 0,90");
  assert.equal(ad.detalle, "Incluye funda");
});

test("el selector histórico de medias no duplica polainas", () => {
  const ad = normalizarAdicionalesContrato({
    medias: "Incluye polainas", cantidadMedias: 14,
    polainas: "Incluye polainas", cantidadPolainas: 9,
  });
  assert.deepEqual(ad.items, [
    { tipo: "Polainas", valor: "Incluye polainas", cantidad: 14 },
  ]);
});

test("los adicionales nuevos mantienen su estructura", () => {
  const ad = normalizarAdicionalesContrato({
    detalle: "Empaque especial",
    items: [{ tipo: "Medias", valor: "Incluye personalizadas", cantidad: 5 }],
    medidas_bandera: "2 × 1 m",
  });
  assert.equal(ad.detalle, "Empaque especial");
  assert.deepEqual(ad.items, [{ tipo: "Medias", valor: "Incluye personalizadas", cantidad: 5 }]);
  assert.equal(ad.medidas_bandera, "2 × 1 m");
});

test("el importador encuentra Adicionales dentro de extra como lo entrega AppScript", () => {
  const ad = adicionalesDesdeDatosContrato({
    adicionales: {},
    extra: {
      Adicionales: JSON.stringify({
        medias: "Incluye medias", cantidadMedias: "20",
        bandaCapitan: "Con banda de capitán", cantidadBandas: "1",
        bandera: "Con bandera", cantidadBanderas: "1",
      }),
    },
  });
  assert.deepEqual(ad.items, [
    { tipo: "Medias", valor: "Incluye medias", cantidad: 20 },
    { tipo: "Banda de Capitán", valor: "Con banda de capitán", cantidad: 1 },
    { tipo: "Bandera", valor: "Con bandera", cantidad: 1 },
  ]);
});

// ── Especificaciones migradas de BomanSport ──────────────────────────────

test("la spec anidada del legado se aplana a los ids de la ficha", () => {
  const campos = aplanarSpec({
    corte: "Recta",
    cuello: { tipo: "Normal", forma: "Redondo", material: "Tela" },
    punos: { tipo: "Aparte Rib", tecnica: "Sublimado" },
    tallaOrigen: "Nacional",
  });
  assert.equal(campos.cuello_tipo, "Normal");
  assert.equal(campos.cuello_forma, "Redondo");
  assert.equal(campos.punos_tecnica, "Sublimado");
  // camelCase -> snake_case: si no, este campo no cae en su etiqueta.
  assert.equal(campos.talla_origen, "Nacional");
});

test("nunca sale [object Object] por muy anidada que venga la spec", () => {
  const campos = aplanarSpec({ cuello: { tipo: "Normal", botones: { tiene: "Sí", cantidad: 3 } } });
  for (const v of Object.values(campos)) assert.ok(!v.includes("[object"), `valor crudo: ${v}`);
  assert.equal(campos.cuello_botones_tiene, "Sí");
});

test("los valores no se apelmazan en un solo campo", () => {
  // El bug: {cuello:{...6 valores}} salia como un unico "Cuello: a · b · c…".
  const campos = aplanarSpec({ cuello: { tipo: "Normal", forma: "Redondo", falso: "No", material: "Tela" } });
  assert.equal(Object.keys(campos).length, 4);
});

test("'variante' (mockup/calidad/otro) es metadata del título, no una fila de la ficha", () => {
  // En Codigo.gs, _etqVar_ usa spec.variante SOLO para el título (" — Mockup 2 ·
  // Profesional"); nunca se imprime como dato. bomansportProduccion.ts guarda el
  // spec migrado tal cual, con ese "variante" adentro, así que sin este skip
  // aparecía como "Variante mockup / Variante calidad / Variante otro" en la ficha.
  const campos = aplanarSpec({
    corte: "Recta",
    variante: { mockup: "Mockup 2", calidad: "Profesional", otro: "nota" },
  });
  assert.equal(campos.corte, "Recta");
  assert.equal(campos.variante_mockup, undefined);
  assert.equal(campos.variante_calidad, undefined);
  assert.equal(campos.variante_otro, undefined);
  // El formato legado {tipo,valor} usa la misma clave "variante": igual se ignora.
  const legado = aplanarSpec({ variante: { tipo: "mockup", valor: "Mockup 1" } });
  assert.deepEqual(legado, {});
});

test("leerSpec entiende la forma nueva, la vieja y la anidada", () => {
  assert.equal(leerSpec({ campos: { basta: "Normal" }, observacion: "ojo" }).campos.basta, "Normal");
  assert.equal(leerSpec({ indicaciones: "texto viejo" }).observacion, "texto viejo");
  assert.equal(leerSpec({ cuello: { tipo: "Polo" } }).campos.cuello_tipo, "Polo");
  // Nunca volcar JSON crudo en pantalla.
  assert.deepEqual(leerSpec(null), { campos: {}, observacion: "" });
});

test("un campo guardado como {tipo} cae en la etiqueta que la ficha espera", () => {
  const campos = aplanarSpec({ basta: { tipo: "Normal" }, pieDeCuello: { tiene: "Sí", color: "Negro" } });
  const usadas = new Set<string>();
  assert.equal(valorDeCampo(campos, "basta", usadas), "Normal");
  assert.equal(valorDeCampo(campos, "pie_de_cuello", usadas), "Sí");
  assert.equal(valorDeCampo(campos, "pie_de_cuello_color", usadas), "Negro");
  // Lo consumido no debe reimprimirse suelto al final de la ficha.
  assert.ok(usadas.has("basta_tipo") && usadas.has("pie_de_cuello_tiene"));
});

// ── Orden y agrupación de jugadores ──────────────────────────────────────

test("el alcance de prenda agrupa en tramos limpios", () => {
  // El bug: ordenar por tipo alfabetico separaba "Arquero completo" de
  // "Uniforme completo" -el mismo grupo- con un "Solo camiseta" en medio, y
  // entonces el grupo abria DOS bandas en la misma calidad.
  const lista = [
    jug({ nombre: "A", tipo_uniforme: "Solo camiseta" }),
    jug({ nombre: "B", tipo_uniforme: "Uniforme completo" }),
    jug({ nombre: "C", tipo_uniforme: "Arquero completo" }),
    jug({ nombre: "D", tipo_uniforme: "Solo pantaloneta", talla_superior: "", talla_inferior: "M" }),
  ].sort((a, b) => compararJugadores(a, b, ORDEN));
  const grupos = lista.map((j) => grupoPrendaJugador(j.tipo_uniforme));
  assert.deepEqual(grupos, [0, 0, 1, 2]);
  // Cada grupo aparece una sola vez: ningun tramo se repite.
  assert.equal(new Set(grupos).size, grupos.filter((g, i) => g !== grupos[i - 1]).length);
});

test("la calidad manda sobre todo lo demás", () => {
  const lista = [
    jug({ nombre: "A", calidad: "Amateur", tipo_uniforme: "Uniforme completo" }),
    jug({ nombre: "B", calidad: "Competición", tipo_uniforme: "Solo camiseta" }),
  ].sort((a, b) => compararJugadores(a, b, ORDEN));
  assert.deepEqual(lista.map((j) => j.calidad), ["Competición", "Amateur"]);
});

test("quien solo lleva prenda inferior se ordena por su talla de abajo", () => {
  // Usar siempre la superior lo mandaba al final, porque viene vacia.
  assert.equal(tallaQueOrdena(jug({ tipo_uniforme: "Solo pantaloneta", talla_superior: "", talla_inferior: "S" })), "S");
  assert.equal(tallaQueOrdena(jug({ talla_superior: "L", talla_inferior: "M" })), "L");
});

test("la sub-banda dice el tipo concreto cuando el tramo es uno solo", () => {
  const lista = [jug({ tipo_uniforme: "Solo camiseta" }), jug({ tipo_uniforme: "Solo camiseta" })];
  assert.equal(etiquetaGrupo(lista, 0), "Solo camiseta");
  assert.equal(cuentaGrupo(lista, 0), 2);
});

test("la sub-banda generaliza cuando el tramo mezcla tipos del mismo alcance", () => {
  const lista = [jug({ tipo_uniforme: "Solo camiseta" }), jug({ tipo_uniforme: "Solo BVD" })];
  assert.equal(etiquetaGrupo(lista, 0), "Solo parte superior");
});

test("el tramo se corta al cambiar de calidad", () => {
  const lista = [
    jug({ tipo_uniforme: "Solo camiseta", calidad: "Amateur" }),
    jug({ tipo_uniforme: "Solo camiseta", calidad: "Profesional" }),
  ];
  assert.equal(cuentaGrupo(lista, 0), 1);
});

// ── Lo que se imprime en cada celda ──────────────────────────────────────

test("las prendas sin manga no dicen 'corta'", () => {
  // Decir "corta" de una pantaloneta o una chompa es informacion falsa en el
  // papel con el que corta el taller.
  for (const t of ["Solo pantaloneta", "Chompa", "Chaleco", "Solo BVD"]) {
    assert.ok(TIPOS_SIN_MANGA.has(t), `${t} deberia imprimir "—" en MANGA`);
  }
  assert.ok(!TIPOS_SIN_MANGA.has("Uniforme completo"));
  assert.ok(!TIPOS_SIN_MANGA.has("Solo camiseta"));
});

test("el tipo abreviado no pierde el significado", () => {
  assert.equal(ABREV_TIPO["Uniforme completo"], "Completo");
  assert.equal(ABREV_TIPO["BVD + Pantaloneta"], "BVD+Pant");
  // Lo que no esta en el mapa se imprime tal cual, no vacio.
  assert.equal(ABREV_TIPO["Personalizado"], undefined);
});
