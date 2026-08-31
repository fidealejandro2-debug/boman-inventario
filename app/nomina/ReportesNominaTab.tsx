"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Periodo = { periodo_id: string; anio: number; mes: number; estado: string };

type Brecha = {
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  afiliado: boolean;
  empresa_afiliacion: string | null;
  empresa_pagadora: string | null;
  paga_otro_ruc: boolean;
  sueldo_real: number;
  sueldo_declarado: number;
  brecha_sueldo: number;
  brecha_sueldo_pct: number | null;
  neto_real: number;
  neto_declarado: number;
  brecha_neto: number;
  brecha_costo: number;
  dias_entre_ingreso_y_afiliacion: number | null;
};

type CostoEmpresa = {
  empresa: string;
  ruc: string | null;
  personas: number;
  afiliados: number;
  no_afiliados: number;
  masa_declarada: number;
  masa_real: number;
  brecha_masa: number;
  aporte_patronal: number;
  costo_declarado: number;
  costo_real: number;
  brecha_costo: number;
};

type Pagadora = {
  empresa_pagadora: string;
  ruc: string | null;
  personas: number;
  personas_afiliadas_en_otro_ruc: number;
  total_a_pagar: number;
  pagado_por_cuenta_de_otro_ruc: number;
  total_descuentos: number;
  anticipos: number;
  multas: number;
  retencion_judicial: number;
};

type Planilla = {
  ruc: string;
  empresa: string;
  cedula: string;
  nombre_completo: string;
  cargo: string | null;
  dias_laborados: number;
  remuneracion: number;
  aporte_personal: number;
  aporte_patronal: number;
  fondos_reserva: number;
  total_aportes: number;
};

type Reporte = "brecha" | "costo" | "pagadora" | "planilla";

const MESES = [
  "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
];

const dinero = (v: number | null | undefined) =>
  (v ?? 0).toLocaleString("es-EC", { style: "currency", currency: "USD" });

export default function ReportesNominaTab() {
  const supabase = createClient();
  const [periodos, setPeriodos] = useState<Periodo[]>([]);
  const [activo, setActivo] = useState("");
  const [reporte, setReporte] = useState<Reporte>("brecha");

  const [brecha, setBrecha] = useState<Brecha[]>([]);
  const [costo, setCosto] = useState<CostoEmpresa[]>([]);
  const [pagadora, setPagadora] = useState<Pagadora[]>([]);
  const [planilla, setPlanilla] = useState<Planilla[]>([]);

  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data, error } = await supabase
        .from("vista_resumen_periodo_nomina_v31")
        .select("periodo_id, anio, mes, estado")
        .order("anio", { ascending: false })
        .order("mes", { ascending: false });

      if (error) setError(error.message);
      else {
        const filas = (data as Periodo[]) ?? [];
        setPeriodos(filas);
        if (filas.length) setActivo(filas[0].periodo_id);
        else setCargando(false);
      }
    })();
  }, [supabase]);

  const periodo = periodos.find((p) => p.periodo_id === activo);

  useEffect(() => {
    if (!activo || !periodo) return;
    (async () => {
      setCargando(true);
      // La planilla IESS se filtra por año y mes: es la única vista que no
      // expone periodo_id, porque sale hacia afuera identificada por período.
      const [b, c, p, pl] = await Promise.all([
        supabase.from("vista_brecha_nomina_v31").select("*").eq("periodo_id", activo),
        supabase
          .from("vista_costo_empleador_por_empresa_v31")
          .select("*")
          .eq("periodo_id", activo),
        supabase
          .from("vista_pagos_por_empresa_pagadora_v31")
          .select("*")
          .eq("periodo_id", activo),
        supabase
          .from("vista_planilla_iess_v31")
          .select("*")
          .eq("anio", periodo.anio)
          .eq("mes", periodo.mes),
      ]);

      const fallo = b.error ?? c.error ?? p.error ?? pl.error;
      if (fallo) setError(fallo.message);
      else {
        setBrecha((b.data as Brecha[]) ?? []);
        setCosto((c.data as CostoEmpresa[]) ?? []);
        setPagadora((p.data as Pagadora[]) ?? []);
        setPlanilla((pl.data as Planilla[]) ?? []);
        setError(null);
      }
      setCargando(false);
    })();
  }, [supabase, activo, periodo]);

  const brechaOrdenada = useMemo(
    () => [...brecha].sort((a, b) => b.brecha_sueldo - a.brecha_sueldo),
    [brecha]
  );

  const totalPagado = useMemo(
    () => pagadora.reduce((s, p) => s + p.total_a_pagar, 0),
    [pagadora]
  );
  const totalPorCuentaAjena = useMemo(
    () => pagadora.reduce((s, p) => s + p.pagado_por_cuenta_de_otro_ruc, 0),
    [pagadora]
  );

  if (error) return <p className="error">No se pudieron cargar los reportes: {error}</p>;

  if (!periodos.length) {
    return (
      <p className="ayuda">
        Los reportes se construyen sobre los roles calculados. Todavía no hay ningún
        período.
      </p>
    );
  }

  const datosActuales =
    reporte === "brecha"
      ? brechaOrdenada
      : reporte === "costo"
      ? costo
      : reporte === "pagadora"
      ? pagadora
      : planilla;

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
        <select value={reporte} onChange={(e) => setReporte(e.target.value as Reporte)}>
          <option value="brecha">Brecha real vs declarado</option>
          <option value="costo">Costo por RUC afiliador</option>
          <option value="pagadora">Desembolso por RUC pagador</option>
          <option value="planilla">Planilla IESS</option>
        </select>
        <button
          className="btn-secundario"
          onClick={() => exportarCSV(`nomina_${reporte}`, datosActuales as any[])}
          disabled={!datosActuales.length}
        >
          Exportar
        </button>
      </div>

      {cargando ? (
        <p className="ayuda">Cargando reporte…</p>
      ) : reporte === "brecha" ? (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Cédula</th>
                <th>Nombre</th>
                <th>Afilia</th>
                <th>Paga</th>
                <th className="num">Real</th>
                <th className="num">Declarado</th>
                <th className="num">Brecha</th>
                <th className="num">%</th>
                <th className="num">Brecha costo</th>
              </tr>
            </thead>
            <tbody>
              {brechaOrdenada.map((f) => (
                <tr key={f.empleado_id}>
                  <td>{f.identificacion}</td>
                  <td>
                    {f.nombre_completo}
                    {(f.dias_entre_ingreso_y_afiliacion ?? 0) > 0 && (
                      <span
                        className="badge bajo"
                        title="Días trabajados antes de constar en el IESS"
                      >
                        +{f.dias_entre_ingreso_y_afiliacion} d
                      </span>
                    )}
                  </td>
                  <td>
                    {f.afiliado ? (
                      f.empresa_afiliacion
                    ) : (
                      <span className="badge bajo">No afiliado</span>
                    )}
                  </td>
                  <td>
                    {f.empresa_pagadora ?? "—"}
                    {f.paga_otro_ruc && <span className="badge ajuste">otro RUC</span>}
                  </td>
                  <td className="num">{dinero(f.sueldo_real)}</td>
                  <td className="num">{dinero(f.sueldo_declarado)}</td>
                  <td className="num">
                    <strong>{dinero(f.brecha_sueldo)}</strong>
                  </td>
                  <td className="num">
                    {f.brecha_sueldo_pct === null ? "—" : `${f.brecha_sueldo_pct}%`}
                  </td>
                  <td className="num">{dinero(f.brecha_costo)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : reporte === "costo" ? (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Empresa</th>
                <th>RUC</th>
                <th className="num">Personas</th>
                <th className="num">No afiliados</th>
                <th className="num">Masa declarada</th>
                <th className="num">Masa real</th>
                <th className="num">Aporte patronal</th>
                <th className="num">Costo declarado</th>
                <th className="num">Costo real</th>
                <th className="num">Brecha</th>
              </tr>
            </thead>
            <tbody>
              {costo.map((c) => (
                <tr key={c.empresa}>
                  <td>{c.empresa}</td>
                  <td>{c.ruc ?? "—"}</td>
                  <td className="num">{c.personas}</td>
                  <td className="num">{c.no_afiliados}</td>
                  <td className="num">{dinero(c.masa_declarada)}</td>
                  <td className="num">{dinero(c.masa_real)}</td>
                  <td className="num">{dinero(c.aporte_patronal)}</td>
                  <td className="num">{dinero(c.costo_declarado)}</td>
                  <td className="num">{dinero(c.costo_real)}</td>
                  <td className="num">
                    <strong>{dinero(c.brecha_costo)}</strong>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : reporte === "pagadora" ? (
        <>
          <p className="ayuda">
            De {dinero(totalPagado)} desembolsados, {dinero(totalPorCuentaAjena)}{" "}
            corresponden a personas afiliadas en un RUC distinto al que paga.
          </p>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Empresa pagadora</th>
                  <th>RUC</th>
                  <th className="num">Personas</th>
                  <th className="num">Afiliadas en otro RUC</th>
                  <th className="num">Total a pagar</th>
                  <th className="num">Por cuenta de otro RUC</th>
                  <th className="num">Anticipos</th>
                  <th className="num">Multas</th>
                  <th className="num">Ret. judicial</th>
                </tr>
              </thead>
              <tbody>
                {pagadora.map((p) => (
                  <tr key={p.empresa_pagadora}>
                    <td>{p.empresa_pagadora}</td>
                    <td>{p.ruc ?? "—"}</td>
                    <td className="num">{p.personas}</td>
                    <td className="num">{p.personas_afiliadas_en_otro_ruc}</td>
                    <td className="num">
                      <strong>{dinero(p.total_a_pagar)}</strong>
                    </td>
                    <td className="num">{dinero(p.pagado_por_cuenta_de_otro_ruc)}</td>
                    <td className="num">{dinero(p.anticipos)}</td>
                    <td className="num">{dinero(p.multas)}</td>
                    <td className="num">{dinero(p.retencion_judicial)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      ) : (
        <>
          <p className="ayuda">
            Lo único que sale hacia el IESS. Solo afiliados, sobre el sueldo declarado.
          </p>
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>RUC</th>
                  <th>Empresa</th>
                  <th>Cédula</th>
                  <th>Nombre</th>
                  <th className="num">Días</th>
                  <th className="num">Remuneración</th>
                  <th className="num">Aporte personal</th>
                  <th className="num">Aporte patronal</th>
                  <th className="num">Fondos reserva</th>
                  <th className="num">Total aportes</th>
                </tr>
              </thead>
              <tbody>
                {planilla.map((p) => (
                  <tr key={p.ruc + p.cedula}>
                    <td>{p.ruc}</td>
                    <td>{p.empresa}</td>
                    <td>{p.cedula}</td>
                    <td>{p.nombre_completo}</td>
                    <td className="num">{p.dias_laborados}</td>
                    <td className="num">{dinero(p.remuneracion)}</td>
                    <td className="num">{dinero(p.aporte_personal)}</td>
                    <td className="num">{dinero(p.aporte_patronal)}</td>
                    <td className="num">{dinero(p.fondos_reserva)}</td>
                    <td className="num">
                      <strong>{dinero(p.total_aportes)}</strong>
                    </td>
                  </tr>
                ))}
                {!planilla.length && (
                  <tr>
                    <td colSpan={10} className="vacio">
                      La planilla se llena cuando el período está calculado o cerrado.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
