"use client";

import { useEffect } from "react";

/**
 * Mensaje flotante de error o confirmación.
 *
 * Antes cada pantalla los pintaba al principio del contenido. Al registrar un
 * movimiento o cerrar la caja —formularios que están abajo— el mensaje salía
 * fuera de la vista: la acción parecía no haber hecho nada y la gente la
 * repetía. Al ir fijo a la ventana se ve siempre, sin importar el scroll.
 *
 * El error se queda hasta que lo cierras, porque hay algo que corregir. La
 * confirmación se va sola: ya no hay nada que hacer con ella.
 */
export default function Aviso({
  error,
  aviso,
  onCerrar,
  segundos = 6,
}: {
  error?: string | null;
  aviso?: string | null;
  /** Limpia el estado en el componente padre. */
  onCerrar: (cual: "error" | "aviso") => void;
  segundos?: number;
}) {
  useEffect(() => {
    if (!aviso) return;
    const t = setTimeout(() => onCerrar("aviso"), segundos * 1000);
    return () => clearTimeout(t);
  }, [aviso, onCerrar, segundos]);

  useEffect(() => {
    if (!error && !aviso) return;
    const alTeclado = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (error) onCerrar("error");
      if (aviso) onCerrar("aviso");
    };
    window.addEventListener("keydown", alTeclado);
    return () => window.removeEventListener("keydown", alTeclado);
  }, [error, aviso, onCerrar]);

  if (!error && !aviso) return null;

  return (
    <div className="aviso-flotante no-imprimir">
      {error && (
        <div className="aviso-tarjeta es-error" role="alert">
          <span className="aviso-icono" aria-hidden="true">!</span>
          <p>{error}</p>
          <button
            type="button"
            aria-label="Cerrar mensaje"
            onClick={() => onCerrar("error")}
          >
            ×
          </button>
        </div>
      )}
      {aviso && (
        <div className="aviso-tarjeta es-ok" role="status">
          <span className="aviso-icono" aria-hidden="true">✓</span>
          <p>{aviso}</p>
          <button
            type="button"
            aria-label="Cerrar mensaje"
            onClick={() => onCerrar("aviso")}
          >
            ×
          </button>
        </div>
      )}
    </div>
  );
}
