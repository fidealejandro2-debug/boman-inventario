"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Fila = {
  producto_id: string;
  sku: string;
  producto: string;
  categoria: string | null;
  categoria_id: string;
  subcategoria: string | null;
  subcategoria_id: string | null;
  talla: string | null;
  color: string | null;
  stock_minimo: number;
  punto_reposicion: number;
  ubicacion: string | null;
  almacen_id: string;
  almacen: string;
  stock_fisico: number;
  stock_reservado: number;
  stock_disponible: number;
  transito_entrada: number;
  transito_salida: number;
  transito_incidencia: number;
  stock_cuarentena: number;
  sugerido_reponer: number;
  bajo_minimo: boolean;
};

export default function StockCliente() {
  const supabase = createClient();
  const [filas, setFilas] = useState<Fila[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [busqueda, setBusqueda] = useState("");
  const [categoria, setCategoria] = useState("");
  const [subcategoria, setSubcategoria] = useState("");
  const [almacen, setAlmacen] = useState("");
  const [soloAlerta, setSoloAlerta] = useState(false);
  const [ocultarCero, setOcultarCero] = useState(true);

  useEffect(() => {
    (async () => {
      const { data, error } = await supabase
        .from("vista_stock_operativo")
        .select("*")
        .order("producto");
      if (error) setError(error.message);
      else setFilas((data as Fila[]) ?? []);
      setCargando(false);
    })();
  }, []);

  const categorias = useMemo(() => {
    const mapa = new Map<string, string>();
    filas.forEach((f) => { if (f.categoria_id && f.categoria) mapa.set(f.categoria_id, f.categoria); });
    return Array.from(mapa, ([id, nombre]) => ({ id, nombre })).sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [filas]);
  const subcategorias = useMemo(() => {
    const mapa = new Map<string, { id: string; nombre: string; categoria_id: string }>();
    filas.forEach((f) => {
      if (f.subcategoria_id && f.subcategoria && (!categoria || f.categoria_id === categoria)) {
        mapa.set(f.subcategoria_id, { id: f.subcategoria_id, nombre: f.subcategoria, categoria_id: f.categoria_id });
      }
    });
    return Array.from(mapa.values()).sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [filas, categoria]);
  const almacenes = useMemo(
    () => Array.from(new Set(filas.map((f) => f.almacen))).sort(),
    [filas]
  );

  const filtradas = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return filas.filter((f) => {
      if (categoria && f.categoria_id !== categoria) return false;
      if (subcategoria && f.subcategoria_id !== subcategoria) return false;
      if (almacen && f.almacen !== almacen) return false;
      if (soloAlerta && !f.bajo_minimo) return false;
      if (ocultarCero && f.stock_fisico === 0 && f.transito_entrada === 0
        && f.transito_incidencia === 0 && f.stock_cuarentena === 0) return false;
      if (!q) return true;
      return (
        f.producto.toLowerCase().includes(q) ||
        f.sku.toLowerCase().includes(q) ||
        (f.categoria ?? "").toLowerCase().includes(q) ||
        (f.subcategoria ?? "").toLowerCase().includes(q) ||
        (f.talla ?? "").toLowerCase().includes(q) ||
        (f.color ?? "").toLowerCase().includes(q)
      );
    });
  }, [filas, busqueda, categoria, subcategoria, almacen, soloAlerta, ocultarCero]);

  const totalUnidades = filtradas.reduce((a, f) => a + f.stock_fisico, 0);
  const totalDisponible = filtradas.reduce((a, f) => a + f.stock_disponible, 0);
  const totalTransito = filtradas.reduce((a, f) => a + f.transito_entrada, 0);
  const totalIncidencia = filtradas.reduce((a, f) => a + f.transito_incidencia, 0);
  const totalCuarentena = filtradas.reduce((a, f) => a + f.stock_cuarentena, 0);
  const enAlerta = filtradas.filter((f) => f.bajo_minimo).length;
  const skusDistintos = new Set(filtradas.map((f) => f.producto_id)).size;

  function limpiar() {
    setBusqueda(""); setCategoria(""); setSubcategoria(""); setAlmacen("");
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
          <div className="label">Disponible</div>
          <div className="valor">{totalDisponible.toLocaleString("es-EC")}</div>
        </div>
        <div className="kpi">
          <div className="label">En tránsito</div>
          <div className="valor">{totalTransito.toLocaleString("es-EC")}</div>
          <small>{skusDistintos} SKU(s)</small>
        </div>
        <div className={`kpi ${totalIncidencia || totalCuarentena ? "alerta" : "ok"}`}>
          <div className="label">Bajo seguimiento</div>
          <div className="valor">{(totalIncidencia + totalCuarentena).toLocaleString("es-EC")}</div>
          <small>{totalIncidencia} no recibida(s) · {totalCuarentena} en cuarentena</small>
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
              placeholder="Nombre, SKU, categoría, subcategoría, talla o color..."
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
            />
          </div>
          <div className="field">
            <label>Categoría</label>
            <select value={categoria} onChange={(e) => { setCategoria(e.target.value); setSubcategoria(""); }}>
              <option value="">Todas</option>
              {categorias.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
          </div>
          <div className="field">
            <label>Subcategoría</label>
            <select value={subcategoria} onChange={(e) => setSubcategoria(e.target.value)}>
              <option value="">Todas</option>
              {subcategorias.map((s) => <option key={s.id} value={s.id}>{s.nombre}</option>)}
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
              SKU: f.sku, Producto: f.producto, Categoria: f.categoria, Subcategoria: f.subcategoria,
              Talla: f.talla, Color: f.color, Almacen: f.almacen,
              Ubicacion: f.ubicacion, Fisico: f.stock_fisico, Reservado: f.stock_reservado,
              Disponible: f.stock_disponible, TransitoEntrada: f.transito_entrada,
              TransitoSalida: f.transito_salida, TransitoIncidencia: f.transito_incidencia,
              Cuarentena: f.stock_cuarentena, StockMinimo: f.stock_minimo,
              PuntoReposicion: f.punto_reposicion, SugeridoReponer: f.sugerido_reponer,
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
                  <th>SKU</th><th>Producto</th><th>Categoría / subcategoría</th>
                  <th>Talla</th><th>Almacén / ubicación</th><th className="num">Físico</th>
                  <th className="num">Reserv.</th><th className="num">Disponible</th>
                  <th className="num">En tránsito</th><th className="num">No recibida</th>
                  <th className="num">Cuarentena</th><th>Estado</th>
                </tr>
              </thead>
              <tbody>
                {filtradas.map((f) => (
                  <tr key={`${f.producto_id}-${f.almacen_id}`} className={f.bajo_minimo && f.stock_fisico > 0 ? "fila-alerta" : ""}>
                    <td>{f.sku}</td>
                    <td>{f.producto}</td>
                    <td>
                      <div>{f.categoria ?? "-"}</div>
                      {f.subcategoria && <small style={{ color: "#6b7280" }}>{f.subcategoria}</small>}
                    </td>
                    <td>{f.talla ?? "-"}</td>
                    <td><div>{f.almacen}</div>{f.ubicacion && <small style={{ color: "#6b7280" }}>{f.ubicacion}</small>}</td>
                    <td className="num">{f.stock_fisico}</td>
                    <td className="num">{f.stock_reservado}</td>
                    <td className="num"><strong>{f.stock_disponible}</strong></td>
                    <td className="num">{f.transito_entrada > 0 ? `+${f.transito_entrada}` : "-"}</td>
                    <td className="num">{f.transito_incidencia || "-"}</td>
                    <td className="num">{f.stock_cuarentena || "-"}</td>
                    <td>
                      {f.transito_incidencia > 0 || f.stock_cuarentena > 0
                        ? <span className="badge bajo">Seguimiento</span>
                        : f.stock_fisico === 0 && f.transito_entrada === 0
                        ? <span className="badge cero">Sin stock</span>
                        : f.bajo_minimo
                          ? <span className="badge bajo">Reponer {f.sugerido_reponer || ""}</span>
                          : <span className="badge ok">OK</span>}
                    </td>
                  </tr>
                ))}
                {!filtradas.length && (
                  <tr><td colSpan={12} className="vacio">No hay resultados con esos filtros.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
