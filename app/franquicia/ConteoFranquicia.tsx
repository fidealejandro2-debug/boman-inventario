"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { fecha } from "@/lib/utils";
import { ETIQUETAS_ESTADO, imprimirDocumento, nuevaClaveIdempotencia } from "@/lib/erp";
import { mensajeError } from "./lib";
import type { Franquicia } from "./FranquiciaCliente";

type Producto = { id: string; sku: string; nombre: string; talla: string | null; categoria: string | null };
type Linea = {
  id: string; producto_id: string; stock_sistema: number;
  cantidad_contada: number | null; observacion: string | null;
  producto: Producto | null;
};
type Conteo = {
  id: string; numero: string; estado: string; nota: string | null; created_at: string;
  creado_por: string; version: number;
  conteo_responsable_id: string | null;
  creador: { nombre_completo: string } | null;
  responsable: { nombre_completo: string } | null;
  lineas: Linea[];
};

export default function ConteoFranquicia({ franquicia, soloLectura = false }: { franquicia: Franquicia; soloLectura?: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [uid, setUid] = useState("");
  const [productos, setProductos] = useState<Producto[]>([]);
  const [conteos, setConteos] = useState<Conteo[]>([]);
  const [activo, setActivo] = useState<Conteo | null>(null);
  const [valores, setValores] = useState<Record<string, string>>({});
  const [observaciones, setObservaciones] = useState<Record<string, string>>({});
  const [mostrarNuevo, setMostrarNuevo] = useState(false);
  const [nota, setNota] = useState("");
  const [conteoCompleto, setConteoCompleto] = useState(true);
  const [seleccionados, setSeleccionados] = useState<Set<string>>(new Set());
  const [busqueda, setBusqueda] = useState("");
  const [busquedaConteo, setBusquedaConteo] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  async function cargar() {
    setCargando(true);
    const [{ data: u }, p, c] = await Promise.all([
      supabase.auth.getUser(),
      supabase.from("productos").select("id, sku, nombre, talla, categoria").eq("activo", true).order("nombre"),
      supabase.from("documentos_inventario").select(`
        id, numero, estado, nota, created_at, creado_por, version, conteo_responsable_id,
        creador:perfiles!documentos_inventario_creado_por_fkey(nombre_completo),
        responsable:perfiles!documentos_inventario_conteo_responsable_id_fkey(nombre_completo),
        lineas:documento_inventario_lineas(
          id, producto_id, stock_sistema, cantidad_contada, observacion,
          producto:productos(id, sku, nombre, talla, categoria)
        )
      `).eq("tipo", "conteo").eq("origen_id", franquicia.almacen_id)
        .order("created_at", { ascending: false }).limit(50),
    ]);
    setUid(u.user?.id ?? "");
    if (p.error || c.error) setMsg({ tipo: "error", texto: (p.error ?? c.error)!.message });
    setProductos((p.data ?? []) as Producto[]);
    setConteos((c.data ?? []) as unknown as Conteo[]);
    setCargando(false);
  }

  useEffect(() => { cargar(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [franquicia.almacen_id]);

  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return productos.slice(0, 200);
    return productos.filter((p) =>
      p.sku.toLowerCase().includes(q) || p.nombre.toLowerCase().includes(q) || (p.talla ?? "").toLowerCase().includes(q)
    ).slice(0, 200);
  }, [busqueda, productos]);

  const lineasActivasFiltradas = useMemo(() => {
    const q = busquedaConteo.trim().toLowerCase();
    if (!q) return activo?.lineas ?? [];
    return (activo?.lineas ?? []).filter((l) =>
      (l.producto?.sku ?? "").toLowerCase().includes(q) || (l.producto?.nombre ?? "").toLowerCase().includes(q)
    );
  }, [activo, busquedaConteo]);

  const pendientes = activo?.lineas.filter((l) => (valores[l.producto_id] ?? "") === "").length ?? 0;
  const conteoEnCurso = conteos.find((c) => c.estado === "en_conteo");

  async function crearConteo(e: React.FormEvent) {
    e.preventDefault(); setMsg(null);
    if (!conteoCompleto && seleccionados.size === 0) { setMsg({ tipo: "error", texto: "Selecciona al menos un producto." }); return; }
    setProcesando(true);
    const { error } = await supabase.rpc("crear_conteo_inventario", {
      p_almacen_id: franquicia.almacen_id,
      p_producto_ids: conteoCompleto ? null : Array.from(seleccionados),
      p_nota: nota || (conteoCompleto ? "Conteo total" : "Conteo parcial"),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: mensajeError(error) }); return; }
    setMostrarNuevo(false); setNota(""); setSeleccionados(new Set());
    setMsg({ tipo: "ok", texto: "Conteo abierto. El stock queda oculto mientras cuentas físicamente." });
    await cargar();
  }

  function prepararConteo(conteo: Conteo) {
    const nuevos: Record<string, string> = {};
    const obs: Record<string, string> = {};
    conteo.lineas.forEach((l) => {
      nuevos[l.producto_id] = l.cantidad_contada == null ? "" : String(l.cantidad_contada);
      obs[l.producto_id] = l.observacion ?? "";
    });
    setActivo(conteo); setValores(nuevos); setObservaciones(obs);
    setBusquedaConteo(""); setMsg(null);
  }

  async function continuarConteo(conteo: Conteo) {
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("abrir_edicion_conteo_v22", {
      p_documento_id: conteo.id, p_forzar: false, p_motivo: null,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: mensajeError(error) }); return; }
    const apertura = data as { version: number };
    prepararConteo({ ...conteo, version: apertura.version });
  }

  async function guardarConteo(enviar: boolean) {
    if (!activo) return;
    const vacios = activo.lineas.filter((l) => (valores[l.producto_id] ?? "") === "");
    if (enviar && vacios.length > 0) {
      if (!confirm(`${vacios.length} producto(s) están vacíos y se registrarán con cantidad 0.\n\nSignifica que físicamente no encontraste existencias de esos productos. ¿Continuar?`)) return;
    }
    const valoresFinales = { ...valores };
    if (enviar) vacios.forEach((l) => { valoresFinales[l.producto_id] = "0"; });
    const items = activo.lineas
      .filter((l) => enviar || (valoresFinales[l.producto_id] ?? "") !== "")
      .map((l) => ({
        producto_id: l.producto_id,
        cantidad: Number(valoresFinales[l.producto_id] || 0),
        observacion: observaciones[l.producto_id] || null,
      }));
    if (items.some((i) => !Number.isInteger(i.cantidad) || i.cantidad < 0)) {
      setMsg({ tipo: "error", texto: "Todas las cantidades deben ser enteros iguales o mayores que cero." }); return;
    }
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("guardar_conteo_inventario_v22", {
      p_documento_id: activo.id, p_items: items, p_enviar_revision: enviar,
      p_nota: enviar ? "Conteo finalizado" : "Avance guardado", p_version: activo.version,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: mensajeError(error) }); return; }
    setMsg({ tipo: "ok", texto: enviar ? "Conteo enviado al administrador. Quedará aplicado cuando lo apruebe." : "Avance guardado." });
    setActivo(null); await cargar();
  }

  function completarVaciosConCero() {
    if (!activo) return;
    const siguientes = { ...valores };
    lineasActivasFiltradas.forEach((l) => { if ((siguientes[l.producto_id] ?? "") === "") siguientes[l.producto_id] = "0"; });
    setValores(siguientes);
  }

  function imprimirHoja(conteo: Conteo) {
    imprimirDocumento(conteo.numero, `<h1>${conteo.numero} · Hoja de conteo ciego</h1>
      <p><b>Tienda:</b> ${franquicia.nombre} &nbsp; <b>Fecha:</b> ${fecha(conteo.created_at)}</p>
      <table><thead><tr><th>Ubicación</th><th>SKU</th><th>Producto</th><th>Talla</th><th class="num">Conteo</th></tr></thead><tbody>
      ${conteo.lineas.map((l) => `<tr><td></td><td>${l.producto?.sku ?? ""}</td><td>${l.producto?.nombre ?? ""}</td><td>${l.producto?.talla ?? ""}</td><td></td></tr>`).join("")}
      </tbody></table>`);
  }

  return (
    <>
      <div className="header-row">
        <div><h3 style={{ margin: 0 }}>Conteo físico</h3><p className="conteo">Cuenta el stock de la tienda; el administrador revisa y aprueba.</p></div>
        {!soloLectura && !activo && !conteoEnCurso && <button onClick={() => setMostrarNuevo((v) => !v)}>{mostrarNuevo ? "Cancelar" : "+ Iniciar conteo"}</button>}
      </div>
      {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

      {!soloLectura && mostrarNuevo && !activo && <form className="card" onSubmit={crearConteo}>
        <div className="field"><label>Acta / motivo</label><input value={nota} onChange={(e) => setNota(e.target.value)} placeholder="Ej: Conteo mensual" style={{ width: "100%" }} /></div>
        <label className="opcion-destacada"><input type="checkbox" checked={conteoCompleto} onChange={(e) => setConteoCompleto(e.target.checked)} /> Contar todo el catálogo habilitado en esta tienda</label>
        {!conteoCompleto && <div>
          <div className="field"><label>Buscar por SKU, nombre o talla</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} style={{ width: "100%" }} /></div>
          <div className="seleccion-productos-conteo">{productosFiltrados.map((p) => <label key={p.id}><input type="checkbox" checked={seleccionados.has(p.id)} onChange={(e) => { const s = new Set(seleccionados); e.target.checked ? s.add(p.id) : s.delete(p.id); setSeleccionados(s); }} /><span><strong>{p.sku}</strong> {p.nombre} {p.talla ?? ""}</span></label>)}</div>
          <p className="conteo">{seleccionados.size} producto(s) seleccionados.</p>
        </div>}
        <button disabled={procesando}>{procesando ? "Abriendo..." : "Abrir conteo"}</button>
      </form>}

      {!soloLectura && !activo && conteoEnCurso && (
        <div className="card">
          <p className="ayuda"><strong>{conteoEnCurso.numero}</strong> ya está en curso, a nombre de {conteoEnCurso.responsable?.nombre_completo ?? conteoEnCurso.creador?.nombre_completo}.</p>
          {(conteoEnCurso.conteo_responsable_id ?? conteoEnCurso.creado_por) === uid && (
            <button disabled={procesando} onClick={() => continuarConteo(conteoEnCurso)}>Continuar mi conteo</button>
          )}
        </div>
      )}

      {activo && <section className="card">
        <div className="header-row">
          <div><h4 style={{ margin: 0 }}>{activo.numero}</h4><span className="badge estado-en_conteo">Conteo ciego</span></div>
          <button className="secondary" onClick={() => imprimirHoja(activo)}>Imprimir hoja</button>
        </div>
        <p className="info-box">El stock del sistema permanece oculto mientras cuentas. Al finalizar, cualquier campo vacío se registrará como <strong>0</strong> después de pedirte confirmación.</p>
        <div className="field"><label>Buscar por SKU, nombre o talla</label><input value={busquedaConteo} onChange={(e) => setBusquedaConteo(e.target.value)} style={{ width: "100%" }} /></div>
        <p className="conteo"><strong>{lineasActivasFiltradas.length}</strong> de {activo.lineas.length} productos visibles · <strong>{pendientes}</strong> pendientes en total.</p>
        <div className="tabla-scroll"><table><thead><tr><th>SKU</th><th>Producto</th><th>Talla</th><th className="num">Cantidad física</th><th>Observación</th></tr></thead><tbody>
          {lineasActivasFiltradas.map((l) => <tr key={l.id}>
            <td><strong>{l.producto?.sku}</strong></td><td>{l.producto?.nombre}</td><td>{l.producto?.talla ?? "-"}</td>
            <td className="num"><input type="number" min={0} value={valores[l.producto_id] ?? ""} onChange={(e) => setValores({ ...valores, [l.producto_id]: e.target.value })} style={{ width: 90, textAlign: "right" }} /></td>
            <td><input value={observaciones[l.producto_id] ?? ""} onChange={(e) => setObservaciones({ ...observaciones, [l.producto_id]: e.target.value })} /></td>
          </tr>)}
          {!lineasActivasFiltradas.length && <tr><td colSpan={5} className="vacio">Sin productos con esa búsqueda.</td></tr>}
        </tbody></table></div>
        <div className="acciones-documento">
          <button className="secondary" disabled={procesando || !lineasActivasFiltradas.length} onClick={completarVaciosConCero}>Completar visibles con 0</button>
          <button className="secondary" disabled={procesando} onClick={() => guardarConteo(false)}>Guardar avance</button>
          <button disabled={procesando} onClick={() => guardarConteo(true)}>Finalizar y enviar al administrador</button>
          <button className="chip-limpiar" onClick={() => setActivo(null)}>Cerrar</button>
        </div>
      </section>}

      <div className="card">
        <h4 style={{ marginTop: 0 }}>Historial de conteos de esta tienda</h4>
        {cargando ? <div className="vacio">Cargando...</div> : <div className="tabla-scroll"><table><thead><tr><th>Número</th><th>Fecha</th><th>Iniciado por</th><th>Estado</th></tr></thead><tbody>
          {conteos.map((c) => <tr key={c.id}>
            <td><strong>{c.numero}</strong></td><td>{fecha(c.created_at)}</td><td>{c.creador?.nombre_completo}</td>
            <td><span className={`badge estado-${c.estado}`}>{ETIQUETAS_ESTADO[c.estado] ?? c.estado}</span></td>
          </tr>)}
          {!conteos.length && <tr><td colSpan={4} className="vacio">No hay conteos registrados en esta tienda.</td></tr>}
        </tbody></table></div>}
      </div>
    </>
  );
}
