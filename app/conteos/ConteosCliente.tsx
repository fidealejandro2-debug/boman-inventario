"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";
import { fecha } from "@/lib/utils";
import { ETIQUETAS_ESTADO, imprimirDocumento, nuevaClaveIdempotencia } from "@/lib/erp";
import { pedirMotivoDialogo, confirmarDialogo } from "@/components/Dialogo";

type Almacen = { id: string; nombre: string; tipo: string };
type Producto = { id: string; sku: string; nombre: string; talla: string | null; categoria: string | null };
type Linea = {
  id: string; producto_id: string; stock_sistema: number;
  cantidad_contada: number | null; cantidad_reconteo: number | null; observacion: string | null;
  producto: Producto | null;
};
type Conteo = {
  id: string; numero: string; estado: string; nota: string | null; created_at: string;
  origen_id: string; creado_por: string; version: number;
  conteo_responsable_id: string | null; conteo_actividad_at: string | null;
  origen: { nombre: string } | null;
  creador: { nombre_completo: string } | null;
  responsable: { nombre_completo: string } | null; lineas: Linea[];
};

function cantidadActual(linea: Linea) {
  return linea.cantidad_reconteo ?? linea.cantidad_contada ?? 0;
}

function lineasResultado(conteo: Conteo) {
  return conteo.lineas.filter((linea) =>
    (linea.stock_sistema ?? 0) !== 0 || cantidadActual(linea) !== 0
  );
}

function actividadReciente(conteo: Conteo) {
  return Boolean(conteo.conteo_actividad_at)
    && Date.now() - new Date(conteo.conteo_actividad_at!).getTime() <= 30 * 60 * 1000;
}

export default function ConteosCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [permitidos, setPermitidos] = useState<string[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [conteos, setConteos] = useState<Conteo[]>([]);
  const [activo, setActivo] = useState<Conteo | null>(null);
  const [valores, setValores] = useState<Record<string, string>>({});
  const [observaciones, setObservaciones] = useState<Record<string, string>>({});
  const [mostrarNuevo, setMostrarNuevo] = useState(false);
  const [almacenId, setAlmacenId] = useState(perfil.entidad_id ?? "");
  const [nota, setNota] = useState("");
  const [conteoCompleto, setConteoCompleto] = useState(true);
  const [seleccionados, setSeleccionados] = useState<Set<string>>(new Set());
  const [busqueda, setBusqueda] = useState("");
  const [categoriaSeleccion, setCategoriaSeleccion] = useState("");
  const [busquedaConteo, setBusquedaConteo] = useState("");
  const [categoriaConteo, setCategoriaConteo] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  const rolGlobal = ["admin", "control", "gerencia"].includes(perfil.rol);
  const puedeContar = ["admin", "control", "bodega", "tienda"].includes(perfil.rol);

  async function cargar() {
    setCargando(true);
    const [a, pa, p, c] = await Promise.all([
      supabase.from("almacenes").select("id, nombre, tipo").eq("activo", true).order("nombre"),
      supabase.from("perfil_almacenes").select("almacen_id").eq("perfil_id", perfil.id),
      supabase.from("productos").select("id, sku, nombre, talla, categoria").eq("activo", true).order("nombre"),
      supabase.from("documentos_inventario").select(`
        id, numero, estado, nota, created_at, origen_id, creado_por, version,
        conteo_responsable_id, conteo_actividad_at,
        origen:almacenes!documentos_inventario_origen_id_fkey(nombre),
        creador:perfiles!documentos_inventario_creado_por_fkey(nombre_completo),
        responsable:perfiles!documentos_inventario_conteo_responsable_id_fkey(nombre_completo),
        lineas:documento_inventario_lineas(
          id, producto_id, stock_sistema, cantidad_contada, cantidad_reconteo, observacion,
          producto:productos(id, sku, nombre, talla, categoria)
        )
      `).eq("tipo", "conteo").order("created_at", { ascending: false }).limit(100),
    ]);
    const error = a.error ?? pa.error ?? p.error ?? c.error;
    if (error) setMsg({ tipo: "error", texto: error.message });
    setAlmacenes((a.data ?? []) as Almacen[]);
    setPermitidos((pa.data ?? []).map((x: any) => x.almacen_id));
    setProductos((p.data ?? []) as Producto[]);
    setConteos((c.data ?? []) as any as Conteo[]);
    if (!almacenId && (pa.data ?? []).length) setAlmacenId((pa.data as any[])[0].almacen_id);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const almacenesPropios = useMemo(() => rolGlobal ? almacenes : almacenes.filter((a) => permitidos.includes(a.id) || a.id === perfil.entidad_id), [almacenes, permitidos, perfil.entidad_id, rolGlobal]);
  const categoriasProductos = useMemo(() => Array.from(new Set(
    productos.map((producto) => producto.categoria).filter((categoria): categoria is string => Boolean(categoria))
  )).sort(), [productos]);
  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return productos.filter((p) => {
      const coincideTexto = !q || p.sku.toLowerCase().includes(q)
        || p.nombre.toLowerCase().includes(q)
        || (p.talla ?? "").toLowerCase().includes(q)
        || (p.categoria ?? "").toLowerCase().includes(q);
      const coincideCategoria = !categoriaSeleccion
        || (categoriaSeleccion === "__sin_categoria__" ? !p.categoria : p.categoria === categoriaSeleccion);
      return coincideTexto && coincideCategoria;
    }).slice(0, 250);
  }, [busqueda, categoriaSeleccion, productos]);
  const categoriasConteo = useMemo(() => Array.from(new Set(
    (activo?.lineas ?? []).map((linea) => linea.producto?.categoria).filter((categoria): categoria is string => Boolean(categoria))
  )).sort(), [activo]);
  const lineasActivasFiltradas = useMemo(() => {
    const q = busquedaConteo.trim().toLowerCase();
    return (activo?.lineas ?? []).filter((linea) => {
      const producto = linea.producto;
      const coincideTexto = !q
        || (producto?.sku ?? "").toLowerCase().includes(q)
        || (producto?.nombre ?? "").toLowerCase().includes(q)
        || (producto?.talla ?? "").toLowerCase().includes(q);
      const coincideCategoria = !categoriaConteo
        || (categoriaConteo === "__sin_categoria__"
          ? !producto?.categoria
          : producto?.categoria === categoriaConteo);
      return coincideTexto && coincideCategoria;
    });
  }, [activo, busquedaConteo, categoriaConteo]);
  const pendientesConteo = activo?.lineas.filter((linea) =>
    (valores[linea.producto_id] ?? "") === ""
  ).length ?? 0;

  async function crearConteo(e: React.FormEvent) {
    e.preventDefault(); setMsg(null);
    if (!almacenId) { setMsg({ tipo: "error", texto: "Selecciona el almacén." }); return; }
    if (!conteoCompleto && seleccionados.size === 0) { setMsg({ tipo: "error", texto: "Selecciona al menos un producto." }); return; }
    setProcesando(true);
    const { error } = await supabase.rpc("crear_conteo_inventario", {
      p_almacen_id: almacenId,
      p_producto_ids: conteoCompleto ? null : Array.from(seleccionados),
      p_nota: nota || (conteoCompleto ? "Conteo total" : "Conteo parcial"),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMostrarNuevo(false); setNota(""); setSeleccionados(new Set());
    setMsg({ tipo: "ok", texto: "Conteo abierto. Los movimientos de esos productos quedan protegidos hasta finalizar." });
    await cargar();
  }

  function prepararConteo(conteo: Conteo) {
    const nuevos: Record<string, string> = {};
    const obs: Record<string, string> = {};
    conteo.lineas.forEach((linea) => {
      nuevos[linea.producto_id] = linea.cantidad_contada == null ? "" : String(linea.cantidad_contada);
      obs[linea.producto_id] = linea.observacion ?? "";
    });
    setActivo(conteo); setValores(nuevos); setObservaciones(obs);
    setBusquedaConteo(""); setCategoriaConteo(""); setMsg(null);
  }

  async function abrirConteo(conteo: Conteo, forzar = false) {
    let motivo: string | null = null;
    if (forzar) {
      motivo = await pedirMotivoDialogo(`Este conteo esta asignado a ${conteo.responsable?.nombre_completo ?? conteo.creador?.nombre_completo ?? "otro usuario"}.\n\nIndica el motivo para tomar el control:`);
      if (!motivo?.trim()) return;
    }
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("abrir_edicion_conteo_v22", {
      p_documento_id: conteo.id,
      p_forzar: forzar,
      p_motivo: motivo,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const apertura = data as { version: number; responsable_id: string; responsable_nombre: string; actividad_at: string; toma_control: boolean };
    prepararConteo({
      ...conteo,
      version: apertura.version,
      conteo_responsable_id: apertura.responsable_id,
      conteo_actividad_at: apertura.actividad_at,
      responsable: { nombre_completo: apertura.responsable_nombre },
    });
    if (apertura.toma_control) {
      setMsg({ tipo: "ok", texto: "Tomaste el control del conteo. La reasignacion quedo auditada." });
    }
  }

  async function guardarConteo(enviar: boolean) {
    if (!activo) return;
    const vacios = activo.lineas.filter((l) => (valores[l.producto_id] ?? "") === "");
    if (enviar && vacios.length > 0) {
      const confirmar = await confirmarDialogo(`${vacios.length} producto(s) están vacíos y se registrarán con cantidad 0.\n\n` +
        "Esto significa que físicamente no encontraste existencias de esos productos. ¿Deseas continuar?");
      if (!confirmar) return;
    }
    const valoresFinales = { ...valores };
    if (enviar) vacios.forEach((l) => { valoresFinales[l.producto_id] = "0"; });
    if (enviar && vacios.length) setValores(valoresFinales);
    const items = activo.lineas.filter((l) => enviar || (valoresFinales[l.producto_id] ?? "") !== "").map((l) => ({
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
      p_nota: enviar ? "Primer conteo finalizado" : "Avance guardado",
      p_version: activo.version,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: enviar ? "Conteo enviado a Control. Las diferencias requieren segundo conteo." : "Avance guardado." });
    setActivo(null); await cargar();
  }

  function completarVaciosConCero() {
    if (!activo) return;
    const siguientes = { ...valores };
    lineasActivasFiltradas.forEach((linea) => {
      if ((siguientes[linea.producto_id] ?? "") === "") siguientes[linea.producto_id] = "0";
    });
    setValores(siguientes);
  }

  function imprimirHojaCiega(conteo: Conteo) {
    imprimirDocumento(conteo.numero, `<h1>${conteo.numero} · Hoja de conteo ciego</h1>
      <p><b>Almacén:</b> ${conteo.origen?.nombre ?? ""} &nbsp; <b>Fecha:</b> ${fecha(conteo.created_at)}</p>
      <table><thead><tr><th>Ubicación</th><th>SKU</th><th>Producto</th><th>Talla</th><th class="num">Conteo</th></tr></thead><tbody>
      ${conteo.lineas.map((l) => `<tr><td></td><td>${l.producto?.sku ?? ""}</td><td>${l.producto?.nombre ?? ""}</td><td>${l.producto?.talla ?? ""}</td><td></td></tr>`).join("")}
      </tbody></table>`);
  }

  function imprimirResultado(conteo: Conteo) {
    const visibles = lineasResultado(conteo);
    const ocultas = conteo.lineas.length - visibles.length;
    const diferencias = visibles.filter((linea) => cantidadActual(linea) !== (linea.stock_sistema ?? 0)).length;
    imprimirDocumento(conteo.numero, `<h1>${conteo.numero} · Resultado de conteo</h1>
      <p><b>Almacén:</b> ${conteo.origen?.nombre ?? ""} &nbsp; <b>Fecha:</b> ${fecha(conteo.created_at)}</p>
      <p><b>${visibles.length}</b> líneas con existencias o movimiento &nbsp; <b>${diferencias}</b> diferencia(s) &nbsp; <b>${ocultas}</b> líneas 0 → 0 omitidas</p>
      <table><thead><tr><th>SKU</th><th>Producto</th><th>Talla</th><th class="num">Stock anterior</th><th class="num">Conteo actual</th><th class="num">Diferencia</th></tr></thead><tbody>
      ${visibles.length ? visibles.map((linea) => {
        const actual = cantidadActual(linea);
        const diferencia = actual - (linea.stock_sistema ?? 0);
        return `<tr><td>${linea.producto?.sku ?? ""}</td><td>${linea.producto?.nombre ?? ""}</td><td>${linea.producto?.talla ?? ""}</td><td class="num">${linea.stock_sistema ?? 0}</td><td class="num">${actual}</td><td class="num">${diferencia > 0 ? "+" : ""}${diferencia}</td></tr>`;
      }).join("") : `<tr><td colspan="6">Sin existencias ni diferencias: todas las líneas fueron 0 → 0.</td></tr>`}
      </tbody></table>`);
  }

  return (
    <>
      <div className="header-row"><div><h2 style={{ color: "#1f3864", margin: 0 }}>Conteos físicos</h2><p className="conteo">Conteo ciego, segundo conteo y aprobación independiente.</p></div>{puedeContar && <button onClick={() => setMostrarNuevo((v) => !v)}>{mostrarNuevo ? "Cancelar" : "+ Iniciar conteo"}</button>}</div>
      {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

      {mostrarNuevo && <form className="card" onSubmit={crearConteo}>
        <h3 style={{ marginTop: 0 }}>Nuevo conteo</h3>
        <div className="grid-2"><div className="field"><label>Almacén</label><select required value={almacenId} onChange={(e) => setAlmacenId(e.target.value)} style={{ width: "100%" }}><option value="">Seleccionar...</option>{almacenesPropios.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}</select></div><div className="field"><label>Acta / motivo</label><input value={nota} onChange={(e) => setNota(e.target.value)} placeholder="Ej: Conteo mensual septiembre" style={{ width: "100%" }} /></div></div>
        <label className="opcion-destacada"><input type="checkbox" checked={conteoCompleto} onChange={(e) => setConteoCompleto(e.target.checked)} /> Contar todo el catálogo habilitado en este almacén</label>
        {!conteoCompleto && <div><div className="grid-2"><div className="field"><label>Buscar por SKU, nombre, talla o categoría</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} style={{ width: "100%" }} /></div><div className="field"><label>Filtrar por categoría</label><select value={categoriaSeleccion} onChange={(e) => setCategoriaSeleccion(e.target.value)} style={{ width: "100%" }}><option value="">Todas las categorías</option>{categoriasProductos.map((categoria) => <option key={categoria} value={categoria}>{categoria}</option>)}<option value="__sin_categoria__">Sin categoría</option></select></div></div><div className="seleccion-productos-conteo">{productosFiltrados.map((p) => <label key={p.id}><input type="checkbox" checked={seleccionados.has(p.id)} onChange={(e) => { const s = new Set(seleccionados); e.target.checked ? s.add(p.id) : s.delete(p.id); setSeleccionados(s); }} /><span><strong>{p.sku}</strong> {p.nombre} {p.talla ?? ""} · {p.categoria ?? "Sin categoría"}</span></label>)}</div><p className="conteo">{seleccionados.size} producto(s) seleccionados · {productosFiltrados.length} visibles.</p></div>}
        <button disabled={procesando}>{procesando ? "Abriendo..." : "Abrir conteo"}</button>
      </form>}

      {activo && <section className="card conteo-activo">
        <div className="header-row"><div><h3 style={{ margin: 0 }}>{activo.numero}</h3><span className="badge estado-en_conteo">Conteo ciego · {activo.origen?.nombre}</span><div className="conteo">Responsable: {activo.responsable?.nombre_completo ?? activo.creador?.nombre_completo}</div></div><button className="secondary" onClick={() => imprimirHojaCiega(activo)}>Imprimir hoja</button></div>
        <p className="info-box">El stock del sistema permanece oculto. Cuenta físicamente cada SKU. Al finalizar, cualquier campo vacío se registrará como <strong>0</strong> después de pedirte confirmación.</p>
        <div className="grid-2"><div className="field"><label>Buscar por SKU, nombre o talla</label><input value={busquedaConteo} onChange={(e) => setBusquedaConteo(e.target.value)} placeholder="Ej: camiseta, CAM-001 o M" style={{ width: "100%" }} /></div><div className="field"><label>Filtrar por categoría</label><select value={categoriaConteo} onChange={(e) => setCategoriaConteo(e.target.value)} style={{ width: "100%" }}><option value="">Todas las categorías</option>{categoriasConteo.map((categoria) => <option key={categoria} value={categoria}>{categoria}</option>)}<option value="__sin_categoria__">Sin categoría</option></select></div></div>
        <p className="conteo"><strong>{lineasActivasFiltradas.length}</strong> de {activo.lineas.length} productos visibles · <strong>{pendientesConteo}</strong> pendientes en todo el conteo.</p>
        <div className="tabla-scroll"><table><thead><tr><th>SKU</th><th>Producto</th><th>Categoría</th><th>Talla</th><th className="num">Cantidad física</th><th>Observación</th></tr></thead><tbody>{lineasActivasFiltradas.map((l) => <tr key={l.id}><td><strong>{l.producto?.sku}</strong></td><td>{l.producto?.nombre}</td><td>{l.producto?.categoria ?? "Sin categoría"}</td><td>{l.producto?.talla ?? "-"}</td><td className="num"><input type="number" min={0} value={valores[l.producto_id] ?? ""} onChange={(e) => setValores({ ...valores, [l.producto_id]: e.target.value })} style={{ width: 90, textAlign: "right" }} /></td><td><input value={observaciones[l.producto_id] ?? ""} onChange={(e) => setObservaciones({ ...observaciones, [l.producto_id]: e.target.value })} /></td></tr>)}{!lineasActivasFiltradas.length && <tr><td colSpan={6} className="vacio">No hay productos que coincidan con la búsqueda y categoría.</td></tr>}</tbody></table></div>
        <div className="acciones-documento"><button className="secondary" disabled={procesando || !lineasActivasFiltradas.length} onClick={completarVaciosConCero}>Completar visibles con 0</button><button className="secondary" disabled={procesando} onClick={() => guardarConteo(false)}>Guardar avance</button><button disabled={procesando} onClick={() => guardarConteo(true)}>Finalizar y enviar a Control</button><button className="chip-limpiar" onClick={() => setActivo(null)}>Cerrar</button></div>
      </section>}

      <div className="card"><h3 style={{ marginTop: 0 }}>Historial de conteos</h3>{cargando ? <div className="vacio">Cargando...</div> : <div className="tabla-scroll"><table><thead><tr><th>Número</th><th>Almacén</th><th>Fecha</th><th>Creado por</th><th>Responsable actual</th><th>Estado</th><th className="num">Líneas relevantes</th><th></th></tr></thead><tbody>{conteos.map((c) => { const responsableId = c.conteo_responsable_id ?? c.creado_por; const propio = responsableId === perfil.id; return <tr key={c.id}><td><strong>{c.numero}</strong></td><td>{c.origen?.nombre}</td><td>{fecha(c.created_at)}</td><td>{c.creador?.nombre_completo}</td><td>{c.responsable?.nombre_completo ?? c.creador?.nombre_completo}{c.estado === "en_conteo" && actividadReciente(c) && <div><span className="badge estado-en_conteo">En edición reciente</span></div>}</td><td><span className={`badge estado-${c.estado}`}>{ETIQUETAS_ESTADO[c.estado] ?? c.estado}</span></td><td className="num">{c.estado === "en_conteo" ? c.lineas.length : lineasResultado(c).length}</td><td>{c.estado === "en_conteo" && puedeContar ? propio ? <button className="secondary" disabled={procesando} onClick={() => abrirConteo(c)}>Continuar</button> : perfil.rol === "admin" ? <button className="peligro" disabled={procesando} onClick={() => abrirConteo(c, true)}>Tomar control</button> : <small>Asignado a otro usuario</small> : <button className="secondary" onClick={() => imprimirResultado(c)}>Ver resultado</button>}</td></tr>; })}{!conteos.length && <tr><td colSpan={8} className="vacio">No hay conteos registrados.</td></tr>}</tbody></table></div>}</div>
    </>
  );
}
