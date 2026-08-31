"use client";

import { useEffect, useState } from "react";
import {
  documentosDe,
  subirDocumento,
  TIPOS_DOCUMENTO,
  type DocumentoEmpleado,
} from "./documentos";

/**
 * Elige un documento de respaldo del expediente, o sube uno en el momento.
 * Lo usan los flujos que exigen respaldo: finiquito (v33), reducción de
 * sueldo y desafiliación (v32), justificante de ausencia (v27).
 */
export default function SelectorDocumento({
  empleadoId,
  valor,
  onCambio,
  tipoSugerido = "otro",
  etiqueta = "Documento de respaldo",
  requerido = false,
}: {
  empleadoId: string | null;
  valor: string | null;
  onCambio: (documentoId: string | null) => void;
  tipoSugerido?: string;
  etiqueta?: string;
  requerido?: boolean;
}) {
  const [documentos, setDocumentos] = useState<DocumentoEmpleado[]>([]);
  const [subiendo, setSubiendo] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [modo, setModo] = useState<"elegir" | "subir">("elegir");
  const [archivo, setArchivo] = useState<File | null>(null);
  const [nombre, setNombre] = useState("");
  const [tipo, setTipo] = useState(tipoSugerido);

  async function cargar() {
    if (!empleadoId) return setDocumentos([]);
    const { documentos, error } = await documentosDe(empleadoId);
    if (error) setError(error);
    else setDocumentos(documentos);
  }

  useEffect(() => {
    let vigente = true;
    setDocumentos([]);
    setError(null);
    if (!empleadoId) return () => { vigente = false; };

    void (async () => {
      const resultado = await documentosDe(empleadoId);
      if (!vigente) return;
      if (resultado.error) setError(resultado.error);
      else setDocumentos(resultado.documentos);
    })();

    return () => { vigente = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [empleadoId]);

  useEffect(() => setTipo(tipoSugerido), [tipoSugerido]);

  // Sin documentos previos no tiene sentido ofrecer "elegir".
  useEffect(() => {
    if (empleadoId && documentos.length === 0) setModo("subir");
  }, [empleadoId, documentos.length]);

  async function subir() {
    if (!empleadoId || !archivo) return setError("Elige un archivo.");
    setSubiendo(true);
    setError(null);
    const { documentoId, error } = await subirDocumento({
      empleadoId,
      archivo,
      tipo,
      nombre: nombre || archivo.name,
    });
    setSubiendo(false);
    if (error) return setError(error);
    setArchivo(null);
    setNombre("");
    await cargar();
    onCambio(documentoId ?? null);
    setModo("elegir");
  }

  if (!empleadoId) {
    return (
      <label>
        {etiqueta}
        <small>Elige primero a la persona.</small>
      </label>
    );
  }

  return (
    <div className="selector-documento">
      <div className="selector-documento-cab">
        <strong>
          {etiqueta}
          {requerido && <span className="obligatorio"> *</span>}
        </strong>
        <button
          type="button"
          className="btn-mini secondary"
          onClick={() => setModo(modo === "elegir" ? "subir" : "elegir")}
        >
          {modo === "elegir" ? "Subir uno nuevo" : "Elegir del expediente"}
        </button>
      </div>

      {error && <p className="error">{error}</p>}

      {modo === "elegir" ? (
        <select value={valor ?? ""} onChange={(e) => onCambio(e.target.value || null)}>
          <option value="">— sin documento —</option>
          {documentos.map((d) => (
            <option key={d.id} value={d.id}>
              {d.nombre} · {new Date(d.created_at).toLocaleDateString("es-EC")}
            </option>
          ))}
        </select>
      ) : (
        <div className="selector-documento-subida">
          <input
            type="file"
            onChange={(e) => {
              const f = e.target.files?.[0] ?? null;
              setArchivo(f);
              if (f && !nombre) setNombre(f.name.replace(/\.[^.]+$/, ""));
            }}
          />
          <input
            type="text"
            placeholder="Nombre del documento"
            value={nombre}
            onChange={(e) => setNombre(e.target.value)}
          />
          <select value={tipo} onChange={(e) => setTipo(e.target.value)}>
            {TIPOS_DOCUMENTO.map((t) => (
              <option key={t.valor} value={t.valor}>
                {t.etiqueta}
              </option>
            ))}
          </select>
          <button type="button" onClick={subir} disabled={subiendo || !archivo}>
            {subiendo ? "Subiendo…" : "Subir y usar"}
          </button>
        </div>
      )}
    </div>
  );
}
