"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { confirmarDialogo } from "./Dialogo";

/** Protege recargas/cierre y enlaces de navegación mientras hay trabajo sin guardar. */
export function useProteccionSalida(pendiente: boolean) {
  const router = useRouter();
  const preguntando = useRef(false);
  useEffect(() => {
    if (!pendiente) return;
    let autorizado = false;
    function cerrar(evento: BeforeUnloadEvent) {
      if (autorizado) return;
      evento.preventDefault();
      evento.returnValue = "";
    }
    function navegar(evento: MouseEvent) {
      if (evento.defaultPrevented || evento.button !== 0 || evento.ctrlKey || evento.metaKey || evento.shiftKey || evento.altKey) return;
      const enlace = evento.target instanceof Element ? evento.target.closest<HTMLAnchorElement>("a[href]") : null;
      if (!enlace || enlace.hasAttribute("download") || (enlace.target && enlace.target !== "_self")) return;
      const destino = new URL(enlace.href, window.location.href);
      if (!['http:', 'https:'].includes(destino.protocol)) return;
      if (destino.pathname === window.location.pathname && destino.search === window.location.search && destino.origin === window.location.origin) return;
      evento.preventDefault();
      evento.stopPropagation();
      if (preguntando.current) return;
      preguntando.current = true;
      void confirmarDialogo("Tienes cambios sin guardar o archivos pendientes de subir. ¿Quieres salir de esta pantalla?", true).then(salir => {
        if (!salir) return;
        autorizado = true;
        if (destino.origin === window.location.origin) router.push(destino.pathname + destino.search + destino.hash);
        else window.location.assign(destino.href);
      }).finally(() => { preguntando.current = false; });
    }
    window.addEventListener("beforeunload", cerrar);
    document.addEventListener("click", navegar, true);
    return () => {
      window.removeEventListener("beforeunload", cerrar);
      document.removeEventListener("click", navegar, true);
    };
  }, [pendiente, router]);
}
