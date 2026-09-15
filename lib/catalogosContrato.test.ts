import { test } from "node:test";
import assert from "node:assert/strict";
import { TALLAS_ADULTOS_CONTRATO, TALLAS_NINOS_CONTRATO } from "./catalogosContrato.ts";

test("XXS (14) es talla infantil estandar y conserva su orden", () => {
  assert.equal(TALLAS_NINOS_CONTRATO.at(-2), "36 (12)");
  assert.equal(TALLAS_NINOS_CONTRATO.at(-1), "XXS (14)");
  assert.equal((TALLAS_ADULTOS_CONTRATO as readonly string[]).includes("XXS (14)"), false);
});
