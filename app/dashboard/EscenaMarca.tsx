"use client";

import Image from "next/image";
import { useState } from "react";
import styles from "./Dashboard.module.css";

const piezas = [
  { id: "marca", titulo: "Marca", archivo: "boman-emblema-3d.jpg", descripcion: "Emblema Boman rojo y blanco en relieve sobre fondo negro" },
  { id: "uniformes", titulo: "Uniformes", archivo: "boman-uniforme-negro-rojo.jpg", descripcion: "Diseño Boman de uniforme deportivo negro con franjas rojas y detalles dorados" },
  { id: "entrenamiento", titulo: "Entrenamiento", archivo: "boman-camiseta-entrenamiento.jpg", descripcion: "Camiseta técnica Boman azul con detalles blancos" },
] as const;

/** Piezas originales facilitadas por Boman. Cambio manual, sin rotación automática. */
export default function EscenaMarca() {
  const [seleccion, setSeleccion] = useState(0);
  const pieza = piezas[seleccion];
  return <div className={styles.brandScene}>
    <div className={styles.brandFrame} id="pieza-marca-boman">
      <Image key={pieza.id} className={styles.brandImage}
        src={`/brand/dashboard/${pieza.archivo}`} alt={pieza.descripcion}
        fill sizes="(max-width: 760px) 220px, (max-width: 1200px) 300px, 380px"
        quality={80} priority={seleccion === 0} />
    </div>
    <div className={styles.brandSelector} role="group" aria-label="Ver piezas de Boman">
      {piezas.map((item, indice) => <button key={item.id} type="button"
        aria-pressed={seleccion === indice} aria-controls="pieza-marca-boman"
        onClick={() => setSeleccion(indice)}>{item.titulo}</button>)}
    </div>
  </div>;
}
