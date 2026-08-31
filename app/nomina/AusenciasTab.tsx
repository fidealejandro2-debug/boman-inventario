"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { exportarCSV } from "@/lib/utils";
import {
  dinero,
  soloFecha,
  hoyISO,
  mensajeError,
  ETIQUETA_AUSENCIA,
  type Empleado,
} from "./lib";
import SelectorDocumento from "./SelectorDocumento";
import CalendarioFeriados from "./CalendarioFeriados";

type Ausencia = {
  id: string;
  empleado_id: string;
  identificacion: string;
  apellidos: string;
  nombres: string;
  tipo: string;
  fecha_desde: string;
  fecha_hasta: string;
  horas: number | null;
  dias_calendario: number;
  dias_habiles: number;
  estado: string;
  observacion: string | null;
  dias_vacaciones_aplicados: number;
  periodos_fifo_usados: number;
};

type Saldo = {
  empleado_id: string;
  identificacion: string;
  apellidos: string;
  nombres: string;
  dias_derecho: number;
  dias_tomados: number;
  dias_saldo: number;
  periodos_con_saldo: number;
  saldo_mas_antiguo_desde: string | null;
  alerta_mas_tres_periodos: boolean;
};

function minutosAtraso(a: Ausencia): number | null {
  const coincidencia = a.observacion?.match(/^\[ATRASO (\d+) MIN\]/);
  return coincidencia ? Number(coincidencia[1]) : null;
}

function observacionVisible(a: Ausencia): string {
  return a.observacion?.replace(/^\[ATRASO \d+ MIN\]\s*/, "") || "—";
}

export default function AusenciasTab({
  puedeEscribir,
  empleados,
  grupoId,
}: {
  puedeEscribir: boolean;
  empleados: Empleado[];
  grupoId: string;
}) {
  const supabase = createClient();
  const [ausencias, setAusencias] = useState<Ausencia[]>([]);
  const [saldos, setSaldos] = useState<Saldo[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);

  const [vista, setVista] = useState<"ausencias" | "saldos">("ausencias");
  const [modoRegistro, setModoRegistro] = useState<"ausencia" | "atraso">("ausencia");
  const [filtroEstado, setFiltroEstado] = useState("solicitada");
  const [busqueda, setBusqueda] = useState("");

  const [form, setForm] = useState({
    empleado_id: "",
    tipo: "vacaciones",
    fecha_desde: hoyISO(),
    fecha_hasta: hoyISO(),
    horas: "",
    minutos_atraso: "",
    observacion: "",
    documento_respaldo_id: null as string | null,
  });

  async function cargar() {
    setCargando(true);
    const [a, s] = await Promise.all([
      supabase
        .from("vista_ausencias_v27")
        .select("*")
        .order("fecha_desde", { ascending: false }),
      supabase.from("vista_saldos_vacaciones_v27").select("*").order("apellidos"),
    ]);
    if (a.error) setError(a.error.message);
    else setAusencias((a.data as Ausencia[]) ?? []);
    if (!s.error) setSaldos((s.data as Saldo[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function solicitar() {
    if (!form.empleado_id) return setError("Elige a la persona.");
    const esAtraso = modoRegistro === "atraso";
    const minutos = Number(form.minutos_atraso);
    if (esAtraso && (!Number.isInteger(minutos) || minutos <= 0 || minutos > 720)) {
      return setError("Los minutos de atraso deben ser un entero entre 1 y 720.");
    }
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("solicitar_ausencia_v27", {
      p_empleado_id: form.empleado_id,
      p_tipo: esAtraso ? "falta_injustificada" : form.tipo,
      p_fecha_desde: form.fecha_desde,
      p_fecha_hasta: esAtraso || form.horas ? form.fecha_desde : form.fecha_hasta,
      p_horas: esAtraso
        ? Number((minutos / 60).toFixed(2))
        : form.horas
          ? Number(form.horas)
          : null,
      p_almacen_id: null,
      p_documento_respaldo_id: form.documento_respaldo_id,
      p_observacion: esAtraso
        ? `[ATRASO ${minutos} MIN] ${form.observacion}`.trim()
        : form.observacion || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(
      esAtraso
        ? "Atraso registrado para aprobación; al aprobarlo se reflejará en el rol del mes."
        : "Ausencia registrada."
    );
    setForm({
      ...form,
      observacion: "",
      horas: "",
      minutos_atraso: "",
      documento_respaldo_id: null,
    });
    cargar();
  }

  async function resolver(id: string, aprobar: boolean) {
    const observacion = window.prompt(
      aprobar ? "Observación de la aprobación (opcional):" : "Motivo del rechazo:"
    );
    if (!aprobar && !observacion?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("resolver_ausencia_v27", {
      p_ausencia_id: id,
      p_aprobar: aprobar,
      p_observacion: observacion || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(aprobar ? "Ausencia aprobada." : "Ausencia rechazada.");
    cargar();
  }

  async function anular(id: string) {
    const motivo = window.prompt("Motivo de la anulación:");
    if (!motivo?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("anular_ausencia_v27", {
      p_ausencia_id: id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Ausencia anulada; los días vacacionales se devolvieron a su período.");
    cargar();
  }

  async function generarPeriodos(empleadoId: string) {
    setGuardando(true);
    // v33: cuenta sobre la antigüedad reconocida del vínculo, no sobre la
    // fecha de ingreso, que cambia en cada reingreso.
    const { error } = await supabase.rpc("generar_periodos_vacaciones_v33", {
      p_empleado_id: empleadoId,
      p_hasta: hoyISO(),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Períodos de vacaciones generados hasta hoy.");
    cargar();
  }

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return ausencias.filter((a) => {
      if (filtroEstado && a.estado !== filtroEstado) return false;
      if (!q) return true;
      return (
        `${a.apellidos} ${a.nombres}`.toLowerCase().includes(q) ||
        a.identificacion.includes(q)
      );
    });
  }, [ausencias, filtroEstado, busqueda]);

  const pendientes = ausencias.filter((a) => a.estado === "solicitada").length;
  const conAlerta = saldos.filter((s) => s.alerta_mas_tres_periodos);

  if (cargando) return <p className="ayuda">Cargando ausencias…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      <CalendarioFeriados grupoId={grupoId} puedeEscribir={puedeEscribir} />

      {conAlerta.length > 0 && (
        <p className="aviso">
          <strong>{conAlerta.length}</strong> persona(s) acumulan más de tres períodos de
          vacaciones sin tomar. Pasado ese límite el derecho más antiguo caduca:{" "}
          {conAlerta.slice(0, 4).map((s) => `${s.apellidos} ${s.nombres}`).join(", ")}
          {conAlerta.length > 4 && ` y ${conAlerta.length - 4} más`}.
        </p>
      )}

      {puedeEscribir && (
        <div className="form-inline">
          <select
            value={form.empleado_id}
            onChange={(e) => setForm({ ...form, empleado_id: e.target.value })}
          >
            <option value="">Persona…</option>
            {empleados
              .filter((e) => e.estado === "activo")
              .map((e) => (
                <option key={e.empleado_id} value={e.empleado_id}>
                  {e.nombre_completo}
                </option>
              ))}
          </select>
          <select
            value={modoRegistro}
            onChange={(e) =>
              setModoRegistro(e.target.value as "ausencia" | "atraso")
            }
          >
            <option value="ausencia">Ausencia o permiso</option>
            <option value="atraso">Atraso injustificado</option>
          </select>
          {modoRegistro === "ausencia" && (
            <select
              value={form.tipo}
              onChange={(e) => setForm({ ...form, tipo: e.target.value })}
            >
              {Object.entries(ETIQUETA_AUSENCIA).map(([k, v]) => (
                <option key={k} value={k}>
                  {v}
                </option>
              ))}
            </select>
          )}
          <input
            type="date"
            value={form.fecha_desde}
            onChange={(e) => setForm({ ...form, fecha_desde: e.target.value })}
          />
          {modoRegistro === "ausencia" ? (
            <>
              <input
                type="date"
                value={form.fecha_hasta}
                disabled={!!form.horas}
                onChange={(e) => setForm({ ...form, fecha_hasta: e.target.value })}
              />
              <input
                type="number"
                step="0.5"
                min="0"
                placeholder="Horas (permiso parcial)"
                value={form.horas}
                // Un permiso por horas es de un solo día: v27 lo exige.
                disabled={form.tipo === "vacaciones"}
                onChange={(e) => setForm({ ...form, horas: e.target.value })}
              />
            </>
          ) : (
            <input
              type="number"
              step="1"
              min="1"
              max="720"
              placeholder="Minutos de atraso"
              value={form.minutos_atraso}
              onChange={(e) => setForm({ ...form, minutos_atraso: e.target.value })}
            />
          )}
          <input
            type="text"
            placeholder="Observación"
            value={form.observacion}
            onChange={(e) => setForm({ ...form, observacion: e.target.value })}
          />
          <button onClick={solicitar} disabled={guardando}>
            Registrar
          </button>
          {/* El certificado médico o el permiso firmado justifican la ausencia. */}
          {form.empleado_id && (
            <SelectorDocumento
              empleadoId={form.empleado_id}
              valor={form.documento_respaldo_id}
              onCambio={(id) => setForm({ ...form, documento_respaldo_id: id })}
              tipoSugerido={modoRegistro === "atraso" ? "otro" : "certificado_medico"}
              etiqueta={modoRegistro === "atraso" ? "Respaldo del atraso (opcional)" : "Justificante"}
            />
          )}
        </div>
      )}

      <p className="ayuda">
        Las ausencias sin sueldo y los atrasos aprobados se asignan al mes de su fecha y
        reducen únicamente el tiempo no trabajado. No generan una multa adicional automática.
      </p>

      <div className="filtros">
        <select value={vista} onChange={(e) => setVista(e.target.value as any)}>
          <option value="ausencias">Ausencias ({pendientes} por resolver)</option>
          <option value="saldos">Saldos de vacaciones</option>
        </select>
        {vista === "ausencias" && (
          <select value={filtroEstado} onChange={(e) => setFiltroEstado(e.target.value)}>
            <option value="solicitada">Solicitadas</option>
            <option value="aprobada">Aprobadas</option>
            <option value="rechazada">Rechazadas</option>
            <option value="anulada">Anuladas</option>
            <option value="">Todas</option>
          </select>
        )}
        <input
          type="search"
          placeholder="Buscar persona"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <button
          className="secondary"
          onClick={() =>
            exportarCSV(vista === "ausencias" ? "ausencias" : "saldos_vacaciones",
              vista === "ausencias" ? visibles : saldos)
          }
        >
          Exportar
        </button>
      </div>

      {vista === "ausencias" ? (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Persona</th>
                <th>Tipo</th>
                <th>Desde</th>
                <th>Hasta</th>
                <th className="num">Días</th>
                <th className="num">Hábiles</th>
                <th>Estado</th>
                <th>Observación</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {visibles.map((a) => (
                <tr key={a.id}>
                  <td>
                    {a.apellidos} {a.nombres}
                  </td>
                  <td>
                    {minutosAtraso(a) !== null
                      ? "Atraso injustificado"
                      : ETIQUETA_AUSENCIA[a.tipo] ?? a.tipo}
                    {a.periodos_fifo_usados > 1 && (
                      <span className="badge ajuste" title="Consumió más de un período de vacaciones">
                        {a.periodos_fifo_usados} períodos
                      </span>
                    )}
                  </td>
                  <td>{soloFecha(a.fecha_desde)}</td>
                  <td>
                    {minutosAtraso(a) !== null
                      ? `${minutosAtraso(a)} min`
                      : a.horas
                        ? `${a.horas} h`
                        : soloFecha(a.fecha_hasta)}
                  </td>
                  <td className="num">{a.dias_calendario}</td>
                  <td className="num">{a.dias_habiles}</td>
                  <td>
                    <span className={`badge estado-${a.estado}`}>{a.estado}</span>
                  </td>
                  <td>{observacionVisible(a)}</td>
                  {puedeEscribir && (
                    <td>
                      {a.estado === "solicitada" && (
                        <>
                          <button
                            className="btn-mini"
                            disabled={guardando}
                            onClick={() => resolver(a.id, true)}
                          >
                            Aprobar
                          </button>
                          <button
                            className="btn-mini secondary"
                            disabled={guardando}
                            onClick={() => resolver(a.id, false)}
                          >
                            Rechazar
                          </button>
                        </>
                      )}
                      {a.estado === "aprobada" && (
                        <button
                          className="btn-mini secondary"
                          disabled={guardando}
                          onClick={() => anular(a.id)}
                        >
                          Anular
                        </button>
                      )}
                    </td>
                  )}
                </tr>
              ))}
              {!visibles.length && (
                <tr>
                  <td colSpan={puedeEscribir ? 9 : 8} className="vacio">
                    Sin ausencias que coincidan.
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
                <th>Persona</th>
                <th className="num">Derecho</th>
                <th className="num">Tomados</th>
                <th className="num">Saldo</th>
                <th className="num">Períodos</th>
                <th>Más antiguo</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {saldos.map((s) => (
                <tr key={s.empleado_id}>
                  <td>
                    {s.apellidos} {s.nombres}
                    {s.alerta_mas_tres_periodos && (
                      <span className="badge bajo" title="Más de tres períodos acumulados">
                        acumula
                      </span>
                    )}
                  </td>
                  <td className="num">{s.dias_derecho}</td>
                  <td className="num">{s.dias_tomados}</td>
                  <td className="num">
                    <strong>{s.dias_saldo}</strong>
                  </td>
                  <td className="num">{s.periodos_con_saldo}</td>
                  <td>{soloFecha(s.saldo_mas_antiguo_desde)}</td>
                  {puedeEscribir && (
                    <td>
                      <button
                        className="btn-mini secondary"
                        disabled={guardando}
                        onClick={() => generarPeriodos(s.empleado_id)}
                        title="Crea los períodos por aniversario que falten hasta hoy"
                      >
                        Generar períodos
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
