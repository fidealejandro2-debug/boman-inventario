"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Personal = {
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  area: string | null;
  tipo_contrato: string;
  estado: string;
  fecha_ingreso_real: string;
  fecha_salida: string | null;
  afiliado: boolean | null;
  empresa_afiliacion_id: string | null;
  empresa_afiliacion: string | null;
  fecha_afiliacion: string | null;
  sueldo_declarado: number | null;
  empresa_pagadora_id: string | null;
  empresa_pagadora: string | null;
  sueldo_real: number | null;
  brecha_sueldo: number | null;
  dias_entre_ingreso_y_afiliacion: number | null;
  paga_otro_ruc: boolean | null;
};

type DocPorVencer = {
  documento_id: string;
  empleado_id: string;
  nombre_completo: string;
  tipo: string;
  nombre: string;
  fecha_caducidad: string;
  dias_restantes: number;
};

const dinero = (v: number | null | undefined) =>
  v === null || v === undefined
    ? "—"
    : v.toLocaleString("es-EC", { style: "currency", currency: "USD" });

const soloFecha = (v: string | null) =>
  v ? new Date(v + "T00:00:00").toLocaleDateString("es-EC") : "—";

export default function PersonalTab({ puedeEscribir }: { puedeEscribir: boolean }) {
  const supabase = createClient();
  const [filas, setFilas] = useState<Personal[]>([]);
  const [vencen, setVencen] = useState<DocPorVencer[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [busqueda, setBusqueda] = useState("");
  const [empresa, setEmpresa] = useState("");
  const [afiliacion, setAfiliacion] = useState("");
  const [estado, setEstado] = useState("activo");

  useEffect(() => {
    (async () => {
      setCargando(true);
      const [personal, documentos] = await Promise.all([
        supabase
          .from("vista_personal_vigente")
          .select("*")
          .order("nombre_completo"),
        supabase
          .from("vista_documentos_por_vencer")
          .select("*")
          .order("dias_restantes"),
      ]);

      if (personal.error) setError(personal.error.message);
      else setFilas((personal.data as Personal[]) ?? []);
      // La alerta de caducidades es secundaria: si falla no bloquea la lista.
      if (!documentos.error) setVencen((documentos.data as DocPorVencer[]) ?? []);
      setCargando(false);
    })();
  }, [supabase]);

  const empresas = useMemo(() => {
    const set = new Set<string>();
    filas.forEach((f) => {
      if (f.empresa_afiliacion) set.add(f.empresa_afiliacion);
    });
    return [...set].sort();
  }, [filas]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return filas.filter((f) => {
      if (estado && f.estado !== estado) return false;
      if (empresa && f.empresa_afiliacion !== empresa) return false;
      if (afiliacion === "afiliado" && !f.afiliado) return false;
      if (afiliacion === "no_afiliado" && f.afiliado) return false;
      if (afiliacion === "otro_ruc" && !f.paga_otro_ruc) return false;
      if (!q) return true;
      return (
        f.nombre_completo.toLowerCase().includes(q) ||
        f.identificacion.includes(q) ||
        (f.cargo ?? "").toLowerCase().includes(q)
      );
    });
  }, [filas, busqueda, empresa, afiliacion, estado]);

  const totales = useMemo(
    () =>
      visibles.reduce(
        (acc, f) => ({
          declarado: acc.declarado + (f.sueldo_declarado ?? 0),
          real: acc.real + (f.sueldo_real ?? 0),
          brecha: acc.brecha + (f.brecha_sueldo ?? 0),
          sinAfiliar: acc.sinAfiliar + (f.afiliado ? 0 : 1),
          otroRuc: acc.otroRuc + (f.paga_otro_ruc ? 1 : 0),
        }),
        { declarado: 0, real: 0, brecha: 0, sinAfiliar: 0, otroRuc: 0 }
      ),
    [visibles]
  );

  // Sin afiliación o sin sueldo vigente: no podrán entrar al rol del período.
  const incompletos = useMemo(
    () =>
      filas.filter(
        (f) => f.estado === "activo" && (f.afiliado === null || f.sueldo_real === null)
      ),
    [filas]
  );

  if (cargando) return <p className="ayuda">Cargando personal…</p>;
  if (error) return <p className="error">No se pudo cargar el personal: {error}</p>;

  return (
    <>
      <div className="kpis">
        <div className="kpi">
          <span className="kpi-valor">{visibles.length}</span>
          <span className="kpi-label">Personas</span>
        </div>
        <div className="kpi">
          <span className="kpi-valor">{dinero(totales.real)}</span>
          <span className="kpi-label">Masa salarial real</span>
        </div>
        <div className="kpi">
          <span className="kpi-valor">{dinero(totales.declarado)}</span>
          <span className="kpi-label">Masa declarada</span>
        </div>
        <div className="kpi">
          <span className="kpi-valor">{dinero(totales.brecha)}</span>
          <span className="kpi-label">Brecha mensual</span>
        </div>
        <div className="kpi">
          <span className="kpi-valor">{totales.sinAfiliar}</span>
          <span className="kpi-label">No afiliados</span>
        </div>
        <div className="kpi">
          <span className="kpi-valor">{totales.otroRuc}</span>
          <span className="kpi-label">Paga otro RUC</span>
        </div>
      </div>

      {incompletos.length > 0 && (
        <p className="aviso">
          <strong>{incompletos.length}</strong> persona(s) activa(s) sin afiliación o sin
          sueldo vigente registrado. No entrarán al rol hasta completarlas:{" "}
          {incompletos.slice(0, 5).map((f) => f.nombre_completo).join(", ")}
          {incompletos.length > 5 && ` y ${incompletos.length - 5} más`}.
        </p>
      )}

      {vencen.length > 0 && (
        <p className="aviso">
          <strong>{vencen.length}</strong> documento(s) del expediente vencen en 60 días o
          menos. El más próximo: {vencen[0].nombre} de {vencen[0].nombre_completo} (
          {vencen[0].dias_restantes < 0
            ? `vencido hace ${Math.abs(vencen[0].dias_restantes)} días`
            : `en ${vencen[0].dias_restantes} días`}
          ).
        </p>
      )}

      <div className="filtros">
        <input
          type="search"
          placeholder="Buscar por nombre, cédula o cargo"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <select value={estado} onChange={(e) => setEstado(e.target.value)}>
          <option value="activo">Activos</option>
          <option value="inactivo">Inactivos</option>
          <option value="liquidado">Liquidados</option>
          <option value="">Todos los estados</option>
        </select>
        <select value={empresa} onChange={(e) => setEmpresa(e.target.value)}>
          <option value="">Toda empresa afiliadora</option>
          {empresas.map((e) => (
            <option key={e} value={e}>
              {e}
            </option>
          ))}
        </select>
        <select value={afiliacion} onChange={(e) => setAfiliacion(e.target.value)}>
          <option value="">Afiliados y no afiliados</option>
          <option value="afiliado">Solo afiliados</option>
          <option value="no_afiliado">Solo no afiliados</option>
          <option value="otro_ruc">Paga un RUC distinto al que afilia</option>
        </select>
        <button
          className="btn-secundario"
          onClick={() => {
            setBusqueda("");
            setEmpresa("");
            setAfiliacion("");
            setEstado("activo");
          }}
        >
          Limpiar
        </button>
        <button
          className="btn-secundario"
          onClick={() => exportarCSV("personal_nomina", visibles)}
          disabled={!visibles.length}
        >
          Exportar
        </button>
      </div>

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Cédula</th>
              <th>Nombre</th>
              <th>Cargo</th>
              <th>Ingreso real</th>
              <th>Afiliación</th>
              <th>Afiliado desde</th>
              <th className="num">Declarado</th>
              <th>Paga</th>
              <th className="num">Real</th>
              <th className="num">Brecha</th>
            </tr>
          </thead>
          <tbody>
            {visibles.map((f) => (
              <tr key={f.empleado_id}>
                <td>{f.identificacion}</td>
                <td>{f.nombre_completo}</td>
                <td>{f.cargo ?? "—"}</td>
                <td>{soloFecha(f.fecha_ingreso_real)}</td>
                <td>
                  {f.afiliado === null ? (
                    <span className="badge cero">Sin registrar</span>
                  ) : f.afiliado ? (
                    f.empresa_afiliacion
                  ) : (
                    <span className="badge bajo">No afiliado</span>
                  )}
                </td>
                <td>
                  {soloFecha(f.fecha_afiliacion)}
                  {/* Trabajó antes de constar en el IESS: parte de la brecha. */}
                  {(f.dias_entre_ingreso_y_afiliacion ?? 0) > 0 && (
                    <span className="badge bajo" title="Días trabajados antes de la afiliación">
                      +{f.dias_entre_ingreso_y_afiliacion} d
                    </span>
                  )}
                </td>
                <td className="num">{dinero(f.sueldo_declarado)}</td>
                <td>
                  {f.empresa_pagadora ?? "—"}
                  {f.paga_otro_ruc && (
                    <span className="badge ajuste" title="La empresa que paga no es la que afilia">
                      otro RUC
                    </span>
                  )}
                </td>
                <td className="num">{dinero(f.sueldo_real)}</td>
                <td className="num">
                  {(f.brecha_sueldo ?? 0) > 0 ? (
                    <strong>{dinero(f.brecha_sueldo)}</strong>
                  ) : (
                    dinero(f.brecha_sueldo)
                  )}
                </td>
              </tr>
            ))}
            {!visibles.length && (
              <tr>
                <td colSpan={10} className="vacio">
                  Ningún empleado coincide con los filtros.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {puedeEscribir && (
        <p className="ayuda">
          El alta de personal, los cambios de afiliación y de sueldo se registran con los
          RPC de v26 (<code>guardar_empleado_v26</code>,{" "}
          <code>registrar_afiliacion_v26</code>, <code>registrar_compensacion_v26</code>).
          El formulario de alta entra en la siguiente tanda de la interfaz.
        </p>
      )}
    </>
  );
}
