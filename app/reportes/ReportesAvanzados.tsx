"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fecha } from "@/lib/utils";

// ---------------- Tipos ----------------

type ProductoBase = { id: string; sku: string; nombre: string };

type MovSalida = { producto_id: string; cantidad: number; created_at: string };

type FilaRotacion = {
  producto_id: string;
  sku: string;
  producto: string;
  ventas90: number;
  ultimaSalida: string | null;
  diasSinMovimiento: number | null;
};

type LineaIncidencia = {
  producto_id: string;
  cantidad_no_conforme_inicial: number;
  cantidad_no_recibida_inicial: number;
  observacion: string | null;
  productos: { sku: string; nombre: string } | null;
};

type Incidencia = {
  id: string;
  documento_id: string;
  estado: "abierta" | "en_investigacion" | "pendiente_aprobacion" | "resuelta";
  descripcion_inicial: string;
  causa_raiz: string | null;
  accion_correctiva: string | null;
  fecha_limite: string;
  created_at: string;
  resuelto_at: string | null;
  documentos_inventario: { numero: string } | null;
  creador: { nombre_completo: string } | null;
  resolutor: { nombre_completo: string } | null;
  lineas: LineaIncidencia[];
};

type LineaVentaXML = { cantidad: number; afecta_inventario: boolean };

type DocumentoVentaXML = {
  id: string;
  numero_documento: string;
  fecha_emision: string;
  importe_total: number;
  unidades_inventario: number;
  almacenes: { nombre: string } | null;
  lineas: LineaVentaXML[];
};

type Tab = "rotacion" | "incidencias" | "conciliacion";

const ETIQUETA_ESTADO_INCIDENCIA: Record<string, string> = {
  abierta: "Abierta",
  en_investigacion: "En investigación",
  pendiente_aprobacion: "Pendiente de aprobación",
  resuelta: "Resuelta",
};

export default function ReportesAvanzados() {
  const supabase = createClient();
  const [tab, setTab] = useState<Tab>("rotacion");
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);

  // Rotación
  const [productos, setProductos] = useState<ProductoBase[]>([]);
  const [movsSalida, setMovsSalida] = useState<MovSalida[]>([]);

  // Incidencias SGC
  const [incidencias, setIncidencias] = useState<Incidencia[]>([]);
  const [filtroEstado, setFiltroEstado] = useState<string>("");

  // Conciliación ventas XML
  const [documentosXML, setDocumentosXML] = useState<DocumentoVentaXML[]>([]);
  const [almacenesLista, setAlmacenesLista] = useState<{ id: string; nombre: string }[]>([]);
  const hace30 = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  const hoyISO = new Date().toISOString().slice(0, 10);
  const [desde, setDesde] = useState(hace30);
  const [hasta, setHasta] = useState(hoyISO);
  const [filtroAlmacenXML, setFiltroAlmacenXML] = useState("");

  useEffect(() => {
    (async () => {
      setCargando(true);
      setError(null);

      const [prodRes, almacenesRes] = await Promise.all([
        supabase.from("productos").select("id, sku, nombre").eq("activo", true),
        supabase.from("almacenes").select("id, nombre").eq("activo", true),
      ]);
      if (prodRes.error) setError(prodRes.error.message);
      if (prodRes.data) setProductos(prodRes.data as ProductoBase[]);
      if (almacenesRes.data) setAlmacenesLista(almacenesRes.data as { id: string; nombre: string }[]);

      // Movimientos de salida (paginados: pueden ser miles)
      const acumulado: MovSalida[] = [];
      const tamanoPagina = 1000;
      let desdeIdx = 0;
      for (;;) {
        const { data, error: eMov } = await supabase
          .from("movimientos")
          .select("producto_id, cantidad, created_at")
          .in("tipo", ["salida", "venta_xml"])
          .eq("anulado", false)
          .order("created_at", { ascending: false })
          .range(desdeIdx, desdeIdx + tamanoPagina - 1);
        if (eMov) { setError(eMov.message); break; }
        const pagina = (data as MovSalida[]) ?? [];
        acumulado.push(...pagina);
        if (pagina.length < tamanoPagina) break;
        desdeIdx += tamanoPagina;
      }
      setMovsSalida(acumulado);

      const { data: inc, error: eInc } = await supabase
        .from("incidencias_transferencia")
        .select(`
          id, documento_id, estado, descripcion_inicial, causa_raiz, accion_correctiva,
          fecha_limite, created_at, resuelto_at,
          documentos_inventario(numero),
          creador:perfiles!incidencias_transferencia_creado_por_fkey(nombre_completo),
          resolutor:perfiles!incidencias_transferencia_resuelto_por_fkey(nombre_completo),
          lineas:incidencia_transferencia_lineas(
            producto_id, cantidad_no_conforme_inicial, cantidad_no_recibida_inicial, observacion,
            productos(sku, nombre)
          )
        `)
        .order("created_at", { ascending: false });
      if (eInc) setError(eInc.message);
      setIncidencias((inc as unknown as Incidencia[]) ?? []);

      setCargando(false);
    })();
  }, []);

  // Ventas XML: se recarga cuando cambia el rango de fechas
  useEffect(() => {
    (async () => {
      const { data, error: eXML } = await supabase
        .from("documentos_venta_xml")
        .select(`
          id, numero_documento, fecha_emision, importe_total, unidades_inventario,
          almacenes(nombre),
          lineas:documento_venta_xml_lineas(cantidad, afecta_inventario)
        `)
        .gte("fecha_emision", desde)
        .lte("fecha_emision", hasta)
        .order("fecha_emision", { ascending: false });
      if (eXML) setError(eXML.message);
      setDocumentosXML((data as unknown as DocumentoVentaXML[]) ?? []);
    })();
  }, [desde, hasta]);

  // ---- Rotación ----
  const rotacion = useMemo<FilaRotacion[]>(() => {
    const hace90 = Date.now() - 90 * 86400000;
    const acumPorProducto = new Map<string, { ventas90: number; ultima: string | null }>();
    movsSalida.forEach((m) => {
      const o = acumPorProducto.get(m.producto_id) ?? { ventas90: 0, ultima: null as string | null };
      const t = new Date(m.created_at).getTime();
      if (t >= hace90) o.ventas90 += m.cantidad;
      if (!o.ultima || new Date(m.created_at) > new Date(o.ultima)) o.ultima = m.created_at;
      acumPorProducto.set(m.producto_id, o);
    });

    return productos
      .map((p) => {
        const o = acumPorProducto.get(p.id);
        const dias = o?.ultima ? Math.floor((Date.now() - new Date(o.ultima).getTime()) / 86400000) : null;
        return {
          producto_id: p.id,
          sku: p.sku,
          producto: p.nombre,
          ventas90: o?.ventas90 ?? 0,
          ultimaSalida: o?.ultima ?? null,
          diasSinMovimiento: dias,
        };
      })
      .sort((a, b) => (b.diasSinMovimiento ?? Infinity) - (a.diasSinMovimiento ?? Infinity));
  }, [productos, movsSalida]);

  // ---- Incidencias SGC ----
  const hoy = new Date().toISOString().slice(0, 10);
  const incidenciasFiltradas = useMemo(
    () => incidencias.filter((i) => !filtroEstado || i.estado === filtroEstado),
    [incidencias, filtroEstado]
  );

  // ---- Conciliación ventas XML ----
  const conciliacion = useMemo(() => {
    return documentosXML
      .filter((d) => !filtroAlmacenXML || d.almacenes?.nombre === filtroAlmacenXML)
      .map((d) => {
        const declaradas = d.lineas
          .filter((l) => l.afecta_inventario)
          .reduce((s, l) => s + l.cantidad, 0);
        const asignadas = d.unidades_inventario;
        return {
          id: d.id,
          numero: d.numero_documento,
          fecha: d.fecha_emision,
          almacen: d.almacenes?.nombre ?? "-",
          importe: d.importe_total,
          declaradas,
          asignadas,
          desfase: declaradas - asignadas,
        };
      });
  }, [documentosXML, filtroAlmacenXML]);

  const desfasesCount = conciliacion.filter((c) => c.desfase !== 0).length;

  if (cargando) {
    return (
      <section style={{ marginTop: 28 }}>
        <h2 style={{ color: "#1f3864" }}>Reportes avanzados</h2>
        <div className="card"><div className="vacio">Cargando datos...</div></div>
      </section>
    );
  }

  return (
    <section style={{ marginTop: 28 }}>
      <h2 style={{ color: "#1f3864" }}>Reportes avanzados</h2>
      {error && <div className="error">No se pudieron cargar los datos: {error}</div>}

      <div className="tabs">
        <div className={`tab ${tab === "rotacion" ? "activo" : ""}`} onClick={() => setTab("rotacion")}>Rotación de inventario</div>
        <div className={`tab ${tab === "incidencias" ? "activo" : ""}`} onClick={() => setTab("incidencias")}>Incidencias de calidad (SGC)</div>
        <div className={`tab ${tab === "conciliacion" ? "activo" : ""}`} onClick={() => setTab("conciliacion")}>Conciliación de ventas XML</div>
      </div>

      {tab === "rotacion" && (
        <div className="card">
          <div className="header-row">
            <div>
              <h3 style={{ marginBottom: 2 }}>Rotación de inventario</h3>
              <p className="conteo" style={{ margin: 0 }}>
                Salidas (ventas y despachos manuales) de los últimos 90 días. Ordenado de más estancado a más activo.
              </p>
            </div>
            <button className="secondary" disabled={!rotacion.length} onClick={() => exportarCSV("rotacion_inventario", rotacion.map((r) => ({
              SKU: r.sku, Producto: r.producto, Salidas90dias: r.ventas90,
              UltimaSalida: r.ultimaSalida ? fecha(r.ultimaSalida) : "Sin movimientos",
              DiasSinMovimiento: r.diasSinMovimiento ?? "Sin movimientos",
            })))}>Exportar a Excel</button>
          </div>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>SKU</th><th>Producto</th>
                  <th className="num">Salidas (90 días)</th>
                  <th>Última salida</th>
                  <th className="num">Días sin movimiento</th>
                </tr>
              </thead>
              <tbody>
                {rotacion.map((r) => (
                  <tr key={r.producto_id} className={r.diasSinMovimiento === null || r.diasSinMovimiento > 90 ? "fila-alerta" : ""}>
                    <td>{r.sku}</td>
                    <td>{r.producto}</td>
                    <td className="num">{r.ventas90}</td>
                    <td>{r.ultimaSalida ? fecha(r.ultimaSalida) : "Sin movimientos"}</td>
                    <td className="num">{r.diasSinMovimiento ?? "-"}</td>
                  </tr>
                ))}
                {!rotacion.length && <tr><td colSpan={5} className="vacio">Sin datos de productos.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === "incidencias" && (
        <div className="card">
          <div className="filtros">
            <div className="field">
              <label>Estado</label>
              <select value={filtroEstado} onChange={(e) => setFiltroEstado(e.target.value)}>
                <option value="">Todos</option>
                <option value="abierta">Abierta</option>
                <option value="en_investigacion">En investigación</option>
                <option value="pendiente_aprobacion">Pendiente de aprobación</option>
                <option value="resuelta">Resuelta</option>
              </select>
            </div>
            <button className="secondary" disabled={!incidenciasFiltradas.length} onClick={() => exportarCSV("incidencias_sgc", incidenciasFiltradas.map((i) => ({
              Fecha: fecha(i.created_at),
              Documento: i.documentos_inventario?.numero ?? "-",
              Productos: i.lineas.map((l) => l.productos?.sku ?? l.producto_id).join(", "),
              Estado: ETIQUETA_ESTADO_INCIDENCIA[i.estado] ?? i.estado,
              CantidadNoConforme: i.lineas.reduce((s, l) => s + l.cantidad_no_conforme_inicial, 0),
              CantidadNoRecibida: i.lineas.reduce((s, l) => s + l.cantidad_no_recibida_inicial, 0),
              CausaRaiz: i.causa_raiz ?? "",
              AccionCorrectiva: i.accion_correctiva ?? "",
              FechaLimite: i.fecha_limite,
              Vencida: i.fecha_limite < hoy && i.estado !== "resuelta" ? "SI" : "NO",
              CreadoPor: i.creador?.nombre_completo ?? "",
              ResueltoPor: i.resolutor?.nombre_completo ?? "",
            })))}>Exportar a Excel</button>
          </div>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th><th>Documento</th><th>Producto(s)</th><th>Estado</th>
                  <th className="num">No conforme</th><th className="num">No recibida</th>
                  <th>Causa raíz</th><th>Fecha límite</th>
                </tr>
              </thead>
              <tbody>
                {incidenciasFiltradas.map((i) => {
                  const vencida = i.fecha_limite < hoy && i.estado !== "resuelta";
                  return (
                    <tr key={i.id} className={vencida ? "fila-alerta" : ""}>
                      <td style={{ whiteSpace: "nowrap" }}>{fecha(i.created_at)}</td>
                      <td>{i.documentos_inventario?.numero ?? "-"}</td>
                      <td>
                        {i.lineas.map((l) => (
                          <div key={l.producto_id} style={{ fontSize: 13 }}>
                            {l.productos?.sku ?? "-"} {l.productos?.nombre ?? ""}
                          </div>
                        ))}
                      </td>
                      <td><span className="badge">{ETIQUETA_ESTADO_INCIDENCIA[i.estado] ?? i.estado}</span></td>
                      <td className="num">{i.lineas.reduce((s, l) => s + l.cantidad_no_conforme_inicial, 0)}</td>
                      <td className="num">{i.lineas.reduce((s, l) => s + l.cantidad_no_recibida_inicial, 0)}</td>
                      <td style={{ fontSize: 13 }}>{i.causa_raiz ?? "-"}</td>
                      <td style={{ whiteSpace: "nowrap" }}>
                        {i.fecha_limite}
                        {vencida && <span className="badge bajo" style={{ marginLeft: 6 }}>VENCIDA</span>}
                      </td>
                    </tr>
                  );
                })}
                {!incidenciasFiltradas.length && <tr><td colSpan={8} className="vacio">Sin incidencias registradas.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === "conciliacion" && (
        <div className="card">
          <div className="filtros">
            <div className="field">
              <label>Desde</label>
              <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} />
            </div>
            <div className="field">
              <label>Hasta</label>
              <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} />
            </div>
            <div className="field">
              <label>Almacén</label>
              <select value={filtroAlmacenXML} onChange={(e) => setFiltroAlmacenXML(e.target.value)}>
                <option value="">Todos</option>
                {almacenesLista.map((a) => <option key={a.id} value={a.nombre}>{a.nombre}</option>)}
              </select>
            </div>
            <button className="secondary" disabled={!conciliacion.length} onClick={() => exportarCSV("conciliacion_ventas_xml", conciliacion.map((c) => ({
              Documento: c.numero, Fecha: c.fecha, Almacen: c.almacen, Importe: c.importe.toFixed(2),
              UnidadesDeclaradas: c.declaradas, UnidadesAsignadas: c.asignadas, Desfase: c.desfase,
            })))}>Exportar a Excel</button>
          </div>
          {desfasesCount > 0 && (
            <div className="error">{desfasesCount} documento(s) con desfase entre lo declarado en la factura y lo asignado en inventario.</div>
          )}
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Documento</th><th>Fecha</th><th>Almacén</th><th className="num">Importe</th>
                  <th className="num">Unidades declaradas</th><th className="num">Unidades asignadas</th><th className="num">Desfase</th>
                </tr>
              </thead>
              <tbody>
                {conciliacion.map((c) => (
                  <tr key={c.id} className={c.desfase !== 0 ? "fila-alerta" : ""}>
                    <td><strong>{c.numero}</strong></td>
                    <td>{c.fecha}</td>
                    <td>{c.almacen}</td>
                    <td className="num">${c.importe.toFixed(2)}</td>
                    <td className="num">{c.declaradas}</td>
                    <td className="num">{c.asignadas}</td>
                    <td className="num">{c.desfase !== 0 ? <strong>{c.desfase > 0 ? `+${c.desfase}` : c.desfase}</strong> : "0"}</td>
                  </tr>
                ))}
                {!conciliacion.length && <tr><td colSpan={7} className="vacio">Sin facturas en el rango seleccionado.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </section>
  );
}
