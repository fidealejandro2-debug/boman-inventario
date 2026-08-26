self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
// No se cachean datos privados ni se encolan movimientos de inventario.
// La idempotencia y los estados de documento protegen los reintentos en línea.
