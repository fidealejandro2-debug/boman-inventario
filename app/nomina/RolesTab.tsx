"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Periodo = {
  periodo_id: string;
  anio: number;
  mes: number;
  estado: string;
  personas: number;
  afiliados: number;
  no_afiliados: number;
  ingresos_reales: number;
  egresos: number;
  neto_a_pagar: number;
  neto_declarado: number;
  brecha_total: number;
  aportes_iess: number;
  costo_empleador_real: number;
};

type LineaRol = {
  rol_linea_id: string;
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  afiliado: boolean;
  empresa_pagadora: string | null;
  dias_laborados: number;
  dias_vacaciones: number;
  dias_ausencia_sin_sueldo: number;
  sueldo_proporcional_real: number;
  valor_horas_extra: number;
  comisiones: number;
  bonos: number;
  total_ingresos_real: number;
  aporte_personal: number;
  anticipos_cuota: number;
  multas: number;
  retencion_judicial: number;
  total_egresos: number;
  neto_real: number;
};

const MESES = [
  "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
];

const dinero = (v: number | null | undefined) =>
  (v ?? 0).toLocaleString("es-EC", { style: "currency", currency: "USD" });

export default function RolesTab() {
  const supabase = createClient();
  const [periodos, setPeriodos] = useState<Periodo[]>([]);
  const [activo, setActivo] = useState<string>("");
  const [lineas, setLineas] = useState<LineaRol[]>([]);
  const [busqueda, setBusqueda] = useState("");
  const [cargando, setCargando] = useState(true);
  const [cargandoLineas, setCargandoLineas] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      setCargando(true);
      const { data, error } = await supabase
        .from("vista_resumen_periodo_nomina_v31")
        .select("*")
        .order("anio", { ascending: false })
        .order("mes", { ascending: false });

      if (error) setError(error.message);
      else {
        const filas = (data as Periodo[]) ?? [];
        setPeriodos(filas);
        if (filas.length) setActivo(filas[0].periodo_id);
      }
      setCargando(false);
    })();
  }, [supabase]);

  useEffect(() => {
    if (!activo) {
      setLineas([]);
      return;
    }
    (async () => {
      setCargandoLineas(true);
      const { data, error } = await supabase
        .from("vista_rol_real_v31")
        .select("*")
        .eq("periodo_id", activo)
        .order("nombre_completo");

      if (error) setError(error.message);
      else setLineas((data as LineaRol[]) ?? []);
      setCargandoLineas(false);
    })();
  }, [supabase, activo]);

  const periodo = periodos.find((p) => p.periodo_id === activo);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return lineas;
    return lineas.filter(
      (l) =>
        l.nombre_completo.toLowerCase().includes(q) ||
        l.identificacion.includes(q)
    );
  }, [lineas, busqueda]);

  if (cargando) return <p className="ayuda">Cargando períodos…</p>;
  if (error) return <p className="error">No se pudieron cargar los roles: {error}</p>;

  if (!periodos.length) {
    return (
      <p className="ayuda">
        Todavía no hay ningún período de nómina. Se abren con{" "}
        <code>abrir_periodo_nomina_v30</code> y se calculan con{" "}
        <code>calcular_rol_v30</code>.
      </p>
    );
  }

  return (
    <>
      <div className="filtros">
        <select value={activo} onChange={(e) => setActivo(e.target.value)}>
          {periodos.map((p) => (
            <option key={p.periodo_id} value={p.periodo_id}>
              {MESES[p.mes - 1]} {p.anio} — {p.estado}
            </option>
          ))}
        </select>
        <input
          type="search"
          placeholder="Buscar persona en el rol"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <button
          className="btn-secundario"
          onClick={() => exportarCSV("rol_real", visibles)}
          disabled={!visibles.length}
        >
          Exportar rol real
        </button>
      </div>

      {periodo && (
        <div className="kpis">
          <div className="kpi">
            <span className="kpi-valor">{periodo.personas}</span>
            <span className="kpi-label">
              Personas ({periodo.no_afiliados} sin afiliar)
            </span>
          </div>
          <div className="kpi">
            <span className="kpi-valor">{dinero(periodo.neto_a_pagar)}</span>
            <span className="kpi-label">Neto a pagar</span>
          </div>
          <div className="kpi">
            <span className="kpi-valor">{dinero(periodo.neto_declarado)}</span>
            <span className="kpi-label">Neto declarado</span>
          </div>
          <div className="kpi">
            <span className="kpi-valor">{dinero(periodo.brecha_total)}</span>
            <span className="kpi-label">Brecha del período</span>
          </div>
          <div className="kpi">
            <span className="kpi-valor">{dinero(periodo.aportes_iess)}</span>
            <span className="kpi-label">Aportes IESS</span>
          </div>
          <div className="kpi">
            <span className="kpi-valor">{dinero(periodo.costo_empleador_real)}</span>
            <span className="kpi-label">Costo empleador real</span>
          </div>
        </div>
      )}

      {periodo?.estado === "cerrado" && (
        <p className="ayuda">
          Período cerrado: es inmutable. Cualquier corrección va como nota de ajuste en un
          período nuevo.
        </p>
      )}

      {cargandoLineas ? (
        <p className="ayuda">Cargando rol…</p>
      ) : (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Cédula</th>
                <th>Nombre</th>
                <th>Paga</th>
                <th className="num">Días</th>
                <th className="num">Sueldo</th>
                <th className="num">Extras</th>
                <th className="num">Comis. y bonos</th>
                <th className="num">Ingresos</th>
                <th className="num">IESS</th>
                <th className="num">Anticipos</th>
                <th className="num">Multas</th>
                <th className="num">Egresos</th>
                <th className="num">Neto</th>
              </tr>
            </thead>
            <tbody>
              {visibles.map((l) => (
                <tr key={l.rol_linea_id}>
                  <td>{l.identificacion}</td>
                  <td>
                    {l.nombre_completo}
                    {!l.afiliado && (
                      <span className="badge bajo" title="No consta en planilla IESS">
                        no afiliado
                      </span>
                    )}
                  </td>
                  <td>{l.empresa_pagadora ?? "—"}</td>
                  <td className="num">{l.dias_laborados}</td>
                  <td className="num">{dinero(l.sueldo_proporcional_real)}</td>
                  <td className="num">{dinero(l.valor_horas_extra)}</td>
                  <td className="num">{dinero(l.comisiones + l.bonos)}</td>
                  <td className="num">{dinero(l.total_ingresos_real)}</td>
                  <td className="num">{dinero(l.aporte_personal)}</td>
                  <td className="num">{dinero(l.anticipos_cuota)}</td>
                  <td className="num">{dinero(l.multas + l.retencion_judicial)}</td>
                  <td className="num">{dinero(l.total_egresos)}</td>
                  <td className="num">
                    <strong>{dinero(l.neto_real)}</strong>
                  </td>
                </tr>
              ))}
              {!visibles.length && (
                <tr>
                  <td colSpan={13} className="vacio">
                    El período no tiene líneas calculadas todavía.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
