"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Producto = {
  id: string;
  sku: string;
  nombre: string;
  categoria: string | null;
  talla: string | null;
  color: string | null;
  stock_minimo: number;
  precio: number | null;
  activo: boolean;
};

const VACIO = { sku: "", nombre: "", categoria: "", talla: "", color: "", stock_minimo: 0, precio: "" };

export default function ProductosCliente() {
  const supabase = createClient();
  const [productos, setProductos] = useState<Producto[]>([]);
  const [cargando, setCargando] = useState(true);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  const [busqueda, setBusqueda] = useState("");
  const [categoria, setCategoria] = useState("");
  const [verInactivos, setVerInactivos] = useState(false);

  const [nuevo, setNuevo] = useState({ ...VACIO });
  const [mostrarForm, setMostrarForm] = useState(false);
  const [editando, setEditando] = useState<string | null>(null);
  const [edit, setEdit] = useState<Partial<Producto>>({});
  const [cambiandoEstado, setCambiandoEstado] = useState<string | null>(null);

  async function cargar() {
    setCargando(true);
    const { data, error } = await supabase
      .from("productos")
      .select("id, sku, nombre, categoria, talla, color, stock_minimo, precio, activo")
      .order("nombre");
    if (error) setMsg({ tipo: "error", texto: error.message });
    else setProductos((data as Producto[]) ?? []);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const categorias = useMemo(
    () => Array.from(new Set(productos.map((p) => p.categoria).filter(Boolean))).sort() as string[],
    [productos]
  );

  const filtrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return productos.filter((p) => {
      if (!verInactivos && !p.activo) return false;
      if (categoria && p.categoria !== categoria) return false;
      if (!q) return true;
      return (
        p.nombre.toLowerCase().includes(q) ||
        p.sku.toLowerCase().includes(q) ||
        (p.categoria ?? "").toLowerCase().includes(q) ||
        (p.talla ?? "").toLowerCase().includes(q) ||
        (p.color ?? "").toLowerCase().includes(q)
      );
    });
  }, [productos, busqueda, categoria, verInactivos]);

  async function crear(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    if (!nuevo.categoria.trim()) {
      setMsg({ tipo: "error", texto: "La categoría es obligatoria." });
      return;
    }
    const { error } = await supabase.from("productos").insert({
      sku: nuevo.sku.trim(),
      nombre: nuevo.nombre.trim(),
      categoria: nuevo.categoria.trim(),
      talla: nuevo.talla.trim() || null,
      color: nuevo.color.trim() || null,
      stock_minimo: Number(nuevo.stock_minimo) || 0,
      precio: nuevo.precio === "" ? null : Number(nuevo.precio),
    }).select("id").single();
    if (error) {
      setMsg({ tipo: "error", texto: error.message.includes("duplicate") ? "Ese SKU ya existe." : error.message });
      return;
    }
    setMsg({ tipo: "ok", texto: "Producto creado." });
    setNuevo({ ...VACIO });
    setMostrarForm(false);
    await cargar();
  }

  function abrirEdicion(p: Producto) {
    setEditando(p.id);
    setEdit({ nombre: p.nombre, categoria: p.categoria, talla: p.talla, color: p.color, stock_minimo: p.stock_minimo, precio: p.precio });
  }

  async function guardar(id: string) {
    setMsg(null);
    const categoriaLimpia = String(edit.categoria ?? "").trim();
    if (!categoriaLimpia) {
      setMsg({ tipo: "error", texto: "La categoría es obligatoria." });
      return;
    }
    const { error } = await supabase.from("productos").update({
      nombre: edit.nombre,
      categoria: categoriaLimpia,
      talla: edit.talla || null,
      color: edit.color || null,
      stock_minimo: Number(edit.stock_minimo) || 0,
      precio: edit.precio === null || edit.precio === undefined || (edit.precio as any) === "" ? null : Number(edit.precio),
    }).eq("id", id).select("id").single();
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setEditando(null);
    setMsg({ tipo: "ok", texto: "Producto actualizado." });
    await cargar();
  }

  async function alternarActivo(p: Producto) {
    const accion = p.activo ? "desactivar" : "reactivar";
    const motivo = window.prompt(
      `${p.activo ? "Desactivar" : "Reactivar"}: ${p.nombre} (${p.sku})\n\n` +
      (p.activo
        ? "Solo se permitirá si su stock total es cero. El historial de movimientos se conservará.\n\n"
        : "El producto volverá a estar disponible para movimientos e importaciones.\n\n") +
      `Indica el motivo para ${accion} el producto:`
    );

    if (motivo === null) return;
    if (!motivo.trim()) {
      setMsg({ tipo: "error", texto: "Debes indicar el motivo del cambio." });
      return;
    }

    setMsg(null);
    setCambiandoEstado(p.id);
    const { error } = await supabase.rpc("admin_cambiar_estado_producto", {
      p_producto_id: p.id,
      p_activo: !p.activo,
      p_motivo: motivo.trim(),
    });
    setCambiandoEstado(null);

    if (error) {
      setMsg({ tipo: "error", texto: error.message });
      return;
    }

    setMsg({
      tipo: "ok",
      texto: p.activo
        ? "Producto desactivado. Su historial permanece disponible."
        : "Producto reactivado correctamente.",
    });
    await cargar();
  }

  return (
    <>
      <div className="header-row">
        <h2 style={{ color: "#1f3864", margin: 0 }}>Productos</h2>
        <button onClick={() => setMostrarForm(!mostrarForm)}>
          {mostrarForm ? "Cancelar" : "+ Nuevo producto"}
        </button>
      </div>

      {mostrarForm && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Nuevo producto</h3>
          <form onSubmit={crear}>
            <div className="grid-2">
              <div className="field"><label>SKU</label>
                <input value={nuevo.sku} onChange={(e) => setNuevo({ ...nuevo, sku: e.target.value })} required style={{ width: "100%" }} /></div>
              <div className="field"><label>Nombre</label>
                <input value={nuevo.nombre} onChange={(e) => setNuevo({ ...nuevo, nombre: e.target.value })} required style={{ width: "100%" }} /></div>
              <div className="field"><label>Categoría</label>
                <input list="cats" value={nuevo.categoria} onChange={(e) => setNuevo({ ...nuevo, categoria: e.target.value })} required style={{ width: "100%" }} />
                <datalist id="cats">{categorias.map((c) => <option key={c} value={c} />)}</datalist></div>
              <div className="field"><label>Talla</label>
                <input value={nuevo.talla} onChange={(e) => setNuevo({ ...nuevo, talla: e.target.value })} style={{ width: "100%" }} /></div>
              <div className="field"><label>Color</label>
                <input value={nuevo.color} onChange={(e) => setNuevo({ ...nuevo, color: e.target.value })} style={{ width: "100%" }} /></div>
              <div className="field"><label>Stock mínimo (alerta)</label>
                <input type="number" min={0} value={nuevo.stock_minimo} onChange={(e) => setNuevo({ ...nuevo, stock_minimo: Number(e.target.value) })} style={{ width: "100%" }} /></div>
              <div className="field"><label>Precio (opcional)</label>
                <input type="number" step="0.01" min={0} value={nuevo.precio} onChange={(e) => setNuevo({ ...nuevo, precio: e.target.value })} style={{ width: "100%" }} /></div>
            </div>
            <button type="submit">Crear producto</button>
          </form>
        </div>
      )}

      <div className="card">
        <div className="filtros">
          <div className="field buscador">
            <label>Buscar</label>
            <input placeholder="Nombre, SKU, categoría, talla..." value={busqueda} onChange={(e) => setBusqueda(e.target.value)} />
          </div>
          <div className="field">
            <label>Categoría</label>
            <select value={categoria} onChange={(e) => setCategoria(e.target.value)}>
              <option value="">Todas</option>
              {categorias.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          </div>
          <div className="field">
            <label style={{ fontWeight: 500 }}>
              <input type="checkbox" checked={verInactivos} onChange={(e) => setVerInactivos(e.target.checked)} style={{ marginRight: 6 }} />
              Ver inactivos
            </label>
          </div>
          <button className="chip-limpiar" onClick={() => { setBusqueda(""); setCategoria(""); setVerInactivos(false); }}>Limpiar</button>
        </div>

        <div className="header-row">
          <span className="conteo">{filtrados.length} producto(s)</span>
          <button className="secondary" disabled={!filtrados.length}
            onClick={() => exportarCSV("productos_boman", filtrados.map((p) => ({
              SKU: p.sku, Nombre: p.nombre, Categoria: p.categoria, Talla: p.talla,
              Color: p.color, StockMinimo: p.stock_minimo, Precio: p.precio, Activo: p.activo ? "Sí" : "No",
            })))}>
            Exportar a Excel
          </button>
        </div>

        {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

        {cargando ? <div className="vacio">Cargando catálogo...</div> : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>SKU</th><th>Nombre</th><th>Categoría</th><th>Talla</th>
                  <th className="num">Mín.</th><th className="num">Precio</th><th>Acciones</th>
                </tr>
              </thead>
              <tbody>
                {filtrados.map((p) => (
                  editando === p.id ? (
                    <tr key={p.id}>
                      <td>{p.sku}</td>
                      <td><input value={edit.nombre ?? ""} onChange={(e) => setEdit({ ...edit, nombre: e.target.value })} style={{ width: "100%" }} /></td>
                      <td><input list="cats2" value={edit.categoria ?? ""} onChange={(e) => setEdit({ ...edit, categoria: e.target.value })} style={{ width: 120 }} />
                        <datalist id="cats2">{categorias.map((c) => <option key={c} value={c} />)}</datalist></td>
                      <td><input value={edit.talla ?? ""} onChange={(e) => setEdit({ ...edit, talla: e.target.value })} style={{ width: 60 }} /></td>
                      <td><input type="number" min={0} value={edit.stock_minimo ?? 0} onChange={(e) => setEdit({ ...edit, stock_minimo: Number(e.target.value) })} style={{ width: 70 }} /></td>
                      <td><input type="number" step="0.01" value={(edit.precio as any) ?? ""} onChange={(e) => setEdit({ ...edit, precio: e.target.value as any })} style={{ width: 80 }} /></td>
                      <td style={{ whiteSpace: "nowrap" }}>
                        <button onClick={() => guardar(p.id)} style={{ padding: "5px 10px", marginRight: 5 }}>Guardar</button>
                        <button className="chip-limpiar" onClick={() => setEditando(null)} style={{ padding: "5px 10px" }}>Cancelar</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={p.id} style={{ opacity: p.activo ? 1 : 0.5 }}>
                      <td>{p.sku}</td>
                      <td>{p.nombre}</td>
                      <td>{p.categoria ?? "-"}</td>
                      <td>{p.talla ?? "-"}</td>
                      <td className="num">{p.stock_minimo}</td>
                      <td className="num">{p.precio != null ? `$${Number(p.precio).toFixed(2)}` : "-"}</td>
                      <td style={{ whiteSpace: "nowrap" }}>
                        <button className="secondary" onClick={() => abrirEdicion(p)} style={{ padding: "5px 10px", marginRight: 5 }}>Editar</button>
                        <button className="chip-limpiar" disabled={cambiandoEstado === p.id}
                          onClick={() => alternarActivo(p)} style={{ padding: "5px 10px" }}>
                          {cambiandoEstado === p.id ? "Procesando..." : p.activo ? "Desactivar" : "Activar"}
                        </button>
                      </td>
                    </tr>
                  )
                ))}
                {!filtrados.length && <tr><td colSpan={7} className="vacio">Sin resultados.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
