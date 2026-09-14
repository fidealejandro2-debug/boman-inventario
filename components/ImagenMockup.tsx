"use client";

/* eslint-disable @next/next/no-img-element */
import { useEffect, useMemo, useState, type ImgHTMLAttributes, type ReactNode } from "react";

type Props = Omit<ImgHTMLAttributes<HTMLImageElement>, "src"> & {
  driveId?: string | null;
  url?: string | null;
  ancho?: number;
  vacio?: ReactNode;
};

function idDeDrive(valor?: string | null) {
  const limpio = valor?.trim();
  if (!limpio) return "";
  if (/^[a-zA-Z0-9_-]{10,}$/.test(limpio)) return limpio;
  return limpio.match(/\/d\/([a-zA-Z0-9_-]+)/)?.[1]
    || limpio.match(/[?&]id=([a-zA-Z0-9_-]+)/)?.[1]
    || "";
}

function listaFuentes(driveId?: string | null, url?: string | null, ancho = 700) {
  const directa = url?.trim() || "";
  const id = idDeDrive(driveId) || idDeDrive(directa);
  const fuentes: string[] = [];

  // Los archivos nuevos viven en Storage y su URL publica es la fuente mas
  // estable. Los enlaces antiguos de Drive requieren una miniatura directa.
  if (directa && !/drive\.google\.com|googleusercontent\.com/i.test(directa)) fuentes.push(directa);
  if (id) {
    fuentes.push(`https://lh3.googleusercontent.com/d/${encodeURIComponent(id)}=w${ancho}`);
    fuentes.push(`https://drive.google.com/thumbnail?id=${encodeURIComponent(id)}&sz=w${ancho}`);
  }
  if (directa) fuentes.push(directa);
  return [...new Set(fuentes)];
}

/** Imagen tolerante a enlaces heredados: prueba Storage, dos rutas de Drive y
 * finalmente oculta el icono roto si ninguna fuente puede entregar el mockup. */
export default function ImagenMockup({ driveId, url, ancho = 700, vacio = null, onError, ...imgProps }: Props) {
  const fuentes = useMemo(() => listaFuentes(driveId, url, ancho), [driveId, url, ancho]);
  const clave = fuentes.join("|");
  const [indice, setIndice] = useState(0);

  useEffect(() => { setIndice(0); }, [clave]);

  const fuente = fuentes[indice];
  if (!fuente) return <>{vacio}</>;

  return <img
    {...imgProps}
    src={fuente}
    referrerPolicy="no-referrer"
    onError={(evento) => {
      onError?.(evento);
      setIndice((actual) => actual + 1);
    }}
  />;
}
