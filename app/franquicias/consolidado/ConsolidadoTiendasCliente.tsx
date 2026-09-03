"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { hoyLocalISO, mensajeError } from "@/app/franquicia/lib";

type FilaTienda = {
  almacen_id: string;
  almacen_codigo: string;
  almacen_nombre: string;
  empresa_codigo: string | null;
  empresa_nombre: string | null;
  facturas_registradas: number;
  facturas_anuladas: number;
  unidades_facturadas: number;
  importe_facturado: number;
  unidades_devueltas: number;
  stock_unidades: number;
  stock_disponible: number;
  valor_inventario: number;
  productos_bajo_minimo: number;
  productos_sin_stock: number;
  unidades_sugeridas_reponer: number;
  solicitudes_pendientes: number;
  transferencias_pendientes_recepcion: number;
  transferencias_pendientes_despacho: number;
  conteos_pendientes_revision: number;
  ultima_factura: string | null;
  ultimo_movimiento: string | null;
  ultimo_conteo: string | null;
};

const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const entero = new Intl.NumberFormat("es-EC", { maximumFractionDigits: 0 });

function inicioMesLocal() {
  const hoy = hoyLocalISO();
  return `${hoy.slice(0, 7)}-01`;
}

function numero(valor: unknown) {
  const convertido = Number(valor);
  return Number.isFinite(convertido) ? convertido : 0;
}

function fechaVisible(valor: string | null, conHora = false) {
  if (!valor) return "—";
  if (!conHora) return valor.slice(0, 10).split("-").reverse().join("/");
  return new Date(valor).toLocaleString("es-EC", {
    timeZone: "America/Guayaquil",
    day: "2-digit", month: "2-digit", year: "numeric",
    hour: "2-digit", minute: "2-digit",
  });
}

export default function ConsolidadoTiendasCliente() {
  const supabase = useMemo(() => createClient(), []);
  const [desde, setDesde] = useState(inicioMesLocal);
  const [hasta, setHasta] = useState(hoyLocalISO);
  const [rango, setRango] = useState({ desde: inicioMesLocal(), hasta: hoyLocalISO() });
  const [busqueda, setBusqueda] = useState("");
  const [filas, setFilas] = useState<FilaTienda[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const { data, error: fallo } = await supabase.rpc("resumen_consolidado_tiendas_v64", {
      p_desde: rango.desde,
      p_hasta: rango.hasta,
    });
    if (fallo) {
      setError(mensajeError(fallo));
      setFilas([]);
    } else {
      setFilas(((data as FilaTienda[]) ?? []).map((fila) => ({
        ...fila,
        facturas_registradas: numero(fila.facturas_registradas),
        facturas_anuladas: numero(fila.facturas_anuladas),
        unidades_facturadas: numero(fila.unidades_facturadas),
        importe_facturado: numero(fila.importe_facturado),
        unidades_devueltas: numero(fila.unidades_devueltas),
        stock_unidades: numero(fila.stock_unidades),
        stock_disponible: numero(fila.stock_disponible),
        valor_inventario: numero(fila.valor_inventario),
        productos_bajo_minimo: numero(fila.productos_bajo_minimo),
        productos_sin_stock: numero(fila.productos_sin_stock),
        unidades_sugeridas_reponer: numero(fila.unidades_sugeridas_reponer),
        solicitudes_pendientes: numero(fila.solicitudes_pendientes),
        transferencias_pendientes_recepcion: numero(fila.transferencias_pendientes_recepcion),
        transferencias_pendientes_despacho: numero(fila.transferencias_pendientes_despacho),
        conteos_pendientes_revision: numero(fila.conteos_pendientes_revision),
      })));
    }
    setCargando(false);
  }, [rango, supabase]);

  useEffect(() => { void cargar(); }, [cargar]);

  const visibles = useMemo(() => {
    const consulta = busqueda.trim().toLocaleLowerCase("es");
    return !consulta ? filas : filas.filter((fila) =>
      `${fila.almacen_nombre} ${fila.almacen_codigo} ${fila.empresa_nombre ?? ""} ${fila.empresa_codigo ?? ""}`
        .toLocaleLowerCase("es").includes(consulta)
    );
  }, [busqueda, filas]);

  const totales = useMemo(() => filas.reduce((total, fila) => ({
    tiendas: total.tiendas + 1,
    facturas: total.facturas + fila.facturas_registradas,
    importe: total.importe + fila.importe_facturado,
    unidades: total.unidades + fila.unidades_facturadas,
    devoluciones: total.devoluciones + fila.unidades_devueltas,
    stock: total.stock + fila.stock_unidades,
    disponible: total.disponible + fila.stock_disponible,
    inventario: total.inventario + fila.valor_inventario,
    bajoMinimo: total.bajoMinimo + fila.productos_bajo_minimo,
    pendientes: total.pendientes + fila.solicitudes_pendientes
      + fila.transferencias_pendientes_recepcion
      + fila.transferencias_pendientes_despacho
      + fila.conteos_pendientes_revision,
  }), {
    tiendas: 0, facturas: 0, importe: 0, unidades: 0, devoluciones: 0,
    stock: 0, disponible: 0, inventario: 0, bajoMinimo: 0, pendientes: 0,
  }), [filas]);

  function aplicarRango() {
    if (!desde || !hasta) return setError("Selecciona las dos fechas del período.");
    if (desde > hasta) return setError("La fecha inicial no puede superar la fecha final.");
    setRango({ desde, hasta });
  }

  function exportar() {
    if (!visibles.length) return;
    const datos = visibles.map((fila) => ({
      Tienda: fila.almacen_nombre,
      Código: fila.almacen_codigo,
      Empresa: fila.empresa_nombre ?? "Sin operadora principal",
      Facturas: fila.facturas_registradas,
      "Facturas anuladas": fila.facturas_anuladas,
      "Importe facturado": fila.importe_facturado,
      "Unidades facturadas": fila.unidades_facturadas,
      "Unidades devueltas": fila.unidades_devueltas,
      "Stock físico": fila.stock_unidades,
      "Stock disponible": fila.stock_disponible,
      "Valor inventario": fila.valor_inventario,
      "Productos bajo mínimo": fila.productos_bajo_minimo,
      "Productos sin stock": fila.productos_sin_stock,
      "Sugerido reponer": fila.unidades_sugeridas_reponer,
      "Solicitudes pendientes": fila.solicitudes_pendientes,
      "Transferencias por recibir": fila.transferencias_pendientes_recepcion,
      "Transferencias por despachar": fila.transferencias_pendientes_despacho,
      "Conteos por revisar": fila.conteos_pendientes_revision,
      "Última factura": fila.ultima_factura ?? "",
      "Último movimiento": fila.ultimo_movimiento ?? "",
    }));
    const libro = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(datos), "Tiendas propias");
    XLSX.writeFile(libro, `tiendas_propias_${rango.desde}_${rango.hasta}.xlsx`);
  }

  return (
    <div className="consolidado-contenido">
      <div className="filtros fq-consolidado-filtros">
        <label>Desde<input type="date" value={desde} max={hasta} onChange={(evento) => setDesde(evento.target.value)} /></label>
        <label>Hasta<input type="date" value={hasta} min={desde} max={hoyLocalISO()} onChange={(evento) => setHasta(evento.target.value)} /></label>
        <button onClick={aplicarRango} disabled={cargando}>Aplicar período</button>
        <label className="buscador">Buscar tienda<input value={busqueda} onChange={(evento) => setBusqueda(evento.target.value)} placeholder="Nombre, código o empresa…" /></label>
        <button type="button" className="secondary" onClick={exportar} disabled={cargando || !visibles.length}>Descargar Excel</button>
      </div>

      {error && <div className="error-box">{error}</div>}

      <div className="kpis fq-consolidado-kpis tiendas-kpis">
        <div className="kpi"><span className="valor">{dinero.format(totales.importe)}</span><span className="label">Facturación XML</span><small>{entero.format(totales.facturas)} facturas importadas</small></div>
        <div className="kpi"><span className="valor">{entero.format(totales.unidades)}</span><span className="label">Unidades facturadas</span><small>{entero.format(totales.devoluciones)} devueltas en el período</small></div>
        <div className="kpi"><span className="valor">{entero.format(totales.stock)}</span><span className="label">Stock físico actual</span><small>{entero.format(totales.disponible)} disponible</small></div>
        <div className="kpi"><span className="valor">{dinero.format(totales.inventario)}</span><span className="label">Inventario actual</span><small>Valorizado a precio de venta</small></div>
        <div className={`kpi ${totales.bajoMinimo ? "alerta" : "ok"}`}><span className="valor">{entero.format(totales.bajoMinimo)}</span><span className="label">SKU bajo mínimo</span><small>Acumulado de {totales.tiendas} tiendas</small></div>
        <div className={`kpi ${totales.pendientes ? "alerta" : "ok"}`}><span className="valor">{entero.format(totales.pendientes)}</span><span className="label">Tareas pendientes</span><small>Reposición, transferencias y conteos</small></div>
      </div>

      <div className="card tienda-aclaracion">
        <strong>Lectura operativa</strong>
        <span>La facturación proviene de los XML cargados. No representa efectivo ni utilidad: las tiendas propias todavía no tienen el diario de caja de las franquicias.</span>
      </div>

      <div className="card">
        <div className="card-titulo-linea">
          <div><h2>Comparativo de tiendas propias</h2><p>{rango.desde.split("-").reverse().join("/")} al {rango.hasta.split("-").reverse().join("/")} · inventario y pendientes al momento de la consulta.</p></div>
          <span className="badge ok">{visibles.length} tiendas</span>
        </div>
        {cargando ? <div className="vacio">Cargando tiendas…</div> : (
          <div className="tabla-scroll fq-tabla-consolidado">
            <table>
              <thead><tr><th>Tienda</th><th className="num">Facturas</th><th className="num">Facturado</th><th className="num">Unidades</th><th className="num">Stock</th><th className="num">Bajo mínimo</th><th>Operaciones pendientes</th><th>Actividad</th><th></th></tr></thead>
              <tbody>
                {visibles.map((fila) => {
                  const pendientes = fila.solicitudes_pendientes + fila.transferencias_pendientes_recepcion
                    + fila.transferencias_pendientes_despacho + fila.conteos_pendientes_revision;
                  return (
                    <tr key={fila.almacen_id} className={pendientes || fila.productos_bajo_minimo ? "fila-alerta-suave" : ""}>
                      <td><strong>{fila.almacen_nombre}</strong><small>{fila.almacen_codigo}<br />{fila.empresa_nombre ?? "Sin empresa operadora principal"}</small></td>
                      <td className="num"><strong>{fila.facturas_registradas}</strong><small>{fila.facturas_anuladas} anuladas</small></td>
                      <td className="num"><strong>{dinero.format(fila.importe_facturado)}</strong><small>Según XML autorizados</small></td>
                      <td className="num"><strong>{fila.unidades_facturadas}</strong><small>{fila.unidades_devueltas} devueltas</small></td>
                      <td className="num"><strong>{fila.stock_unidades}</strong><small>{fila.stock_disponible} disponible · {dinero.format(fila.valor_inventario)}</small></td>
                      <td className="num">{fila.productos_bajo_minimo ? <span className="badge bajo">{fila.productos_bajo_minimo} SKU</span> : <span className="badge ok">Al día</span>}<small>{fila.unidades_sugeridas_reponer} unidades sugeridas · {fila.productos_sin_stock} sin stock</small></td>
                      <td>{pendientes ? <span className="badge bajo">{pendientes} pendientes</span> : <span className="badge ok">Sin pendientes</span>}<small>{fila.solicitudes_pendientes} solicitudes · {fila.transferencias_pendientes_recepcion} por recibir<br />{fila.transferencias_pendientes_despacho} por despachar · {fila.conteos_pendientes_revision} conteos</small></td>
                      <td><small>Factura: {fechaVisible(fila.ultima_factura)}<br />Movimiento: {fechaVisible(fila.ultimo_movimiento, true)}<br />Conteo: {fechaVisible(fila.ultimo_conteo, true)}</small></td>
                      <td><Link className="btn-enlace" href="/inventario">Ver inventario</Link></td>
                    </tr>
                  );
                })}
                {!visibles.length && <tr><td colSpan={9} className="vacio">No existen tiendas propias activas que coincidan con la búsqueda.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
