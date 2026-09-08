"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fecha } from "@/lib/utils";

type Agrupacion = "dia" | "prenda" | "disenador" | "contrato";

type FilaSimple = { etiqueta: string; contratos: number; prendas: number };
type FilaContrato = {
  etiqueta: string;
  cliente: string;
  vendedor: string;
  disenador: string | null;
  estado: string;
  fecha_inicio_produccion: string | null;
  fecha_entrega: string;
  total_prendas: number;
  prendas: Record<string, number>;
};
type Reporte = {
  agrupado_por: Agrupacion;
  rango: { desde: string; hasta: string };
  total_contratos: number;
  total_prendas: number;
  filas: (FilaSimple | FilaContrato)[];
};

const VACIO: Reporte = { agrupado_por: "dia", rango: { desde: "", hasta: "" }, total_contratos: 0, total_prendas: 0, filas: [] };

const ETIQUETAS_AGRUPACION: Record<Agrupacion, string> = {
  dia: "Día (inicio de producción)",
  prenda: "Prenda",
  disenador: "Diseñador",
  contrato: "Contrato",
};

function isoLocal(d: Date) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function rangoMes() {
  const hoy = new Date();
  return { desde: isoLocal(new Date(hoy.getFullYear(), hoy.getMonth(), 1)), hasta: isoLocal(hoy) };
}
function textoPrendas(prendas: Record<string, number>) {
  return Object.entries(prendas || {}).sort((a, b) => b[1] - a[1]).map(([n, c]) => `${n} ${c}`).join(" · ");
}

export default function ReportesProduccionCliente() {
  const supabase = useMemo(() => createClient(), []);
  const inicial = useMemo(rangoMes, []);
  const [desde, setDesde] = useState(inicial.desde);
  const [hasta, setHasta] = useState(inicial.hasta);
  const [agrupacion, setAgrupacion] = useState<Agrupacion>("dia");
  const [aplicado, setAplicado] = useState({ ...inicial, agrupacion: "dia" as Agrupacion });
  const [datos, setDatos] = useState<Reporte>(VACIO);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const { data, error: err } = await supabase.rpc("reporte_produccion_v98", {
      p_desde: aplicado.desde,
      p_hasta: aplicado.hasta,
      p_agrupar_por: aplicado.agrupacion,
    });
    if (err) {
      setError(err.message.includes("reporte_produccion_v98") ? "Falta instalar v98 en Supabase." : err.message);
    } else {
      setDatos(data as Reporte);
    }
    setCargando(false);
  }, [aplicado, supabase]);

  useEffect(() => {
    void cargar();
  }, [cargar]);

  function aplicar() {
    if (!desde || !hasta || hasta < desde) return;
    setAplicado({ desde, hasta, agrupacion });
  }

  function exportar() {
    if (datos.agrupado_por === "contrato") {
      exportarCSV(
        `reporte_produccion_${aplicado.desde}_${aplicado.hasta}`,
        (datos.filas as FilaContrato[]).map((f) => ({
          Contrato: f.etiqueta,
          Cliente: f.cliente,
          Vendedor: f.vendedor,
          Diseñador: f.disenador ?? "",
          Estado: f.estado,
          Inicio: f.fecha_inicio_produccion ?? "",
          Entrega: f.fecha_entrega,
          Prendas: f.total_prendas,
          Desglose: textoPrendas(f.prendas),
        }))
      );
    } else {
      exportarCSV(
        `reporte_produccion_${datos.agrupado_por}_${aplicado.desde}_${aplicado.hasta}`,
        (datos.filas as FilaSimple[]).map((f) => ({
          [ETIQUETAS_AGRUPACION[datos.agrupado_por]]: f.etiqueta,
          Contratos: f.contratos,
          Prendas: f.prendas,
        }))
      );
    }
  }

  return (
    <>
      <div className="header-row">
        <div>
          <h2 style={{ color: "#1f3864", margin: 0 }}>Reportes de producción</h2>
          <p className="conteo">Producción agrupada por día, prenda, diseñador o contrato, para exportar o imprimir.</p>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <button className="secondary" onClick={() => window.print()}>Imprimir</button>
          <button className="secondary" disabled={!datos.filas.length} onClick={exportar}>Exportar Excel</button>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="field" style={{ display: "flex", gap: 10, alignItems: "flex-end", flexWrap: "wrap" }}>
          <div>
            <label>Desde</label>
            <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} />
          </div>
          <div>
            <label>Hasta</label>
            <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} />
          </div>
          <div>
            <label>Agrupar por</label>
            <select value={agrupacion} onChange={(e) => setAgrupacion(e.target.value as Agrupacion)}>
              {(Object.keys(ETIQUETAS_AGRUPACION) as Agrupacion[]).map((a) => (
                <option key={a} value={a}>{ETIQUETAS_AGRUPACION[a]}</option>
              ))}
            </select>
          </div>
          <button onClick={aplicar}>Aplicar</button>
        </div>
      </div>

      {error && <div className="error-box">{error}</div>}

      <div className="kpis" style={{ marginBottom: 16 }}>
        <div className="kpi"><span className="label">Contratos</span><span className="valor">{datos.total_contratos}</span></div>
        <div className="kpi"><span className="label">Prendas</span><span className="valor">{datos.total_prendas}</span></div>
      </div>

      <div className="card">
        {cargando ? (
          <div className="vacio">Calculando…</div>
        ) : !datos.filas.length ? (
          <div className="vacio">Sin datos en este rango.</div>
        ) : datos.agrupado_por === "contrato" ? (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Contrato</th><th>Cliente</th><th>Vendedor</th><th>Diseñador</th><th>Estado</th>
                  <th>Inicio</th><th>Entrega</th><th className="num">Prendas</th><th>Desglose</th>
                </tr>
              </thead>
              <tbody>
                {(datos.filas as FilaContrato[]).map((f) => (
                  <tr key={f.etiqueta}>
                    <td><strong>{f.etiqueta}</strong></td>
                    <td>{f.cliente}</td>
                    <td>{f.vendedor}</td>
                    <td>{f.disenador || "—"}</td>
                    <td>{f.estado}</td>
                    <td>{f.fecha_inicio_produccion ? fecha(f.fecha_inicio_produccion) : "—"}</td>
                    <td>{fecha(f.fecha_entrega)}</td>
                    <td className="num">{f.total_prendas}</td>
                    <td>{textoPrendas(f.prendas)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>{ETIQUETAS_AGRUPACION[datos.agrupado_por]}</th>
                  <th className="num">Contratos</th>
                  <th className="num">Prendas</th>
                </tr>
              </thead>
              <tbody>
                {(datos.filas as FilaSimple[]).map((f) => (
                  <tr key={f.etiqueta}>
                    <td>{datos.agrupado_por === "dia" ? fecha(f.etiqueta) : f.etiqueta}</td>
                    <td className="num">{f.contratos}</td>
                    <td className="num">{f.prendas}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
