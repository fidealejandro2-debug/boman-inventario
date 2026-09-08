"use client";

import { Fragment, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { fecha } from "@/lib/utils";

type ErrorFila = { numero: string; mensaje: string };
type Importacion = {
  id: string;
  origen: "cron" | "manual";
  estado: "en_curso" | "ok" | "error";
  mensaje_error: string | null;
  total_filas_origen: number;
  creados: number;
  actualizados: number;
  sin_cambio: number;
  con_error: number;
  errores: ErrorFila[];
  duracion_ms: number | null;
  iniciado_en: string;
  finalizado_en: string | null;
  ejecutado_por_perfil: { nombre_completo: string } | null;
};

type ErrorContratoProduccion = { numero: string; mensaje: string };
type ImportacionProduccion = {
  id: string;
  origen: "cron" | "manual";
  estado: "en_curso" | "ok" | "error";
  mensaje_error: string | null;
  contratos_procesados: number;
  etapas_nuevas: number;
  eventos_nuevos: number;
  con_error: number;
  errores: ErrorContratoProduccion[];
  ultima_fila_trazabilidad: number;
  duracion_ms: number | null;
  iniciado_en: string;
  finalizado_en: string | null;
  ejecutado_por_perfil: { nombre_completo: string } | null;
};

const ETIQUETAS_ESTADO: Record<string, string> = {
  en_curso: "En curso",
  ok: "Completada",
  error: "Con error",
};

export default function ContratosBomansportCliente() {
  const supabase = createClient();
  const [importaciones, setImportaciones] = useState<Importacion[]>([]);
  const [importacionesProduccion, setImportacionesProduccion] = useState<ImportacionProduccion[]>([]);
  const [totalContratos, setTotalContratos] = useState(0);
  const [totalContratosV79, setTotalContratosV79] = useState<number | null>(null);
  const [porEstado, setPorEstado] = useState<Record<string, number>>({});
  const [cargando, setCargando] = useState(true);
  const [sincronizando, setSincronizando] = useState(false);
  const [modoCierre, setModoCierre] = useState<string>("paralelo");
  const [erroresAbiertos, setErroresAbiertos] = useState<string | null>(null);
  const [erroresProduccionAbiertos, setErroresProduccionAbiertos] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  async function cargar() {
    setCargando(true);
    const [imp, estados, total, cierre, impProduccion, totalV79] = await Promise.all([
      supabase
        .from("bomansport_importaciones")
        .select("*, ejecutado_por_perfil:perfiles!bomansport_importaciones_ejecutado_por_fkey(nombre_completo)")
        .order("iniciado_en", { ascending: false })
        .limit(20),
      supabase.from("bomansport_contratos").select("estado"),
      supabase.from("bomansport_contratos").select("id", { count: "exact", head: true }),
      supabase.from("bomansport_cierre_migracion_v103").select("modo").eq("id", true).maybeSingle(),
      // v94 puede no estar instalada todavia en Supabase: si la tabla no
      // existe, esta consulta simplemente falla y la seccion se oculta.
      supabase
        .from("bomansport_produccion_importaciones")
        .select("*, ejecutado_por_perfil:perfiles!bomansport_produccion_importaciones_ejecutado_por_fkey(nombre_completo)")
        .order("iniciado_en", { ascending: false })
        .limit(20),
      supabase.from("contratos").select("id", { count: "exact", head: true }),
    ]);
    if (imp.error) setMsg({ tipo: "error", texto: imp.error.message });
    setImportaciones((imp.data ?? []) as unknown as Importacion[]);
    const conteo: Record<string, number> = {};
    (estados.data ?? []).forEach((f: { estado: string }) => {
      conteo[f.estado] = (conteo[f.estado] ?? 0) + 1;
    });
    setPorEstado(conteo);
    setTotalContratos(total.count ?? 0);
    if (!cierre.error && cierre.data?.modo) setModoCierre(cierre.data.modo);
    if (!impProduccion.error) setImportacionesProduccion((impProduccion.data ?? []) as unknown as ImportacionProduccion[]);
    setTotalContratosV79(totalV79.error ? null : totalV79.count ?? 0);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const hayEnCurso = importaciones.some((i) => i.estado === "en_curso");

  async function sincronizarAhora() {
    setSincronizando(true);
    setMsg(null);
    try {
      const res = await fetch("/api/bomansport/importar-contratos", { method: "POST" });
      const cuerpo = await res.json();
      if (!res.ok || !cuerpo.ok) {
        setMsg({ tipo: "error", texto: cuerpo.error || `La sincronización falló (${res.status}).` });
      } else {
        setMsg({
          tipo: "ok",
          texto: `Listo: ${cuerpo.creados} nuevo(s), ${cuerpo.actualizados} actualizado(s), ${cuerpo.sin_cambio} sin cambio${cuerpo.con_error ? `, ${cuerpo.con_error} con error` : ""}.`,
        });
      }
    } catch (e) {
      setMsg({ tipo: "error", texto: e instanceof Error ? e.message : "No se pudo conectar con el servidor." });
    }
    setSincronizando(false);
    cargar();
  }

  return (
    <>
      <div className="header-row">
        <div>
          <h2 style={{ color: "#1f3864", margin: 0 }}>Sincronización BomanSport</h2>
          <p className="conteo">Importa los contratos de la hoja de cálculo de BomanSport hacia Supabase.</p>
        </div>
        <button disabled={sincronizando || hayEnCurso || modoCierre !== "paralelo"} onClick={sincronizarAhora}>
          {modoCierre !== "paralelo" ? "Importación heredada cerrada" : sincronizando ? "Sincronizando..." : hayEnCurso ? "Ya hay una en curso..." : "Sincronizar ahora"}
        </button>
      </div>

      {modoCierre !== "paralelo" && <div className="info-box">Supabase es la fuente principal. Esta pantalla conserva el historial, pero ya no admite nuevas importaciones desde Apps Script.</div>}

      {msg?.tipo === "ok" && <div className="success">{msg.texto}</div>}
      {msg?.tipo === "error" && <div className="error">{msg.texto}</div>}

      <div className="kpis">
        <div className="kpi">
          <span className="label">Contratos importados</span>
          <span className="valor">{totalContratos}</span>
        </div>
        {Object.entries(porEstado).map(([estado, n]) => (
          <div className="kpi" key={estado}>
            <span className="label">{estado}</span>
            <span className="valor">{n}</span>
          </div>
        ))}
        {totalContratosV79 !== null && (
          <div className="kpi">
            <span className="label">Migrados a producción (v79)</span>
            <span className="valor">{totalContratosV79}</span>
          </div>
        )}
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Corridas recientes</h3>
        {cargando ? (
          <div className="vacio">Cargando...</div>
        ) : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Inicio</th>
                  <th>Origen</th>
                  <th>Quién</th>
                  <th>Estado</th>
                  <th className="num">Filas origen</th>
                  <th className="num">Nuevos</th>
                  <th className="num">Actualizados</th>
                  <th className="num">Sin cambio</th>
                  <th className="num">Errores</th>
                  <th className="num">Duración</th>
                </tr>
              </thead>
              <tbody>
                {importaciones.map((i) => (
                  <Fragment key={i.id}>
                    <tr>
                      <td>{fecha(i.iniciado_en)}</td>
                      <td>{i.origen === "cron" ? "Automática" : "Manual"}</td>
                      <td>{i.ejecutado_por_perfil?.nombre_completo ?? "—"}</td>
                      <td><span className={`badge estado-${i.estado === "ok" ? "aplicado" : i.estado === "error" ? "rechazado" : "pendiente_revision"}`}>{ETIQUETAS_ESTADO[i.estado] ?? i.estado}</span></td>
                      <td className="num">{i.total_filas_origen}</td>
                      <td className="num">{i.creados}</td>
                      <td className="num">{i.actualizados}</td>
                      <td className="num">{i.sin_cambio}</td>
                      <td className="num">
                        {i.con_error > 0 ? (
                          <button className="secondary btn-mini" onClick={() => setErroresAbiertos(erroresAbiertos === i.id ? null : i.id)}>
                            {i.con_error} {erroresAbiertos === i.id ? "▲" : "▼"}
                          </button>
                        ) : (
                          0
                        )}
                      </td>
                      <td className="num">{i.duracion_ms ? `${(i.duracion_ms / 1000).toFixed(1)}s` : "—"}</td>
                    </tr>
                    {erroresAbiertos === i.id && i.con_error > 0 && (
                      <tr key={`${i.id}-errores`}>
                        <td colSpan={10}>
                          <div className="error" style={{ margin: "6px 0" }}>
                            <strong>Contratos con error en esta corrida:</strong>
                            <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
                              {i.errores.map((e, idx) => (
                                <li key={idx}><strong>{e.numero}</strong>: {e.mensaje}</li>
                              ))}
                            </ul>
                          </div>
                        </td>
                      </tr>
                    )}
                    {i.estado === "error" && i.mensaje_error && (
                      <tr key={`${i.id}-fallo`}>
                        <td colSpan={10}>
                          <div className="error" style={{ margin: "6px 0" }}>{i.mensaje_error}</div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
                {!importaciones.length && (
                  <tr><td colSpan={10} className="vacio">Todavía no se ha corrido ninguna sincronización.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {importacionesProduccion.length > 0 && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Producción (v94): tallas, jugadores, mockups, etapas y asignaciones</h3>
          <p className="conteo">Transforma bomansport_contratos + Asignaciones/Observaciones/Maquila/Trazabilidad de BomanSport hacia el esquema de producción (contratos, prendas, jugadores, etapas...). Corre junto con la sincronización de arriba.</p>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Inicio</th>
                  <th>Origen</th>
                  <th>Quién</th>
                  <th>Estado</th>
                  <th className="num">Contratos</th>
                  <th className="num">Etapas nuevas</th>
                  <th className="num">Eventos nuevos</th>
                  <th className="num">Errores</th>
                  <th className="num">Fila trazabilidad</th>
                  <th className="num">Duración</th>
                </tr>
              </thead>
              <tbody>
                {importacionesProduccion.map((i) => (
                  <Fragment key={i.id}>
                    <tr>
                      <td>{fecha(i.iniciado_en)}</td>
                      <td>{i.origen === "cron" ? "Automática" : "Manual"}</td>
                      <td>{i.ejecutado_por_perfil?.nombre_completo ?? "—"}</td>
                      <td><span className={`badge estado-${i.estado === "ok" ? "aplicado" : i.estado === "error" ? "rechazado" : "pendiente_revision"}`}>{ETIQUETAS_ESTADO[i.estado] ?? i.estado}</span></td>
                      <td className="num">{i.contratos_procesados}</td>
                      <td className="num">{i.etapas_nuevas}</td>
                      <td className="num">{i.eventos_nuevos}</td>
                      <td className="num">
                        {i.con_error > 0 ? (
                          <button className="secondary btn-mini" onClick={() => setErroresProduccionAbiertos(erroresProduccionAbiertos === i.id ? null : i.id)}>
                            {i.con_error} {erroresProduccionAbiertos === i.id ? "▲" : "▼"}
                          </button>
                        ) : (
                          0
                        )}
                      </td>
                      <td className="num">{i.ultima_fila_trazabilidad}</td>
                      <td className="num">{i.duracion_ms ? `${(i.duracion_ms / 1000).toFixed(1)}s` : "—"}</td>
                    </tr>
                    {erroresProduccionAbiertos === i.id && i.con_error > 0 && (
                      <tr key={`${i.id}-errores`}>
                        <td colSpan={10}>
                          <div className="error" style={{ margin: "6px 0" }}>
                            <strong>Contratos con error en esta corrida:</strong>
                            <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
                              {i.errores.map((e, idx) => (
                                <li key={idx}><strong>{e.numero}</strong>: {e.mensaje}</li>
                              ))}
                            </ul>
                          </div>
                        </td>
                      </tr>
                    )}
                    {i.estado === "error" && i.mensaje_error && (
                      <tr key={`${i.id}-fallo`}>
                        <td colSpan={10}>
                          <div className="error" style={{ margin: "6px 0" }}>{i.mensaje_error}</div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </>
  );
}
