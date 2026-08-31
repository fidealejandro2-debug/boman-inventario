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
  ETIQUETA_ORIGEN_DESCUENTO,
  type Empleado,
  type Empresa,
} from "./lib";

type Anticipo = {
  id: string;
  empleado_id: string;
  identificacion: string;
  apellidos: string;
  nombres: string;
  empresa_pagadora: string;
  fecha: string;
  monto: number;
  motivo: string;
  cuotas: number;
  estado: string;
  saldo: number | null;
};

type Descuento = {
  id: string;
  empleado_id: string;
  identificacion: string;
  apellidos: string;
  nombres: string;
  empresa_acreedora: string | null;
  origen: string;
  descripcion: string;
  monto_total: number;
  monto_aplicado: number;
  saldo: number;
  cuotas_total: number;
  cuotas_pagadas: number;
  monto_cuota: number;
  fecha_inicio: string;
  estado: string;
  prioridad: number;
  cuotas_pendientes: number;
  cuota_pendiente_mas_antigua: string | null;
};

export default function DescuentosTab({
  puedeEscribir,
  empleados,
  empresas,
}: {
  puedeEscribir: boolean;
  empleados: Empleado[];
  empresas: Empresa[];
}) {
  const supabase = createClient();
  const [vista, setVista] = useState<"anticipos" | "descuentos">("anticipos");
  const [anticipos, setAnticipos] = useState<Anticipo[]>([]);
  const [descuentos, setDescuentos] = useState<Descuento[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [busqueda, setBusqueda] = useState("");
  const [mostrarForm, setMostrarForm] = useState(false);

  const [form, setForm] = useState({
    empleado_id: "",
    empresa_pagadora_id: "",
    fecha: hoyISO(),
    monto: "",
    motivo: "",
    cuotas: "1",
  });

  async function cargar() {
    setCargando(true);
    const [a, d] = await Promise.all([
      supabase.from("vista_anticipos_v29").select("*").order("fecha", { ascending: false }),
      supabase
        .from("vista_descuentos_programados_v29")
        .select("*")
        .order("prioridad")
        .order("fecha_inicio", { ascending: false }),
    ]);
    if (a.error) setError(a.error.message);
    else setAnticipos((a.data as Anticipo[]) ?? []);
    if (!d.error) setDescuentos((d.data as Descuento[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!form.empleado_id || form.empresa_pagadora_id) return;
    const emp = empleados.find((e) => e.empleado_id === form.empleado_id);
    if (emp?.empresa_pagadora_id)
      setForm((f) => ({ ...f, empresa_pagadora_id: emp.empresa_pagadora_id! }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form.empleado_id]);

  async function solicitar() {
    if (!form.empleado_id || !form.empresa_pagadora_id)
      return setError("Falta la persona o la empresa que desembolsa.");
    if (!form.motivo.trim()) return setError("El motivo es obligatorio.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("solicitar_anticipo_v29", {
      p_empleado_id: form.empleado_id,
      p_empresa_pagadora_id: form.empresa_pagadora_id,
      p_fecha: form.fecha,
      p_monto: Number(form.monto),
      p_motivo: form.motivo,
      p_cuotas: Number(form.cuotas),
      p_fecha_primera_cuota: null,
      p_documento_respaldo_id: null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Anticipo solicitado.");
    setMostrarForm(false);
    setForm({ ...form, monto: "", motivo: "", cuotas: "1" });
    cargar();
  }

  async function resolverAnticipo(id: string, aprobar: boolean) {
    const motivo = window.prompt(
      aprobar ? "Observación de la aprobación:" : "Motivo del rechazo:"
    );
    if (!aprobar && !motivo?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("resolver_anticipo_v29", {
      p_anticipo_id: id,
      p_aprobar: aprobar,
      p_motivo: motivo || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(aprobar ? "Anticipo aprobado." : "Anticipo rechazado.");
    cargar();
  }

  async function desembolsar(id: string) {
    const forma = window.prompt("Forma de desembolso (transferencia, efectivo, cheque):", "transferencia");
    if (!forma) return;
    const referencia = window.prompt("Referencia del pago (opcional):");
    setGuardando(true);
    const { error } = await supabase.rpc("desembolsar_anticipo_v29", {
      p_anticipo_id: id,
      p_forma_desembolso: forma,
      p_referencia: referencia || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Anticipo desembolsado; su descuento queda programado.");
    cargar();
  }

  async function anularAnticipo(id: string) {
    const motivo = window.prompt("Motivo de la anulación:");
    if (!motivo?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("anular_anticipo_v29", {
      p_anticipo_id: id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Anticipo anulado.");
    cargar();
  }

  async function accionDescuento(id: string, accion: string) {
    const motivo = window.prompt(`Motivo para ${accion} este descuento:`);
    if (!motivo?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("resolver_descuento_programado_v29", {
      p_descuento_id: id,
      p_accion: accion,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Descuento actualizado.");
    cargar();
  }

  const anticiposVisibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return anticipos;
    return anticipos.filter(
      (a) =>
        `${a.apellidos} ${a.nombres}`.toLowerCase().includes(q) ||
        a.identificacion.includes(q)
    );
  }, [anticipos, busqueda]);

  const descuentosVisibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return descuentos;
    return descuentos.filter(
      (d) =>
        `${d.apellidos} ${d.nombres}`.toLowerCase().includes(q) ||
        d.identificacion.includes(q)
    );
  }, [descuentos, busqueda]);

  const saldoVigente = descuentos
    .filter((d) => d.estado === "vigente")
    .reduce((s, d) => s + Number(d.saldo), 0);

  if (cargando) return <p className="ayuda">Cargando anticipos y descuentos…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      <div className="kpis">
        <div className="kpi">
          <span className="valor">
            {anticipos.filter((a) => a.estado === "solicitado").length}
          </span>
          <span className="label">Anticipos por aprobar</span>
        </div>
        <div className="kpi">
          <span className="valor">
            {anticipos.filter((a) => a.estado === "aprobado").length}
          </span>
          <span className="label">Aprobados sin desembolsar</span>
        </div>
        <div className="kpi">
          <span className="valor">{dinero(saldoVigente)}</span>
          <span className="label">Saldo por descontar</span>
        </div>
      </div>

      <div className="filtros">
        <select value={vista} onChange={(e) => setVista(e.target.value as any)}>
          <option value="anticipos">Anticipos</option>
          <option value="descuentos">Descuentos programados</option>
        </select>
        {puedeEscribir && vista === "anticipos" && (
          <button onClick={() => setMostrarForm(!mostrarForm)}>
            {mostrarForm ? "Cancelar" : "Nuevo anticipo"}
          </button>
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
            exportarCSV(
              vista === "anticipos" ? "anticipos" : "descuentos",
              vista === "anticipos" ? anticiposVisibles : descuentosVisibles
            )
          }
        >
          Exportar
        </button>
      </div>

      {mostrarForm && puedeEscribir && vista === "anticipos" && (
        <div className="card-interna">
          <h4>Nuevo anticipo</h4>
          <div className="form-grid">
            <label>
              Persona
              <select
                value={form.empleado_id}
                onChange={(e) => setForm({ ...form, empleado_id: e.target.value })}
              >
                <option value="">Elegir…</option>
                {empleados
                  .filter((e) => e.estado === "activo")
                  .map((e) => (
                    <option key={e.empleado_id} value={e.empleado_id}>
                      {e.nombre_completo}
                    </option>
                  ))}
              </select>
            </label>
            <label>
              Empresa que desembolsa
              <select
                value={form.empresa_pagadora_id}
                onChange={(e) => setForm({ ...form, empresa_pagadora_id: e.target.value })}
              >
                <option value="">Elegir…</option>
                {empresas.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.razon_social}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Fecha
              <input
                type="date"
                value={form.fecha}
                onChange={(e) => setForm({ ...form, fecha: e.target.value })}
              />
            </label>
            <label>
              Monto
              <input
                type="number"
                step="0.01"
                min="0"
                value={form.monto}
                onChange={(e) => setForm({ ...form, monto: e.target.value })}
              />
            </label>
            <label>
              Cuotas
              <input
                type="number"
                min="1"
                value={form.cuotas}
                onChange={(e) => setForm({ ...form, cuotas: e.target.value })}
              />
            </label>
            <label className="ancho-total">
              Motivo
              <input
                type="text"
                value={form.motivo}
                onChange={(e) => setForm({ ...form, motivo: e.target.value })}
              />
            </label>
          </div>
          <button onClick={solicitar} disabled={guardando}>
            Solicitar anticipo
          </button>
        </div>
      )}

      {vista === "anticipos" ? (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Persona</th>
                <th>Desembolsa</th>
                <th>Motivo</th>
                <th className="num">Monto</th>
                <th className="num">Cuotas</th>
                <th className="num">Saldo</th>
                <th>Estado</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {anticiposVisibles.map((a) => (
                <tr key={a.id}>
                  <td>{soloFecha(a.fecha)}</td>
                  <td>
                    {a.apellidos} {a.nombres}
                  </td>
                  <td>{a.empresa_pagadora}</td>
                  <td>{a.motivo}</td>
                  <td className="num">{dinero(a.monto)}</td>
                  <td className="num">{a.cuotas}</td>
                  <td className="num">{a.saldo === null ? "—" : dinero(a.saldo)}</td>
                  <td>
                    <span className={`badge estado-${a.estado}`}>{a.estado}</span>
                  </td>
                  {puedeEscribir && (
                    <td>
                      {a.estado === "solicitado" && (
                        <>
                          <button
                            className="btn-mini"
                            disabled={guardando}
                            onClick={() => resolverAnticipo(a.id, true)}
                          >
                            Aprobar
                          </button>
                          <button
                            className="btn-mini secondary"
                            disabled={guardando}
                            onClick={() => resolverAnticipo(a.id, false)}
                          >
                            Rechazar
                          </button>
                        </>
                      )}
                      {a.estado === "aprobado" && (
                        <button
                          className="btn-mini"
                          disabled={guardando}
                          onClick={() => desembolsar(a.id)}
                        >
                          Desembolsar
                        </button>
                      )}
                      {["solicitado", "aprobado"].includes(a.estado) && (
                        <button
                          className="btn-mini secondary"
                          disabled={guardando}
                          onClick={() => anularAnticipo(a.id)}
                        >
                          Anular
                        </button>
                      )}
                    </td>
                  )}
                </tr>
              ))}
              {!anticiposVisibles.length && (
                <tr>
                  <td colSpan={puedeEscribir ? 9 : 8} className="vacio">
                    Sin anticipos registrados.
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
                <th className="num">Prio.</th>
                <th>Persona</th>
                <th>Origen</th>
                <th>Descripción</th>
                <th className="num">Total</th>
                <th className="num">Aplicado</th>
                <th className="num">Saldo</th>
                <th className="num">Cuota</th>
                <th className="num">Cuotas</th>
                <th>Estado</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {descuentosVisibles.map((d) => (
                <tr key={d.id}>
                  <td className="num">{d.prioridad}</td>
                  <td>
                    {d.apellidos} {d.nombres}
                  </td>
                  <td>
                    {ETIQUETA_ORIGEN_DESCUENTO[d.origen] ?? d.origen}
                    {d.origen === "judicial" && (
                      <span className="badge bajo" title="Se aplica antes que cualquier otro descuento">
                        prioritario
                      </span>
                    )}
                  </td>
                  <td>{d.descripcion}</td>
                  <td className="num">{dinero(d.monto_total)}</td>
                  <td className="num">{dinero(d.monto_aplicado)}</td>
                  <td className="num">
                    <strong>{dinero(d.saldo)}</strong>
                  </td>
                  <td className="num">{dinero(d.monto_cuota)}</td>
                  <td className="num">
                    {d.cuotas_pagadas}/{d.cuotas_total}
                  </td>
                  <td>
                    <span className={`badge estado-${d.estado}`}>{d.estado}</span>
                  </td>
                  {puedeEscribir && (
                    <td>
                      {d.estado === "vigente" && (
                        <>
                          <button
                            className="btn-mini secondary"
                            disabled={guardando}
                            onClick={() => accionDescuento(d.id, "suspender")}
                          >
                            Suspender
                          </button>
                          <button
                            className="btn-mini secondary"
                            disabled={guardando}
                            onClick={() => accionDescuento(d.id, "condonar")}
                          >
                            Condonar
                          </button>
                        </>
                      )}
                      {d.estado === "suspendido" && (
                        <button
                          className="btn-mini"
                          disabled={guardando}
                          onClick={() => accionDescuento(d.id, "reactivar")}
                        >
                          Reactivar
                        </button>
                      )}
                    </td>
                  )}
                </tr>
              ))}
              {!descuentosVisibles.length && (
                <tr>
                  <td colSpan={puedeEscribir ? 11 : 10} className="vacio">
                    Sin descuentos programados.
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
