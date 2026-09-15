"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { dinero, hoyLocalISO, mensajeError } from "@/app/franquicia/lib";
import { pedirMotivoDialogo, pedirTextoDialogo, mostrarAvisoDialogo } from "@/components/Dialogo";
import ComprobanteDeposito, { type ArchivoComprobante } from "@/app/franquicia/ComprobanteDeposito";

const BUCKET_EVIDENCIA = "novedades-evidencia";

const TIPOS = [
  { valor: "descuadre_caja", etiqueta: "Descuadre de caja" },
  { valor: "cierre_pendiente", etiqueta: "Cierre pendiente" },
  { valor: "deposito_faltante", etiqueta: "Depósito faltante" },
  { valor: "otro", etiqueta: "Otro" },
];

type Novedad = {
  id: string; numero: number; almacen_id: string; almacen_nombre: string;
  tipo: string; fecha_hecho: string; descripcion: string; monto_afectado: number | null;
  asignado_a: string | null; asignado_a_nombre: string | null;
  fecha_limite: string | null; prioridad: string; estado: string;
  comentario_resolucion: string | null;
  motivo_anulacion: string | null;
  creado_por: string | null; creado_por_nombre: string | null;
  evidencias: number; created_at: string;
};

type Evento = {
  id: string; tipo: string; estado_anterior: string | null; estado_nuevo: string | null;
  detalle: string; usuario_id: string | null; created_at: string;
};

type Evidencia = {
  id: string; storage_path: string; nombre_archivo: string;
  mime_type: string; descripcion: string | null; created_at: string;
};

type Almacen = { id: string; nombre: string };
type Perfil = { id: string; nombre_completo: string };

function etiquetaTipo(t: string) {
  return TIPOS.find((x) => x.valor === t)?.etiqueta ?? t;
}

export default function NovedadesCliente({ puedeConfigurar }: { puedeConfigurar: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [tab, setTab] = useState<"novedades" | "configuracion">("novedades");

  const [novedades, setNovedades] = useState<Novedad[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [perfiles, setPerfiles] = useState<Perfil[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);

  const [filtroEstado, setFiltroEstado] = useState<"abierta" | "todas">("abierta");
  const [filtroTipo, setFiltroTipo] = useState("");

  const [seleccionada, setSeleccionada] = useState<string | null>(null);
  const [eventos, setEventos] = useState<Evento[]>([]);
  const [evidencias, setEvidencias] = useState<Evidencia[]>([]);
  const [cargandoDetalle, setCargandoDetalle] = useState(false);
  const [formAsignado, setFormAsignado] = useState("");
  const [formFechaLimite, setFormFechaLimite] = useState("");
  const [archivoEvidencia, setArchivoEvidencia] = useState<ArchivoComprobante | null>(null);

  const [mostrarNueva, setMostrarNueva] = useState(false);
  const [formNueva, setFormNueva] = useState({
    almacen_id: "", tipo: "otro", fecha_hecho: hoyLocalISO(),
    descripcion: "", monto_afectado: "", prioridad: "normal",
  });

  const [configuracion, setConfiguracion] = useState<Record<string, { hora: string; area: string }>>({});

  const nombrePerfil = useCallback(
    (id: string | null) => (id ? perfiles.find((p) => p.id === id)?.nombre_completo ?? "—" : "Sistema"),
    [perfiles]
  );

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const consultas = await Promise.all([
      supabase.from("vista_novedades_operativas_v154").select("*").order("created_at", { ascending: false }).limit(500),
      supabase.from("almacenes").select("id,nombre").eq("activo", true).order("nombre"),
      supabase.from("perfiles").select("id,nombre_completo").eq("activo", true).order("nombre_completo"),
      supabase.from("almacen_configuracion_operativa_v153").select("almacen_id,hora_limite_cierre,area_m2"),
    ]);
    const fallo = consultas.find((c) => c.error)?.error;
    if (fallo) {
      setError(mensajeError(fallo));
    } else {
      setNovedades((consultas[0].data as Novedad[]) ?? []);
      setAlmacenes((consultas[1].data as Almacen[]) ?? []);
      setPerfiles((consultas[2].data as Perfil[]) ?? []);
      const conf: Record<string, { hora: string; area: string }> = {};
      for (const fila of (consultas[3].data as { almacen_id: string; hora_limite_cierre: string; area_m2: number | null }[]) ?? []) {
        conf[fila.almacen_id] = { hora: fila.hora_limite_cierre?.slice(0, 5) ?? "20:00", area: fila.area_m2 != null ? String(fila.area_m2) : "" };
      }
      setConfiguracion(conf);
    }
    setCargando(false);
  }, [supabase]);

  useEffect(() => { void cargar(); }, [cargar]);

  const visibles = useMemo(() => novedades.filter((n) => {
    if (filtroEstado === "abierta" && n.estado !== "abierta") return false;
    if (filtroTipo && n.tipo !== filtroTipo) return false;
    return true;
  }), [novedades, filtroEstado, filtroTipo]);

  async function abrirDetalle(id: string) {
    setSeleccionada(id);
    setFormAsignado(""); setFormFechaLimite(""); setArchivoEvidencia(null);
    setCargandoDetalle(true);
    const [ev, evd] = await Promise.all([
      supabase.from("novedad_operativa_eventos_v154").select("id,tipo,estado_anterior,estado_nuevo,detalle,usuario_id,created_at").eq("novedad_id", id).order("created_at"),
      supabase.from("novedad_operativa_evidencias_v154").select("id,storage_path,nombre_archivo,mime_type,descripcion,created_at").eq("novedad_id", id).order("created_at"),
    ]);
    setEventos((ev.data as Evento[]) ?? []);
    setEvidencias((evd.data as Evidencia[]) ?? []);
    setCargandoDetalle(false);
  }

  const activa = seleccionada ? novedades.find((n) => n.id === seleccionada) ?? null : null;

  async function crearNovedad() {
    if (!formNueva.almacen_id) return setError("Selecciona el local.");
    if (formNueva.descripcion.trim().length < 5) return setError("Describe la novedad con al menos 5 caracteres.");
    setGuardando(true); setError(null);
    const { error: fallo } = await supabase.rpc("crear_novedad_operativa_v154", {
      p_datos: {
        almacen_id: formNueva.almacen_id, tipo: formNueva.tipo,
        fecha_hecho: formNueva.fecha_hecho, descripcion: formNueva.descripcion.trim(),
        monto_afectado: formNueva.monto_afectado ? Number(formNueva.monto_afectado) : null,
        prioridad: formNueva.prioridad,
      },
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (fallo) return setError(mensajeError(fallo));
    setMostrarNueva(false);
    setFormNueva({ almacen_id: "", tipo: "otro", fecha_hecho: hoyLocalISO(), descripcion: "", monto_afectado: "", prioridad: "normal" });
    void cargar();
  }

  async function asignar(id: string) {
    if (!formAsignado) return setError("Selecciona un responsable.");
    setGuardando(true); setError(null);
    const comentario = await pedirTextoDialogo("Comentario para la asignación (opcional).", "");
    const { error: fallo } = await supabase.rpc("asignar_novedad_operativa_v154", {
      p_novedad_id: id, p_asignado_a: formAsignado,
      p_fecha_limite: formFechaLimite || null,
      p_comentario: comentario || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (fallo) return setError(mensajeError(fallo));
    void cargar(); void abrirDetalle(id);
  }

  async function comentar(id: string) {
    const texto = await pedirTextoDialogo("Escribe un comentario de seguimiento.", "");
    if (!texto || texto.trim().length < 3) return;
    setGuardando(true); setError(null);
    const { error: fallo } = await supabase.rpc("agregar_comentario_novedad_v154", {
      p_novedad_id: id, p_comentario: texto.trim(), p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (fallo) return setError(mensajeError(fallo));
    void abrirDetalle(id);
  }

  async function resolver(id: string) {
    const comentario = await pedirMotivoDialogo("Explica cómo se resolvió esta novedad (mínimo 3 caracteres).", 3, "Comentario de resolución");
    if (!comentario) return;
    setGuardando(true); setError(null);
    const { error: fallo } = await supabase.rpc("resolver_novedad_operativa_v154", {
      p_novedad_id: id, p_comentario: comentario, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (fallo) return setError(mensajeError(fallo));
    void cargar(); void abrirDetalle(id);
  }

  async function anular(id: string) {
    const motivo = await pedirMotivoDialogo("Explica por qué se anula esta novedad (mínimo 10 caracteres).", 10, "Motivo de anulación");
    if (!motivo) return;
    setGuardando(true); setError(null);
    const { error: fallo } = await supabase.rpc("anular_novedad_operativa_v154", {
      p_novedad_id: id, p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (fallo) return setError(mensajeError(fallo));
    void cargar(); void abrirDetalle(id);
  }

  async function subirEvidencia(id: string) {
    if (!archivoEvidencia) return;
    const file = archivoEvidencia.file;
    setGuardando(true); setError(null);
    const { data: preparado, error: errorPrep } = await supabase.rpc("preparar_evidencia_novedad_v154", {
      p_novedad_id: id, p_nombre_archivo: file.name, p_mime_type: file.type, p_tamano_bytes: file.size,
      p_idempotency_key: archivoEvidencia.id,
    });
    if (errorPrep) { setGuardando(false); return setError(mensajeError(errorPrep)); }
    const path = (preparado as { path: string }).path;
    const { error: errorSubida } = await supabase.storage.from(BUCKET_EVIDENCIA).upload(path, file, { contentType: file.type, upsert: false });
    if (errorSubida && !/already exists|duplicate/i.test(errorSubida.message)) {
      setGuardando(false); return setError(mensajeError(errorSubida));
    }
    const { error: errorRegistro } = await supabase.rpc("agregar_evidencia_novedad_v154", {
      p_novedad_id: id, p_evidencia_id: archivoEvidencia.id, p_descripcion: null, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (errorRegistro) return setError(mensajeError(errorRegistro));
    setArchivoEvidencia(null);
    void cargar(); void abrirDetalle(id);
  }

  async function verEvidencia(path: string) {
    const ventana = window.open("", "_blank");
    const { data, error: fallo } = await supabase.storage.from(BUCKET_EVIDENCIA).createSignedUrl(path, 300);
    if (fallo || !data?.signedUrl) {
      ventana?.close();
      await mostrarAvisoDialogo(fallo?.message ?? "No se pudo abrir la evidencia.", "Error", true);
      return;
    }
    if (ventana) { ventana.opener = null; ventana.location.href = data.signedUrl; }
  }

  async function guardarConfig(almacenId: string) {
    const conf = configuracion[almacenId];
    if (!conf) return;
    setGuardando(true); setError(null);
    const { error: fallo } = await supabase.rpc("guardar_configuracion_operativa_v153", {
      p_almacen_id: almacenId,
      p_hora_limite_cierre: conf.hora ? `${conf.hora}:00` : "20:00:00",
      p_area_m2: conf.area ? Number(conf.area) : null,
    });
    setGuardando(false);
    if (fallo) return setError(mensajeError(fallo));
    await mostrarAvisoDialogo("Configuración guardada.", "Listo");
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <span className="eyebrow">FRANQUICIAS · v153–v155</span>
          <h1>Novedades operativas</h1>
          <p>Descuadres de caja, cierres pendientes y depósitos faltantes, con responsable y evidencia hasta su resolución.</p>
        </div>
        {tab === "novedades" && <button onClick={() => setMostrarNueva((v) => !v)}>{mostrarNueva ? "Cancelar" : "Registrar novedad"}</button>}
      </div>

      {puedeConfigurar && (
        <div className="consolidado-tabs" role="tablist" aria-label="Vista">
          <button type="button" role="tab" aria-selected={tab === "novedades"} className={tab === "novedades" ? "activo" : ""} onClick={() => setTab("novedades")}>Novedades</button>
          <button type="button" role="tab" aria-selected={tab === "configuracion"} className={tab === "configuracion" ? "activo" : ""} onClick={() => setTab("configuracion")}>Configuración</button>
        </div>
      )}

      {error && <div className="error-box">{error}</div>}

      {tab === "configuracion" ? (
        <div className="card">
          <div className="card-titulo-linea"><div><h2>Hora límite de cierre y tamaño por local</h2><p>Usados en el recordatorio diario de cierre y en el ranking de locales.</p></div></div>
          <div className="tabla-scroll">
            <table>
              <thead><tr><th>Local</th><th>Hora límite de cierre</th><th>Área (m²)</th><th></th></tr></thead>
              <tbody>
                {almacenes.map((a) => {
                  const conf = configuracion[a.id] ?? { hora: "20:00", area: "" };
                  return (
                    <tr key={a.id}>
                      <td>{a.nombre}</td>
                      <td><input type="time" value={conf.hora} onChange={(e) => setConfiguracion((c) => ({ ...c, [a.id]: { ...conf, hora: e.target.value } }))} /></td>
                      <td><input type="number" min="0" step="0.1" placeholder="Opcional" value={conf.area} onChange={(e) => setConfiguracion((c) => ({ ...c, [a.id]: { ...conf, area: e.target.value } }))} /></td>
                      <td><button type="button" className="secondary btn-mini" disabled={guardando} onClick={() => guardarConfig(a.id)}>Guardar</button></td>
                    </tr>
                  );
                })}
                {!almacenes.length && <tr><td colSpan={4} className="vacio">No hay locales activos.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      ) : (
        <>
          {mostrarNueva && (
            <div className="card-interna">
              <h4>Registrar novedad manual</h4>
              <div className="form-grid">
                <label>Local
                  <select value={formNueva.almacen_id} onChange={(e) => setFormNueva({ ...formNueva, almacen_id: e.target.value })}>
                    <option value="">Selecciona…</option>
                    {almacenes.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}
                  </select>
                </label>
                <label>Tipo
                  <select value={formNueva.tipo} onChange={(e) => setFormNueva({ ...formNueva, tipo: e.target.value })}>
                    {TIPOS.map((t) => <option key={t.valor} value={t.valor}>{t.etiqueta}</option>)}
                  </select>
                </label>
                <label>Fecha del hecho
                  <input type="date" max={hoyLocalISO()} value={formNueva.fecha_hecho} onChange={(e) => setFormNueva({ ...formNueva, fecha_hecho: e.target.value })} />
                </label>
                <label>Monto afectado
                  <input type="number" step="0.01" placeholder="Opcional" value={formNueva.monto_afectado} onChange={(e) => setFormNueva({ ...formNueva, monto_afectado: e.target.value })} />
                </label>
                <label>Prioridad
                  <select value={formNueva.prioridad} onChange={(e) => setFormNueva({ ...formNueva, prioridad: e.target.value })}>
                    <option value="normal">Normal</option>
                    <option value="urgente">Urgente</option>
                  </select>
                </label>
                <label className="ancho-total">Descripción
                  <input type="text" placeholder="Qué pasó y dónde" value={formNueva.descripcion} onChange={(e) => setFormNueva({ ...formNueva, descripcion: e.target.value })} />
                </label>
              </div>
              <button type="button" onClick={crearNovedad} disabled={guardando}>{guardando ? "Guardando…" : "Registrar novedad"}</button>
            </div>
          )}

          <div className="filtros">
            <label>Estado
              <select value={filtroEstado} onChange={(e) => setFiltroEstado(e.target.value as "abierta" | "todas")}>
                <option value="abierta">Abiertas</option>
                <option value="todas">Todas</option>
              </select>
            </label>
            <label>Tipo
              <select value={filtroTipo} onChange={(e) => setFiltroTipo(e.target.value)}>
                <option value="">Todos</option>
                {TIPOS.map((t) => <option key={t.valor} value={t.valor}>{t.etiqueta}</option>)}
              </select>
            </label>
          </div>

          <div className="card">
            <div className="card-titulo-linea"><div><h2>Novedades</h2></div><span className="badge ok">{visibles.length}</span></div>
            {cargando ? <div className="vacio">Cargando…</div> : (
              <div className="tabla-scroll">
                <table>
                  <thead><tr><th>N°</th><th>Local</th><th>Tipo</th><th>Fecha</th><th>Descripción</th><th className="num">Monto</th><th>Responsable</th><th>Estado</th><th></th></tr></thead>
                  <tbody>
                    {visibles.map((n) => (
                      <tr key={n.id} className={n.estado === "anulada" ? "fila-anulada" : n.prioridad === "urgente" && n.estado === "abierta" ? "fila-alerta-suave" : ""}>
                        <td>{n.numero}</td>
                        <td>{n.almacen_nombre}</td>
                        <td>{etiquetaTipo(n.tipo)}</td>
                        <td>{n.fecha_hecho.split("-").reverse().join("/")}</td>
                        <td>{n.descripcion}</td>
                        <td className="num">{n.monto_afectado != null ? dinero(n.monto_afectado) : "—"}</td>
                        <td>{n.asignado_a_nombre ?? <em>Sin asignar</em>}{n.fecha_limite ? <small><br />Límite: {n.fecha_limite.split("-").reverse().join("/")}</small> : null}</td>
                        <td><span className={`badge ${n.estado === "resuelta" ? "ok" : n.estado === "anulada" ? "" : "bajo"}`}>{n.estado}</span></td>
                        <td><button type="button" className="secondary btn-mini" onClick={() => abrirDetalle(n.id)}>Ver</button></td>
                      </tr>
                    ))}
                    {!visibles.length && <tr><td colSpan={9} className="vacio">No hay novedades con ese filtro.</td></tr>}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          {activa && (
            <div className="card">
              <div className="card-titulo-linea">
                <div><h2>{etiquetaTipo(activa.tipo)} — {activa.almacen_nombre}</h2><p>{activa.descripcion}</p></div>
                <button type="button" className="secondary btn-mini" onClick={() => setSeleccionada(null)}>Cerrar</button>
              </div>

              {cargandoDetalle ? <div className="vacio">Cargando…</div> : (
                <>
                  <div className="filtros">
                    <span>Estado: <strong>{activa.estado}</strong></span>
                    <span>Prioridad: <strong>{activa.prioridad}</strong></span>
                    <span>Registrada por: <strong>{activa.creado_por_nombre ?? "Sistema (automática)"}</strong></span>
                  </div>

                  {activa.estado === "abierta" && (
                    <div className="card-interna">
                      <h4>Asignar responsable</h4>
                      <div className="form-grid">
                        <label>Responsable
                          <select value={formAsignado} onChange={(e) => setFormAsignado(e.target.value)}>
                            <option value="">Selecciona…</option>
                            {perfiles.map((p) => <option key={p.id} value={p.id}>{p.nombre_completo}</option>)}
                          </select>
                        </label>
                        <label>Fecha límite
                          <input type="date" value={formFechaLimite} onChange={(e) => setFormFechaLimite(e.target.value)} />
                        </label>
                      </div>
                      <div className="filtros">
                        <button type="button" onClick={() => asignar(activa.id)} disabled={guardando}>{activa.asignado_a_nombre ? "Reasignar" : "Asignar"}</button>
                        <button type="button" className="secondary" onClick={() => comentar(activa.id)} disabled={guardando}>Agregar comentario</button>
                        <button type="button" className="secondary" onClick={() => resolver(activa.id)} disabled={guardando}>Marcar resuelta</button>
                        <button type="button" className="secondary" onClick={() => anular(activa.id)} disabled={guardando}>Anular</button>
                      </div>
                    </div>
                  )}

                  {activa.estado === "resuelta" && <div className="card-interna"><h4>Resolución</h4><p>{activa.comentario_resolucion}</p></div>}
                  {activa.estado === "anulada" && <div className="card-interna"><h4>Anulación</h4><p>{activa.motivo_anulacion}</p></div>}

                  <div className="card-interna">
                    <h4>Evidencia ({evidencias.length})</h4>
                    {evidencias.length > 0 && (
                      <div className="filtros">
                        {evidencias.map((e) => (
                          <button key={e.id} type="button" className="secondary btn-mini" onClick={() => verEvidencia(e.storage_path)}>{e.nombre_archivo}</button>
                        ))}
                      </div>
                    )}
                    {activa.estado !== "anulada" && (
                      <>
                        <ComprobanteDeposito archivo={archivoEvidencia} onChange={setArchivoEvidencia} disabled={guardando} titulo="Evidencia de la novedad" />
                        {archivoEvidencia && (
                          <button type="button" onClick={() => subirEvidencia(activa.id)} disabled={guardando}>{guardando ? "Subiendo…" : "Adjuntar evidencia"}</button>
                        )}
                      </>
                    )}
                  </div>

                  <div className="card-interna">
                    <h4>Historial</h4>
                    {eventos.map((ev) => (
                      <p key={ev.id}><strong>{nombrePerfil(ev.usuario_id)}</strong> — {ev.detalle} <small>({new Date(ev.created_at).toLocaleString("es-EC")})</small></p>
                    ))}
                    {!eventos.length && <p className="ayuda">Sin eventos.</p>}
                  </div>
                </>
              )}
            </div>
          )}
        </>
      )}
    </>
  );
}
