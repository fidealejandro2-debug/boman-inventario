"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";
import { fecha } from "@/lib/utils";
import { ETIQUETAS_ESTADO, imprimirDocumento, nuevaClaveIdempotencia } from "@/lib/erp";
import LineasDocumentoEditor, {
  type LineaDocumentoEdicion,
  type ProductoDocumento,
} from "@/components/LineasDocumentoEditor";
import { pedirMotivoDialogo, confirmarDialogo } from "@/components/Dialogo";

type Almacen = { id: string; nombre: string; tipo: string };
type Linea = {
  id: string;
  producto_id: string;
  cantidad_solicitada: number | null;
  cantidad_aprobada: number | null;
  cantidad_preparada: number | null;
  cantidad_despachada: number | null;
  cantidad_recibida: number | null;
  cantidad_rechazada: number | null;
  cantidad_no_conforme: number;
  cantidad_no_recibida: number;
  observacion: string | null;
  descripcion_libre: string | null;
  producto: ProductoDocumento | null;
};
type Documento = {
  id: string;
  numero: string;
  tipo: "solicitud_reposicion" | "transferencia";
  estado: string;
  prioridad: string;
  nota: string | null;
  created_at: string;
  despachado_at: string | null;
  recibido_at: string | null;
  origen_id: string | null;
  destino_id: string | null;
  origen: { nombre: string } | null;
  destino: { nombre: string } | null;
  creador: { nombre_completo: string } | null;
  lineas: Linea[];
};

const VACIO: LineaDocumentoEdicion[] = [];

export default function OperacionesCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [tab, setTab] = useState<"solicitudes" | "transferencias">("solicitudes");
  const [productos, setProductos] = useState<ProductoDocumento[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [permitidos, setPermitidos] = useState<string[]>([]);
  const [documentos, setDocumentos] = useState<Documento[]>([]);
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const [mostrarNuevo, setMostrarNuevo] = useState(false);
  const [modoNuevo, setModoNuevo] = useState<"solicitud" | "transferencia">("solicitud");
  const [lineas, setLineas] = useState<LineaDocumentoEdicion[]>(VACIO);
  const [origenId, setOrigenId] = useState("");
  const [destinoId, setDestinoId] = useState(perfil.entidad_id ?? "");
  const [prioridad, setPrioridad] = useState("normal");
  const [nota, setNota] = useState("");
  const [origenSolicitud, setOrigenSolicitud] = useState<Record<string, string>>({});
  const [recibiendo, setRecibiendo] = useState<Documento | null>(null);
  const [recepcion, setRecepcion] = useState<Record<string, { recibida: number; noConforme: number; noRecibida: number; observacion: string }>>({});
  const [notaRecepcion, setNotaRecepcion] = useState("");
  const [sinCodigo, setSinCodigo] = useState<{ descripcion: string; cantidad: number }[]>([]);
  const [asignando, setAsignando] = useState<Record<string, string>>({});
  const [rectificando, setRectificando] = useState<Documento | null>(null);
  const [motivoRectificacion, setMotivoRectificacion] = useState("");

  const rolGlobal = ["admin", "control", "gerencia"].includes(perfil.rol);
  const puedeSolicitar = ["admin", "control", "bodega", "tienda", "franquiciado"].includes(perfil.rol);
  const puedeCrearTransferencia = ["admin", "control", "bodega"].includes(perfil.rol);
  const puedeResolver = ["admin", "control", "bodega"].includes(perfil.rol);
  const puedeTransportar = ["admin", "control", "bodega", "logistica"].includes(perfil.rol);
  const puedeRecibir = ["admin", "control", "bodega", "tienda", "franquiciado"].includes(perfil.rol);

  async function cargar() {
    setCargando(true);
    const [p, a, pa, d] = await Promise.all([
      supabase.from("productos").select("id, sku, nombre, talla, color").eq("activo", true).order("nombre"),
      supabase.from("almacenes").select("id, nombre, tipo").eq("activo", true).order("tipo").order("nombre"),
      supabase.from("perfil_almacenes").select("almacen_id").eq("perfil_id", perfil.id),
      supabase.from("documentos_inventario").select(`
        id, numero, tipo, estado, prioridad, nota, created_at, despachado_at, recibido_at,
        origen_id, destino_id,
        origen:almacenes!documentos_inventario_origen_id_fkey(nombre),
        destino:almacenes!documentos_inventario_destino_id_fkey(nombre),
        creador:perfiles!documentos_inventario_creado_por_fkey(nombre_completo),
        lineas:documento_inventario_lineas(
          id, producto_id, cantidad_solicitada, cantidad_aprobada, cantidad_preparada,
          cantidad_despachada, cantidad_recibida, cantidad_rechazada,
          cantidad_no_conforme, cantidad_no_recibida, observacion, descripcion_libre,
          producto:productos(id, sku, nombre, talla, color)
        )
      `).in("tipo", ["solicitud_reposicion", "transferencia"]).order("created_at", { ascending: false }).limit(300),
    ]);

    const error = p.error ?? a.error ?? pa.error ?? d.error;
    if (error) setMsg({ tipo: "error", texto: error.message });
    setProductos((p.data ?? []) as ProductoDocumento[]);
    setAlmacenes((a.data ?? []) as Almacen[]);
    setPermitidos((pa.data ?? []).map((x: any) => x.almacen_id));
    setDocumentos((d.data ?? []) as any as Documento[]);
    if (!destinoId && (pa.data ?? []).length) setDestinoId((pa.data as any[])[0].almacen_id);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const almacenesPropios = useMemo(() => rolGlobal
    ? almacenes
    : almacenes.filter((a) => permitidos.includes(a.id) || a.id === perfil.entidad_id),
  [almacenes, permitidos, perfil.entidad_id, rolGlobal]);

  const solicitudes = documentos.filter((d) => d.tipo === "solicitud_reposicion");
  const transferencias = documentos.filter((d) => d.tipo === "transferencia");
  const listaActual = tab === "solicitudes" ? solicitudes : transferencias;

  function limpiarFormulario() {
    setLineas([]); setSinCodigo([]); setNota(""); setPrioridad("normal"); setOrigenId("");
    setMostrarNuevo(false);
  }

  async function crearDocumento(e: React.FormEvent) {
    e.preventDefault(); setMsg(null);
    const libres = modoNuevo === "solicitud"
      ? sinCodigo
          .filter((l) => l.cantidad > 0 && l.descripcion.trim())
          .map((l) => ({ producto_id: null, cantidad: l.cantidad, descripcion: l.descripcion.trim() }))
      : [];
    if (libres.some((l) => l.descripcion.length < 5)) {
      setMsg({ tipo: "error", texto: "Describe cada producto sin código con al menos 5 caracteres." }); return;
    }
    const items = [...lineas.filter((l) => l.cantidad > 0), ...libres];
    if (!items.length) { setMsg({ tipo: "error", texto: "Agrega al menos un producto con cantidad." }); return; }
    if (!destinoId || (modoNuevo === "transferencia" && !origenId)) {
      setMsg({ tipo: "error", texto: "Selecciona los almacenes del documento." }); return;
    }
    const clave = nuevaClaveIdempotencia();
    setProcesando("nuevo");
    const respuesta = modoNuevo === "solicitud"
      ? await supabase.rpc(perfil.rol === "franquiciado" ? "crear_solicitud_reposicion_v42" : "crear_solicitud_reposicion", {
          p_destino_id: destinoId, p_items: items, p_prioridad: prioridad,
          p_nota: nota || null, p_idempotency_key: clave,
        })
      : await supabase.rpc("crear_transferencia_directa", {
          p_origen_id: origenId, p_destino_id: destinoId, p_items: items,
          p_nota: nota || null, p_idempotency_key: clave,
        });
    setProcesando(null);
    if (respuesta.error) { setMsg({ tipo: "error", texto: respuesta.error.message }); return; }
    setMsg({ tipo: "ok", texto: modoNuevo === "solicitud" ? "Solicitud creada y enviada a bodega." : "Transferencia creada y stock reservado." });
    limpiarFormulario(); await cargar();
  }

  async function asignarProducto(linea: Linea) {
    const productoId = asignando[linea.id] || "";
    if (!productoId) { setMsg({ tipo: "error", texto: "Elige el producto del catálogo para esa línea." }); return; }
    setProcesando(linea.id); setMsg(null);
    const { error } = await supabase.rpc("asignar_producto_linea_v43", {
      p_linea_id: linea.id, p_producto_id: productoId,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: "Pedido sin código convertido a producto del catálogo." });
    await cargar();
  }

  async function resolverSolicitud(documento: Documento, aprobar: boolean) {
    const origen = origenSolicitud[documento.id] || "";
    if (aprobar && documento.lineas.some((l) => !l.producto_id)) {
      setMsg({ tipo: "error", texto: "Hay pedidos sin código. Crea el producto en Catálogo y asígnalo antes de aprobar." });
      return;
    }
    if (aprobar && !origen) { setMsg({ tipo: "error", texto: "Selecciona la bodega que atenderá la solicitud." }); return; }
    const motivo = aprobar ? "Solicitud aprobada para preparación" : (await pedirMotivoDialogo("Motivo del rechazo:"))?.trim();
    if (!aprobar && !motivo) return;
    setProcesando(documento.id); setMsg(null);
    const { error } = await supabase.rpc("resolver_solicitud_reposicion", {
      p_solicitud_id: documento.id, p_aprobar: aprobar, p_origen_id: aprobar ? origen : null,
      p_items: null, p_nota: motivo, p_idempotency_key: aprobar ? nuevaClaveIdempotencia() : null,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: aprobar ? "Solicitud aprobada y transferencia generada." : "Solicitud rechazada con trazabilidad." });
    await cargar();
  }

  async function prepararTodo(documento: Documento) {
    const items = documento.lineas.filter((l) => (l.cantidad_aprobada ?? 0) > 0).map((l) => ({
      producto_id: l.producto_id, cantidad: l.cantidad_aprobada, observacion: l.observacion,
    }));
    setProcesando(documento.id); setMsg(null);
    const { error } = await supabase.rpc("guardar_preparacion_transferencia", {
      p_documento_id: documento.id, p_items: items, p_nota: "Picking verificado",
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: "Preparación registrada. Revisa la guía antes de despachar." }); await cargar();
  }

  async function despachar(documento: Documento) {
    if (!await confirmarDialogo(`¿Confirmas el despacho de ${documento.numero}? El stock saldrá de ${documento.origen?.nombre}.`)) return;
    setProcesando(documento.id); setMsg(null);
    const { error } = await supabase.rpc("despachar_transferencia", {
      p_documento_id: documento.id, p_nota: "Despacho físico confirmado",
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: "Despacho confirmado. La mercadería está pendiente de recepción." }); await cargar();
  }

  async function marcarTransito(documento: Documento) {
    setProcesando(documento.id);
    const { error } = await supabase.rpc("marcar_transferencia_en_transito", {
      p_documento_id: documento.id, p_nota: "Mercadería retirada para transporte",
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    await cargar();
  }

  function abrirRecepcion(documento: Documento) {
    const valores: typeof recepcion = {};
    documento.lineas.forEach((l) => {
      valores[l.producto_id] = {
        recibida: l.cantidad_despachada ?? 0,
        noConforme: 0,
        noRecibida: 0,
        observacion: "",
      };
    });
    setRecepcion(valores); setNotaRecepcion(""); setRecibiendo(documento);
  }

  function actualizarClasificacion(
    linea: Linea,
    campo: "recibida" | "noConforme" | "noRecibida" | "observacion",
    valor: number | string
  ) {
    const actual = recepcion[linea.producto_id] ?? { recibida: 0, noConforme: 0, noRecibida: 0, observacion: "" };
    const siguiente = { ...actual };
    if (campo === "observacion") siguiente.observacion = String(valor);
    else siguiente[campo] = Number(valor);
    if (campo === "recibida" || campo === "noConforme") {
      siguiente.noRecibida = Math.max(
        (linea.cantidad_despachada ?? 0) - siguiente.recibida - siguiente.noConforme, 0
      );
    }
    setRecepcion((valores) => ({ ...valores, [linea.producto_id]: siguiente }));
  }

  async function guardarRecepcion() {
    if (!recibiendo) return;
    const items = recibiendo.lineas.map((l) => ({
      producto_id: l.producto_id,
      cantidad_recibida: recepcion[l.producto_id]?.recibida ?? 0,
      cantidad_no_conforme: recepcion[l.producto_id]?.noConforme ?? 0,
      cantidad_no_recibida: recepcion[l.producto_id]?.noRecibida ?? 0,
      observacion: recepcion[l.producto_id]?.observacion || null,
    }));
    const hayDiferencia = recibiendo.lineas.some((l) => {
      const r = recepcion[l.producto_id];
      return (r?.noConforme ?? 0) > 0 || (r?.noRecibida ?? 0) > 0;
    });
    const incompleta = recibiendo.lineas.some((l) => {
      const r = recepcion[l.producto_id];
      return (r?.recibida ?? 0) + (r?.noConforme ?? 0) + (r?.noRecibida ?? 0)
        !== (l.cantidad_despachada ?? 0);
    });
    if (incompleta) {
      setMsg({ tipo: "error", texto: "Clasifica exactamente todas las unidades como conformes, no conformes o no recibidas." }); return;
    }
    if (hayDiferencia && !notaRecepcion.trim()) {
      setMsg({ tipo: "error", texto: "Explica la diferencia o el rechazo antes de recibir." }); return;
    }
    setProcesando(recibiendo.id); setMsg(null);
    const { data, error } = await supabase.rpc(perfil.rol === "franquiciado" ? "recibir_transferencia_franquicia_v42" : "recibir_transferencia", {
      p_documento_id: recibiendo.id, p_items: items, p_nota: notaRecepcion || "Recepción completa verificada",
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setRecibiendo(null);
    setMsg({ tipo: "ok", texto: data === "recibido" ? "Recepción completa aplicada al stock." : "Recepción aplicada y diferencia enviada a Control." });
    await cargar();
  }

  async function rectificarRecepcion() {
    if (!rectificando) return;
    if (motivoRectificacion.trim().length < 10) {
      setMsg({ tipo: "error", texto: "Describe con claridad el error y la evidencia de la rectificación (mínimo 10 caracteres)." });
      return;
    }
    setProcesando(rectificando.id); setMsg(null);
    const { error } = await supabase.rpc("admin_rectificar_recepcion_transferencia", {
      p_documento_id: rectificando.id,
      p_motivo: motivoRectificacion.trim(),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setRectificando(null); setMotivoRectificacion("");
    setMsg({ tipo: "ok", texto: "Recepción rectificada. La transferencia volvió a tránsito y debe recibirse nuevamente." });
    await cargar();
  }

  function imprimir(documento: Documento) {
    imprimirDocumento(documento.numero, `
      <h1>${documento.numero} · ${documento.tipo === "transferencia" ? "Transferencia" : "Solicitud de reposición"}</h1>
      <p><b>Estado:</b> ${ETIQUETAS_ESTADO[documento.estado] ?? documento.estado}</p>
      <p><b>Origen:</b> ${documento.origen?.nombre ?? "Por asignar"} &nbsp; <b>Destino:</b> ${documento.destino?.nombre ?? "-"}</p>
      <p><b>Fecha:</b> ${fecha(documento.created_at)} &nbsp; <b>Responsable:</b> ${documento.creador?.nombre_completo ?? "-"}</p>
      <table><thead><tr><th>SKU</th><th>Producto</th><th class="num">Solic.</th><th class="num">Aprob.</th><th class="num">Desp.</th></tr></thead><tbody>
      ${documento.lineas.map((l) => `<tr><td>${l.producto?.sku ?? ""}</td><td>${l.producto?.nombre ?? ""} ${l.producto?.talla ?? ""}</td><td class="num">${l.cantidad_solicitada ?? ""}</td><td class="num">${l.cantidad_aprobada ?? ""}</td><td class="num">${l.cantidad_despachada ?? ""}</td></tr>`).join("")}
      </tbody></table><p><b>Observaciones:</b> ${documento.nota ?? "Sin observaciones"}</p>`);
  }

  return (
    <>
      <div className="header-row">
        <div><h2 style={{ color: "#1f3864", margin: 0 }}>Operaciones entre bodega y tiendas</h2>
          <p className="conteo">Solicitudes, picking, despacho, tránsito y recepción confirmada.</p></div>
        {(puedeSolicitar || puedeCrearTransferencia) && <button onClick={() => setMostrarNuevo((v) => !v)}>{mostrarNuevo ? "Cancelar" : "+ Nuevo documento"}</button>}
      </div>
      {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

      {mostrarNuevo && (
        <form className="card" onSubmit={crearDocumento}>
          <div className="tabs">
            {puedeSolicitar && <button type="button" className={`tab ${modoNuevo === "solicitud" ? "activo" : ""}`} onClick={() => setModoNuevo("solicitud")}>Solicitud de reposición</button>}
            {puedeCrearTransferencia && <button type="button" className={`tab ${modoNuevo === "transferencia" ? "activo" : ""}`} onClick={() => setModoNuevo("transferencia")}>Transferencia directa</button>}
          </div>
          <div className="grid-2">
            {modoNuevo === "transferencia" && <div className="field"><label>Origen</label><select required value={origenId} onChange={(e) => setOrigenId(e.target.value)} style={{ width: "100%" }}><option value="">Seleccionar...</option>{almacenesPropios.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}</select></div>}
            <div className="field"><label>{modoNuevo === "solicitud" ? "Tienda solicitante" : "Destino"}</label><select required value={destinoId} onChange={(e) => setDestinoId(e.target.value)} style={{ width: "100%" }}><option value="">Seleccionar...</option>{(modoNuevo === "solicitud" ? almacenesPropios : almacenes.filter((a) => a.id !== origenId)).map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}</select></div>
            {modoNuevo === "solicitud" && <div className="field"><label>Prioridad</label><select value={prioridad} onChange={(e) => setPrioridad(e.target.value)} style={{ width: "100%" }}><option value="normal">Normal</option><option value="urgente">Urgente</option></select></div>}
            <div className="field"><label>Observación</label><input value={nota} onChange={(e) => setNota(e.target.value)} placeholder="Motivo, campaña o referencia" style={{ width: "100%" }} /></div>
          </div>
          <LineasDocumentoEditor productos={productos} lineas={lineas} onChange={setLineas} />
          {modoNuevo === "solicitud" && (
            <div className="bloque-sin-codigo">
              <div className="header-row">
                <div><strong>Productos que aún no están en el catálogo</strong>
                  <div className="conteo">Descríbelo y bodega lo creará antes de aprobar la solicitud.</div></div>
                <button type="button" className="secondary" onClick={() => setSinCodigo([...sinCodigo, { descripcion: "", cantidad: 1 }])}>+ Pedir sin código</button>
              </div>
              {sinCodigo.map((l, i) => (
                <div className="linea-sin-codigo" key={i}>
                  <input value={l.descripcion} placeholder="Ej.: Camiseta polo azul marino talla L, cuello redondo"
                    onChange={(e) => setSinCodigo(sinCodigo.map((x, j) => j === i ? { ...x, descripcion: e.target.value } : x))} />
                  <input type="number" min={1} value={l.cantidad} style={{ width: 80 }}
                    onChange={(e) => setSinCodigo(sinCodigo.map((x, j) => j === i ? { ...x, cantidad: Number(e.target.value) || 0 } : x))} />
                  <button type="button" className="chip-limpiar" onClick={() => setSinCodigo(sinCodigo.filter((_, j) => j !== i))}>Quitar</button>
                </div>
              ))}
            </div>
          )}
          <button disabled={procesando === "nuevo" || (!lineas.length && !sinCodigo.length)}>{procesando === "nuevo" ? "Guardando..." : "Crear documento"}</button>
        </form>
      )}

      <div className="tabs">
        <button className={`tab ${tab === "solicitudes" ? "activo" : ""}`} onClick={() => setTab("solicitudes")}>Solicitudes ({solicitudes.filter((d) => d.estado === "solicitado").length} pendientes)</button>
        <button className={`tab ${tab === "transferencias" ? "activo" : ""}`} onClick={() => setTab("transferencias")}>Transferencias ({transferencias.filter((d) => ["aprobado", "preparando", "despachado", "en_transito"].includes(d.estado)).length} activas)</button>
      </div>

      {cargando ? <div className="card"><div className="vacio">Cargando operaciones...</div></div> : (
        <div className="lista-documentos">
          {listaActual.map((documento) => (
            <article className={`card documento-operativo ${documento.prioridad === "urgente" ? "urgente" : ""}`} key={documento.id}>
              <div className="header-row">
                <div><strong className="numero-documento">{documento.numero}</strong><span className={`badge estado-${documento.estado}`}>{ETIQUETAS_ESTADO[documento.estado] ?? documento.estado}</span>
                  <div className="conteo">{fecha(documento.created_at)} · {documento.creador?.nombre_completo ?? "-"}</div></div>
                <button className="secondary" onClick={() => imprimir(documento)}>Imprimir guía</button>
              </div>
              <div className="ruta-documento"><span>{documento.origen?.nombre ?? "Origen por asignar"}</span><b>→</b><span>{documento.destino?.nombre ?? "-"}</span></div>
              <div className="tabla-scroll"><table><thead><tr><th>SKU</th><th>Producto</th><th className="num">Solic.</th><th className="num">Aprob.</th><th className="num">Prepar.</th><th className="num">Desp.</th><th className="num">Recib.</th></tr></thead><tbody>
                {documento.lineas.map((l) => <tr key={l.id} className={!l.producto_id ? "fila-alerta" : ""}><td>{l.producto?.sku ?? <span className="badge bajo">sin código</span>}</td><td>{l.producto?.nombre ?? l.descripcion_libre}{l.producto?.talla ? <small> · {l.producto.talla}</small> : null}</td><td className="num">{l.cantidad_solicitada ?? "-"}</td><td className="num">{l.cantidad_aprobada ?? "-"}</td><td className="num">{l.cantidad_preparada ?? "-"}</td><td className="num">{l.cantidad_despachada ?? "-"}</td><td className="num">{l.cantidad_recibida ?? "-"}{(l.cantidad_no_conforme > 0 || l.cantidad_no_recibida > 0) && <small className="detalle-incidencia-linea">NC {l.cantidad_no_conforme} · No llegó {l.cantidad_no_recibida}</small>}</td></tr>)}
              </tbody></table></div>
              {documento.nota && <p className="nota-documento">{documento.nota}</p>}
              <div className="acciones-documento">
                {documento.tipo === "solicitud_reposicion" && documento.estado === "solicitado" && puedeResolver
                  && documento.lineas.filter((l) => !l.producto_id).map((l) => (
                  <div className="linea-sin-codigo" key={l.id} style={{ width: "100%" }}>
                    <span>Sin código: <strong>{l.descripcion_libre}</strong> ({l.cantidad_solicitada})</span>
                    <select value={asignando[l.id] ?? ""} onChange={(e) => setAsignando({ ...asignando, [l.id]: e.target.value })}>
                      <option value="">Producto del catálogo...</option>
                      {productos.map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.nombre}{p.talla ? " · " + p.talla : ""}</option>)}
                    </select>
                    <button disabled={procesando === l.id} onClick={() => asignarProducto(l)}>Asignar</button>
                  </div>
                ))}
                {documento.tipo === "solicitud_reposicion" && documento.estado === "solicitado" && puedeResolver && <>
                  <select value={origenSolicitud[documento.id] ?? ""} onChange={(e) => setOrigenSolicitud({ ...origenSolicitud, [documento.id]: e.target.value })}><option value="">Bodega que atenderá...</option>{almacenesPropios.filter((a) => a.id !== documento.destino_id).map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}</select>
                  <button disabled={procesando === documento.id} onClick={() => resolverSolicitud(documento, true)}>Aprobar y generar transferencia</button>
                  <button className="peligro" disabled={procesando === documento.id} onClick={() => resolverSolicitud(documento, false)}>Rechazar</button>
                </>}
                {documento.tipo === "transferencia" && documento.estado === "aprobado" && puedeCrearTransferencia && <button disabled={procesando === documento.id} onClick={() => prepararTodo(documento)}>Confirmar picking completo</button>}
                {documento.tipo === "transferencia" && documento.estado === "preparando" && puedeCrearTransferencia && <button disabled={procesando === documento.id} onClick={() => despachar(documento)}>Despachar mercadería</button>}
                {documento.tipo === "transferencia" && documento.estado === "despachado" && puedeTransportar && <button disabled={procesando === documento.id} onClick={() => marcarTransito(documento)}>Marcar en tránsito</button>}
                {documento.tipo === "transferencia" && ["despachado", "en_transito"].includes(documento.estado) && puedeRecibir && (["admin", "control"].includes(perfil.rol) || almacenesPropios.some((a) => a.id === documento.destino_id)) && <button disabled={procesando === documento.id} onClick={() => abrirRecepcion(documento)}>Recibir en tienda</button>}
                {documento.tipo === "transferencia" && perfil.rol === "admin" && ["recibido", "recibido_con_diferencia", "cerrado_con_diferencia"].includes(documento.estado) && <button className="peligro" disabled={procesando === documento.id} onClick={() => { setRectificando(documento); setMotivoRectificacion(""); setMsg(null); }}>Rectificar recepción</button>}
              </div>
            </article>
          ))}
          {!listaActual.length && <div className="card"><div className="vacio">No hay documentos en esta sección.</div></div>}
        </div>
      )}

      {recibiendo && (
        <div className="modal-operativo" role="dialog" aria-modal="true">
          <div className="modal-contenido">
            <div className="header-row"><h3>Recibir {recibiendo.numero}</h3><button className="chip-limpiar" onClick={() => setRecibiendo(null)}>Cerrar</button></div>
            <div className="info-box"><strong>Clasifica el 100% de lo despachado.</strong> Conforme entra al stock disponible; no conforme entra a cuarentena; no recibida permanece en tránsito con incidencia.</div>
            <div className="tabla-scroll"><table><thead><tr><th>Producto</th><th className="num">Despachado</th><th className="num">Conforme</th><th className="num">No conforme</th><th className="num">No recibida</th><th className="num">Control</th><th>Observación</th></tr></thead><tbody>
              {recibiendo.lineas.map((l) => { const valor = recepcion[l.producto_id]; const total = (valor?.recibida ?? 0) + (valor?.noConforme ?? 0) + (valor?.noRecibida ?? 0); const completo = total === (l.cantidad_despachada ?? 0); return <tr key={l.id} className={!completo ? "fila-alerta" : ""}><td><strong>{l.producto?.sku}</strong><br />{l.producto?.nombre}</td><td className="num">{l.cantidad_despachada}</td><td className="num"><input type="number" min={0} max={l.cantidad_despachada ?? 0} value={valor?.recibida ?? 0} onChange={(e) => actualizarClasificacion(l, "recibida", Number(e.target.value) || 0)} style={{ width: 70 }} /></td><td className="num"><input type="number" min={0} max={l.cantidad_despachada ?? 0} value={valor?.noConforme ?? 0} onChange={(e) => actualizarClasificacion(l, "noConforme", Number(e.target.value) || 0)} style={{ width: 70 }} /></td><td className="num"><input type="number" min={0} max={l.cantidad_despachada ?? 0} value={valor?.noRecibida ?? 0} onChange={(e) => actualizarClasificacion(l, "noRecibida", Number(e.target.value) || 0)} style={{ width: 70 }} /></td><td className="num"><span className={`badge ${completo ? "ok" : "bajo"}`}>{total}/{l.cantidad_despachada}</span></td><td><input value={valor?.observacion ?? ""} onChange={(e) => actualizarClasificacion(l, "observacion", e.target.value)} /></td></tr>; })}
            </tbody></table></div>
            <div className="field"><label>Acta / evidencia inicial de recepción</label><textarea rows={3} value={notaRecepcion} onChange={(e) => setNotaRecepcion(e.target.value)} placeholder="Obligatoria cuando exista producto no conforme o no recibido" style={{ width: "100%" }} /></div>
            <button disabled={procesando === recibiendo.id} onClick={guardarRecepcion}>{procesando === recibiendo.id ? "Aplicando..." : "Confirmar recepción"}</button>
          </div>
        </div>
      )}

      {rectificando && (
        <div className="modal-operativo" role="dialog" aria-modal="true">
          <div className="modal-contenido">
            <div className="header-row"><div><h3 style={{ margin: 0 }}>Rectificar {rectificando.numero}</h3><span className="conteo">Acción exclusiva de Administración</span></div><button className="chip-limpiar" onClick={() => setRectificando(null)}>Cerrar</button></div>
            <div className="error-box"><strong>No elimina la recepción original.</strong> El sistema retirará del destino las cantidades registradas, liberará la clasificación anterior y devolverá el documento a tránsito para repetir la recepción. Si detecta ventas, transferencias, conteos o disposiciones posteriores, bloqueará la operación.</div>
            <div className="tabla-scroll"><table><thead><tr><th>Producto</th><th className="num">Conforme a revertir</th><th className="num">Cuarentena a revertir</th><th className="num">No recibida</th></tr></thead><tbody>{rectificando.lineas.map((l) => <tr key={l.id}><td><strong>{l.producto?.sku}</strong><div className="conteo">{l.producto?.nombre}</div></td><td className="num">{l.cantidad_recibida ?? 0}</td><td className="num">{l.cantidad_no_conforme ?? 0}</td><td className="num">{l.cantidad_no_recibida ?? 0}</td></tr>)}</tbody></table></div>
            <div className="field"><label>Motivo y evidencia de la rectificación *</label><textarea rows={4} value={motivoRectificacion} onChange={(e) => setMotivoRectificacion(e.target.value)} placeholder="Ej.: Se digitó 2 unidades conformes, pero el acta física confirma 3. Verificado con guía..." style={{ width: "100%" }} /></div>
            <div className="acciones-documento"><button className="peligro" disabled={procesando === rectificando.id} onClick={rectificarRecepcion}>{procesando === rectificando.id ? "Rectificando..." : "Confirmar rectificación"}</button><button className="secondary" disabled={procesando === rectificando.id} onClick={() => setRectificando(null)}>Cancelar</button></div>
          </div>
        </div>
      )}
    </>
  );
}
