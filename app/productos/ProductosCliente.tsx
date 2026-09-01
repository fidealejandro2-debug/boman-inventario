"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";
import ImportarCatalogo from "./ImportarCatalogo";

type Producto = {
  id: string;
  sku: string;
  nombre: string;
  categoria: string | null;
  categoria_id: string | null;
  subcategoria: string | null;
  subcategoria_id: string | null;
  talla: string | null;
  color: string | null;
  stock_minimo: number;
  precio: number | null;
  activo: boolean;
};

type CategoriaProducto = {
  id: string;
  nombre: string;
  descripcion: string | null;
  activo: boolean;
};

type SubcategoriaProducto = {
  id: string;
  categoria_id: string;
  nombre: string;
  descripcion: string | null;
  activo: boolean;
};

const VACIO = {
  sku: "",
  nombre: "",
  categoria_id: "",
  subcategoria_id: "",
  talla: "",
  color: "",
  stock_minimo: 0,
  precio: "",
};

export default function ProductosCliente() {
  const supabase = createClient();
  const [productos, setProductos] = useState<Producto[]>([]);
  const [categoriasCatalogo, setCategoriasCatalogo] = useState<CategoriaProducto[]>([]);
  const [subcategoriasCatalogo, setSubcategoriasCatalogo] = useState<SubcategoriaProducto[]>([]);
  const [cargando, setCargando] = useState(true);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  const [busqueda, setBusqueda] = useState("");
  const [categoria, setCategoria] = useState("");
  const [subcategoria, setSubcategoria] = useState("");
  const [verInactivos, setVerInactivos] = useState(false);

  const [nuevo, setNuevo] = useState({ ...VACIO });
  const [mostrarForm, setMostrarForm] = useState(false);
  const [mostrarImportacion, setMostrarImportacion] = useState(false);
  const [editando, setEditando] = useState<string | null>(null);
  const [edit, setEdit] = useState<Partial<Producto>>({});
  const [cambiandoEstado, setCambiandoEstado] = useState<string | null>(null);
  const [mostrarCategorias, setMostrarCategorias] = useState(false);
  const [nuevaCategoria, setNuevaCategoria] = useState("");
  const [nuevasSubcategorias, setNuevasSubcategorias] = useState<Record<string, string>>({});
  const [guardandoCatalogo, setGuardandoCatalogo] = useState(false);
  const [seleccionados, setSeleccionados] = useState<Set<string>>(new Set());
  const [categoriaMasiva, setCategoriaMasiva] = useState("");
  const [subcategoriaMasiva, setSubcategoriaMasiva] = useState("");
  const [aplicandoMasivo, setAplicandoMasivo] = useState(false);

  async function cargar() {
    setCargando(true);
    const [productosRes, categoriasRes, subcategoriasRes] = await Promise.all([
      supabase
        .from("productos")
        .select("id, sku, nombre, categoria, categoria_id, subcategoria, subcategoria_id, talla, color, stock_minimo, precio, activo")
        .order("nombre"),
      supabase.from("categorias_productos").select("id, nombre, descripcion, activo").order("nombre"),
      supabase.from("subcategorias_productos").select("id, categoria_id, nombre, descripcion, activo").order("nombre"),
    ]);

    const error = productosRes.error || categoriasRes.error || subcategoriasRes.error;
    if (error) setMsg({ tipo: "error", texto: error.message });
    if (productosRes.data) setProductos(productosRes.data as Producto[]);
    if (categoriasRes.data) setCategoriasCatalogo(categoriasRes.data as CategoriaProducto[]);
    if (subcategoriasRes.data) setSubcategoriasCatalogo(subcategoriasRes.data as SubcategoriaProducto[]);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const categoriasActivas = useMemo(
    () => categoriasCatalogo.filter((c) => c.activo),
    [categoriasCatalogo]
  );

  const subcategoriasActivas = useMemo(
    () => subcategoriasCatalogo.filter((s) => s.activo),
    [subcategoriasCatalogo]
  );

  const subcategoriasFiltro = useMemo(
    () => subcategoriasCatalogo.filter((s) => !categoria || s.categoria_id === categoria),
    [subcategoriasCatalogo, categoria]
  );

  const filtrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return productos.filter((p) => {
      if (!verInactivos && !p.activo) return false;
      if (categoria && p.categoria_id !== categoria) return false;
      if (subcategoria && p.subcategoria_id !== subcategoria) return false;
      if (!q) return true;
      return (
        p.nombre.toLowerCase().includes(q) ||
        p.sku.toLowerCase().includes(q) ||
        (p.categoria ?? "").toLowerCase().includes(q) ||
        (p.subcategoria ?? "").toLowerCase().includes(q) ||
        (p.talla ?? "").toLowerCase().includes(q) ||
        (p.color ?? "").toLowerCase().includes(q)
      );
    });
  }, [productos, busqueda, categoria, subcategoria, verInactivos]);

  const todosFiltradosSeleccionados = filtrados.length > 0 && filtrados.every((p) => seleccionados.has(p.id));

  function alternarSeleccion(id: string) {
    setSeleccionados((actual) => {
      const siguiente = new Set(actual);
      if (siguiente.has(id)) siguiente.delete(id);
      else siguiente.add(id);
      return siguiente;
    });
  }

  function alternarSeleccionFiltrados() {
    setSeleccionados((actual) => {
      const siguiente = new Set(actual);
      if (todosFiltradosSeleccionados) filtrados.forEach((p) => siguiente.delete(p.id));
      else filtrados.forEach((p) => siguiente.add(p.id));
      return siguiente;
    });
  }

  async function aplicarClasificacionMasiva() {
    setMsg(null);
    const ids = Array.from(seleccionados);
    const categoriaSeleccionada = categoriasActivas.find((c) => c.id === categoriaMasiva);
    const subcategoriaSeleccionada = subcategoriasActivas.find(
      (s) => s.id === subcategoriaMasiva && s.categoria_id === categoriaMasiva
    );
    if (!ids.length) {
      setMsg({ tipo: "error", texto: "Selecciona al menos un producto." });
      return;
    }
    if (!categoriaSeleccionada) {
      setMsg({ tipo: "error", texto: "Selecciona la categoría que deseas asignar." });
      return;
    }
    if (subcategoriaMasiva && !subcategoriaSeleccionada) {
      setMsg({ tipo: "error", texto: "La subcategoría no pertenece a la categoría seleccionada." });
      return;
    }
    const destino = `${categoriaSeleccionada.nombre}${subcategoriaSeleccionada ? ` / ${subcategoriaSeleccionada.nombre}` : " / Sin subcategoría"}`;
    if (!window.confirm(`Se asignará “${destino}” a ${ids.length} producto(s).\n\n¿Continuar?`)) return;

    setAplicandoMasivo(true);
    let actualizados = 0;
    for (let i = 0; i < ids.length; i += 100) {
      const lote = ids.slice(i, i + 100);
      const { error } = await supabase.from("productos").update({
        categoria_id: categoriaSeleccionada.id,
        subcategoria_id: subcategoriaSeleccionada?.id || null,
      }).in("id", lote);
      if (error) {
        setAplicandoMasivo(false);
        setMsg({
          tipo: "error",
          texto: actualizados
            ? `Se actualizaron ${actualizados} productos antes del error: ${error.message}`
            : error.message,
        });
        await cargar();
        return;
      }
      actualizados += lote.length;
    }
    setAplicandoMasivo(false);
    setSeleccionados(new Set());
    setCategoriaMasiva("");
    setSubcategoriaMasiva("");
    setEditando(null);
    setMsg({ tipo: "ok", texto: `${actualizados} producto(s) clasificados correctamente.` });
    await cargar();
  }

  async function crear(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    const categoriaSeleccionada = categoriasCatalogo.find((c) => c.id === nuevo.categoria_id && c.activo);
    const subcategoriaSeleccionada = subcategoriasCatalogo.find(
      (s) => s.id === nuevo.subcategoria_id && s.categoria_id === nuevo.categoria_id && s.activo
    );
    if (!categoriaSeleccionada) {
      setMsg({ tipo: "error", texto: "La categoría es obligatoria." });
      return;
    }
    if (nuevo.subcategoria_id && !subcategoriaSeleccionada) {
      setMsg({ tipo: "error", texto: "La subcategoría no pertenece a la categoría seleccionada." });
      return;
    }
    const { error } = await supabase.from("productos").insert({
      sku: nuevo.sku.trim(),
      nombre: nuevo.nombre.trim(),
      categoria_id: categoriaSeleccionada.id,
      categoria: categoriaSeleccionada.nombre,
      subcategoria_id: subcategoriaSeleccionada?.id || null,
      subcategoria: subcategoriaSeleccionada?.nombre || null,
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
    const categoriaId = p.categoria_id || categoriasCatalogo.find(
      (c) => c.nombre.toLowerCase() === String(p.categoria || "").toLowerCase()
    )?.id || null;
    setEditando(p.id);
    setEdit({
      sku: p.sku,
      nombre: p.nombre,
      categoria: p.categoria,
      categoria_id: categoriaId,
      subcategoria: p.subcategoria,
      subcategoria_id: p.subcategoria_id,
      talla: p.talla,
      color: p.color,
      stock_minimo: p.stock_minimo,
      precio: p.precio,
    });
  }

  async function guardar(id: string) {
    setMsg(null);
    const categoriaSeleccionada = categoriasCatalogo.find((c) => c.id === edit.categoria_id);
    const subcategoriaSeleccionada = subcategoriasCatalogo.find(
      (s) => s.id === edit.subcategoria_id && s.categoria_id === edit.categoria_id
    );
    if (!categoriaSeleccionada) {
      setMsg({ tipo: "error", texto: "La categoría es obligatoria." });
      return;
    }
    if (edit.subcategoria_id && !subcategoriaSeleccionada) {
      setMsg({ tipo: "error", texto: "La subcategoría no pertenece a la categoría seleccionada." });
      return;
    }
    const sku = (edit.sku ?? "").trim().toUpperCase();
    if (!sku) { setMsg({ tipo: "error", texto: "El SKU es obligatorio." }); return; }
    const skuAnterior = productos.find((x) => x.id === id)?.sku ?? "";
    if (sku !== skuAnterior && !window.confirm(
      `Vas a cambiar el SKU de ${skuAnterior} a ${sku}.

El histórico de movimientos, transferencias y ventas seguirá apuntando al mismo producto, pero las etiquetas físicas y los archivos exportados con el código anterior quedarán desactualizados.

¿Continuar?`
    )) return;
    const { error } = await supabase.from("productos").update({
      sku,
      nombre: edit.nombre,
      categoria_id: categoriaSeleccionada.id,
      categoria: categoriaSeleccionada.nombre,
      subcategoria_id: subcategoriaSeleccionada?.id || null,
      subcategoria: subcategoriaSeleccionada?.nombre || null,
      talla: edit.talla || null,
      color: edit.color || null,
      stock_minimo: Number(edit.stock_minimo) || 0,
      precio: edit.precio === null || edit.precio === undefined || (edit.precio as any) === "" ? null : Number(edit.precio),
    }).eq("id", id).select("id").single();
    if (error) {
      setMsg({ tipo: "error", texto: error.message.includes("duplicate") ? "Ese SKU ya pertenece a otro producto." : error.message });
      return;
    }
    setEditando(null);
    setMsg({ tipo: "ok", texto: "Producto actualizado." });
    await cargar();
  }

  async function crearCategoria(e: React.FormEvent) {
    e.preventDefault();
    const nombre = nuevaCategoria.trim();
    if (!nombre) return;
    setGuardandoCatalogo(true);
    setMsg(null);
    const { error } = await supabase.from("categorias_productos").insert({ nombre });
    setGuardandoCatalogo(false);
    if (error) {
      setMsg({ tipo: "error", texto: error.code === "23505" ? "Esa categoría ya existe." : error.message });
      return;
    }
    setNuevaCategoria("");
    setMsg({ tipo: "ok", texto: "Categoría creada correctamente." });
    await cargar();
  }

  async function crearSubcategoria(categoriaId: string) {
    const nombre = String(nuevasSubcategorias[categoriaId] || "").trim();
    if (!nombre) return;
    setGuardandoCatalogo(true);
    setMsg(null);
    const { error } = await supabase.from("subcategorias_productos").insert({
      categoria_id: categoriaId,
      nombre,
    });
    setGuardandoCatalogo(false);
    if (error) {
      setMsg({ tipo: "error", texto: error.code === "23505" ? "Esa subcategoría ya existe dentro de la categoría." : error.message });
      return;
    }
    setNuevasSubcategorias((actual) => ({ ...actual, [categoriaId]: "" }));
    setMsg({ tipo: "ok", texto: "Subcategoría creada correctamente." });
    await cargar();
  }

  async function cambiarEstadoCategoria(categoriaItem: CategoriaProducto) {
    setMsg(null);
    const { error } = await supabase
      .from("categorias_productos")
      .update({ activo: !categoriaItem.activo, updated_at: new Date().toISOString() })
      .eq("id", categoriaItem.id);
    if (error) {
      setMsg({ tipo: "error", texto: error.message });
      return;
    }
    await cargar();
  }

  async function cambiarEstadoSubcategoria(subcategoriaItem: SubcategoriaProducto) {
    setMsg(null);
    const { error } = await supabase
      .from("subcategorias_productos")
      .update({ activo: !subcategoriaItem.activo, updated_at: new Date().toISOString() })
      .eq("id", subcategoriaItem.id);
    if (error) {
      setMsg({ tipo: "error", texto: error.message });
      return;
    }
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
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <button className="secondary" onClick={() => setMostrarCategorias(!mostrarCategorias)}>
            {mostrarCategorias ? "Cerrar categorías" : "Categorías y subcategorías"}
          </button>
          <button className="secondary" onClick={() => { setMostrarImportacion(!mostrarImportacion); setMostrarForm(false); }}>
            {mostrarImportacion ? "Cerrar importación" : "Importar catálogo"}
          </button>
          <button onClick={() => { setMostrarForm(!mostrarForm); setMostrarImportacion(false); }}>
            {mostrarForm ? "Cancelar" : "+ Nuevo producto"}
          </button>
        </div>
      </div>

      {mostrarImportacion && (
        <ImportarCatalogo
          productos={productos.map((p) => ({ sku: p.sku, nombre: p.nombre }))}
          alCompletar={cargar}
          alCerrar={() => setMostrarImportacion(false)}
        />
      )}

      {mostrarCategorias && (
        <div className="card">
          <div className="header-row">
            <div>
              <h3 style={{ margin: 0 }}>Catálogo de categorías</h3>
              <p style={{ margin: "5px 0 0", color: "#6b7280", fontSize: 13 }}>
                Crea categorías principales y sus subcategorías. Se desactivan en lugar de eliminarse para conservar el historial.
              </p>
            </div>
          </div>

          <form onSubmit={crearCategoria} style={{ display: "flex", gap: 8, margin: "14px 0", flexWrap: "wrap" }}>
            <input
              value={nuevaCategoria}
              onChange={(e) => setNuevaCategoria(e.target.value)}
              placeholder="Nueva categoría, por ejemplo: Camisetas"
              style={{ flex: "1 1 260px" }}
            />
            <button type="submit" disabled={guardandoCatalogo || !nuevaCategoria.trim()}>
              + Crear categoría
            </button>
          </form>

          <div style={{ display: "grid", gap: 10 }}>
            {categoriasCatalogo.map((c) => {
              const subs = subcategoriasCatalogo.filter((s) => s.categoria_id === c.id);
              return (
                <div key={c.id} style={{ border: "1px solid #dbe3ee", borderRadius: 9, padding: 12, opacity: c.activo ? 1 : 0.65 }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                    <strong style={{ color: "#1f3864", flex: 1 }}>{c.nombre}</strong>
                    <span className="conteo">{subs.length} subcategoría(s)</span>
                    <button type="button" className="chip-limpiar" onClick={() => cambiarEstadoCategoria(c)} style={{ padding: "5px 10px" }}>
                      {c.activo ? "Desactivar" : "Activar"}
                    </button>
                  </div>

                  <div style={{ display: "flex", gap: 6, flexWrap: "wrap", margin: "10px 0" }}>
                    {subs.map((s) => (
                      <span key={s.id} style={{ display: "inline-flex", alignItems: "center", gap: 6, background: s.activo ? "#eef5ff" : "#f3f4f6", border: "1px solid #cbd5e1", borderRadius: 18, padding: "4px 8px 4px 11px", fontSize: 12, opacity: s.activo ? 1 : 0.6 }}>
                        {s.nombre}
                        <button type="button" className="chip-limpiar" onClick={() => cambiarEstadoSubcategoria(s)} style={{ padding: "1px 6px", fontSize: 10 }}>
                          {s.activo ? "Desactivar" : "Activar"}
                        </button>
                      </span>
                    ))}
                    {!subs.length && <span style={{ color: "#9ca3af", fontSize: 12 }}>Sin subcategorías.</span>}
                  </div>

                  <div style={{ display: "flex", gap: 7, flexWrap: "wrap" }}>
                    <input
                      value={nuevasSubcategorias[c.id] || ""}
                      onChange={(e) => setNuevasSubcategorias((actual) => ({ ...actual, [c.id]: e.target.value }))}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") {
                          e.preventDefault();
                          crearSubcategoria(c.id);
                        }
                      }}
                      disabled={!c.activo}
                      placeholder="Nueva subcategoría"
                      style={{ flex: "1 1 220px" }}
                    />
                    <button type="button" className="secondary" disabled={guardandoCatalogo || !c.activo || !String(nuevasSubcategorias[c.id] || "").trim()} onClick={() => crearSubcategoria(c.id)}>
                      + Agregar subcategoría
                    </button>
                  </div>
                </div>
              );
            })}
            {!categoriasCatalogo.length && <div className="vacio">Aún no existen categorías.</div>}
          </div>
        </div>
      )}

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
                <select value={nuevo.categoria_id} onChange={(e) => setNuevo({ ...nuevo, categoria_id: e.target.value, subcategoria_id: "" })} required style={{ width: "100%" }}>
                  <option value="">Seleccionar categoría...</option>
                  {categoriasActivas.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
                </select></div>
              <div className="field"><label>Subcategoría (opcional)</label>
                <select value={nuevo.subcategoria_id} onChange={(e) => setNuevo({ ...nuevo, subcategoria_id: e.target.value })} disabled={!nuevo.categoria_id} style={{ width: "100%" }}>
                  <option value="">Sin subcategoría</option>
                  {subcategoriasActivas.filter((s) => s.categoria_id === nuevo.categoria_id).map((s) => <option key={s.id} value={s.id}>{s.nombre}</option>)}
                </select></div>
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
            <input placeholder="Nombre, SKU, categoría, subcategoría, talla..." value={busqueda} onChange={(e) => setBusqueda(e.target.value)} />
          </div>
          <div className="field">
            <label>Categoría</label>
            <select value={categoria} onChange={(e) => { setCategoria(e.target.value); setSubcategoria(""); }}>
              <option value="">Todas</option>
              {categoriasCatalogo.map((c) => <option key={c.id} value={c.id}>{c.nombre}{c.activo ? "" : " (inactiva)"}</option>)}
            </select>
          </div>
          <div className="field">
            <label>Subcategoría</label>
            <select value={subcategoria} onChange={(e) => setSubcategoria(e.target.value)}>
              <option value="">Todas</option>
              {subcategoriasFiltro.map((s) => <option key={s.id} value={s.id}>{s.nombre}{s.activo ? "" : " (inactiva)"}</option>)}
            </select>
          </div>
          <div className="field">
            <label style={{ fontWeight: 500 }}>
              <input type="checkbox" checked={verInactivos} onChange={(e) => setVerInactivos(e.target.checked)} style={{ marginRight: 6 }} />
              Ver inactivos
            </label>
          </div>
          <button className="chip-limpiar" onClick={() => { setBusqueda(""); setCategoria(""); setSubcategoria(""); setVerInactivos(false); }}>Limpiar</button>
        </div>

        <div className="header-row">
          <span className="conteo">{filtrados.length} producto(s)</span>
          <button className="secondary" disabled={!filtrados.length}
            onClick={() => exportarCSV("productos_boman", filtrados.map((p) => ({
              SKU: p.sku, Nombre: p.nombre, Categoria: p.categoria, Subcategoria: p.subcategoria, Talla: p.talla,
              Color: p.color, StockMinimo: p.stock_minimo, Precio: p.precio, Activo: p.activo ? "Sí" : "No",
            })))}>
            Exportar a Excel
          </button>
        </div>

        {seleccionados.size > 0 && (
          <div style={{ background: "#eef5ff", border: "1.5px solid #93b4d8", borderRadius: 9, padding: 12, marginBottom: 14 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              <strong style={{ color: "#1f3864", marginRight: 4 }}>{seleccionados.size} seleccionado(s)</strong>
              <select
                value={categoriaMasiva}
                onChange={(e) => { setCategoriaMasiva(e.target.value); setSubcategoriaMasiva(""); }}
                style={{ minWidth: 190 }}
              >
                <option value="">Asignar categoría...</option>
                {categoriasActivas.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
              </select>
              <select
                value={subcategoriaMasiva}
                onChange={(e) => setSubcategoriaMasiva(e.target.value)}
                disabled={!categoriaMasiva}
                style={{ minWidth: 190 }}
              >
                <option value="">Sin subcategoría</option>
                {subcategoriasActivas
                  .filter((s) => s.categoria_id === categoriaMasiva)
                  .map((s) => <option key={s.id} value={s.id}>{s.nombre}</option>)}
              </select>
              <button type="button" disabled={aplicandoMasivo || !categoriaMasiva} onClick={aplicarClasificacionMasiva}>
                {aplicandoMasivo ? "Aplicando..." : "Aplicar clasificación"}
              </button>
              <button type="button" className="chip-limpiar" disabled={aplicandoMasivo} onClick={() => setSeleccionados(new Set())}>
                Cancelar selección
              </button>
            </div>
            <div style={{ marginTop: 6, color: "#64748b", fontSize: 12 }}>
              La categoría anterior será reemplazada en todos los productos seleccionados.
            </div>
          </div>
        )}

        {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

        {cargando ? <div className="vacio">Cargando catálogo...</div> : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th style={{ width: 38, textAlign: "center" }}>
                    <input
                      type="checkbox"
                      checked={todosFiltradosSeleccionados}
                      onChange={alternarSeleccionFiltrados}
                      disabled={!filtrados.length || aplicandoMasivo}
                      title="Seleccionar todos los productos visibles"
                      aria-label="Seleccionar todos los productos visibles"
                    />
                  </th>
                  <th>SKU</th><th>Nombre</th><th>Categoría / subcategoría</th><th>Talla</th>
                  <th className="num">Mín.</th><th className="num">Precio</th><th>Acciones</th>
                </tr>
              </thead>
              <tbody>
                {filtrados.map((p) => (
                  editando === p.id ? (
                    <tr key={p.id}>
                      <td style={{ textAlign: "center" }}>
                        <input type="checkbox" checked={seleccionados.has(p.id)} onChange={() => alternarSeleccion(p.id)} disabled={aplicandoMasivo} aria-label={`Seleccionar ${p.nombre}`} />
                      </td>
                      <td><input value={edit.sku ?? ""} onChange={(e) => setEdit({ ...edit, sku: e.target.value })} style={{ width: 110 }} /></td>
                      <td><input value={edit.nombre ?? ""} onChange={(e) => setEdit({ ...edit, nombre: e.target.value })} style={{ width: "100%" }} /></td>
                      <td>
                        <div style={{ display: "grid", gap: 5, minWidth: 170 }}>
                          <select
                            value={edit.categoria_id ?? ""}
                            onChange={(e) => setEdit({ ...edit, categoria_id: e.target.value || null, subcategoria_id: null })}
                            required
                          >
                            <option value="">Seleccionar categoría...</option>
                            {categoriasCatalogo.map((c) => (
                              <option key={c.id} value={c.id} disabled={!c.activo && c.id !== edit.categoria_id}>
                                {c.nombre}{c.activo ? "" : " (inactiva)"}
                              </option>
                            ))}
                          </select>
                          <select
                            value={edit.subcategoria_id ?? ""}
                            onChange={(e) => setEdit({ ...edit, subcategoria_id: e.target.value || null })}
                            disabled={!edit.categoria_id}
                          >
                            <option value="">Sin subcategoría</option>
                            {subcategoriasCatalogo
                              .filter((s) => s.categoria_id === edit.categoria_id)
                              .map((s) => (
                                <option key={s.id} value={s.id} disabled={!s.activo && s.id !== edit.subcategoria_id}>
                                  {s.nombre}{s.activo ? "" : " (inactiva)"}
                                </option>
                              ))}
                          </select>
                        </div>
                      </td>
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
                      <td style={{ textAlign: "center" }}>
                        <input type="checkbox" checked={seleccionados.has(p.id)} onChange={() => alternarSeleccion(p.id)} disabled={aplicandoMasivo} aria-label={`Seleccionar ${p.nombre}`} />
                      </td>
                      <td>{p.sku}</td>
                      <td>{p.nombre}</td>
                      <td>
                        <div>{p.categoria ?? "-"}</div>
                        {p.subcategoria && <small style={{ color: "#6b7280" }}>{p.subcategoria}</small>}
                      </td>
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
                {!filtrados.length && <tr><td colSpan={8} className="vacio">Sin resultados.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
