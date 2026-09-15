"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { hoyLocalISO, mensajeError } from "@/app/franquicia/lib";

type FilaRanking = {
  almacen_id: string;
  nombre: string;
  tipo: "franquicia" | "tienda";
  ingresos_total: number;
  egresos_total: number;
  resultado_operativo: number;
  num_ventas: number;
  ticket_promedio: number;
  pct_efectivo: number;
  pct_transferencia: number;
  pct_tarjeta: number;
  pct_otros: number;
  dias_con_actividad: number;
  area_m2: number | null;
  venta_por_dia_abierto: number;
  venta_por_m2: number | null;
  ingresos_periodo_anterior: number;
  variacion_pct: number | null;
};

type Columna = "ingresos_total" | "ticket_promedio" | "resultado_operativo" | "venta_por_dia_abierto" | "venta_por_m2" | "variacion_pct";

const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const entero = new Intl.NumberFormat("es-EC", { maximumFractionDigits: 0 });

function inicioMesLocal() {
  const hoy = new Date();
  return `${hoy.getFullYear()}-${String(hoy.getMonth() + 1).padStart(2, "0")}-01`;
}

function numero(valor: unknown) {
  const n = Number(valor);
  return Number.isFinite(n) ? n : 0;
}

export default function RankingLocalesCliente() {
  const supabase = useMemo(() => createClient(), []);
  const [desde, setDesde] = useState(inicioMesLocal);
  const [hasta, setHasta] = useState(hoyLocalISO);
  const [rango, setRango] = useState({ desde: inicioMesLocal(), hasta: hoyLocalISO() });
  const [busqueda, setBusqueda] = useState("");
  const [filas, setFilas] = useState<FilaRanking[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [orden, setOrden] = useState<Columna>("ingresos_total");
  const [ordenDesc, setOrdenDesc] = useState(true);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const { data, error: fallo } = await supabase.rpc("ranking_locales_v156", {
      p_desde: rango.desde, p_hasta: rango.hasta,
    });
    if (fallo) {
      setError(mensajeError(fallo));
      setFilas([]);
    } else {
      setFilas(((data as FilaRanking[]) ?? []).map((f) => ({
        ...f,
        ingresos_total: numero(f.ingresos_total),
        egresos_total: numero(f.egresos_total),
        resultado_operativo: numero(f.resultado_operativo),
        num_ventas: numero(f.num_ventas),
        ticket_promedio: numero(f.ticket_promedio),
        pct_efectivo: numero(f.pct_efectivo),
        pct_transferencia: numero(f.pct_transferencia),
        pct_tarjeta: numero(f.pct_tarjeta),
        pct_otros: numero(f.pct_otros),
        dias_con_actividad: numero(f.dias_con_actividad),
        area_m2: f.area_m2 == null ? null : numero(f.area_m2),
        venta_por_dia_abierto: numero(f.venta_por_dia_abierto),
        venta_por_m2: f.venta_por_m2 == null ? null : numero(f.venta_por_m2),
        ingresos_periodo_anterior: numero(f.ingresos_periodo_anterior),
        variacion_pct: f.variacion_pct == null ? null : numero(f.variacion_pct),
      })));
    }
    setCargando(false);
  }, [rango, supabase]);

  useEffect(() => { void cargar(); }, [cargar]);

  const sinTamano = useMemo(() => filas.some((f) => f.area_m2 == null), [filas]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    const base = q ? filas.filter((f) => f.nombre.toLocaleLowerCase("es").includes(q)) : filas;
    const factor = ordenDesc ? -1 : 1;
    return [...base].sort((a, b) => {
      const va = a[orden] ?? -Infinity;
      const vb = b[orden] ?? -Infinity;
      return va === vb ? 0 : (va < vb ? -1 : 1) * factor;
    });
  }, [busqueda, filas, orden, ordenDesc]);

  function alternarOrden(col: Columna) {
    if (col === orden) setOrdenDesc((d) => !d);
    else { setOrden(col); setOrdenDesc(true); }
  }

  function aplicarRango() {
    if (!desde || !hasta) return setError("Selecciona las dos fechas del período.");
    if (desde > hasta) return setError("La fecha inicial no puede superar la fecha final.");
    setRango({ desde, hasta });
  }

  function exportar() {
    const datos = visibles.map((f) => ({
      Local: f.nombre, Tipo: f.tipo,
      Ventas: f.num_ventas, "Ticket promedio": f.ticket_promedio,
      Ingresos: f.ingresos_total, Egresos: f.egresos_total,
      "Resultado operativo": f.resultado_operativo,
      "% Efectivo": f.pct_efectivo, "% Transferencia": f.pct_transferencia,
      "% Tarjeta": f.pct_tarjeta, "% Otros": f.pct_otros,
      "Días con actividad": f.dias_con_actividad,
      "Venta por día abierto": f.venta_por_dia_abierto,
      "Área m²": f.area_m2 ?? "", "Venta por m²": f.venta_por_m2 ?? "",
      "Ingresos período anterior": f.ingresos_periodo_anterior,
      "Variación %": f.variacion_pct ?? "",
    }));
    const libro = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(datos), "Ranking");
    XLSX.writeFile(libro, `ranking_locales_${rango.desde}_${rango.hasta}.xlsx`);
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <span className="eyebrow">FRANQUICIAS · v156</span>
          <h1>Ranking de locales</h1>
          <p>Ticket promedio, medios de pago y comparación contra el período anterior, normalizado por días con actividad y tamaño del local.</p>
        </div>
        <button onClick={exportar} disabled={cargando || !visibles.length}>Descargar Excel</button>
      </div>

      <div className="filtros fq-consolidado-filtros">
        <label>Desde<input type="date" value={desde} max={hasta} onChange={(e) => setDesde(e.target.value)} /></label>
        <label>Hasta<input type="date" value={hasta} min={desde} max={hoyLocalISO()} onChange={(e) => setHasta(e.target.value)} /></label>
        <button onClick={aplicarRango} disabled={cargando}>Aplicar período</button>
        <label className="buscador">Buscar local<input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Nombre del local…" /></label>
      </div>

      {error && <div className="error-box">{error}</div>}
      {sinTamano && !cargando && (
        <div className="error-box">Algunos locales no tienen área (m²) configurada — no se les calcula venta por m². Configúrala en Franquicias → Novedades operativas → Configuración.</div>
      )}

      <div className="card">
        <div className="card-titulo-linea">
          <div><h2>Comparativo por local</h2><p>{rango.desde.split("-").reverse().join("/")} al {rango.hasta.split("-").reverse().join("/")} · variación contra un período anterior de igual duración.</p></div>
          <span className="badge ok">{visibles.length} locales</span>
        </div>
        {cargando ? <div className="vacio">Cargando ranking…</div> : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Local</th>
                  <th className="num" onClick={() => alternarOrden("ticket_promedio")} style={{ cursor: "pointer" }}>Ticket prom.</th>
                  <th className="num" onClick={() => alternarOrden("ingresos_total")} style={{ cursor: "pointer" }}>Ingresos</th>
                  <th className="num" onClick={() => alternarOrden("resultado_operativo")} style={{ cursor: "pointer" }}>Resultado</th>
                  <th>Medios de pago</th>
                  <th className="num" onClick={() => alternarOrden("venta_por_dia_abierto")} style={{ cursor: "pointer" }}>Venta/día abierto</th>
                  <th className="num" onClick={() => alternarOrden("venta_por_m2")} style={{ cursor: "pointer" }}>Venta/m²</th>
                  <th className="num" onClick={() => alternarOrden("variacion_pct")} style={{ cursor: "pointer" }}>Vs. período anterior</th>
                </tr>
              </thead>
              <tbody>
                {visibles.map((f) => (
                  <tr key={f.almacen_id}>
                    <td><strong>{f.nombre}</strong><small>{f.tipo === "franquicia" ? "Franquicia" : "Tienda propia"} · {f.num_ventas} ventas · {f.dias_con_actividad} días con actividad</small></td>
                    <td className="num">{dinero.format(f.ticket_promedio)}</td>
                    <td className="num"><strong>{dinero.format(f.ingresos_total)}</strong><small>{dinero.format(f.egresos_total)} egresos</small></td>
                    <td className={`num ${f.resultado_operativo < 0 ? "texto-rojo" : ""}`}>{dinero.format(f.resultado_operativo)}</td>
                    <td><small>Efvo {f.pct_efectivo.toFixed(0)}% · Transf {f.pct_transferencia.toFixed(0)}% · Tarj {f.pct_tarjeta.toFixed(0)}%{f.pct_otros > 0 ? ` · Otros ${f.pct_otros.toFixed(0)}%` : ""}</small></td>
                    <td className="num">{dinero.format(f.venta_por_dia_abierto)}</td>
                    <td className="num">{f.venta_por_m2 != null ? dinero.format(f.venta_por_m2) : <small>Sin área</small>}</td>
                    <td className={`num ${f.variacion_pct == null ? "" : f.variacion_pct < 0 ? "texto-rojo" : ""}`}>
                      {f.variacion_pct == null ? <small>Sin comparación</small> : `${f.variacion_pct > 0 ? "+" : ""}${f.variacion_pct.toFixed(1)}%`}
                    </td>
                  </tr>
                ))}
                {!visibles.length && <tr><td colSpan={8} className="vacio">No hay locales que coincidan con la búsqueda.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
