import { test } from "node:test";
import assert from "node:assert/strict";
import { mensajeError, esFaltaMigracion } from "./errores.ts";

test("reconoce una migración sin correr, venga como venga el mensaje", () => {
  // Las tres redacciones que PostgREST y Postgres usan para lo mismo.
  for (const m of [
    "Could not find the function public.marcar_etapa_contrato_v116 in the schema cache",
    'function public.columnas_tablero_v121() does not exist',
    'no existe la función public.foo()',
  ]) assert.ok(esFaltaMigracion({ message: m }), m);
});

test("nombra el archivo que hay que correr", () => {
  const m = mensajeError({ message: "Could not find the function public.x in the schema cache" }, "v124_tablero_entregados.sql");
  assert.ok(m.includes("v124_tablero_entregados.sql"));
  // Sin archivo, al menos dice dónde mirar.
  assert.ok(mensajeError({ message: "does not exist" }).includes("que_migraciones_faltan"));
});

test("un error desconocido se muestra tal cual, no se disfraza", () => {
  // Inventar una redacción esconde informacion al que tiene que arreglarlo.
  assert.equal(mensajeError({ message: "deadlock detected" }), "deadlock detected");
});

test("no confunde un error normal con una migración faltante", () => {
  assert.ok(!esFaltaMigracion({ message: "El monto debe ser mayor que cero" }));
  assert.equal(mensajeError({ message: "El monto debe ser mayor que cero" }), "El monto debe ser mayor que cero");
});

test("sin error devuelve algo accionable, no vacío", () => {
  assert.ok(mensajeError(null).length > 10);
  assert.ok(mensajeError({ message: "   " }).length > 10);
});
