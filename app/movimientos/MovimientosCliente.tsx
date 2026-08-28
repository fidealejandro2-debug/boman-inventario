"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fecha, ETIQUETA_TIPO } from "@/lib/utils";
import type { Perfil } from "@/lib/getPerfil";

type Producto = {
  id: string; sku: string; nombre: string;
  categoria: string | null; categoria_id: string | null;
  subcategoria: string | null; subcategoria_id: string | null;
  talla: string | null;
};
type Almacen = { id: string; nombre: string; tipo: string };
type Movimiento = {
  id: string; tipo: string; cantidad: number; nota: string | null; created_at: string;
  grupo_id: string | null;
  anulado: boolean;
  anulado_at: string | null;
  motivo_anulacion: string | null;
  anulador: { nombre_completo: string } | null;
  productos: {
    nombre: string; sku: string;
    categoria: string | null; categoria_id: string | null;
    subcategoria: string | null; subcategoria_id: string | null;
  } | null;
  almacenes: { nombre: string } | null;
  almacen_destino: { nombre: string } | null;
  perfiles: { nombre_completo: string } | null;
  empresa_id: string | null;
};
type Empresa = { id: string; razon_social: string };

export default function MovimientosCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();

  const [productos, setProductos] = useState<Producto[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [movs, setMovs] = useState<Movimiento[]>([]);
  const [cargando, setCargando] = useState(true);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  // --- formulario ---
  const [buscaProd, setBuscaProd] = useState("");
  const [productoId, setProductoId] = useState("");
  const [almacenId, setAlmacenId] = useState(perfil.entidad_id ?? "");
  const [tipo, setTipo] = useState("entrada");
  const [cantidad, setCantidad] = useState(1);
  const [nota, setNota] = useState("");
  const [guardando, setGuardando] = useState(false);

  // --- filtros historial ---
  const [fTexto, setFTexto] = useState("");
  const [fTipo, setFTipo] = useState("");
  const [fAlmacen, setFAlmacen] = useState("");
  const [fCategoria, setFCategoria] = useState("");
  const [fSubcategoria, setFSubcategoria] = useState("");
  const [fDesde, setFDesde] = useState("");
  const [fHasta, setFHasta] = useState("");
  const [fEmpresa, setFEmpresa] = useState("");
  const [verAnulados, setVerAnulados] = useState(true);

  const puedeRegistrar = ["admin", "bodega"].includes(perfil.rol);
  const puedeAnular = perfil.rol === "control";
  const [anulando, setAnulando] = useState<string | null>(null);
  const [editNota, setEditNota] = useState<string | null>(null);
  const [notaTmp, setNotaTmp] = useState("");

  async function anular(m: Movimiento) {
    const etiqueta = ETIQUETA_TIPO[m.tipo] ?? m.tipo;
    const extra = m.tipo === "transferencia_envio"
      ? "\nSe anulará también la recepción en la tienda destino."
      : "";
    const motivo = window.prompt(
      `Anular: ${etiqueta} de ${m.cantidad} × ${m.productos?.nombre} (${m.almacenes?.nombre})${extra}\n\n` +
      `El stock se corregirá y el movimiento quedará registrado como ANULADO.\n\n` +
      `Indica el motivo de la anulación:`
    );
    if (motivo === null) return;
    if (!motivo.trim()) { setMsg({ tipo: "error", texto: "Debes indicar el motivo de la anulación." }); return; }

    setAnulando(m.id);
    setMsg(null);
    const { error } = await supabase.rpc("control_anular_movimiento", { p_movimiento_id: m.id, p_motivo: motivo.trim() });
    setAnulando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: "Movimiento anulado. Queda en el historial para trazabilidad y el stock ya se corrigió." });
    cargar();
  }

  async function guardarNota(id: string) {
    const { error } = await supabase.from("movimientos").update({ nota: notaTmp || null }).eq("id", id);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setEditNota(null);
    cargar();
  }

  async function cargar() {
    setCargando(true);
    const [p, a, e] = await Promise.all([
      supabase.from("productos").select("id, sku, nombre, categoria, categoria_id, subcategoria, subcategoria_id, talla").eq("activo", true).order("nombre"),
      supabase.from("almacenes").select("id, nombre, tipo").eq("activo", true).order("tipo"),
      supabase.from("empresas").select("id, razon_social").eq("activo", true).order("razon_social"),
    ]);

    if (p.data) setProductos(p.data as Producto[]);
    if (a.data) setAlmacenes(a.data as Almacen[]);
    if (e.data) setEmpresas(e.data as Empresa[]);
    if (p.error || a.error) {
      setMsg({ tipo: "error", texto: p.error?.message ?? a.error!.message });
      setCargando(false);
      return;
    }

    const todos: Movimiento[] = [];
    const tamanoPagina = 1000;
    let desde = 0;
    while (true) {
      const m = await supabase.from("movimientos")
        .select("id, tipo, cantidad, nota, created_at, grupo_id, anulado, anulado_at, motivo_anulacion, empresa_id, anulador:perfiles!movimientos_anulado_por_fkey(nombre_completo), productos(nombre, sku, categoria, categoria_id, subcategoria, subcategoria_id), almacenes!movimientos_entidad_id_fkey(nombre), almacen_destino:almacenes!movimientos_entidad_destino_id_fkey(nombre), perfiles!movimientos_usuario_id_fkey(nombre_completo)")
        .order("created_at", { ascending: false })
        .range(desde, desde + tamanoPagina - 1);

      if (m.error) {
        setMsg({ tipo: "error", texto: m.error.message });
        break;
      }
      const pagina = (m.data as any as Movimiento[]) ?? [];
      todos.push(...pagina);
      if (pagina.length < tamanoPagina) break;
      desde += tamanoPagina;
    }
    setMovs(todos);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const sugerencias = useMemo(() => {
    const q = buscaProd.trim().toLowerCase();
    if (!q) return [];
    return productos.filter((p) =>
      p.nombre.toLowerCase().includes(q) || p.sku.toLowerCase().includes(q) ||
      (p.categoria ?? "").toLowerCase().includes(q) ||
      (p.subcategoria ?? "").toLowerCase().includes(q)
    ).slice(0, 8);
  }, [buscaProd, productos]);

  const categoriasHistorial = useMemo(() => {
    const mapa = new Map<string, string>();
    movs.forEach((m) => {
      const p = m.productos;
      if (p?.categoria_id && p.categoria) mapa.set(p.categoria_id, p.categoria);
    });
    return Array.from(mapa, ([id, nombre]) => ({ id, nombre })).sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [movs]);

  const subcategoriasHistorial = useMemo(() => {
    const mapa = new Map<string, string>();
    movs.forEach((m) => {
      const p = m.productos;
      if (p?.subcategoria_id && p.subcategoria && (!fCategoria || p.categoria_id === fCategoria)) {
        mapa.set(p.subcategoria_id, p.subcategoria);
      }
    });
    return Array.from(mapa, ([id, nombre]) => ({ id, nombre })).sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [movs, fCategoria]);

  const seleccionado = productos.find((p) => p.id === productoId);
  const almacenesOrigen = perfil.entidad_id
    ? almacenes.filter((a) => a.id === perfil.entidad_id)
    : almacenes;

  const movsFiltrados = useMemo(() => {
    const q = fTexto.trim().toLowerCase();
    return movs.filter((m) => {
      if (!verAnulados && m.anulado) return false;
      if (fTipo && m.tipo !== fTipo) return false;
      if (fAlmacen && m.almacenes?.nombre !== fAlmacen && m.almacen_destino?.nombre !== fAlmacen) return false;
      if (fCategoria && m.productos?.categoria_id !== fCategoria) return false;
      if (fSubcategoria && m.productos?.subcategoria_id !== fSubcategoria) return false;
      if (fEmpresa && m.empresa_id !== fEmpresa) return false;
      if (fDesde && new Date(m.created_at) < new Date(fDesde + "T00:00:00")) return false;
      if (fHasta && new Date(m.created_at) > new Date(fHasta + "T23:59:59")) return false;
      if (!q) return true;
      return (
        (m.productos?.nombre ?? "").toLowerCase().includes(q) ||
        (m.productos?.sku ?? "").toLowerCase().includes(q) ||
        (m.productos?.categoria ?? "").toLowerCase().includes(q) ||
        (m.productos?.subcategoria ?? "").toLowerCase().includes(q) ||
        (m.nota ?? "").toLowerCase().includes(q) ||
        (m.perfiles?.nombre_completo ?? "").toLowerCase().includes(q)
      );
    });
  }, [movs, fTexto, fTipo, fAlmacen, fCategoria, fSubcategoria, fEmpresa, fDesde, fHasta, verAnulados]);

  async function registrar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    if (!productoId) { setMsg({ tipo: "error", texto: "Busca y selecciona un producto." }); return; }
    if (!almacenId) { setMsg({ tipo: "error", texto: "Selecciona el almacén." }); return; }
    if (cantidad <= 0) { setMsg({ tipo: "error", texto: "La cantidad debe ser mayor a cero." }); return; }
    if (!nota.trim()) { setMsg({ tipo: "error", texto: "La referencia o motivo es obligatorio." }); return; }

    setGuardando(true);
    const { error } = await supabase.rpc("registrar_movimiento_manual", {
      p_producto_id: productoId,
      p_entidad_id: almacenId,
      p_tipo: tipo,
      p_cantidad: cantidad,
      p_referencia: nota.trim(),
    });
    setGuardando(false);

    if (error) {
      setMsg({ tipo: "error", texto: error.message.includes("Stock insuficiente") ? "Stock insuficiente en ese almacén." : error.message });
      return;
    }
    setMsg({ tipo: "ok", texto: `Registrado: ${ETIQUETA_TIPO[tipo]} de ${cantidad} × ${seleccionado?.nombre}.` });
    setCantidad(1); setNota(""); setProductoId(""); setBuscaProd("");
    cargar();
  }

  return (
    <>
      <h2 style={{ color: "#1f3864" }}>Movimientos</h2>

      {puedeRegistrar && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Registrar movimiento</h3>
          <form onSubmit={registrar}>
            <div className="field" style={{ position: "relative" }}>
              <label>Producto</label>
              {seleccionado ? (
                <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 10px", background: "#eef4fb", border: "1px solid #2e75b6", borderRadius: 6 }}>
                  <strong>{seleccionado.nombre}</strong>
                  <span style={{ color: "#6b7280", fontSize: 13 }}>
                    {seleccionado.sku}{seleccionado.talla ? ` · T/${seleccionado.talla}` : ""}
                    {seleccionado.categoria ? ` · ${seleccionado.categoria}` : ""}
                    {seleccionado.subcategoria ? ` / ${seleccionado.subcategoria}` : ""}
                  </span>
                  <button type="button" className="chip-limpiar" style={{ marginLeft: "auto", padding: "4px 10px" }}
                    onClick={() => { setProductoId(""); setBuscaProd(""); }}>Cambiar</button>
                </div>
              ) : (
                <>
                  <input placeholder="Escribe nombre, SKU, categoría o subcategoría..." value={buscaProd}
                    onChange={(e) => setBuscaProd(e.target.value)} style={{ width: "100%" }} autoComplete="off" />
                  {sugerencias.length > 0 && (
                    <div style={{ position: "absolute", zIndex: 20, background: "white", border: "1px solid #d1d5db", borderRadius: 6, width: "100%", maxHeight: 240, overflowY: "auto", boxShadow: "0 4px 12px rgba(0,0,0,.1)" }}>
                      {sugerencias.map((p) => (
                        <div key={p.id} onClick={() => { setProductoId(p.id); setBuscaProd(""); }}
                          style={{ padding: "8px 12px", cursor: "pointer", borderBottom: "1px solid #f3f4f6", fontSize: 14 }}
                          onMouseEnter={(e) => (e.currentTarget.style.background = "#f3f4f6")}
                          onMouseLeave={(e) => (e.currentTarget.style.background = "white")}>
                          <strong>{p.nombre}</strong>{p.talla ? ` · T/${p.talla}` : ""}
                          <div style={{ color: "#6b7280", fontSize: 12 }}>
                            {p.sku} · {p.categoria ?? "sin categoría"}{p.subcategoria ? ` / ${p.subcategoria}` : ""}
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </>
              )}
            </div>

            <div className="grid-2">
              <div className="field">
                <label>Tipo de movimiento</label>
                <select value={tipo} onChange={(e) => setTipo(e.target.value)} style={{ width: "100%" }}>
                  <option value="entrada">Entrada manual con referencia</option>
                  <option value="salida">Salida manual con referencia</option>
                </select>
              </div>
              <div className="field">
                <label>Cantidad</label>
                <input type="number" min={1} value={cantidad}
                  onChange={(e) => setCantidad(parseInt(e.target.value) || 0)} style={{ width: "100%" }} />
              </div>
              <div className="field">
                <label>Almacén</label>
                <select value={almacenId} onChange={(e) => setAlmacenId(e.target.value)} style={{ width: "100%" }}>
                  <option value="">Selecciona...</option>
                  {almacenesOrigen.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}
                </select>
              </div>
              <div className="field">
                <label>Referencia / motivo obligatorio</label>
                <input required value={nota} onChange={(e) => setNota(e.target.value)} placeholder="N° orden, factura, contrato o motivo..." style={{ width: "100%" }} />
              </div>
            </div>

            {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}
            <button type="submit" disabled={guardando}>{guardando ? "Guardando..." : "Registrar movimiento"}</button>
          </form>
        </div>
      )}

      <div className="card">
        <div className="filtros">
          <div className="field buscador">
            <label>Buscar</label>
            <input placeholder="Producto, SKU, categoría, nota o usuario..." value={fTexto} onChange={(e) => setFTexto(e.target.value)} />
          </div>
          <div className="field">
            <label>Tipo</label>
            <select value={fTipo} onChange={(e) => setFTipo(e.target.value)}>
              <option value="">Todos</option>
              {Object.entries(ETIQUETA_TIPO).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </div>
          <div className="field">
            <label>Almacén</label>
            <select value={fAlmacen} onChange={(e) => setFAlmacen(e.target.value)}>
              <option value="">Todos</option>
              {almacenes.map((a) => <option key={a.id} value={a.nombre}>{a.nombre}</option>)}
            </select>
          </div>
          <div className="field">
            <label>Categoría</label>
            <select value={fCategoria} onChange={(e) => { setFCategoria(e.target.value); setFSubcategoria(""); }}>
              <option value="">Todas</option>
              {categoriasHistorial.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
          </div>
          <div className="field">
            <label>Subcategoría</label>
            <select value={fSubcategoria} onChange={(e) => setFSubcategoria(e.target.value)}>
              <option value="">Todas</option>
              {subcategoriasHistorial.map((s) => <option key={s.id} value={s.id}>{s.nombre}</option>)}
            </select>
          </div>
          <div className="field"><label>Desde</label><input type="date" value={fDesde} onChange={(e) => setFDesde(e.target.value)} /></div>
          <div className="field"><label>Hasta</label><input type="date" value={fHasta} onChange={(e) => setFHasta(e.target.value)} /></div>
          <div className="field">
            <label>Empresa</label>
            <select value={fEmpresa} onChange={(e) => setFEmpresa(e.target.value)}>
              <option value="">Todas</option>
              {empresas.map((e) => <option key={e.id} value={e.id}>{e.razon_social}</option>)}
            </select>
          </div>
          <div className="field">
            <label style={{ fontWeight: 500 }}>
              <input type="checkbox" checked={verAnulados} onChange={(e) => setVerAnulados(e.target.checked)} style={{ marginRight: 6 }} />
              Mostrar anulados
            </label>
          </div>
          <button className="chip-limpiar" onClick={() => { setFTexto(""); setFTipo(""); setFAlmacen(""); setFCategoria(""); setFSubcategoria(""); setFEmpresa(""); setFDesde(""); setFHasta(""); setVerAnulados(true); }}>Limpiar</button>
        </div>

        <div className="header-row">
          <h3>Historial</h3>
          <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
            <span className="conteo">{movsFiltrados.length} movimiento(s)</span>
            <button className="secondary" disabled={!movsFiltrados.length}
              onClick={() => exportarCSV("movimientos_boman", movsFiltrados.map((m) => ({
                Fecha: fecha(m.created_at), Tipo: ETIQUETA_TIPO[m.tipo] ?? m.tipo,
                SKU: m.productos?.sku, Producto: m.productos?.nombre,
                Categoria: m.productos?.categoria, Subcategoria: m.productos?.subcategoria,
                Almacen: m.almacenes?.nombre, Destino: m.almacen_destino?.nombre ?? "",
                Cantidad: m.cantidad, Usuario: m.perfiles?.nombre_completo, Nota: m.nota ?? "",
                Estado: m.anulado ? "ANULADO" : "Vigente",
                MotivoAnulacion: m.motivo_anulacion ?? "",
                AnuladoPor: m.anulador?.nombre_completo ?? "",
                AnuladoEl: m.anulado_at ? fecha(m.anulado_at) : "",
              })))}>
              Exportar a Excel
            </button>
          </div>
        </div>

        {cargando ? <div className="vacio">Cargando movimientos...</div> : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th><th>Tipo</th><th>Producto</th><th>Almacén</th>
                  <th>Destino</th><th className="num">Cant.</th><th>Usuario</th><th>Nota</th>
                  {puedeRegistrar && <th>Acciones</th>}
                </tr>
              </thead>
              <tbody>
                {movsFiltrados.map((m) => (
                  <tr key={m.id} className={m.anulado ? "fila-anulada" : ""}>
                    <td style={{ whiteSpace: "nowrap" }}>{fecha(m.created_at)}</td>
                    <td>
                      <span className={`badge ${m.tipo}`}>{ETIQUETA_TIPO[m.tipo] ?? m.tipo}</span>
                      {m.anulado && <span className="badge anulado" style={{ marginLeft: 4 }}>ANULADO</span>}
                    </td>
                    <td>
                      {m.productos?.nombre}
                      <div style={{ fontSize: 12, color: "#6b7280" }}>{m.productos?.sku}</div>
                      {(m.productos?.categoria || m.productos?.subcategoria) && (
                        <div style={{ fontSize: 11, color: "#64748b" }}>
                          {m.productos?.categoria ?? "Sin categoría"}{m.productos?.subcategoria ? ` / ${m.productos.subcategoria}` : ""}
                        </div>
                      )}
                    </td>
                    <td>{m.almacenes?.nombre}</td>
                    <td>{m.almacen_destino?.nombre ?? "-"}</td>
                    <td className="num">{m.cantidad}</td>
                    <td>{m.perfiles?.nombre_completo}</td>
                    <td style={{ maxWidth: 180, fontSize: 13 }}>
                      {m.anulado ? (
                        <div style={{ fontSize: 12 }}>
                          {m.nota && <div>{m.nota}</div>}
                          <div style={{ color: "#991b1b", marginTop: 2 }}>
                            <strong>Motivo:</strong> {m.motivo_anulacion}
                          </div>
                          <div style={{ color: "#9ca3af" }}>
                            {m.anulador?.nombre_completo}{m.anulado_at ? ` · ${fecha(m.anulado_at)}` : ""}
                          </div>
                        </div>
                      ) : editNota === m.id ? (
                        <div style={{ display: "flex", gap: 4 }}>
                          <input value={notaTmp} onChange={(e) => setNotaTmp(e.target.value)} style={{ width: 130 }} />
                          <button onClick={() => guardarNota(m.id)} style={{ padding: "3px 8px" }}>OK</button>
                        </div>
                      ) : (
                        <span
                          onClick={() => { if (puedeRegistrar) { setEditNota(m.id); setNotaTmp(m.nota ?? ""); } }}
                          style={{ cursor: puedeRegistrar ? "pointer" : "default" }}
                          title={puedeRegistrar ? "Clic para editar" : ""}
                        >
                          {m.nota ?? "-"}
                        </span>
                      )}
                    </td>
                    {puedeAnular && (
                      <td style={{ whiteSpace: "nowrap" }}>
                        {m.anulado ? (
                          <span style={{ fontSize: 12, color: "#9ca3af" }}>—</span>
                        ) : m.tipo === "transferencia_recibo" ? (
                          <span style={{ fontSize: 12, color: "#9ca3af" }}>Anula el despacho</span>
                        ) : (
                          <button className="peligro" disabled={anulando === m.id}
                            onClick={() => anular(m)} style={{ padding: "5px 10px" }}>
                            {anulando === m.id ? "..." : "Anular"}
                          </button>
                        )}
                      </td>
                    )}
                  </tr>
                ))}
                {!movsFiltrados.length && <tr><td colSpan={puedeRegistrar ? 9 : 8} className="vacio">Sin movimientos con esos filtros.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
