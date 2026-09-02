"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { soloFecha, mensajeError, type Empleado } from "./lib";
import {
  documentosDe,
  subirDocumento,
  urlDocumento,
  tamanoLegible,
  TIPOS_DOCUMENTO,
  ETIQUETA_DOCUMENTO,
  type DocumentoEmpleado,
} from "./documentos";
import Aviso from "@/components/Aviso";

export default function ExpedienteTab({
  puedeEscribir,
  empleados,
}: {
  puedeEscribir: boolean;
  empleados: Empleado[];
}) {
  const supabase = createClient();
  const [empleadoId, setEmpleadoId] = useState("");
  const [documentos, setDocumentos] = useState<DocumentoEmpleado[]>([]);
  const [verArchivados, setVerArchivados] = useState(false);
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [subiendo, setSubiendo] = useState(false);

  const [archivo, setArchivo] = useState<File | null>(null);
  const [nombre, setNombre] = useState("");
  const [tipo, setTipo] = useState("hoja_vida");
  const [fechaEmision, setFechaEmision] = useState("");
  const [fechaCaducidad, setFechaCaducidad] = useState("");

  const empleado = empleados.find((e) => e.empleado_id === empleadoId);

  async function cargar() {
    if (!empleadoId) return setDocumentos([]);
    setCargando(true);
    const { documentos, error } = await documentosDe(empleadoId, !verArchivados);
    if (error) setError(error);
    else {
      setDocumentos(documentos);
      setError(null);
    }
    setCargando(false);
  }

  useEffect(() => {
    let vigente = true;
    if (!empleadoId) {
      setDocumentos([]);
      setCargando(false);
      return () => { vigente = false; };
    }

    setDocumentos([]);
    setCargando(true);
    setError(null);
    void (async () => {
      const [consulta, registro] = await Promise.all([
        documentosDe(empleadoId, !verArchivados),
        // Deja constancia de quién abrió el expediente: es dato sensible.
        supabase.rpc("registrar_consulta_expediente_v26", {
          p_empleado_id: empleadoId,
        }),
      ]);
      if (!vigente) return;
      setCargando(false);
      if (consulta.error) return setError(consulta.error);
      setDocumentos(consulta.documentos);
      if (registro.error) {
        setError(
          `Los documentos se cargaron, pero no se pudo auditar la consulta: ${registro.error.message}`
        );
      }
    })();

    return () => { vigente = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [empleadoId, verArchivados]);

  async function subir() {
    if (!empleadoId || !archivo) return setError("Elige a la persona y el archivo.");
    setSubiendo(true);
    setError(null);
    const { error } = await subirDocumento({
      empleadoId,
      archivo,
      tipo,
      nombre: nombre || archivo.name,
      fechaEmision,
      fechaCaducidad,
    });
    setSubiendo(false);
    if (error) return setError(error);
    setAviso("Documento cargado al expediente.");
    setArchivo(null);
    setNombre("");
    setFechaEmision("");
    setFechaCaducidad("");
    await cargar();
  }

  async function abrir(path: string) {
    const { url, error } = await urlDocumento(path);
    if (error || !url) return setError(error ?? "No se pudo abrir el documento.");
    window.open(url, "_blank", "noopener");
  }

  async function archivarDoc(id: string) {
    const motivo = window.prompt("Motivo para archivar el documento:");
    if (!motivo?.trim()) return;
    const { error } = await supabase.rpc("archivar_documento_empleado_v26", {
      p_documento_id: id,
      p_motivo: motivo,
    });
    if (error) return setError(mensajeError(error));
    setAviso("Documento archivado. No se borra: queda en el expediente.");
    await cargar();
  }

  const hoy = new Date();
  const porVencer = documentos.filter(
    (d) =>
      d.activo &&
      d.fecha_caducidad &&
      (new Date(d.fecha_caducidad + "T00:00:00").getTime() - hoy.getTime()) /
        86400000 <=
        60
  );

  return (
    <>
      <Aviso error={error} aviso={aviso} onCerrar={(cual) => (cual === "error" ? setError(null) : setAviso(null))} />
      <div className="filtros">
        <select value={empleadoId} onChange={(e) => setEmpleadoId(e.target.value)}>
          <option value="">Elige a la persona…</option>
          {empleados.map((e) => (
            <option key={e.empleado_id} value={e.empleado_id}>
              {e.nombre_completo} · {e.identificacion}
            </option>
          ))}
        </select>
        {empleadoId && (
          <label className="check-inline">
            <input
              type="checkbox"
              checked={verArchivados}
              onChange={(e) => setVerArchivados(e.target.checked)}
            />{" "}
            Ver también archivados
          </label>
        )}
      </div>

      {!empleadoId ? (
        <p className="ayuda">
          El expediente guarda hoja de vida, contratos, certificados, la firma que se
          estampa en los roles y llamados, y las actas de finiquito. Los archivos viven en
          un bucket privado: se abren con un enlace firmado que caduca en dos minutos.
        </p>
      ) : (
        <>
          <p className="ayuda">
            Expediente de <strong>{empleado?.nombre_completo}</strong>. Cada apertura queda
            registrada en la bitácora.
          </p>

          {porVencer.length > 0 && (
            <p className="aviso">
              <strong>{porVencer.length}</strong> documento(s) vencen en 60 días o menos:{" "}
              {porVencer.map((d) => d.nombre).join(", ")}.
            </p>
          )}

          {puedeEscribir && (
            <div className="card-interna">
              <h4>Cargar documento</h4>
              <div className="form-grid">
                <label>
                  Archivo
                  <input
                    type="file"
                    onChange={(e) => {
                      const f = e.target.files?.[0] ?? null;
                      setArchivo(f);
                      if (f && !nombre) setNombre(f.name.replace(/\.[^.]+$/, ""));
                    }}
                  />
                  <small>Máximo 10 MB.</small>
                </label>
                <label>
                  Nombre
                  <input
                    type="text"
                    value={nombre}
                    onChange={(e) => setNombre(e.target.value)}
                  />
                </label>
                <label>
                  Tipo
                  <select value={tipo} onChange={(e) => setTipo(e.target.value)}>
                    {TIPOS_DOCUMENTO.map((t) => (
                      <option key={t.valor} value={t.valor}>
                        {t.etiqueta}
                      </option>
                    ))}
                  </select>
                  {(tipo === "firma" || tipo === "foto") && (
                    <small>La versión anterior se archiva sola.</small>
                  )}
                </label>
                <label>
                  Fecha de emisión
                  <input
                    type="date"
                    value={fechaEmision}
                    onChange={(e) => setFechaEmision(e.target.value)}
                  />
                </label>
                <label>
                  Fecha de caducidad
                  <input
                    type="date"
                    value={fechaCaducidad}
                    onChange={(e) => setFechaCaducidad(e.target.value)}
                  />
                  <small>Alimenta las alertas por vencer.</small>
                </label>
              </div>
              <button onClick={subir} disabled={subiendo || !archivo}>
                {subiendo ? "Subiendo…" : "Cargar al expediente"}
              </button>
            </div>
          )}

          {cargando ? (
            <p className="ayuda">Cargando documentos…</p>
          ) : (
            <div className="tabla-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Documento</th>
                    <th>Tipo</th>
                    <th>Emisión</th>
                    <th>Caducidad</th>
                    <th className="num">Tamaño</th>
                    <th>Cargado</th>
                    <th>Acciones</th>
                  </tr>
                </thead>
                <tbody>
                  {documentos.map((d) => (
                    <tr key={d.id} className={d.activo ? "" : "fila-anulada"}>
                      <td>
                        {d.nombre}
                        {!d.activo && (
                          <span className="badge cero" title={d.motivo_baja ?? ""}>
                            archivado
                          </span>
                        )}
                      </td>
                      <td>{ETIQUETA_DOCUMENTO[d.tipo] ?? d.tipo}</td>
                      <td>{soloFecha(d.fecha_emision)}</td>
                      <td>
                        {soloFecha(d.fecha_caducidad)}
                        {d.activo &&
                          d.fecha_caducidad &&
                          new Date(d.fecha_caducidad + "T00:00:00") < hoy && (
                            <span className="badge bajo">vencido</span>
                          )}
                      </td>
                      <td className="num">{tamanoLegible(d.tamano_bytes)}</td>
                      <td>{soloFecha(d.created_at.slice(0, 10))}</td>
                      <td>
                        <button
                          className="btn-mini secondary"
                          onClick={() => abrir(d.storage_path)}
                        >
                          Abrir
                        </button>
                        {puedeEscribir && d.activo && (
                          <button
                            className="btn-mini secondary"
                            onClick={() => archivarDoc(d.id)}
                          >
                            Archivar
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                  {!documentos.length && (
                    <tr>
                      <td colSpan={7} className="vacio">
                        El expediente está vacío.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </>
  );
}
