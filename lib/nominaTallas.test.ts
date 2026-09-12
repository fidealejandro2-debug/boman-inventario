import { test } from "node:test";
import assert from "node:assert/strict";
import { aplanarLineas, compararNominaTallas, textoDiferencias, type LineaTallas } from "./nominaTallas.ts";

const linea = (p: Partial<LineaTallas>): LineaTallas => ({
  prenda: "Camiseta Jugador", calidad: "Amateur",
  adultos: {}, ninos: {}, espA: [], espN: [], ...p,
});

test("mismo total pero talla distinta: ESTE es el caso que hay que detectar", () => {
  // 10 en la nomina y 10 en la matriz. Un control de totales diria que esta
  // cuadrado; el taller cortaria 10 L cuando los jugadores son M.
  const nomina = [linea({ adultos: { M: { H: 10, M: 0 } } })];
  const matriz = [linea({ adultos: { L: { H: 10, M: 0 } } })];
  const r = compararNominaTallas(nomina, matriz);
  assert.equal(r.coincide, false);
  assert.equal(r.totalNomina, 10);
  assert.equal(r.totalMatriz, 10);
  assert.equal(r.mismoTotal, true);
  assert.equal(r.diferencias.length, 2);
  const texto = textoDiferencias(r);
  assert.ok(texto.includes("Los totales coinciden"));
  assert.ok(texto.includes("talla M"));
  assert.ok(texto.includes("talla L"));
});

test("cuando coincide de verdad no avisa nada", () => {
  const iguales = [linea({ adultos: { M: { H: 4, M: 2 } }, ninos: { "28 (4)": 1 } })];
  const r = compararNominaTallas(iguales, [linea({ adultos: { M: { H: 4, M: 2 } }, ninos: { "28 (4)": 1 } })]);
  assert.equal(r.coincide, true);
  assert.equal(r.diferencias.length, 0);
  assert.equal(textoDiferencias(r), "");
});

test("el genero cuenta: 10 de mujer no son 10 de hombre", () => {
  // Es otro corte, no la misma prenda.
  const r = compararNominaTallas(
    [linea({ adultos: { M: { H: 0, M: 10 } } })],
    [linea({ adultos: { M: { H: 10, M: 0 } } })],
  );
  assert.equal(r.coincide, false);
  assert.ok(textoDiferencias(r).includes("mujer"));
});

test("la calidad cuenta: Amateur no cubre Semiprofesional", () => {
  const r = compararNominaTallas(
    [linea({ calidad: "Amateur", adultos: { M: { H: 5, M: 0 } } })],
    [linea({ calidad: "Semiprofesional", adultos: { M: { H: 5, M: 0 } } })],
  );
  assert.equal(r.coincide, false);
  assert.equal(r.diferencias.length, 2);
});

test("una talla especial sin nombre es un hueco, no una talla", () => {
  // La matriz reserva tres filas de talla especial que el vendedor nombra a
  // mano. Contar las vacias inventaria diferencias en todos los contratos.
  const conHueco = [linea({ espA: [{ nombre: "", H: 3, M: 0 }, { nombre: "TALLA ESPECIAL", H: 2, M: 0 }] })];
  const plano = aplanarLineas(conHueco);
  assert.equal(Array.from(plano.values()).reduce((s, n) => s + n, 0), 2);
});

test("las tallas especiales nombradas si se comparan", () => {
  const r = compararNominaTallas(
    [linea({ espA: [{ nombre: "TALLA ESPECIAL", H: 2, M: 0 }] })],
    [linea({ espA: [{ nombre: "TALLA ESPECIAL", H: 1, M: 0 }] })],
  );
  assert.equal(r.coincide, false);
  assert.deepEqual(r.diferencias[0], {
    prenda: "Camiseta Jugador", calidad: "Amateur", talla: "TALLA ESPECIAL",
    genero: "H", nomina: 2, matriz: 1,
  });
});

test("una prenda que la nomina no implica aparece como sobrante", () => {
  const r = compararNominaTallas(
    [linea({ adultos: { M: { H: 5, M: 0 } } })],
    [linea({ adultos: { M: { H: 5, M: 0 } } }), linea({ prenda: "Medias", adultos: { M: { H: 5, M: 0 } } })],
  );
  assert.equal(r.coincide, false);
  assert.equal(r.diferencias.length, 1);
  assert.equal(r.diferencias[0].prenda, "Medias");
  assert.equal(r.diferencias[0].nomina, 0);
  assert.ok(!r.mismoTotal, "los totales NO coinciden aqui");
});

test("sin nomina y sin matriz no hay nada que avisar", () => {
  const r = compararNominaTallas([], []);
  assert.equal(r.coincide, true);
  assert.equal(r.totalNomina, 0);
});

test("el aviso se corta y dice cuantas diferencias quedan fuera", () => {
  const muchas = Array.from({ length: 12 }, (_, i) =>
    linea({ prenda: `Prenda ${String(i).padStart(2, "0")}`, adultos: { M: { H: i + 1, M: 0 } } }));
  const r = compararNominaTallas(muchas, []);
  assert.equal(r.diferencias.length, 12);
  const texto = textoDiferencias(r, 5);
  assert.ok(texto.includes("y 7 diferencia(s) más"));
  // Un dialogo de cincuenta renglones se cierra sin leerlo.
  assert.ok(texto.split("\n").filter((l) => l.startsWith("•")).length === 6);
});

test("el aviso siempre dice quien manda en el taller", () => {
  const r = compararNominaTallas([linea({ adultos: { M: { H: 1, M: 0 } } })], []);
  assert.ok(textoDiferencias(r).includes("tabla de tallas"));
  assert.ok(textoDiferencias(r).includes("¿Seguro quieres continuar?"));
  assert.ok(textoDiferencias(r).includes("jugadores 1, subtotal 0"));
});
