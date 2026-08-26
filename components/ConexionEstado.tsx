"use client";

import { useEffect, useState } from "react";

export default function ConexionEstado() {
  const [enLinea, setEnLinea] = useState(true);
  useEffect(() => {
    setEnLinea(navigator.onLine);
    const online = () => setEnLinea(true);
    const offline = () => setEnLinea(false);
    window.addEventListener("online", online);
    window.addEventListener("offline", offline);
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => undefined);
    return () => { window.removeEventListener("online", online); window.removeEventListener("offline", offline); };
  }, []);
  if (enLinea) return null;
  return <div className="aviso-offline" role="status">Sin conexión: conserva esta pantalla abierta. No se enviarán operaciones hasta recuperar internet.</div>;
}
