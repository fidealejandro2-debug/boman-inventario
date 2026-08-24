"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Fila = {
  producto_id: string;
  sku: string;
  producto: string;
  categoria: string | null;
  talla: string | null;
  color: string | null;
  stock_minimo: number;
  almacen_id: string;
  almacen: string;
  cantidad: number;
  bajo_minimo: boolean;
};

export default function StockCliente() {
  const supabase = createClient();
  const [filas, setFilas] = useState<Fila[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [busqueda, setBusqueda] = useState("");
  const [categoria, setCategoria] = useState("");
  const [almacen, setAlmacen] = useState("");
  const [soloAlerta, setSoloAlerta] = useState(false);
  const [ocultarCero, setOcultarCero] = useState(true);

  useEffect(() => {
    (async () => {
      const { data, error } = await supabase
        .from("vista_stock")
        .select("*")
        .order("producto");
      if (error) setError(error.message);
      else setFilas((data as Fila[]) ?? []);
      setCargando(false);
    })();
  }, []);

  const categorias = useMemo(
    () => Array.from(new Set(filas.map((f) => f.categoria).filter(Boolean))).sort() as string[],
    [filas]
  );
  const almacenes = useMemo(
    () => Array.from(new Set(filas.map((f) => f.almacen))).sort(),
    [filas]
  );

  const filtradas = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return filas.filter((f) => {
      if (categoria && f.categoria !== categoria) return false;
      if (almacen && f.almacen !== almacen) return false;
      if (soloAlerta && !f.bajo_minimo) return false;
      if (ocultarCero && f.cantidad === 0) return false;
      if (!q) return true;
      return (
        f.producto.toLowerCase().includes(q) ||
        f.sku.toLowerCase().includes(q) ||
        (f.categoria ?? "").toLowerCase().includes(q) ||
        (f.talla ?? "").toLowerCase().includes(q) ||
        (f.color ?? "").toLowerCase().includes(q)
      );
    });
  }, [filas, busqueda, categoria, almacen, soloAlerta, ocultarCero]);

  const totalUnidades = filtradas.reduce((a, f) => a + f.cantidad, 0);
  const enAlerta = filtradas.filter((f) => f.bajo_minimo).length;
  const skusDistintos = new Set(filtradas.map((f) => f.producto_id)).size;

  function limpiar() {
    setBusqueda(""); setCategoria(""); setAlmacen("");
    setSoloAlerta(false); setOcultarCero(true);
  }

  return (
    <>
      <h2 style={{ color: "#1f3864" }}>Stock</h2>

      <div className="kpis">
        <div className="kpi">
          <div className="label">Unidades</div>
          <div className="valor">{totalUnidades.toLocaleString("es-EC")}</div>
        </div>
        <div className="kpi">
          <div className="label">SKUs distintos</div>
          <div className="valor">{skusDistintos}</div>
        </div>
        <div className={`kpi ${enAlerta > 0 ? "alerta" : "ok"}`}>
          <div className="label">Bajo mínimo</div>
          <div className="valor">{enAlerta}</div>
        </div>
      </div>

      <div className="card">
        <div className="filtros">
          <div className="field buscador">
            <label>Buscar</label>
            <input
              placeholder="Nombre, SKU, categoría, talla o color..."
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
            />
          </div>
          <div className="field">
            <label>Categoría</label>
            <select value={categoria} onChange={(e) => setCategoria(e.target.value)}>
              <option value="">Todas</option>
              {categorias.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          </div>
          <div className="field">
            <label>Almacén</label>
            <select value={almacen} onChange={(e) => setAlmacen(e.target.value)}>
              <option value="">Todos</option>
              {almacenes.map((a) => <option key={a} value={a}>{a}</option>)}
            </select>
          </div>
          <div className="field">
            <label style={{ fontWeight: 500 }}>
              <input type="checkbox" checked={soloAlerta} onChange={(e) => setSoloAlerta(e.target.checked)} style={{ marginRight: 6 }} />
              Solo bajo mínimo
            </label>
            <label style={{ fontWeight: 500, marginTop: 4 }}>
              <input type="checkbox" checked={ocultarCero} onChange={(e) => setOcultarCero(e.target.checked)} style={{ marginRight: 6 }} />
              Ocultar sin stock
            </label>
          </div>
          <button className="chip-limpiar" onClick={limpiar}>Limpiar</button>
        </div>

        <div className="header-row">
          <span className="conteo">{filtradas.length} resultado(s)</span>
          <button
            className="secondary"
            onClick={() => exportarCSV("stock_boman", filtradas.map((f) => ({
              SKU: f.sku, Producto: f.producto, Categoria: f.categoria,
              Talla: f.talla, Color: f.color, Almacen: f.almacen,
              Cantidad: f.cantidad, StockMinimo: f.stock_minimo,
            })))}
            disabled={!filtradas.length}
          >
            Exportar a Excel
          </button>
        </div>

        {error && <div className="error">{error}</div>}
        {cargando ? (
          <div className="vacio">Cargando stock...</div>
        ) : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>SKU</th><th>Producto</th><th>Categoría</th>
                  <th>Talla</th><th>Almacén</th><th className="num">Cant.</th><th>Estado</th>
                </tr>
              </thead>
              <tbody>
                {filtradas.map((f) => (
                  <tr key={`${f.producto_id}-${f.almacen_id}`} className={f.bajo_minimo && f.cantidad > 0 ? "fila-alerta" : ""}>
                    <td>{f.sku}</td>
                    <td>{f.producto}</td>
                    <td>{f.categoria ?? "-"}</td>
                    <td>{f.talla ?? "-"}</td>
                    <td>{f.almacen}</td>
                    <td className="num">{f.cantidad}</td>
                    <td>
                      {f.cantidad === 0
                        ? <span className="badge cero">Sin stock</span>
                        : f.bajo_minimo
                          ? <span className="badge bajo">Bajo mínimo</span>
                          : <span className="badge ok">OK</span>}
                    </td>
                  </tr>
                ))}
                {!filtradas.length && (
                  <tr><td colSpan={7} className="vacio">No hay resultados con esos filtros.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
