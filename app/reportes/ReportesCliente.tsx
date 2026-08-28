"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fecha, ETIQUETA_TIPO } from "@/lib/utils";

type Fila = {
  producto_id: string; sku: string; producto: string; categoria: string | null;
  categoria_id: string; subcategoria: string | null; subcategoria_id: string | null;
  talla: string | null; stock_minimo: number; precio: number | null;
  almacen_id: string; almacen: string; almacen_tipo: string;
  cantidad: number; bajo_minimo: boolean;
};
type Mov = {
  id: string; tipo: string; cantidad: number; nota: string | null; created_at: string;
  anulado: boolean; motivo_anulacion: string | null;
  productos: { nombre: string; sku: string } | null;
  almacenes: { nombre: string } | null;
  almacen_destino: { nombre: string } | null;
  perfiles: { nombre_completo: string } | null;
};

type Tab = "almacen" | "categoria" | "bajo" | "matriz" | "kardex";
type Empresa = { id: string; razon_social: string };

export default function ReportesCliente() {
  const supabase = createClient();
  const [filas, setFilas] = useState<Fila[]>([]);
  const [kardex, setKardex] = useState<Mov[]>([]);
  const [cargandoKardex, setCargandoKardex] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("almacen");
  const [kardexProd, setKardexProd] = useState("");
  const [buscaKardex, setBuscaKardex] = useState("");
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [kardexEmpresa, setKardexEmpresa] = useState("");

  useEffect(() => {
    (async () => {
      const s = await supabase.from("vista_stock").select("*");
      if (s.error) setError(s.error.message);
      if (s.data) setFilas(s.data as Fila[]);
      setCargando(false);
    })();
  }, []);

  useEffect(() => {
    (async () => {
      const e = await supabase.from("empresas").select("id, razon_social").eq("activo", true).order("razon_social");
      if (e.data) setEmpresas(e.data as Empresa[]);
    })();
  }, []);

  useEffect(() => {
    if (!kardexProd) {
      setKardex([]);
      return;
    }

    let cancelado = false;
    (async () => {
      setCargandoKardex(true);
      setError(null);
      const acumulado: Mov[] = [];
      const tamanoPagina = 1000;
      let desde = 0;

      while (!cancelado) {
        let query = supabase.from("movimientos")
          .select("id, tipo, cantidad, nota, created_at, anulado, motivo_anulacion, productos(nombre, sku), almacenes!movimientos_entidad_id_fkey(nombre), almacen_destino:almacenes!movimientos_entidad_destino_id_fkey(nombre), perfiles!movimientos_usuario_id_fkey(nombre_completo)")
          .eq("producto_id", kardexProd);
        if (kardexEmpresa) query = query.eq("empresa_id", kardexEmpresa);
        const { data, error: errorKardex } = await query
          .order("created_at", { ascending: false })
          .range(desde, desde + tamanoPagina - 1);

        if (errorKardex) {
          if (!cancelado) setError(errorKardex.message);
          break;
        }

        const pagina = (data as unknown as Mov[]) ?? [];
        acumulado.push(...pagina);
        if (pagina.length < tamanoPagina) break;
        desde += tamanoPagina;
      }

      if (!cancelado) {
        setKardex(acumulado);
        setCargandoKardex(false);
      }
    })();

    return () => { cancelado = true; };
  }, [kardexProd, kardexEmpresa]);

  // ---- Agregados ----
  const porAlmacen = useMemo(() => {
    const map = new Map<string, { almacen: string; tipo: string; unidades: number; skus: Set<string>; alerta: number; valor: number }>();
    filas.forEach((f) => {
      const k = f.almacen;
      if (!map.has(k)) map.set(k, { almacen: k, tipo: f.almacen_tipo, unidades: 0, skus: new Set(), alerta: 0, valor: 0 });
      const o = map.get(k)!;
      o.unidades += f.cantidad;
      if (f.cantidad > 0) o.skus.add(f.producto_id);
      if (f.bajo_minimo && f.cantidad > 0) o.alerta++;
      o.valor += (f.precio ?? 0) * f.cantidad;
    });
    return Array.from(map.values()).sort((a, b) => b.unidades - a.unidades);
  }, [filas]);

  const porCategoria = useMemo(() => {
    const map = new Map<string, { categoria: string; subcategoria: string; unidades: number; skus: Set<string>; valor: number }>();
    filas.forEach((f) => {
      const categoria = f.categoria ?? "Sin categoría";
      const subcategoria = f.subcategoria ?? "Sin subcategoría";
      const k = `${f.categoria_id || categoria}\u241f${f.subcategoria_id || subcategoria}`;
      if (!map.has(k)) map.set(k, { categoria, subcategoria, unidades: 0, skus: new Set(), valor: 0 });
      const o = map.get(k)!;
      o.unidades += f.cantidad;
      if (f.cantidad > 0) o.skus.add(f.producto_id);
      o.valor += (f.precio ?? 0) * f.cantidad;
    });
    return Array.from(map.values()).sort((a, b) =>
      a.categoria.localeCompare(b.categoria) || a.subcategoria.localeCompare(b.subcategoria)
    );
  }, [filas]);

  const bajoMinimo = useMemo(
    () => filas.filter((f) => f.bajo_minimo).sort((a, b) => a.cantidad - b.cantidad),
    [filas]
  );

  // Matriz producto × almacén
  const matriz = useMemo(() => {
    const almacenes = Array.from(new Set(filas.map((f) => f.almacen))).sort();
    const map = new Map<string, any>();
    filas.forEach((f) => {
      if (!map.has(f.producto_id)) {
        map.set(f.producto_id, { sku: f.sku, producto: f.producto, categoria: f.categoria, subcategoria: f.subcategoria, talla: f.talla, total: 0 });
        almacenes.forEach((a) => (map.get(f.producto_id)[a] = 0));
      }
      const o = map.get(f.producto_id);
      o[f.almacen] = (o[f.almacen] ?? 0) + f.cantidad;
      o.total += f.cantidad;
    });
    const datos = Array.from(map.values()).filter((r) => r.total > 0).sort((a, b) => b.total - a.total);
    return { almacenes, datos };
  }, [filas]);

  const productosUnicos = useMemo(() => {
    const m = new Map<string, { id: string; sku: string; nombre: string; categoria: string | null; subcategoria: string | null }>();
    filas.forEach((f) => m.set(f.producto_id, {
      id: f.producto_id, sku: f.sku, nombre: f.producto,
      categoria: f.categoria, subcategoria: f.subcategoria,
    }));
    return Array.from(m.values()).sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [filas]);

  const totalUnidades = filas.reduce((a, f) => a + f.cantidad, 0);
  const valorTotal = filas.reduce((a, f) => a + (f.precio ?? 0) * f.cantidad, 0);

  const money = (n: number) => `$${n.toLocaleString("es-EC", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  if (cargando) return <><h2 style={{ color: "#1f3864" }}>Reportes</h2><div className="card"><div className="vacio">Cargando datos...</div></div></>;

  return (
    <>
      <h2 style={{ color: "#1f3864" }}>Reportes</h2>
      {error && <div className="error">No se pudieron cargar los datos: {error}</div>}

      <div className="kpis">
        <div className="kpi"><div className="label">Unidades totales</div><div className="valor">{totalUnidades.toLocaleString("es-EC")}</div></div>
        <div className="kpi"><div className="label">SKUs con stock</div><div className="valor">{new Set(filas.filter(f => f.cantidad > 0).map(f => f.producto_id)).size}</div></div>
        <div className={`kpi ${bajoMinimo.length ? "alerta" : "ok"}`}><div className="label">Alertas de stock</div><div className="valor">{bajoMinimo.length}</div></div>
        <div className="kpi"><div className="label">Valor inventario</div><div className="valor" style={{ fontSize: 22 }}>{money(valorTotal)}</div></div>
      </div>

      <div className="tabs">
        {([["almacen", "Por almacén"], ["categoria", "Por categoría / subcategoría"], ["bajo", "Stock bajo"], ["matriz", "Matriz por tienda"], ["kardex", "Kardex de producto"]] as [Tab, string][])
          .map(([k, label]) => (
            <div key={k} className={`tab ${tab === k ? "activo" : ""}`} onClick={() => setTab(k)}>{label}</div>
          ))}
      </div>

      {tab === "almacen" && (
        <div className="card">
          <div className="header-row">
            <h3>Stock por almacén</h3>
            <button className="secondary" onClick={() => exportarCSV("reporte_por_almacen", porAlmacen.map((r) => ({
              Almacen: r.almacen, Tipo: r.tipo, Unidades: r.unidades, SKUs: r.skus.size, Alertas: r.alerta, Valor: r.valor.toFixed(2),
            })))}>Exportar a Excel</button>
          </div>
          <table>
            <thead><tr><th>Almacén</th><th>Tipo</th><th className="num">Unidades</th><th className="num">SKUs</th><th className="num">Alertas</th><th className="num">Valor</th></tr></thead>
            <tbody>
              {porAlmacen.map((r) => (
                <tr key={r.almacen}>
                  <td><strong>{r.almacen}</strong></td>
                  <td>{r.tipo === "bodega" ? "Bodega" : "Tienda"}</td>
                  <td className="num">{r.unidades.toLocaleString("es-EC")}</td>
                  <td className="num">{r.skus.size}</td>
                  <td className="num">{r.alerta > 0 ? <span className="badge bajo">{r.alerta}</span> : "0"}</td>
                  <td className="num">{money(r.valor)}</td>
                </tr>
              ))}
              {!porAlmacen.length && <tr><td colSpan={6} className="vacio">Sin datos de stock.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {tab === "categoria" && (
        <div className="card">
          <div className="header-row">
            <h3>Stock por categoría y subcategoría</h3>
            <button className="secondary" onClick={() => exportarCSV("reporte_por_categoria", porCategoria.map((r) => ({
              Categoria: r.categoria, Subcategoria: r.subcategoria, Unidades: r.unidades, SKUs: r.skus.size, Valor: r.valor.toFixed(2),
            })))}>Exportar a Excel</button>
          </div>
          <table>
            <thead><tr><th>Categoría</th><th>Subcategoría</th><th className="num">Unidades</th><th className="num">SKUs</th><th className="num">Valor</th></tr></thead>
            <tbody>
              {porCategoria.map((r) => (
                <tr key={`${r.categoria}-${r.subcategoria}`}>
                  <td><strong>{r.categoria}</strong></td>
                  <td>{r.subcategoria}</td>
                  <td className="num">{r.unidades.toLocaleString("es-EC")}</td>
                  <td className="num">{r.skus.size}</td>
                  <td className="num">{money(r.valor)}</td>
                </tr>
              ))}
              {!porCategoria.length && <tr><td colSpan={5} className="vacio">Sin datos.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {tab === "bajo" && (
        <div className="card">
          <div className="header-row">
            <h3>Productos bajo stock mínimo</h3>
            <button className="secondary" disabled={!bajoMinimo.length} onClick={() => exportarCSV("reporte_stock_bajo", bajoMinimo.map((f) => ({
              SKU: f.sku, Producto: f.producto, Categoria: f.categoria, Subcategoria: f.subcategoria, Talla: f.talla,
              Almacen: f.almacen, Cantidad: f.cantidad, StockMinimo: f.stock_minimo,
            })))}>Exportar a Excel</button>
          </div>
          <p style={{ fontSize: 13, color: "#6b7280", marginTop: 0 }}>
            Define el stock mínimo de cada producto desde la pestaña Productos. Por defecto es 0.
          </p>
          <div className="tabla-scroll">
            <table>
              <thead><tr><th>SKU</th><th>Producto</th><th>Categoría / subcategoría</th><th>Talla</th><th>Almacén</th><th className="num">Actual</th><th className="num">Mínimo</th></tr></thead>
              <tbody>
                {bajoMinimo.map((f) => (
                  <tr key={`${f.producto_id}-${f.almacen_id}`} className="fila-alerta">
                    <td>{f.sku}</td><td>{f.producto}</td>
                    <td>{f.categoria ?? "-"}{f.subcategoria ? <div style={{ fontSize: 11, color: "#6b7280" }}>{f.subcategoria}</div> : null}</td>
                    <td>{f.talla ?? "-"}</td><td>{f.almacen}</td>
                    <td className="num">{f.cantidad}</td><td className="num">{f.stock_minimo}</td>
                  </tr>
                ))}
                {!bajoMinimo.length && <tr><td colSpan={7} className="vacio">Ningún producto bajo su mínimo.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === "matriz" && (
        <div className="card">
          <div className="header-row">
            <h3>Matriz producto × almacén</h3>
            <button className="secondary" disabled={!matriz.datos.length}
              onClick={() => exportarCSV("matriz_stock", matriz.datos.map((r) => {
                const o: any = { SKU: r.sku, Producto: r.producto, Categoria: r.categoria, Subcategoria: r.subcategoria, Talla: r.talla };
                matriz.almacenes.forEach((a) => (o[a] = r[a]));
                o.TOTAL = r.total;
                return o;
              }))}>Exportar a Excel</button>
          </div>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>SKU</th><th>Producto</th><th>Categoría / subcategoría</th><th>Talla</th>
                  {matriz.almacenes.map((a) => <th key={a} className="num">{a}</th>)}
                  <th className="num">Total</th>
                </tr>
              </thead>
              <tbody>
                {matriz.datos.slice(0, 300).map((r, i) => (
                  <tr key={i}>
                    <td>{r.sku}</td><td>{r.producto}</td>
                    <td>{r.categoria ?? "-"}{r.subcategoria ? <div style={{ fontSize: 11, color: "#6b7280" }}>{r.subcategoria}</div> : null}</td>
                    <td>{r.talla ?? "-"}</td>
                    {matriz.almacenes.map((a) => <td key={a} className="num" style={{ color: r[a] ? "inherit" : "#d1d5db" }}>{r[a]}</td>)}
                    <td className="num"><strong>{r.total}</strong></td>
                  </tr>
                ))}
                {!matriz.datos.length && <tr><td colSpan={matriz.almacenes.length + 5} className="vacio">Sin stock registrado.</td></tr>}
              </tbody>
            </table>
          </div>
          {matriz.datos.length > 300 && (
            <p style={{ fontSize: 13, color: "#6b7280" }}>Mostrando los 300 con más stock. Exporta a Excel para ver todos ({matriz.datos.length}).</p>
          )}
        </div>
      )}

      {tab === "kardex" && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Kardex — historial de un producto</h3>
          <div className="filtros">
            <div className="field buscador">
              <label>Buscar producto</label>
              <input placeholder="Nombre, SKU, categoría o subcategoría..." value={buscaKardex} onChange={(e) => setBuscaKardex(e.target.value)} />
            </div>
            <div className="field" style={{ minWidth: 280 }}>
              <label>Producto</label>
              <select value={kardexProd} onChange={(e) => setKardexProd(e.target.value)} style={{ width: "100%" }}>
                <option value="">Selecciona...</option>
                {productosUnicos
                  .filter((p) => !buscaKardex || p.nombre.toLowerCase().includes(buscaKardex.toLowerCase()) || p.sku.toLowerCase().includes(buscaKardex.toLowerCase()) || (p.categoria ?? "").toLowerCase().includes(buscaKardex.toLowerCase()) || (p.subcategoria ?? "").toLowerCase().includes(buscaKardex.toLowerCase()))
                  .slice(0, 200)
                  .map((p) => <option key={p.id} value={p.id}>{p.nombre} ({p.sku}) · {p.categoria ?? "Sin categoría"}{p.subcategoria ? ` / ${p.subcategoria}` : ""}</option>)}
              </select>
            </div>
            <div className="field">
              <label>Empresa</label>
              <select value={kardexEmpresa} onChange={(e) => setKardexEmpresa(e.target.value)}>
                <option value="">Todas las empresas</option>
                {empresas.map((e) => <option key={e.id} value={e.id}>{e.razon_social}</option>)}
              </select>
            </div>
            {kardex.length > 0 && (
              <button className="secondary" onClick={() => exportarCSV("kardex", kardex.map((m) => ({
                Fecha: fecha(m.created_at), Tipo: ETIQUETA_TIPO[m.tipo] ?? m.tipo,
                Almacen: m.almacenes?.nombre, Destino: m.almacen_destino?.nombre ?? "",
                Cantidad: m.cantidad, Usuario: m.perfiles?.nombre_completo, Nota: m.nota ?? "",
                Estado: m.anulado ? "ANULADO" : "Vigente", MotivoAnulacion: m.motivo_anulacion ?? "",
              })))}>Exportar a Excel</button>
            )}
          </div>

          {!kardexProd ? (
            <div className="vacio">Selecciona un producto para ver todo su historial de movimientos.</div>
          ) : cargandoKardex ? (
            <div className="vacio">Cargando kardex completo...</div>
          ) : (
            <div className="tabla-scroll">
              <table>
                <thead><tr><th>Fecha</th><th>Tipo</th><th>Almacén</th><th>Destino</th><th className="num">Cant.</th><th>Usuario</th><th>Nota</th></tr></thead>
                <tbody>
                  {kardex.map((m) => (
                    <tr key={m.id} className={m.anulado ? "fila-anulada" : ""}>
                      <td style={{ whiteSpace: "nowrap" }}>{fecha(m.created_at)}</td>
                      <td>
                        <span className={`badge ${m.tipo}`}>{ETIQUETA_TIPO[m.tipo] ?? m.tipo}</span>
                        {m.anulado && <span className="badge anulado" style={{ marginLeft: 4 }}>ANULADO</span>}
                      </td>
                      <td>{m.almacenes?.nombre}</td>
                      <td>{m.almacen_destino?.nombre ?? "-"}</td>
                      <td className="num">{m.cantidad}</td>
                      <td>{m.perfiles?.nombre_completo}</td>
                      <td style={{ fontSize: 13 }}>
                        {m.anulado ? <span style={{ color: "#991b1b" }}>Motivo: {m.motivo_anulacion}</span> : (m.nota ?? "-")}
                      </td>
                    </tr>
                  ))}
                  {!kardex.length && <tr><td colSpan={7} className="vacio">Este producto no tiene movimientos registrados.</td></tr>}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </>
  );
}
