"use client";

import { useEffect, useId, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { useFocoDialogo } from "./useFocoDialogo";

export default function ModalOperativo({ titulo, onCerrar, children }: {
  titulo: string; onCerrar: () => void; children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const tituloId = useId();
  const cerrarRef = useRef(onCerrar);
  cerrarRef.current = onCerrar;
  useFocoDialogo(ref, true);
  useEffect(() => {
    function teclado(evento: KeyboardEvent) {
      if (evento.key === "Escape" && !evento.defaultPrevented && !ref.current?.closest('[inert]')) {
        evento.preventDefault(); cerrarRef.current();
      }
    }
    window.addEventListener("keydown", teclado);
    return () => window.removeEventListener("keydown", teclado);
  }, []);
  return createPortal(
    <div className="modal-operativo" onMouseDown={e => { if (e.target === e.currentTarget) onCerrar(); }}>
      <div ref={ref} className="modal-contenido ancho" role="dialog" aria-modal="true" aria-labelledby={tituloId} tabIndex={-1}>
        <div className="header-row"><h2 id={tituloId}>{titulo}</h2><button type="button" className="secondary" onClick={onCerrar}>Cerrar</button></div>
        {children}
      </div>
    </div>, document.body
  );
}
