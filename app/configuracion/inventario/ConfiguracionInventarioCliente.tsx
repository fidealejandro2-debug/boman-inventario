"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Fila = {
  producto_id: string; almacen_id: string; sku: string; producto: string;
  categoria: string | null; subcategoria: string | null; talla: string | null;
  almacen: string; ubicacion: string | null; stock_minimo: number; stock_maximo: number | null;
  stock_seguridad: number; punto_reposicion: number; stock_fisico: number;
  stock_disponible: number; transito_entrada: number; sugerido_reponer: number;
};
type Cambio = {
  stock_minimo: number; stock_maximo: number | null; stock_seguridad: number;
  punto_reposicion: number; ubicacion: string; activo: boolean;
};

const clave = (f: Pick<Fila, "producto_id" | "almacen_id">) => `${f.producto_id}:${f.almacen_id}`;

export default function ConfiguracionInventarioCliente() {
  const supabase = createClient();
  const [filas, setFilas] = useState<Fila[]>([]);
  const [cambios, setCambios] = useState<Record<string, Cambio>>({});
  const [busqueda, setBusqueda] = useState("");
  const [almacen, setAlmacen] = useState("");
  const [categoria, setCategoria] = useState("");
  const [soloSugeridos, setSoloSugeridos] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  async function cargar() {
    setCargando(true); setMsg(null);
    const todas: Fila[] = [];
    for (let desde = 0; ; desde += 1000) {
      const { data, error } = await supabase.from("vista_stock_operativo").select("*").order("almacen").order("producto").range(desde, desde + 999);
      if (error) { setMsg({ tipo: "error", texto: error.message }); break; }
      const pagina = (data ?? []) as Fila[]; todas.push(...pagina);
      if (pagina.length < 1000) break;
    }
    setFilas(todas); setCambios({}); setCargando(false);
  }
  useEffect(() => { cargar(); }, []);

  const almacenes = useMemo(() => Array.from(new Set(filas.map((f) => f.almacen))).sort(), [filas]);
  const categorias = useMemo(() => Array.from(new Set(filas.map((f) => f.categoria ?? "Sin categoría"))).sort(), [filas]);
  const filtradas = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return filas.filter((f) =>
      (!q || f.sku.toLowerCase().includes(q) || f.producto.toLowerCase().includes(q) || (f.talla ?? "").toLowerCase().includes(q) || (f.ubicacion ?? "").toLowerCase().includes(q)) &&
      (!almacen || f.almacen === almacen) && (!categoria || (f.categoria ?? "Sin categoría") === categoria) &&
      (!soloSugeridos || f.sugerido_reponer > 0)
    );
  }, [filas, busqueda, almacen, categoria, soloSugeridos]);

  function valor(fila: Fila): Cambio {
    return cambios[clave(fila)] ?? {
      stock_minimo: fila.stock_minimo, stock_maximo: fila.stock_maximo,
      stock_seguridad: fila.stock_seguridad, punto_reposicion: fila.punto_reposicion,
      ubicacion: fila.ubicacion ?? "", activo: true,
    };
  }
  function cambiar(fila: Fila, cambio: Partial<Cambio>) {
    setCambios({ ...cambios, [clave(fila)]: { ...valor(fila), ...cambio } });
  }

  function aplicarMasivo() {
    const minimo = Number(window.prompt("Stock mínimo para los resultados visibles:", "0"));
    if (!Number.isInteger(minimo) || minimo < 0) return;
    const punto = Number(window.prompt("Punto de reposición:", String(minimo)));
    if (!Number.isInteger(punto) || punto < 0) return;
    const siguiente = { ...cambios };
    filtradas.forEach((f) => { siguiente[clave(f)] = { ...valor(f), stock_minimo: minimo, punto_reposicion: punto }; });
    setCambios(siguiente);
  }

  async function guardar() {
    const entradas = Object.entries(cambios).map(([k, c]) => {
      const [producto_id, almacen_id] = k.split(":");
      return { producto_id, almacen_id, ...c, ubicacion: c.ubicacion || null };
    });
    if (!entradas.length) return;
    if (entradas.some((x) => x.stock_minimo < 0 || x.stock_seguridad < 0 || x.punto_reposicion < 0 || (x.stock_maximo != null && x.stock_maximo < x.stock_minimo))) {
      setMsg({ tipo: "error", texto: "Revisa mínimos, máximos y puntos de reposición." }); return;
    }
    setGuardando(true); setMsg(null);
    const { data, error } = await supabase.rpc("guardar_config_producto_almacen", { p_items: entradas });
    setGuardando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: `${data ?? entradas.length} configuraciones actualizadas.` }); await cargar();
  }

  return <>
    <div className="header-row"><div><h2 style={{ color: "#1f3864", margin: 0 }}>Políticas por producto y almacén</h2><p className="conteo">Mínimos, máximos, seguridad, reposición y ubicación física.</p></div><div><button className="secondary" onClick={aplicarMasivo} disabled={!filtradas.length}>Aplicar mínimo masivo</button> <button onClick={guardar} disabled={guardando || !Object.keys(cambios).length}>{guardando ? "Guardando..." : `Guardar cambios (${Object.keys(cambios).length})`}</button></div></div>
    {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}
    <div className="card"><div className="filtros"><div className="field buscador"><label>Buscar</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="SKU, producto, talla o ubicación..." /></div><div className="field"><label>Almacén</label><select value={almacen} onChange={(e) => setAlmacen(e.target.value)}><option value="">Todos</option>{almacenes.map((a) => <option key={a}>{a}</option>)}</select></div><div className="field"><label>Categoría</label><select value={categoria} onChange={(e) => setCategoria(e.target.value)}><option value="">Todas</option>{categorias.map((c) => <option key={c}>{c}</option>)}</select></div><label className="opcion-filtro"><input type="checkbox" checked={soloSugeridos} onChange={(e) => setSoloSugeridos(e.target.checked)} /> Solo requieren reposición</label><button className="secondary" disabled={!filtradas.length} onClick={() => exportarCSV("politicas_inventario", filtradas.map((f) => ({ Almacen: f.almacen, SKU: f.sku, Producto: f.producto, Talla: f.talla, Ubicacion: valor(f).ubicacion, Fisico: f.stock_fisico, Disponible: f.stock_disponible, Transito: f.transito_entrada, Minimo: valor(f).stock_minimo, Maximo: valor(f).stock_maximo, Seguridad: valor(f).stock_seguridad, PuntoReposicion: valor(f).punto_reposicion, Sugerido: f.sugerido_reponer })))}>Exportar</button></div>
      <div className="header-row"><span className="conteo">{filtradas.length} configuraciones · mostrando máximo 600 en pantalla</span>{cargando && <span>Cargando...</span>}</div>
      <div className="tabla-scroll"><table><thead><tr><th>Almacén / ubicación</th><th>Producto</th><th className="num">Físico</th><th className="num">Disponible</th><th className="num">En tránsito</th><th className="num">Mín.</th><th className="num">Máx.</th><th className="num">Seg.</th><th className="num">P. reposición</th><th className="num">Sugerido</th></tr></thead><tbody>{filtradas.slice(0, 600).map((f) => { const v = valor(f); return <tr key={clave(f)} className={f.sugerido_reponer > 0 ? "fila-alerta" : ""}><td><strong>{f.almacen}</strong><input value={v.ubicacion} onChange={(e) => cambiar(f, { ubicacion: e.target.value })} placeholder="Pasillo / estante" style={{ display: "block", width: 130, marginTop: 4 }} /></td><td><strong>{f.sku}</strong><div>{f.producto} {f.talla ?? ""}</div><small>{f.categoria}{f.subcategoria ? ` / ${f.subcategoria}` : ""}</small></td><td className="num">{f.stock_fisico}</td><td className="num">{f.stock_disponible}</td><td className="num">{f.transito_entrada}</td><td><input type="number" min={0} value={v.stock_minimo} onChange={(e) => cambiar(f, { stock_minimo: Number(e.target.value) || 0 })} /></td><td><input type="number" min={0} value={v.stock_maximo ?? ""} onChange={(e) => cambiar(f, { stock_maximo: e.target.value === "" ? null : Number(e.target.value) })} /></td><td><input type="number" min={0} value={v.stock_seguridad} onChange={(e) => cambiar(f, { stock_seguridad: Number(e.target.value) || 0 })} /></td><td><input type="number" min={0} value={v.punto_reposicion} onChange={(e) => cambiar(f, { punto_reposicion: Number(e.target.value) || 0 })} /></td><td className="num"><strong>{f.sugerido_reponer}</strong></td></tr>; })}{!filtradas.length && !cargando && <tr><td colSpan={10} className="vacio">Sin resultados.</td></tr>}</tbody></table></div>
    </div>
  </>;
}
