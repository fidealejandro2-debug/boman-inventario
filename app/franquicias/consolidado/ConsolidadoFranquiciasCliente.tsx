"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { hoyLocalISO, mensajeError } from "@/app/franquicia/lib";

type FilaConsolidado = {
  franquicia_id: string;
  franquicia_codigo: string;
  franquicia_nombre: string;
  ciudad: string | null;
  empresa_codigo: string;
  empresa_nombre: string;
  almacen_id: string;
  almacen_nombre: string;
  ventas_registradas: number;
  ventas_anuladas: number;
  unidades_vendidas: number;
  total_vendido: number;
  descuentos_otorgados: number;
  ingresos_total: number;
  egresos_total: number;
  resultado_operativo: number;
  ingresos_efectivo: number;
  ingresos_transferencia: number;
  ingresos_tarjeta: number;
  ingresos_otros: number;
  dias_cerrados: number;
  dias_con_diferencia: number;
  diferencia_acumulada: number;
  cierres_pendientes: number;
  cierre_pendiente_mas_antiguo: string | null;
  stock_unidades: number;
  stock_disponible: number;
  valor_inventario: number;
  productos_bajo_minimo: number;
  productos_sin_stock: number;
  unidades_sugeridas_reponer: number;
  solicitudes_pendientes: number;
  transferencias_pendientes_recepcion: number;
  alertas_activas: number;
  ultima_venta: string | null;
  ultimo_cierre: string | null;
};

const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const entero = new Intl.NumberFormat("es-EC", { maximumFractionDigits: 0 });

function inicioMesLocal() {
  const hoy = new Date();
  return `${hoy.getFullYear()}-${String(hoy.getMonth() + 1).padStart(2, "0")}-01`;
}

function fechaVisible(valor: string | null) {
  return valor ? valor.split("-").reverse().join("/") : "—";
}

function numero(valor: unknown) {
  const n = Number(valor);
  return Number.isFinite(n) ? n : 0;
}

export default function ConsolidadoFranquiciasCliente() {
  const supabase = useMemo(() => createClient(), []);
  const [desde, setDesde] = useState(inicioMesLocal);
  const [hasta, setHasta] = useState(hoyLocalISO);
  const [rango, setRango] = useState({ desde: inicioMesLocal(), hasta: hoyLocalISO() });
  const [busqueda, setBusqueda] = useState("");
  const [filas, setFilas] = useState<FilaConsolidado[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const { data, error: fallo } = await supabase.rpc(
      "resumen_consolidado_franquicias_v62",
      { p_desde: rango.desde, p_hasta: rango.hasta }
    );
    if (fallo) {
      setError(mensajeError(fallo));
      setFilas([]);
    } else {
      setFilas(((data as FilaConsolidado[]) ?? []).map((fila) => ({
        ...fila,
        ventas_registradas: numero(fila.ventas_registradas),
        ventas_anuladas: numero(fila.ventas_anuladas),
        unidades_vendidas: numero(fila.unidades_vendidas),
        total_vendido: numero(fila.total_vendido),
        descuentos_otorgados: numero(fila.descuentos_otorgados),
        ingresos_total: numero(fila.ingresos_total),
        egresos_total: numero(fila.egresos_total),
        resultado_operativo: numero(fila.resultado_operativo),
        ingresos_efectivo: numero(fila.ingresos_efectivo),
        ingresos_transferencia: numero(fila.ingresos_transferencia),
        ingresos_tarjeta: numero(fila.ingresos_tarjeta),
        ingresos_otros: numero(fila.ingresos_otros),
        dias_cerrados: numero(fila.dias_cerrados),
        dias_con_diferencia: numero(fila.dias_con_diferencia),
        diferencia_acumulada: numero(fila.diferencia_acumulada),
        cierres_pendientes: numero(fila.cierres_pendientes),
        stock_unidades: numero(fila.stock_unidades),
        stock_disponible: numero(fila.stock_disponible),
        valor_inventario: numero(fila.valor_inventario),
        productos_bajo_minimo: numero(fila.productos_bajo_minimo),
        productos_sin_stock: numero(fila.productos_sin_stock),
        unidades_sugeridas_reponer: numero(fila.unidades_sugeridas_reponer),
        solicitudes_pendientes: numero(fila.solicitudes_pendientes),
        transferencias_pendientes_recepcion: numero(fila.transferencias_pendientes_recepcion),
        alertas_activas: numero(fila.alertas_activas),
      })));
    }
    setCargando(false);
  }, [rango, supabase]);

  useEffect(() => { void cargar(); }, [cargar]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    if (!q) return filas;
    return filas.filter((fila) =>
      `${fila.franquicia_nombre} ${fila.franquicia_codigo} ${fila.ciudad ?? ""} ${fila.empresa_nombre} ${fila.almacen_nombre}`
        .toLocaleLowerCase("es").includes(q)
    );
  }, [busqueda, filas]);

  const totales = useMemo(() => filas.reduce((suma, fila) => ({
    vendido: suma.vendido + fila.total_vendido,
    ventas: suma.ventas + fila.ventas_registradas,
    unidades: suma.unidades + fila.unidades_vendidas,
    ingresos: suma.ingresos + fila.ingresos_total,
    egresos: suma.egresos + fila.egresos_total,
    resultado: suma.resultado + fila.resultado_operativo,
    inventario: suma.inventario + fila.valor_inventario,
    alertas: suma.alertas + fila.alertas_activas + fila.cierres_pendientes,
    efectivo: suma.efectivo + fila.ingresos_efectivo,
    transferencia: suma.transferencia + fila.ingresos_transferencia,
    tarjeta: suma.tarjeta + fila.ingresos_tarjeta,
    otros: suma.otros + fila.ingresos_otros,
  }), {
    vendido: 0, ventas: 0, unidades: 0, ingresos: 0, egresos: 0,
    resultado: 0, inventario: 0, alertas: 0, efectivo: 0,
    transferencia: 0, tarjeta: 0, otros: 0,
  }), [filas]);

  function aplicarRango() {
    if (!desde || !hasta) return setError("Selecciona las dos fechas del período.");
    if (desde > hasta) return setError("La fecha inicial no puede superar la fecha final.");
    setRango({ desde, hasta });
  }

  function exportar() {
    const datos = visibles.map((fila) => ({
      Local: fila.franquicia_nombre,
      Código: fila.franquicia_codigo,
      Ciudad: fila.ciudad ?? "",
      Empresa: fila.empresa_nombre,
      Ventas: fila.ventas_registradas,
      "Total vendido": fila.total_vendido,
      "Unidades vendidas": fila.unidades_vendidas,
      Ingresos: fila.ingresos_total,
      Egresos: fila.egresos_total,
      "Resultado operativo": fila.resultado_operativo,
      "Ingresos efectivo": fila.ingresos_efectivo,
      "Ingresos transferencia": fila.ingresos_transferencia,
      "Ingresos tarjeta": fila.ingresos_tarjeta,
      "Días cerrados": fila.dias_cerrados,
      "Cierres pendientes": fila.cierres_pendientes,
      "Diferencia de caja": fila.diferencia_acumulada,
      "Stock físico": fila.stock_unidades,
      "Stock disponible": fila.stock_disponible,
      "Valor inventario": fila.valor_inventario,
      "Productos bajo mínimo": fila.productos_bajo_minimo,
      "Sugerido reponer": fila.unidades_sugeridas_reponer,
      "Solicitudes pendientes": fila.solicitudes_pendientes,
      "Transferencias por recibir": fila.transferencias_pendientes_recepcion,
    }));
    const libro = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(datos), "Consolidado");
    XLSX.writeFile(libro, `franquicias_${rango.desde}_${rango.hasta}.xlsx`);
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <span className="eyebrow">Franquicias · v62</span>
          <h1>Panel consolidado</h1>
          <p>Compara la operación, caja e inventario de todos los locales desde una sola vista.</p>
        </div>
        <button onClick={exportar} disabled={cargando || !visibles.length}>Descargar Excel</button>
      </div>

      <div className="filtros fq-consolidado-filtros">
        <label>Desde<input type="date" value={desde} max={hasta} onChange={(e) => setDesde(e.target.value)} /></label>
        <label>Hasta<input type="date" value={hasta} min={desde} max={hoyLocalISO()} onChange={(e) => setHasta(e.target.value)} /></label>
        <button onClick={aplicarRango} disabled={cargando}>Aplicar período</button>
        <label className="buscador">Buscar local<input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Nombre, ciudad, empresa…" /></label>
      </div>

      {error && <div className="error-box">{error}</div>}

      <div className="kpis fq-consolidado-kpis">
        <div className="kpi"><span className="valor">{dinero.format(totales.vendido)}</span><span className="label">Total vendido</span><small>{entero.format(totales.ventas)} ventas · {entero.format(totales.unidades)} unidades</small></div>
        <div className="kpi"><span className="valor">{dinero.format(totales.ingresos)}</span><span className="label">Ingresos de caja</span><small>Incluye ventas y otros ingresos</small></div>
        <div className="kpi"><span className="valor">{dinero.format(totales.egresos)}</span><span className="label">Egresos de caja</span><small>Control interno de locales</small></div>
        <div className={`kpi ${totales.resultado < 0 ? "alerta" : "ok"}`}><span className="valor">{dinero.format(totales.resultado)}</span><span className="label">Resultado operativo</span><small>Ingresos menos egresos</small></div>
        <div className="kpi"><span className="valor">{dinero.format(totales.inventario)}</span><span className="label">Inventario actual</span><small>Valorizado a precio de venta</small></div>
        <div className={`kpi ${totales.alertas ? "alerta" : "ok"}`}><span className="valor">{entero.format(totales.alertas)}</span><span className="label">Alertas y cierres</span><small>Atención pendiente hoy</small></div>
      </div>

      <div className="card fq-medios-consolidado">
        <div className="card-titulo-linea"><div><h2>Composición de ingresos</h2><p>Cómo ingresó el dinero en el período seleccionado.</p></div></div>
        <div className="fq-medios-grid">
          {[
            ["Efectivo", totales.efectivo], ["Transferencia", totales.transferencia],
            ["Tarjeta", totales.tarjeta], ["Otros", totales.otros],
          ].map(([etiqueta, valor]) => {
            const monto = Number(valor);
            const porcentaje = totales.ingresos > 0 ? (monto / totales.ingresos) * 100 : 0;
            return <div className="fq-medio" key={String(etiqueta)}><span>{etiqueta}</span><strong>{dinero.format(monto)}</strong><div><i style={{ width: `${Math.min(porcentaje, 100)}%` }} /></div><small>{porcentaje.toFixed(1)}%</small></div>;
          })}
        </div>
      </div>

      <div className="card">
        <div className="card-titulo-linea"><div><h2>Comparativo por local</h2><p>{rango.desde.split("-").reverse().join("/")} al {rango.hasta.split("-").reverse().join("/")} · el inventario y las alertas corresponden al estado actual.</p></div><span className="badge ok">{visibles.length} locales</span></div>
        {cargando ? <div className="vacio">Cargando consolidado…</div> : (
          <div className="tabla-scroll fq-tabla-consolidado">
            <table>
              <thead><tr><th>Local</th><th className="num">Ventas</th><th className="num">Vendido</th><th className="num">Resultado caja</th><th className="num">Stock</th><th className="num">Bajo mínimo</th><th className="num">Por recibir</th><th>Cierres</th><th>Actividad</th><th></th></tr></thead>
              <tbody>
                {visibles.map((fila) => (
                  <tr key={fila.franquicia_id} className={fila.cierres_pendientes || fila.productos_bajo_minimo ? "fila-alerta-suave" : ""}>
                    <td><strong>{fila.franquicia_nombre}</strong><small>{fila.franquicia_codigo} · {fila.ciudad || fila.almacen_nombre}<br />{fila.empresa_nombre}</small></td>
                    <td className="num"><strong>{entero.format(fila.ventas_registradas)}</strong><small>{entero.format(fila.unidades_vendidas)} unidades{fila.ventas_anuladas ? ` · ${fila.ventas_anuladas} anul.` : ""}</small></td>
                    <td className="num"><strong>{dinero.format(fila.total_vendido)}</strong><small>{dinero.format(fila.descuentos_otorgados)} descuentos</small></td>
                    <td className={`num ${fila.resultado_operativo < 0 ? "texto-rojo" : ""}`}><strong>{dinero.format(fila.resultado_operativo)}</strong><small>{dinero.format(fila.ingresos_total)} entra · {dinero.format(fila.egresos_total)} sale</small></td>
                    <td className="num"><strong>{entero.format(fila.stock_unidades)}</strong><small>{entero.format(fila.stock_disponible)} disponible · {dinero.format(fila.valor_inventario)}</small></td>
                    <td className="num">{fila.productos_bajo_minimo ? <span className="badge bajo">{fila.productos_bajo_minimo} SKU</span> : <span className="badge ok">Al día</span>}<small>{entero.format(fila.unidades_sugeridas_reponer)} unidades sugeridas</small></td>
                    <td className="num"><strong>{fila.transferencias_pendientes_recepcion}</strong><small>{fila.solicitudes_pendientes} solicitudes · {fila.alertas_activas} alertas</small></td>
                    <td>{fila.cierres_pendientes ? <span className="badge bajo">{fila.cierres_pendientes} pendientes</span> : <span className="badge ok">Sin pendientes</span>}<small>{fila.cierre_pendiente_mas_antiguo ? `Desde ${fechaVisible(fila.cierre_pendiente_mas_antiguo)}` : `${fila.dias_cerrados} cerrados`}</small></td>
                    <td><small>Venta: {fechaVisible(fila.ultima_venta)}<br />Cierre: {fechaVisible(fila.ultimo_cierre)}</small></td>
                    <td><Link className="btn-enlace" href={`/franquicia?local=${fila.franquicia_id}`}>Revisar</Link></td>
                  </tr>
                ))}
                {!visibles.length && <tr><td colSpan={10} className="vacio">No hay locales que coincidan con la búsqueda.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
