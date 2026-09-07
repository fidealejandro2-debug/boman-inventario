"use client";

import { useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { PortadaProducto } from "@/lib/portadasProductos";

export default function ProductoConImagen({
  nombre,
  sku,
  portada,
  onAbrirGaleria,
}: {
  nombre: string;
  sku: string;
  portada?: PortadaProducto;
  onAbrirGaleria?: () => void;
}) {
  const referencia = useRef<HTMLSpanElement>(null);
  const [posicion, setPosicion] = useState<{ top: number; left: number } | null>(null);

  function mostrar() {
    if (!portada || !referencia.current) return;
    const caja = referencia.current.getBoundingClientRect();
    const ancho = 300;
    const left = Math.min(Math.max(12, caja.left), window.innerWidth - ancho - 12);
    const cabeArriba = caja.bottom + 330 > window.innerHeight;
    setPosicion({
      left,
      top: cabeArriba ? Math.max(12, caja.top - 318) : caja.bottom + 8,
    });
  }

  return (
    <span
      ref={referencia}
      className={`producto-con-imagen ${portada ? "tiene-imagen" : ""}`}
      tabIndex={portada ? 0 : undefined}
      onMouseEnter={mostrar}
      onMouseLeave={() => setPosicion(null)}
      onFocus={mostrar}
      onBlur={() => setPosicion(null)}
    >
      {portada ? (
        <button
          type="button"
          className="producto-miniatura"
          onClick={onAbrirGaleria}
          aria-label={onAbrirGaleria ? `Administrar fotos de ${nombre}` : `Ver foto de ${nombre}`}
        >
          <img src={portada.url} alt="" loading="lazy" />
        </button>
      ) : onAbrirGaleria ? (
        <button
          type="button"
          className="producto-miniatura producto-sin-foto"
          onClick={onAbrirGaleria}
          aria-label={`Agregar foto a ${nombre}`}
          title="Agregar foto"
        >
          +
        </button>
      ) : null}
      <span className="producto-nombre">{nombre}</span>
      {portada && posicion && createPortal(
        <span
          className="producto-previsualizacion"
          style={{ top: posicion.top, left: posicion.left }}
          role="tooltip"
        >
          <img src={portada.url} alt={`Vista previa de ${nombre}`} />
          <span><strong>{sku}</strong> · {nombre}</span>
          {portada.descripcion && <small>{portada.descripcion}</small>}
        </span>,
        document.body
      )}
    </span>
  );
}
