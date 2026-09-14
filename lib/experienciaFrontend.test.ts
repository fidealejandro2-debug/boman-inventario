import { test } from "node:test";
import assert from "node:assert/strict";
import { validarContactosCliente } from "./contactosCliente.ts";
import { leerConsulta, escribirConsulta } from "./estadoConsulta.ts";

test("clientes: rechaza filas incompletas que la RPC descartaría silenciosamente", () => {
  assert.match(validarContactosCliente([{ tipo: "telefono", valor: "", etiqueta: "Compras" }], [])!, /Contacto 1/);
  assert.match(validarContactosCliente([], [{ direccion: "", etiqueta: "Entrega" }])!, /Dirección 1/);
  assert.match(validarContactosCliente([{ tipo: "telefono", valor: "12" }], [])!, /3 caracteres/);
  assert.match(validarContactosCliente([], [{ direccion: "1234" }])!, /5 caracteres/);
});

test("clientes: conserva contactos y direcciones estructurados, incluso con barras y saltos", () => {
  const contactos = [{ tipo: "telefono", valor: "0999999999", etiqueta: "Compras | principal", principal: true }];
  const direcciones = [{ direccion: "Ambato\nCalle A | local 2", etiqueta: "Entrega", principal: true }];
  const copia = structuredClone({ contactos, direcciones });
  assert.equal(validarContactosCliente(contactos, direcciones), null);
  assert.deepEqual({ contactos, direcciones }, copia);
  assert.equal(validarContactosCliente([], []), null);
});

test("clientes: detecta correos inválidos y duplicados antes de guardar", () => {
  assert.match(validarContactosCliente([{ tipo: "email", valor: "sin-correo" }], [])!, /correo/);
  assert.match(validarContactosCliente([{ tipo: "email", valor: "A@b.com" }, { tipo: "email", valor: "a@b.com " }], [])!, /Contacto 2.*ya está/);
  assert.match(validarContactosCliente([], [{ direccion: "Calle Uno" }, { direccion: " Calle Uno " }])!, /Dirección 2.*ya está/);
  assert.equal(validarContactosCliente([{ tipo: "telefono", valor: "0999999999" }, { tipo: "whatsapp", valor: "0999999999" }], []), null);
});

test("consulta: volver a la URL recupera local, búsqueda, página y vista sin perder otros parámetros", () => {
  const inicial = { local: "", buscar: "", pagina: 1, completa: false, ocultarCero: true };
  const estado = { local: "local-1", buscar: "camiseta azul + niño", pagina: 4, completa: true, ocultarCero: false };
  const url = escribirConsulta("?origen=panel", estado, inicial);
  assert.deepEqual(leerConsulta(url, inicial), estado);
  assert.equal(new URLSearchParams(url).get("origen"), "panel");
  assert.equal(escribirConsulta(url, inicial, inicial), "?origen=panel");
});

test("consulta: valores corruptos no producen páginas negativas, infinitas o flags inesperados", () => {
  for (const valor of ["-1", "0", "1.5", "NaN", "Infinity", "9007199254740993", ""]) {
    assert.equal(leerConsulta(`?pagina=${valor}`, { pagina: 1 }).pagina, 1);
  }
  assert.equal(leerConsulta("?ocultarCero=erroneo", { ocultarCero: true }).ocultarCero, true);
  assert.equal(leerConsulta("?ocultarCero=0", { ocultarCero: true }).ocultarCero, false);
  assert.deepEqual(leerConsulta("?__proto__=otro&tab=roles", { tab: "personal" }), { tab: "roles" });
});
