"use client";

import { useEffect, useMemo, useState } from "react";
import BuscadorCodigoProducto from "@/components/BuscadorCodigoProducto";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import GaleriaImagenes from "@/components/GaleriaImagenes";
import ProductoConImagen from "@/components/ProductoConImagen";
import type { Perfil } from "@/lib/getPerfil";
import { cargarPortadasProductos, type PortadaProducto } from "@/lib/portadasProductos";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Almacen = { id: string; codigo: string; nombre: string; tipo: string };
type Fila = {
  producto_id: string; sku: string; producto: string;
  categoria: string | null; categoria_id: string;
  subcategoria: string | null; subcategoria_id: string | null;
  talla: string | null; color: string | null;
  stock_minimo: number; punto_reposicion: number; ubicacion: string | null;
  almacen_id: string; almacen: string; stock_fisico: number;
  stock_reservado: number; stock_disponible: number;
  transito_entrada: number; transito_salida: number; transito_incidencia: number;
  stock_cuarentena: number; sugerido_reponer: number; bajo_minimo: boolean;
};

const TAMANO_PAGINA_API = 1000;
const FILAS_POR_PAGINA = 75;
const ROLES_TODOS_LOCALES = new Set(["admin", "control", "gerencia"]);

export default function StockCliente({ perfil, puedeEditarFotos = false }: {
  perfil: Perfil;
  puedeEditarFotos?: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [almacenId, setAlmacenId] = useState("");
  const [filas, setFilas] = useState<Fila[]>([]);
  const [portadas, setPortadas] = useState<Map<string, PortadaProducto>>(new Map());
  const [fotosDe, setFotosDe] = useState<{ id: string; sku: string; nombre: string } | null>(null);
  const [cargandoAlmacenes, setCargandoAlmacenes] = useState(true);
  const [cargandoStock, setCargandoStock] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busqueda, setBusqueda] = useState("");
  const [categoria, setCategoria] = useState("");
  const [subcategoria, setSubcategoria] = useState("");
  const [soloAlerta, setSoloAlerta] = useState(false);
  const [ocultarCero, setOcultarCero] = useState(true);
  const [pagina, setPagina] = useState(1);

  const almacenSeleccionado = almacenes.find((item) => item.id === almacenId) ?? null;

  useEffect(() => {
    let cancelado = false;
    (async () => {
      setCargandoAlmacenes(true);
      setError(null);
      const { data, error: errorAlmacenes } = await supabase
        .from("almacenes")
        .select("id,codigo,nombre,tipo")
        .eq("activo", true)
        .order("tipo")
        .order("nombre");
      if (cancelado) return;
      if (errorAlmacenes) {
        setError(errorAlmacenes.message);
        setCargandoAlmacenes(false);
        return;
      }

      let disponibles = (data ?? []) as Almacen[];
      if (!ROLES_TODOS_LOCALES.has(perfil.rol)) {
        const { data: asignaciones, error: errorAsignaciones } = await supabase
          .from("perfil_almacenes")
          .select("almacen_id")
          .eq("perfil_id", perfil.id);
        if (cancelado) return;
        if (errorAsignaciones) {
          setError(errorAsignaciones.message);
          setCargandoAlmacenes(false);
          return;
        }
        const permitidos = new Set((asignaciones ?? []).map((item) => item.almacen_id as string));
        if (perfil.entidad_id) permitidos.add(perfil.entidad_id);
        disponibles = disponibles.filter((item) => permitidos.has(item.id));
      }
      setAlmacenes(disponibles);
      setCargandoAlmacenes(false);
    })();
    return () => { cancelado = true; };
  }, [perfil.entidad_id, perfil.id, perfil.rol, supabase]);

  useEffect(() => {
    let cancelado = false;
    if (!almacenId) {
      setFilas([]);
      setPortadas(new Map());
      setCargandoStock(false);
      return () => { cancelado = true; };
    }

    (async () => {
      setCargandoStock(true);
      setError(null);
      setFilas([]);
      setPortadas(new Map());
      setPagina(1);
      const acumulado: Fila[] = [];
      let desde = 0;
      while (true) {
        const { data, error: errorStock } = await supabase
          .from("vista_stock_operativo")
          .select("*")
          .eq("almacen_id", almacenId)
          .order("producto")
          .order("sku")
          .order("producto_id")
          .range(desde, desde + TAMANO_PAGINA_API - 1);
        if (cancelado) return;
        if (errorStock) {
          setError(errorStock.message);
          setCargandoStock(false);
          await mostrarAvisoDialogo(errorStock.message, "No se pudo cargar el inventario del local", true);
          return;
        }
        const bloque = (data ?? []) as Fila[];
        acumulado.push(...bloque);
        if (bloque.length < TAMANO_PAGINA_API) break;
        desde += TAMANO_PAGINA_API;
      }

      setFilas(acumulado);
      setCargandoStock(false);
      try {
        const fotos = await cargarPortadasProductos(supabase, acumulado.map((fila) => fila.producto_id));
        if (!cancelado) setPortadas(fotos);
      } catch (e) {
        if (!cancelado) {
          const mensaje = e instanceof Error ? e.message : "No se pudieron cargar las fotos.";
          setError(mensaje);
          await mostrarAvisoDialogo(mensaje, "No se pudieron cargar las fotos", true);
        }
      }
      if (!cancelado) setCargandoStock(false);
    })();
    return () => { cancelado = true; };
  }, [almacenId, supabase]);

  async function refrescarPortadas() {
    try {
      setPortadas(await cargarPortadasProductos(supabase, filas.map((fila) => fila.producto_id)));
    } catch (e) {
      const mensaje = e instanceof Error ? e.message : "No se pudieron actualizar las fotos.";
      setError(mensaje);
      await mostrarAvisoDialogo(mensaje, "No se pudieron actualizar las fotos", true);
    }
  }

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

  const filtradas = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return filas.filter((f) => {
      if (categoria && f.categoria_id !== categoria) return false;
      if (subcategoria && f.subcategoria_id !== subcategoria) return false;
      if (soloAlerta && !f.bajo_minimo) return false;
      if (ocultarCero && !q && f.stock_fisico === 0 && f.transito_entrada === 0
        && f.transito_incidencia === 0 && f.stock_cuarentena === 0) return false;
      if (!q) return true;
      return f.producto.toLowerCase().includes(q) || f.sku.toLowerCase().includes(q)
        || (f.categoria ?? "").toLowerCase().includes(q)
        || (f.subcategoria ?? "").toLowerCase().includes(q)
        || (f.talla ?? "").toLowerCase().includes(q)
        || (f.color ?? "").toLowerCase().includes(q);
    });
  }, [filas, busqueda, categoria, subcategoria, soloAlerta, ocultarCero]);

  useEffect(() => { setPagina(1); }, [busqueda, categoria, subcategoria, soloAlerta, ocultarCero]);

  const totalPaginas = Math.max(1, Math.ceil(filtradas.length / FILAS_POR_PAGINA));
  const filasPagina = filtradas.slice((pagina - 1) * FILAS_POR_PAGINA, pagina * FILAS_POR_PAGINA);
  const totalUnidades = filtradas.reduce((a, f) => a + f.stock_fisico, 0);
  const totalDisponible = filtradas.reduce((a, f) => a + f.stock_disponible, 0);
  const totalTransito = filtradas.reduce((a, f) => a + f.transito_entrada, 0);
  const totalIncidencia = filtradas.reduce((a, f) => a + f.transito_incidencia, 0);
  const totalCuarentena = filtradas.reduce((a, f) => a + f.stock_cuarentena, 0);
  const enAlerta = filtradas.filter((f) => f.bajo_minimo).length;
  const skusDistintos = new Set(filtradas.map((f) => f.producto_id)).size;

  function limpiarFiltros() {
    setBusqueda(""); setCategoria(""); setSubcategoria("");
    setSoloAlerta(false); setOcultarCero(true);
  }

  function cambiarLocal() {
    setAlmacenId("");
    limpiarFiltros();
  }

  return (
    <>
      <header className="page-heading workspace-heading">
        <div><span className="eyebrow">INVENTARIO</span><h1>Existencias por local</h1><p>Selecciona primero una bodega o tienda. Así la pantalla carga solamente su inventario y puedes buscar en todos sus SKU sin el límite de 1000 filas.</p></div>
      </header>

      <section className="card context-selector" style={{ marginBottom: 16 }}>
        <div className="header-row" style={{ alignItems: "flex-end" }}>
          <div className="field" style={{ flex: "1 1 360px", maxWidth: 620 }}>
            <label>Local que deseas consultar *</label>
            <select value={almacenId} disabled={cargandoAlmacenes || cargandoStock} onChange={(e) => { setAlmacenId(e.target.value); limpiarFiltros(); }}>
              <option value="">{cargandoAlmacenes ? "Cargando locales…" : "Selecciona una bodega o tienda…"}</option>
              {almacenes.map((item) => <option key={item.id} value={item.id}>{item.nombre} · {item.codigo}</option>)}
            </select>
          </div>
          {almacenSeleccionado && <div className="acciones"><span className="badge ok">{almacenSeleccionado.tipo === "bodega" ? "Bodega" : "Tienda"}</span><button type="button" className="secondary" onClick={cambiarLocal}>Cambiar local</button></div>}
        </div>
        {!cargandoAlmacenes && almacenes.length === 0 && <div className="error-box">No tienes locales asignados para consultar existencias.</div>}
      </section>

      {!almacenId ? (
        <section className="empty-state"><span className="empty-state-icon" aria-hidden="true">01</span><strong>Elige el local para comenzar</strong><p>Las cantidades, alertas, fotografías y búsqueda se cargarán después de seleccionar una ubicación.</p></section>
      ) : (
        <>
          <div className="kpis">
            <div className="kpi"><div className="label">Unidades físicas</div><div className="valor">{totalUnidades.toLocaleString("es-EC")}</div><small>{almacenSeleccionado?.nombre}</small></div>
            <div className="kpi"><div className="label">Disponible</div><div className="valor">{totalDisponible.toLocaleString("es-EC")}</div><small>{skusDistintos} SKU visibles</small></div>
            <div className="kpi"><div className="label">En tránsito</div><div className="valor">{totalTransito.toLocaleString("es-EC")}</div></div>
            <div className={`kpi ${totalIncidencia || totalCuarentena ? "alerta" : "ok"}`}><div className="label">Bajo seguimiento</div><div className="valor">{(totalIncidencia + totalCuarentena).toLocaleString("es-EC")}</div><small>{totalIncidencia} no recibidas · {totalCuarentena} en cuarentena</small></div>
            <div className={`kpi ${enAlerta > 0 ? "alerta" : "ok"}`}><div className="label">Bajo mínimo</div><div className="valor">{enAlerta}</div></div>
          </div>

          <section className="card">
            <div className="filtros filter-bar">
              <BuscadorCodigoProducto onEncontrado={async (producto) => {
                if (!filas.some((fila) => fila.producto_id === producto.producto_id)) {
                  await mostrarAvisoDialogo(`${producto.sku} · ${producto.producto} no está habilitado en ${almacenSeleccionado?.nombre ?? "el local seleccionado"}.`, "Producto fuera del local");
                  return;
                }
                setBusqueda(producto.sku); setCategoria(""); setSubcategoria("");
                setSoloAlerta(false); setOcultarCero(false);
              }} />
              <div className="field buscador"><label>Buscar dentro de {almacenSeleccionado?.nombre}</label><input placeholder="Nombre, SKU, categoría, talla o color…" value={busqueda} onChange={(e) => setBusqueda(e.target.value)} /></div>
              <div className="field"><label>Categoría</label><select value={categoria} onChange={(e) => { setCategoria(e.target.value); setSubcategoria(""); }}><option value="">Todas</option>{categorias.map((item) => <option key={item.id} value={item.id}>{item.nombre}</option>)}</select></div>
              <div className="field"><label>Subcategoría</label><select value={subcategoria} onChange={(e) => setSubcategoria(e.target.value)}><option value="">Todas</option>{subcategorias.map((item) => <option key={item.id} value={item.id}>{item.nombre}</option>)}</select></div>
              <div className="field"><label style={{ fontWeight: 500 }}><input type="checkbox" checked={soloAlerta} onChange={(e) => setSoloAlerta(e.target.checked)} style={{ marginRight: 6 }} />Solo bajo mínimo</label><label style={{ fontWeight: 500, marginTop: 4 }}><input type="checkbox" checked={ocultarCero} onChange={(e) => setOcultarCero(e.target.checked)} style={{ marginRight: 6 }} />Ocultar sin stock</label></div>
              <button type="button" className="chip-limpiar" onClick={limpiarFiltros}>Limpiar filtros</button>
            </div>

            <div className="header-row"><span className="conteo">{filtradas.length} de {filas.length} existencia(s) · {almacenSeleccionado?.nombre}</span><button className="secondary" onClick={() => exportarCSV("stock_boman", filtradas.map((f) => ({ SKU: f.sku, Producto: f.producto, Categoria: f.categoria, Subcategoria: f.subcategoria, Talla: f.talla, Color: f.color, Almacen: f.almacen, Ubicacion: f.ubicacion, Fisico: f.stock_fisico, Reservado: f.stock_reservado, Disponible: f.stock_disponible, TransitoEntrada: f.transito_entrada, TransitoSalida: f.transito_salida, TransitoIncidencia: f.transito_incidencia, Cuarentena: f.stock_cuarentena, StockMinimo: f.stock_minimo, PuntoReposicion: f.punto_reposicion, SugeridoReponer: f.sugerido_reponer })))} disabled={!filtradas.length}>Exportar a Excel</button></div>

            {error && <div className="error-box">{error}</div>}
            {cargandoStock ? <div className="vacio" style={{ padding: 40 }}>Cargando todas las existencias de {almacenSeleccionado?.nombre}…</div> : (
              <>
                <div className="tabla-scroll">
                  <table>
                    <thead><tr><th>SKU</th><th>Producto</th><th>Categoría / subcategoría</th><th>Talla / color</th><th>Ubicación</th><th className="num">Físico</th><th className="num">Reserv.</th><th className="num">Disponible</th><th className="num">En tránsito</th><th className="num">Seguimiento</th><th>Estado</th></tr></thead>
                    <tbody>
                      {filasPagina.map((f) => <tr key={`${f.producto_id}-${f.almacen_id}`} className={f.bajo_minimo && f.stock_fisico > 0 ? "fila-alerta" : ""}><td><strong>{f.sku}</strong></td><td><ProductoConImagen nombre={f.producto} sku={f.sku} portada={portadas.get(f.producto_id)} puedeAgregarFoto={puedeEditarFotos} onAbrirGaleria={portadas.has(f.producto_id) || puedeEditarFotos ? () => setFotosDe({ id: f.producto_id, sku: f.sku, nombre: f.producto }) : undefined} /></td><td><div>{f.categoria ?? "-"}</div>{f.subcategoria && <small className="conteo">{f.subcategoria}</small>}</td><td><div>{f.talla ?? "-"}</div>{f.color && <small className="conteo">{f.color}</small>}</td><td>{f.ubicacion ?? "-"}</td><td className="num">{f.stock_fisico}</td><td className="num">{f.stock_reservado}</td><td className="num"><strong>{f.stock_disponible}</strong></td><td className="num">{f.transito_entrada > 0 ? `+${f.transito_entrada}` : "-"}</td><td className="num">{f.transito_incidencia + f.stock_cuarentena || "-"}</td><td>{f.transito_incidencia > 0 || f.stock_cuarentena > 0 ? <span className="badge bajo">Seguimiento</span> : f.stock_fisico === 0 && f.transito_entrada === 0 ? <span className="badge cero">Sin stock</span> : f.bajo_minimo ? <span className="badge bajo">Reponer {f.sugerido_reponer || ""}</span> : <span className="badge ok">OK</span>}</td></tr>)}
                      {!filtradas.length && <tr><td colSpan={11} className="vacio">No hay resultados con esos filtros. Si buscas un producto sin unidades, desmarca “Ocultar sin stock”.</td></tr>}
                    </tbody>
                  </table>
                </div>
                {filtradas.length > FILAS_POR_PAGINA && <div className="acciones" style={{ justifyContent: "center", marginTop: 16 }}><button type="button" className="secondary" disabled={pagina === 1} onClick={() => setPagina((actual) => Math.max(1, actual - 1))}>Anterior</button><span className="conteo">Página {pagina} de {totalPaginas} · mostrando {filasPagina.length}</span><button type="button" className="secondary" disabled={pagina === totalPaginas} onClick={() => setPagina((actual) => Math.min(totalPaginas, actual + 1))}>Siguiente</button></div>}
              </>
            )}
          </section>
        </>
      )}

      {fotosDe && <div className="modal-operativo" onMouseDown={(e) => { if (e.target === e.currentTarget) { setFotosDe(null); void refrescarPortadas(); } }}><div className="modal-contenido ancho"><div className="header-row"><div><h2 style={{ margin: 0 }}>{fotosDe.sku} · {fotosDe.nombre}</h2><p className="conteo">La portada aparecerá en Inventario y Productos.</p></div><button className="secondary" onClick={() => { setFotosDe(null); void refrescarPortadas(); }}>Cerrar</button></div><GaleriaImagenes entidadTipo="producto" entidadId={fotosDe.id} titulo={fotosDe.nombre} puedeEditar={puedeEditarFotos} /></div></div>}
    </>
  );
}
