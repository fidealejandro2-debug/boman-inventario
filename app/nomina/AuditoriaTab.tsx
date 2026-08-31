"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV, fecha } from "@/lib/utils";
import { dinero, soloFecha } from "./lib";

type Cambio = {
  id: string;
  created_at: string;
  tabla: string;
  operacion: string;
  campo: string;
  valor_anterior: string | null;
  valor_nuevo: string | null;
  sensible: boolean;
  motivo: string | null;
  identificacion: string | null;
  nombre_completo: string | null;
  usuario: string | null;
  db_usuario: string;
};

type HistorialSueldo = {
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  fecha_desde: string;
  fecha_hasta: string | null;
  sueldo_real: number;
  sueldo_anterior: number | null;
  variacion: number | null;
  empresa_pagadora: string | null;
  motivo_tipo: string | null;
  motivo: string;
  tiene_respaldo: boolean;
  documento_respaldo: string | null;
  registrado_por: string | null;
  registrado_at: string;
};

const ETIQUETA_TABLA: Record<string, string> = {
  empleados: "Personal",
  empleado_compensacion: "Sueldo real",
  empleado_afiliaciones: "Afiliación",
  nomina_parametros: "Parámetros",
};

const ETIQUETA_CAMPO: Record<string, string> = {
  numero_cuenta: "Número de cuenta",
  banco: "Banco",
  tipo_cuenta: "Tipo de cuenta",
  forma_pago: "Forma de pago",
  identificacion: "Identificación",
  sueldo_real: "Sueldo real",
  sueldo_declarado: "Sueldo declarado",
  afiliado: "Afiliado",
  empresa_id: "RUC afiliador",
  empresa_pagadora_id: "Empresa pagadora",
  fecha_afiliacion: "Fecha de afiliación",
  fecha_ingreso_real: "Fecha de ingreso",
  fecha_salida: "Fecha de salida",
  estado: "Estado",
  cargo: "Cargo",
  salario_basico_unificado: "SBU",
};

const ETIQUETA_MOTIVO: Record<string, string> = {
  contratacion: "Contratación",
  aumento_desempeno: "Aumento por desempeño",
  ajuste_sbu: "Ajuste por SBU",
  promocion: "Promoción",
  reestructuracion: "Reestructuración",
  acuerdo_partes: "Acuerdo de partes",
  cambio_pagadora: "Cambio de pagadora",
  reduccion_acordada: "Reducción acordada",
  correccion_error: "Corrección de error",
};

export default function AuditoriaTab() {
  const supabase = createClient();
  const [vista, setVista] = useState<"bitacora" | "sueldos">("sueldos");
  const [cambios, setCambios] = useState<Cambio[]>([]);
  const [historial, setHistorial] = useState<HistorialSueldo[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [soloSensibles, setSoloSensibles] = useState(true);
  const [busqueda, setBusqueda] = useState("");

  useEffect(() => {
    (async () => {
      setCargando(true);
      const [c, h] = await Promise.all([
        supabase
          .from("vista_auditoria_nomina_v32")
          .select("*")
          .order("created_at", { ascending: false })
          .limit(500),
        supabase
          .from("vista_historial_sueldo_v32")
          .select("*")
          .order("nombre_completo")
          .order("fecha_desde", { ascending: false }),
      ]);
      if (c.error) setError(c.error.message);
      else setCambios((c.data as Cambio[]) ?? []);
      if (!h.error) setHistorial((h.data as HistorialSueldo[]) ?? []);
      setCargando(false);
    })();
  }, [supabase]);

  const cambiosVisibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return cambios.filter((c) => {
      if (soloSensibles && !c.sensible) return false;
      if (!q) return true;
      return (
        (c.nombre_completo ?? "").toLowerCase().includes(q) ||
        (c.identificacion ?? "").includes(q) ||
        c.campo.includes(q)
      );
    });
  }, [cambios, soloSensibles, busqueda]);

  const historialVisible = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return historial;
    return historial.filter(
      (h) =>
        h.nombre_completo.toLowerCase().includes(q) || h.identificacion.includes(q)
    );
  }, [historial, busqueda]);

  // Lo que un auditor busca primero: cambios de dinero o de destino del pago
  // que nadie justificó.
  const sinJustificar = cambios.filter(
    (c) => c.sensible && c.operacion === "modificacion" && !c.motivo?.trim()
  );
  const cambiosDeCuenta = cambios.filter(
    (c) => c.campo === "numero_cuenta" && c.operacion === "modificacion"
  );

  if (cargando) return <p className="ayuda">Cargando auditoría…</p>;
  if (error) return <p className="error">No se pudo cargar la auditoría: {error}</p>;

  return (
    <>
      <div className="kpis">
        <div className="kpi">
          <span className="valor">{cambios.filter((c) => c.sensible).length}</span>
          <span className="label">Cambios sensibles</span>
        </div>
        <div className={`kpi ${sinJustificar.length ? "alerta" : ""}`}>
          <span className="valor">{sinJustificar.length}</span>
          <span className="label">Sin justificar</span>
        </div>
        <div className={`kpi ${cambiosDeCuenta.length ? "alerta" : ""}`}>
          <span className="valor">{cambiosDeCuenta.length}</span>
          <span className="label">Cambios de cuenta bancaria</span>
        </div>
      </div>

      {cambiosDeCuenta.length > 0 && (
        <p className="aviso">
          Se registraron <strong>{cambiosDeCuenta.length}</strong> cambio(s) de cuenta
          bancaria. Conviene confirmarlos con la persona antes del siguiente pago.
        </p>
      )}

      <div className="filtros">
        <select value={vista} onChange={(e) => setVista(e.target.value as any)}>
          <option value="sueldos">Historial de sueldos</option>
          <option value="bitacora">Bitácora de cambios</option>
        </select>
        {vista === "bitacora" && (
          <label className="check-inline">
            <input
              type="checkbox"
              checked={soloSensibles}
              onChange={(e) => setSoloSensibles(e.target.checked)}
            />{" "}
            Solo campos sensibles
          </label>
        )}
        <input
          type="search"
          placeholder="Buscar persona o campo"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <button
          className="secondary"
          onClick={() =>
            exportarCSV(
              vista === "sueldos" ? "historial_sueldos" : "auditoria_nomina",
              vista === "sueldos" ? historialVisible : cambiosVisibles
            )
          }
        >
          Exportar
        </button>
      </div>

      {vista === "sueldos" ? (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Persona</th>
                <th>Desde</th>
                <th>Hasta</th>
                <th className="num">Anterior</th>
                <th className="num">Nuevo</th>
                <th className="num">Variación</th>
                <th>Motivo</th>
                <th>Respaldo</th>
                <th>Registró</th>
              </tr>
            </thead>
            <tbody>
              {historialVisible.map((h, i) => (
                <tr key={`${h.empleado_id}-${h.fecha_desde}-${i}`}>
                  <td>{h.nombre_completo}</td>
                  <td>{soloFecha(h.fecha_desde)}</td>
                  <td>{h.fecha_hasta ? soloFecha(h.fecha_hasta) : "vigente"}</td>
                  <td className="num">{dinero(h.sueldo_anterior)}</td>
                  <td className="num">{dinero(h.sueldo_real)}</td>
                  <td className="num">
                    {h.variacion === null ? (
                      "—"
                    ) : (
                      <strong className={h.variacion < 0 ? "negativo" : ""}>
                        {h.variacion > 0 ? "+" : ""}
                        {dinero(h.variacion)}
                      </strong>
                    )}
                  </td>
                  <td>
                    {h.motivo_tipo ? (
                      <>
                        <span className="badge ok">
                          {ETIQUETA_MOTIVO[h.motivo_tipo] ?? h.motivo_tipo}
                        </span>
                        <br />
                      </>
                    ) : (
                      <span className="badge cero" title="Registrado antes de v32">
                        sin tipificar
                      </span>
                    )}
                    <small>{h.motivo}</small>
                  </td>
                  <td>
                    {h.tiene_respaldo ? (
                      <span className="badge ok" title={h.documento_respaldo ?? ""}>
                        sí
                      </span>
                    ) : h.variacion !== null && h.variacion < 0 ? (
                      <span className="badge bajo">falta</span>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td>{h.registrado_por ?? "—"}</td>
                </tr>
              ))}
              {!historialVisible.length && (
                <tr>
                  <td colSpan={9} className="vacio">
                    Sin cambios de sueldo registrados.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Cuándo</th>
                <th>Persona</th>
                <th>Qué</th>
                <th>Campo</th>
                <th>Antes</th>
                <th>Después</th>
                <th>Motivo</th>
                <th>Usuario</th>
              </tr>
            </thead>
            <tbody>
              {cambiosVisibles.map((c) => (
                <tr key={c.id}>
                  <td>{fecha(c.created_at)}</td>
                  <td>{c.nombre_completo ?? "—"}</td>
                  <td>{ETIQUETA_TABLA[c.tabla] ?? c.tabla}</td>
                  <td>
                    {ETIQUETA_CAMPO[c.campo] ?? c.campo}
                    {c.sensible && <span className="badge bajo">sensible</span>}
                  </td>
                  <td>{c.valor_anterior ?? "—"}</td>
                  <td>
                    <strong>{c.valor_nuevo ?? "—"}</strong>
                  </td>
                  <td>
                    {c.motivo ?? (
                      <span className="badge bajo">sin justificar</span>
                    )}
                  </td>
                  <td>
                    {c.usuario ?? <em>{c.db_usuario}</em>}
                  </td>
                </tr>
              ))}
              {!cambiosVisibles.length && (
                <tr>
                  <td colSpan={8} className="vacio">
                    Sin cambios registrados con estos filtros.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}

      <p className="ayuda">
        La bitácora la escribe un trigger de base de datos, no la aplicación: no se puede
        editar ni borrar desde aquí, y registra el cambio aunque se haga directamente
        sobre la base.
      </p>
    </>
  );
}
