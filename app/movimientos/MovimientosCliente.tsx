"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fecha, ETIQUETA_TIPO } from "@/lib/utils";
import type { Perfil } from "@/lib/getPerfil";

type Producto = { id: string; sku: string; nombre: string; categoria: string | null; talla: string | null };
type Almacen = { id: string; nombre: string; tipo: string };
type Movimiento = {
  id: string; tipo: string; cantidad: number; nota: string | null; created_at: string;
  grupo_id: string | null;
  anulado: boolean;
  anulado_at: string | null;
  motivo_anulacion: string | null;
  anulador: { nombre_completo: string } | null;
  productos: { nombre: string; sku: string } | null;
  almacenes: { nombre: string } | null;
  almacen_destino: { nombre: string } | null;
  perfiles: { nombre_completo: string } | null;
};

export default function MovimientosCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();

  const [productos, setProductos] = useState<Producto[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [movs, setMovs] = useState<Movimiento[]>([]);
  const [cargando, setCargando] = useState(true);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  // --- formulario ---
  const [buscaProd, setBuscaProd] = useState("");
  const [productoId, setProductoId] = useState("");
  const [almacenId, setAlmacenId] = useState(perfil.entidad_id ?? "");
  const [destinoId, setDestinoId] = useState("");
  const [tipo, setTipo] = useState("entrada");
  const [cantidad, setCantidad] = useState(1);
  const [nota, setNota] = useState("");
  const [guardando, setGuardando] = useState(false);

  // --- filtros historial ---
  const [fTexto, setFTexto] = useState("");
  const [fTipo, setFTipo] = useState("");
  const [fAlmacen, setFAlmacen] = useState("");
  const [fDesde, setFDesde] = useState("");
  const [fHasta, setFHasta] = useState("");
  const [verAnulados, setVerAnulados] = useState(true);

  const puedeRegistrar = ["admin", "bodega", "logistica"].includes(perfil.rol);
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
    const { error } = await supabase.rpc("anular_movimiento", { p_movimiento_id: m.id, p_motivo: motivo.trim() });
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
    const [p, a, m] = await Promise.all([
      supabase.from("productos").select("id, sku, nombre, categoria, talla").eq("activo", true).order("nombre"),
      supabase.from("almacenes").select("id, nombre, tipo").eq("activo", true).order("tipo"),
      supabase.from("movimientos")
        .select("id, tipo, cantidad, nota, created_at, grupo_id, anulado, anulado_at, motivo_anulacion, anulador:perfiles!movimientos_anulado_por_fkey(nombre_completo), productos(nombre, sku), almacenes!movimientos_entidad_id_fkey(nombre), almacen_destino:almacenes!movimientos_entidad_destino_id_fkey(nombre), perfiles!movimientos_usuario_id_fkey(nombre_completo)")
        .order("created_at", { ascending: false }).limit(500),
    ]);
    if (p.data) setProductos(p.data as Producto[]);
    if (a.data) setAlmacenes(a.data as Almacen[]);
    if (m.error) setMsg({ tipo: "error", texto: m.error.message });
    else setMovs((m.data as any) ?? []);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const sugerencias = useMemo(() => {
    const q = buscaProd.trim().toLowerCase();
    if (!q) return [];
    return productos.filter((p) =>
      p.nombre.toLowerCase().includes(q) || p.sku.toLowerCase().includes(q) ||
      (p.categoria ?? "").toLowerCase().includes(q)
    ).slice(0, 8);
  }, [buscaProd, productos]);

  const seleccionado = productos.find((p) => p.id === productoId);

  const movsFiltrados = useMemo(() => {
    const q = fTexto.trim().toLowerCase();
    return movs.filter((m) => {
      if (!verAnulados && m.anulado) return false;
      if (fTipo && m.tipo !== fTipo) return false;
      if (fAlmacen && m.almacenes?.nombre !== fAlmacen && m.almacen_destino?.nombre !== fAlmacen) return false;
      if (fDesde && new Date(m.created_at) < new Date(fDesde + "T00:00:00")) return false;
      if (fHasta && new Date(m.created_at) > new Date(fHasta + "T23:59:59")) return false;
      if (!q) return true;
      return (
        (m.productos?.nombre ?? "").toLowerCase().includes(q) ||
        (m.productos?.sku ?? "").toLowerCase().includes(q) ||
        (m.nota ?? "").toLowerCase().includes(q) ||
        (m.perfiles?.nombre_completo ?? "").toLowerCase().includes(q)
      );
    });
  }, [movs, fTexto, fTipo, fAlmacen, fDesde, fHasta, verAnulados]);

  async function registrar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    if (!productoId) { setMsg({ tipo: "error", texto: "Busca y selecciona un producto." }); return; }
    if (!almacenId) { setMsg({ tipo: "error", texto: "Selecciona el almacén." }); return; }
    if (tipo === "transferencia_envio" && !destinoId) { setMsg({ tipo: "error", texto: "Selecciona el almacén destino." }); return; }
    if (cantidad <= 0) { setMsg({ tipo: "error", texto: "La cantidad debe ser mayor a cero." }); return; }

    setGuardando(true);
    const { error } = await supabase.rpc("registrar_movimiento", {
      p_producto_id: productoId,
      p_entidad_id: almacenId,
      p_tipo: tipo,
      p_cantidad: cantidad,
      p_nota: nota || null,
      p_usuario_id: perfil.id,
      p_entidad_destino_id: tipo === "transferencia_envio" ? destinoId : null,
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
                  </span>
                  <button type="button" className="chip-limpiar" style={{ marginLeft: "auto", padding: "4px 10px" }}
                    onClick={() => { setProductoId(""); setBuscaProd(""); }}>Cambiar</button>
                </div>
              ) : (
                <>
                  <input placeholder="Escribe nombre, SKU o categoría..." value={buscaProd}
                    onChange={(e) => setBuscaProd(e.target.value)} style={{ width: "100%" }} autoComplete="off" />
                  {sugerencias.length > 0 && (
                    <div style={{ position: "absolute", zIndex: 20, background: "white", border: "1px solid #d1d5db", borderRadius: 6, width: "100%", maxHeight: 240, overflowY: "auto", boxShadow: "0 4px 12px rgba(0,0,0,.1)" }}>
                      {sugerencias.map((p) => (
                        <div key={p.id} onClick={() => { setProductoId(p.id); setBuscaProd(""); }}
                          style={{ padding: "8px 12px", cursor: "pointer", borderBottom: "1px solid #f3f4f6", fontSize: 14 }}
                          onMouseEnter={(e) => (e.currentTarget.style.background = "#f3f4f6")}
                          onMouseLeave={(e) => (e.currentTarget.style.background = "white")}>
                          <strong>{p.nombre}</strong>{p.talla ? ` · T/${p.talla}` : ""}
                          <div style={{ color: "#6b7280", fontSize: 12 }}>{p.sku} · {p.categoria ?? "sin categoría"}</div>
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
                  <option value="entrada">Entrada — llega producción</option>
                  <option value="salida">Salida — venta o baja</option>
                  <option value="transferencia_envio">Despacho — de Bodega a Tienda</option>
                  <option value="ajuste">Ajuste — fijar stock exacto</option>
                </select>
              </div>
              <div className="field">
                <label>Cantidad {tipo === "ajuste" ? "(stock final)" : ""}</label>
                <input type="number" min={tipo === "ajuste" ? 0 : 1} value={cantidad}
                  onChange={(e) => setCantidad(parseInt(e.target.value) || 0)} style={{ width: "100%" }} />
              </div>
              <div className="field">
                <label>Almacén {tipo === "transferencia_envio" ? "(origen)" : ""}</label>
                <select value={almacenId} onChange={(e) => setAlmacenId(e.target.value)} style={{ width: "100%" }}>
                  <option value="">Selecciona...</option>
                  {almacenes.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}
                </select>
              </div>
              {tipo === "transferencia_envio" && (
                <div className="field">
                  <label>Almacén destino</label>
                  <select value={destinoId} onChange={(e) => setDestinoId(e.target.value)} style={{ width: "100%" }}>
                    <option value="">Selecciona...</option>
                    {almacenes.filter((a) => a.id !== almacenId).map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}
                  </select>
                </div>
              )}
              <div className="field">
                <label>Nota / referencia (opcional)</label>
                <input value={nota} onChange={(e) => setNota(e.target.value)} placeholder="N° guía, factura, contrato..." style={{ width: "100%" }} />
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
            <input placeholder="Producto, SKU, nota o usuario..." value={fTexto} onChange={(e) => setFTexto(e.target.value)} />
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
          <div className="field"><label>Desde</label><input type="date" value={fDesde} onChange={(e) => setFDesde(e.target.value)} /></div>
          <div className="field"><label>Hasta</label><input type="date" value={fHasta} onChange={(e) => setFHasta(e.target.value)} /></div>
          <div className="field">
            <label style={{ fontWeight: 500 }}>
              <input type="checkbox" checked={verAnulados} onChange={(e) => setVerAnulados(e.target.checked)} style={{ marginRight: 6 }} />
              Mostrar anulados
            </label>
          </div>
          <button className="chip-limpiar" onClick={() => { setFTexto(""); setFTipo(""); setFAlmacen(""); setFDesde(""); setFHasta(""); setVerAnulados(true); }}>Limpiar</button>
        </div>

        <div className="header-row">
          <h3>Historial</h3>
          <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
            <span className="conteo">{movsFiltrados.length} movimiento(s)</span>
            <button className="secondary" disabled={!movsFiltrados.length}
              onClick={() => exportarCSV("movimientos_boman", movsFiltrados.map((m) => ({
                Fecha: fecha(m.created_at), Tipo: ETIQUETA_TIPO[m.tipo] ?? m.tipo,
                SKU: m.productos?.sku, Producto: m.productos?.nombre,
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
                    <td>{m.productos?.nombre}<div style={{ fontSize: 12, color: "#6b7280" }}>{m.productos?.sku}</div></td>
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
                    {puedeRegistrar && (
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
