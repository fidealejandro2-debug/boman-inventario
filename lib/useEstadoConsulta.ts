"use client";

import { useSyncExternalStore } from "react";
import { escribirConsulta, leerConsulta, type EstadoConsulta } from "./estadoConsulta";

const EVENTO = "boman:consulta";
type Valores<T> = { [K in keyof T]: T[K] extends boolean ? boolean : T[K] extends number ? number : string };
function suscribir(avisar: () => void) {
  window.addEventListener("popstate", avisar);
  window.addEventListener(EVENTO, avisar);
  return () => {
    window.removeEventListener("popstate", avisar);
    window.removeEventListener(EVENTO, avisar);
  };
}

/** Conserva el contexto en el historial, sin guardar datos de trabajo en el dispositivo. */
export function useEstadoConsulta<T extends EstadoConsulta>(inicial: T) {
  const base = inicial as Valores<T>;
  const consulta = useSyncExternalStore(suscribir, () => window.location.search, () => "");
  const estado = leerConsulta(consulta, base);
  function actualizar(cambio: Partial<Valores<T>> | ((actual: Valores<T>) => Partial<Valores<T>>), agregarHistorial = false) {
    const actual = leerConsulta(window.location.search, base);
    const siguiente = { ...actual, ...(typeof cambio === "function" ? cambio(actual) : cambio) };
    const busqueda = escribirConsulta(window.location.search, siguiente, base);
    if (busqueda === window.location.search) return;
    const destino = `${window.location.pathname}${busqueda}${window.location.hash}`;
    if (agregarHistorial) window.history.pushState(null, "", destino);
    else window.history.replaceState(null, "", destino);
    window.dispatchEvent(new Event(EVENTO));
  }
  return [estado, actualizar] as const;
}
