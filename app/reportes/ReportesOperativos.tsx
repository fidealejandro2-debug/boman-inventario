"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fecha } from "@/lib/utils";
import { ETIQUETAS_ESTADO } from "@/lib/erp";

type Stock = {
  producto_id: string; almacen_id: string; sku: string; producto: string; talla: string | null;
  categoria: string | null; subcategoria: string | null; almacen: string; ubicacion: string | null;
  stock_fisico: number; stock_reservado: number; stock_disponible: number;
  transito_entrada: number; transito_salida: number; punto_reposicion: number;
  sugerido_reponer: number; precio: number | null;
};

type Empresa = { id: string; razon_social: string };

export default function ReportesOperativos() {
  const supabase = createClient();
  const [stock, setStock] = useState<Stock[]>([]);
  const [documentos, setDocumentos] = useState<any[]>([]);
  const [tab, setTab] = useState<"disponibilidad" | "reposicion" | "transferencias" | "conteos">("disponibilidad");
  const [almacen, setAlmacen] = useState("");
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [empresaId, setEmpresaId] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);

  useEffect(() => {
    (async () => {
      const todas: Stock[] = [];
      for (let desde = 0; ; desde += 1000) {
        const { data, error: e } = await supabase.from("vista_stock_operativo").select("*").range(desde, desde + 999);
        if (e) { setError(e.message); break; }
        const pagina = (data ?? []) as Stock[]; todas.push(...pagina);
        if (pagina.length < 1000) break;
      }
      const { data: emp } = await supabase.from("empresas").select("id, razon_social").eq("activo", true).order("razon_social");
      if (emp) setEmpresas(emp as Empresa[]);
      setStock(todas); setCargando(false);
    })();
  }, []);

  useEffect(() => {
    (async () => {
      let query = supabase.from("documentos_inventario").select(`
        id, numero, tipo, estado, created_at, despachado_at, recibido_at, aplicado_at, nota,
        origen:almacenes!documentos_inventario_origen_id_fkey(nombre),
        destino:almacenes!documentos_inventario_destino_id_fkey(nombre),
        creador:perfiles!documentos_inventario_creado_por_fkey(nombre_completo),
        lineas:documento_inventario_lineas(
          stock_sistema, cantidad_contada, cantidad_reconteo, cantidad_despachada,
          cantidad_recibida, cantidad_rechazada, producto:productos(sku, nombre, precio)
        )
      `);
      if (empresaId) query = query.eq("empresa_responsable_id", empresaId);
      const { data: docs, error: eDocs } = await query.order("created_at", { ascending: false }).limit(1000);
      if (eDocs) setError(eDocs.message);
      setDocumentos(docs ?? []);
    })();
  }, [empresaId]);

  const almacenes = useMemo(() => Array.from(new Set(stock.map((s) => s.almacen))).sort(), [stock]);
  const stockFiltrado = useMemo(() => stock.filter((s) => !almacen || s.almacen === almacen), [stock, almacen]);
  const reposicion = useMemo(() => stockFiltrado.filter((s) => s.sugerido_reponer > 0).sort((a, b) => b.sugerido_reponer - a.sugerido_reponer), [stockFiltrado]);
  const transferencias = documentos.filter((d) => d.tipo === "transferencia");
  const conteos = documentos.filter((d) => d.tipo === "conteo");
  const totalFisico = stockFiltrado.reduce((s, f) => s + f.stock_fisico, 0);
  const totalReservado = stockFiltrado.reduce((s, f) => s + f.stock_reservado, 0);
  const totalTransito = stockFiltrado.reduce((s, f) => s + f.transito_entrada, 0);
  const totalDisponible = stockFiltrado.reduce((s, f) => s + f.stock_disponible, 0);

  function horasEntre(inicio: string | null, fin: string | null) {
    if (!inicio || !fin) return null;
    return Math.round((new Date(fin).getTime() - new Date(inicio).getTime()) / 360000) / 10;
  }

  function exportarDiferenciasConteos() {
    exportarCSV("diferencias_conteos", conteos.flatMap((d) =>
      d.lineas
        .filter((l: any) => l.cantidad_contada !== l.stock_sistema)
        .map((l: any) => ({
          Conteo: d.numero,
          Almacen: d.origen?.nombre,
          Estado: ETIQUETAS_ESTADO[d.estado] ?? d.estado,
          SKU: l.producto?.sku,
          Producto: l.producto?.nombre,
          StockAnterior: l.stock_sistema,
          PrimerConteo: l.cantidad_contada,
          ConteoFinal: l.cantidad_reconteo ?? l.cantidad_contada,
          DiferenciaFinal: (l.cantidad_reconteo ?? l.cantidad_contada ?? 0) - (l.stock_sistema ?? 0),
          ValorDiferencia: ((l.cantidad_reconteo ?? l.cantidad_contada ?? 0) - (l.stock_sistema ?? 0)) * (l.producto?.precio ?? 0),
        }))
    ));
  }

  if (cargando) return <div className="card"><div className="vacio">Cargando reportes operativos...</div></div>;

  return <section style={{ marginTop: 28 }}>
    <div className="header-row"><div><h2 style={{ color: "#1f3864", margin: 0 }}>Reportes operativos ERP</h2><p className="conteo">Disponible, reservado, tránsito, reposición, transferencias y diferencias.</p></div><div style={{ display: "flex", gap: 8 }}><select value={empresaId} onChange={(e) => setEmpresaId(e.target.value)} title="Filtra transferencias y conteos por empresa responsable"><option value="">Todas las empresas</option>{empresas.map((e) => <option key={e.id} value={e.id}>{e.razon_social}</option>)}</select><select value={almacen} onChange={(e) => setAlmacen(e.target.value)}><option value="">Todos los almacenes</option>{almacenes.map((a) => <option key={a}>{a}</option>)}</select></div></div>
    {error && <div className="error">{error}</div>}
    <div className="kpis"><div className="kpi"><div className="label">Stock físico</div><div className="valor">{totalFisico}</div></div><div className="kpi"><div className="label">Reservado para picking</div><div className="valor">{totalReservado}</div></div><div className="kpi"><div className="label">En tránsito de entrada</div><div className="valor">{totalTransito}</div></div><div className="kpi"><div className="label">Disponible</div><div className="valor">{totalDisponible}</div></div></div>
    <div className="tabs"><button className={`tab ${tab === "disponibilidad" ? "activo" : ""}`} onClick={() => setTab("disponibilidad")}>Disponibilidad</button><button className={`tab ${tab === "reposicion" ? "activo" : ""}`} onClick={() => setTab("reposicion")}>Reposición ({reposicion.length})</button><button className={`tab ${tab === "transferencias" ? "activo" : ""}`} onClick={() => setTab("transferencias")}>Transferencias</button><button className={`tab ${tab === "conteos" ? "activo" : ""}`} onClick={() => setTab("conteos")}>Conteos y mermas</button></div>

    {tab === "disponibilidad" && <div className="card"><div className="header-row"><h3>Stock operativo por almacén</h3><button className="secondary" onClick={() => exportarCSV("stock_operativo", stockFiltrado.map((s) => ({ Almacen: s.almacen, Ubicacion: s.ubicacion, SKU: s.sku, Producto: s.producto, Talla: s.talla, Fisico: s.stock_fisico, Reservado: s.stock_reservado, Disponible: s.stock_disponible, TransitoEntrada: s.transito_entrada, TransitoSalida: s.transito_salida })))}>Exportar</button></div><div className="tabla-scroll"><table><thead><tr><th>Almacén</th><th>Ubicación</th><th>SKU / producto</th><th className="num">Físico</th><th className="num">Reservado</th><th className="num">Disponible</th><th className="num">Tránsito entrada</th><th className="num">Tránsito salida</th></tr></thead><tbody>{stockFiltrado.filter((s) => s.stock_fisico || s.stock_reservado || s.transito_entrada || s.transito_salida).slice(0, 600).map((s) => <tr key={`${s.producto_id}-${s.almacen_id}`}><td>{s.almacen}</td><td>{s.ubicacion ?? "-"}</td><td><strong>{s.sku}</strong><div>{s.producto} {s.talla ?? ""}</div></td><td className="num">{s.stock_fisico}</td><td className="num">{s.stock_reservado}</td><td className="num"><strong>{s.stock_disponible}</strong></td><td className="num">{s.transito_entrada}</td><td className="num">{s.transito_salida}</td></tr>)}</tbody></table></div></div>}

    {tab === "reposicion" && <div className="card"><div className="header-row"><h3>Sugerencia de reposición</h3><button className="secondary" onClick={() => exportarCSV("sugerencia_reposicion", reposicion.map((s) => ({ Almacen: s.almacen, SKU: s.sku, Producto: s.producto, Talla: s.talla, Fisico: s.stock_fisico, EnTransito: s.transito_entrada, PuntoReposicion: s.punto_reposicion, Sugerido: s.sugerido_reponer })))}>Exportar</button></div><div className="tabla-scroll"><table><thead><tr><th>Almacén</th><th>SKU</th><th>Producto</th><th className="num">Físico</th><th className="num">En tránsito</th><th className="num">Punto reposición</th><th className="num">Sugerido</th></tr></thead><tbody>{reposicion.map((s) => <tr key={`${s.producto_id}-${s.almacen_id}`} className="fila-alerta"><td>{s.almacen}</td><td><strong>{s.sku}</strong></td><td>{s.producto} {s.talla ?? ""}</td><td className="num">{s.stock_fisico}</td><td className="num">{s.transito_entrada}</td><td className="num">{s.punto_reposicion}</td><td className="num"><strong>{s.sugerido_reponer}</strong></td></tr>)}</tbody></table></div></div>}

    {tab === "transferencias" && <div className="card"><div className="header-row"><h3>Cumplimiento de transferencias</h3><button className="secondary" onClick={() => exportarCSV("transferencias_operativas", transferencias.map((d) => ({ Numero: d.numero, Origen: d.origen?.nombre, Destino: d.destino?.nombre, Estado: ETIQUETAS_ESTADO[d.estado] ?? d.estado, Creada: fecha(d.created_at), Despachada: d.despachado_at ? fecha(d.despachado_at) : "", Recibida: d.recibido_at ? fecha(d.recibido_at) : "", HorasTransito: horasEntre(d.despachado_at, d.recibido_at), Lineas: d.lineas.length, Enviado: d.lineas.reduce((s: number, l: any) => s + (l.cantidad_despachada ?? 0), 0), Recibido: d.lineas.reduce((s: number, l: any) => s + (l.cantidad_recibida ?? 0), 0) })))}>Exportar</button></div><div className="tabla-scroll"><table><thead><tr><th>Documento</th><th>Ruta</th><th>Estado</th><th>Despacho</th><th>Recepción</th><th className="num">Horas tránsito</th><th className="num">Enviado</th><th className="num">Recibido</th></tr></thead><tbody>{transferencias.map((d) => <tr key={d.id} className={d.estado === "recibido_con_diferencia" ? "fila-alerta" : ""}><td><strong>{d.numero}</strong></td><td>{d.origen?.nombre} → {d.destino?.nombre}</td><td><span className={`badge estado-${d.estado}`}>{ETIQUETAS_ESTADO[d.estado] ?? d.estado}</span></td><td>{d.despachado_at ? fecha(d.despachado_at) : "-"}</td><td>{d.recibido_at ? fecha(d.recibido_at) : "-"}</td><td className="num">{horasEntre(d.despachado_at, d.recibido_at) ?? "-"}</td><td className="num">{d.lineas.reduce((s: number, l: any) => s + (l.cantidad_despachada ?? 0), 0)}</td><td className="num">{d.lineas.reduce((s: number, l: any) => s + (l.cantidad_recibida ?? 0), 0)}</td></tr>)}</tbody></table></div></div>}

    {tab === "conteos" && <div className="card"><div className="header-row"><h3>Diferencias de conteos físicos</h3><button className="secondary" onClick={exportarDiferenciasConteos}>Exportar</button></div><div className="tabla-scroll"><table><thead><tr><th>Conteo</th><th>Almacén</th><th>SKU / producto</th><th className="num">Stock anterior</th><th className="num">Primer conteo</th><th className="num">Conteo final</th><th className="num">Diferencia final</th><th>Estado</th></tr></thead><tbody>{conteos.flatMap((d) => d.lineas.filter((l: any) => l.cantidad_contada !== l.stock_sistema).map((l: any) => { const actual = l.cantidad_reconteo ?? l.cantidad_contada ?? 0; const dif = actual - (l.stock_sistema ?? 0); return <tr key={`${d.id}-${l.producto?.sku}`} className="fila-alerta"><td><strong>{d.numero}</strong></td><td>{d.origen?.nombre}</td><td><strong>{l.producto?.sku}</strong><div>{l.producto?.nombre}</div></td><td className="num">{l.stock_sistema}</td><td className="num">{l.cantidad_contada}</td><td className="num">{actual}</td><td className="num">{dif > 0 ? `+${dif}` : dif}</td><td>{ETIQUETAS_ESTADO[d.estado] ?? d.estado}</td></tr>; }))}</tbody></table></div></div>}
  </section>;
}
