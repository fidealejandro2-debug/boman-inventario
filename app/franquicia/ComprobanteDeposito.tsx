"use client";

import { useEffect, useRef, useState } from "react";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import estilos from "./ComprobanteDeposito.module.css";

export type ArchivoComprobante = {
  id: string;
  file: File;
};

const LIMITE_BYTES = 8 * 1024 * 1024;
const LIMITE_ORIGINAL_BYTES = 30 * 1024 * 1024;
const TIPOS_PERMITIDOS = [
  "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "application/pdf",
];

function pesoLegible(bytes: number) {
  return bytes >= 1024 * 1024
    ? `${(bytes / (1024 * 1024)).toFixed(1)} MB`
    : `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

async function leerImagen(file: File) {
  const url = URL.createObjectURL(file);
  try {
    const imagen = new Image();
    await new Promise<void>((resolve, reject) => {
      imagen.onload = () => resolve();
      imagen.onerror = () => reject(new Error("No se pudo leer la imagen seleccionada."));
      imagen.src = url;
    });
    return imagen;
  } finally {
    URL.revokeObjectURL(url);
  }
}

async function optimizarComprobante(original: File): Promise<File> {
  if (!TIPOS_PERMITIDOS.includes(original.type)) {
    throw new Error("Usa una foto JPG, PNG o WebP, o un comprobante PDF.");
  }
  if (original.size <= 0) throw new Error("El archivo seleccionado está vacío.");
  if (original.size > LIMITE_ORIGINAL_BYTES) throw new Error("El archivo supera el límite de 30 MB para procesarlo.");
  if (original.type === "application/pdf") {
    if (original.size > LIMITE_BYTES) throw new Error("El PDF debe pesar máximo 8 MB.");
    return original;
  }

  const imagen = await leerImagen(original);
  const escala = Math.min(1, 2200 / Math.max(imagen.naturalWidth, imagen.naturalHeight));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(imagen.naturalWidth * escala));
  canvas.height = Math.max(1, Math.round(imagen.naturalHeight * escala));
  const contexto = canvas.getContext("2d");
  if (!contexto) throw new Error("El navegador no pudo preparar la foto.");
  contexto.fillStyle = "#ffffff";
  contexto.fillRect(0, 0, canvas.width, canvas.height);
  contexto.drawImage(imagen, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.84));
  if (!blob) throw new Error("No se pudo comprimir la foto.");

  const archivo = original.size <= LIMITE_BYTES && original.size <= blob.size
    ? original
    : new File([blob], `${original.name.replace(/\.[^.]+$/, "") || "comprobante"}.jpg`, {
        type: "image/jpeg",
        lastModified: Date.now(),
      });
  if (archivo.size > LIMITE_BYTES) throw new Error("La foto supera 8 MB incluso después de optimizarla.");
  return archivo;
}

export default function ComprobanteDeposito({
  archivo,
  onChange,
  disabled = false,
}: {
  archivo: ArchivoComprobante | null;
  onChange: (archivo: ArchivoComprobante | null) => void;
  disabled?: boolean;
}) {
  const camaraRef = useRef<HTMLInputElement>(null);
  const archivoRef = useRef<HTMLInputElement>(null);
  const [procesando, setProcesando] = useState(false);
  const [vistaPrevia, setVistaPrevia] = useState<string | null>(null);

  useEffect(() => {
    if (!archivo || archivo.file.type === "application/pdf") {
      setVistaPrevia(null);
      return;
    }
    const url = URL.createObjectURL(archivo.file);
    setVistaPrevia(url);
    return () => URL.revokeObjectURL(url);
  }, [archivo]);

  async function seleccionar(files: FileList | null) {
    const original = files?.[0];
    if (!original) return;
    setProcesando(true);
    try {
      const file = await optimizarComprobante(original);
      onChange({ id: crypto.randomUUID(), file });
    } catch (error) {
      await mostrarAvisoDialogo(
        error instanceof Error ? error.message : "No se pudo preparar el comprobante.",
        "Comprobante no válido",
        true
      );
    } finally {
      setProcesando(false);
      if (camaraRef.current) camaraRef.current.value = "";
      if (archivoRef.current) archivoRef.current.value = "";
    }
  }

  const bloqueado = disabled || procesando;
  return (
    <div className={estilos.contenedor}>
      <div className={estilos.cabecera}>
        <div>
          <strong>Comprobante del depósito</strong>
          <small>Foto o PDF · se guarda de forma privada · máximo 8 MB</small>
        </div>
        <div className={estilos.acciones}>
          <button type="button" onClick={() => camaraRef.current?.click()} disabled={bloqueado}>
            {procesando ? "Preparando…" : "Tomar foto"}
          </button>
          <button type="button" className="secondary" onClick={() => archivoRef.current?.click()} disabled={bloqueado}>
            Elegir archivo
          </button>
        </div>
      </div>
      <input ref={camaraRef} hidden type="file" accept="image/*" capture="environment" onChange={(e) => void seleccionar(e.target.files)} />
      <input ref={archivoRef} hidden type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf" onChange={(e) => void seleccionar(e.target.files)} />
      {archivo && (
        <div className={estilos.archivo}>
          <div className={estilos.vista}>
            {vistaPrevia ? <img src={vistaPrevia} alt="Vista previa del comprobante" /> : "PDF"}
          </div>
          <div className={estilos.datos}>
            <strong title={archivo.file.name}>{archivo.file.name}</strong>
            <small>{pesoLegible(archivo.file.size)} · listo para subir con el depósito</small>
          </div>
          <button type="button" className="secondary btn-mini" onClick={() => onChange(null)} disabled={bloqueado}>
            Quitar
          </button>
        </div>
      )}
    </div>
  );
}
