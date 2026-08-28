const CACHE_NAME = "boman-shell-v2";
const APP_SHELL = ["/login", "/boman-logo.png", "/manifest.webmanifest"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => Promise.allSettled(APP_SHELL.map((url) => cache.add(url))))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// No se cachean datos privados ni se encolan movimientos de inventario.
// La idempotencia y los estados de documento protegen los reintentos en línea.
// Lo único que se cachea aquí es el "app shell" (HTML de páginas visitadas,
// JS/CSS estáticos y el logo) para que la app cargue algo si se pierde la
// conexión en bodega. Las llamadas a la API/Supabase (POST, /api/, u otro
// origen) nunca pasan por cache.
self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  const esEstatico = url.pathname.startsWith("/_next/static/") || url.pathname === "/boman-logo.png";

  if (esEstatico) {
    event.respondWith(
      caches.match(request).then(
        (cached) =>
          cached ||
          fetch(request).then((res) => {
            const copia = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copia));
            return res;
          })
      )
    );
    return;
  }

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request)
        .then((res) => {
          const copia = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copia));
          return res;
        })
        .catch(() => caches.match(request).then((cached) => cached || caches.match("/login")))
    );
  }
});
