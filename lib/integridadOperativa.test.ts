import { test } from "node:test";
import assert from "node:assert/strict";
import {
  calcularCierreCaja,
  calcularStockOperativo,
  diferenciaPagos,
  normalizarBeneficiosNomina,
} from "./integridadOperativa.ts";
import { hashContrato, mapearContrato } from "./bomansportContratos.ts";

test("ventas: los pagos mixtos deben cuadrar a centavos", () => {
  assert.equal(diferenciaPagos(30, [10.1, "19.90", ""]), 0);
  assert.equal(diferenciaPagos(30, [10, 19.99]), -0.01);
  assert.equal(diferenciaPagos(30, [15, 15.01]), 0.01);
});

test("caja: saldo esperado y diferencia conservan signo y centavos", () => {
  assert.deepEqual(calcularCierreCaja({
    saldoInicial: 6.78,
    ingresosEfectivo: 100.12,
    egresosEfectivo: 20.1,
    efectivoContado: 86.79,
  }), { saldoEsperado: 86.8, diferencia: -0.01 });
});

test("inventario: las reservas nunca producen disponibilidad negativa", () => {
  assert.deepEqual(calcularStockOperativo({
    fisico: 3, reservado: 5, transitoEntrada: 0, puntoReposicion: 2, stockMaximo: 10,
  }), { disponible: 0, sugeridoReponer: 10 });
});

test("inventario: el tránsito evita sugerir una reposición innecesaria", () => {
  assert.equal(calcularStockOperativo({
    fisico: 2, reservado: 0, transitoEntrada: 5, puntoReposicion: 4, stockMaximo: 10,
  }).sugeridoReponer, 0);
});

test("nómina: una persona no afiliada no mensualiza ningún décimo", () => {
  assert.deepEqual(normalizarBeneficiosNomina({
    afiliado: false, decimoTercero: true, decimoCuarto: true, fondosMensual: false,
  }), { decimoTercero: false, decimoCuarto: false, fondosMensual: true });
});

test("nómina: una persona afiliada conserva su elección de beneficios", () => {
  assert.deepEqual(normalizarBeneficiosNomina({
    afiliado: true, decimoTercero: true, decimoCuarto: false, fondosMensual: false,
  }), { decimoTercero: true, decimoCuarto: false, fondosMensual: false });
});

test("contratos: una fila válida se normaliza y una fecha rota no aborta el lote", () => {
  const resultado = mapearContrato({
    numero: "BOM-2026-1234", cliente: " Equipo Azul ", totalPrendas: "12.9",
    fechaIngreso: "11/09/2026", fechaEntrega: "2026-09-20",
  });
  assert.equal(resultado.ok, true);
  if (resultado.ok) {
    assert.equal(resultado.contrato.cliente, "Equipo Azul");
    assert.equal(resultado.contrato.total_prendas, 12);
    assert.equal(resultado.contrato.fecha_ingreso, null);
    assert.equal(resultado.contrato.fecha_entrega, "2026-09-20");
  }
});

test("contratos: el hash no cambia por el orden de las propiedades", () => {
  assert.equal(hashContrato({ numero: "BOM-2026-1234", extra: { a: 1, b: 2 } }),
    hashContrato({ extra: { b: 2, a: 1 }, numero: "BOM-2026-1234" }));
});
