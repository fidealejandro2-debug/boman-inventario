"use client";

import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { fecha } from "@/lib/utils";

type PrendaDia = { prenda: string; cantidad: number; capacidad: number; excede: boolean };
type Dia = { fecha: string; contratos: number; total_prendas: number; excede: boolean; prendas: PrendaDia[] };
type Capacidad = { prenda: string; capacidad_dia: number };
type MockupPendiente = { numero: string; cliente: string; fecha_entrega: string; descripcion: string; url: string };
type Cronograma = {
  generado_at: string;
  rango: { desde: string; hasta: string };
  capacidad_defecto: number;
  dias: Dia[];
  capacidades: Capacidad[];
  mockups_pendientes: MockupPendiente[];
};

type ContratoDia = {
  numero: string;
  cliente: string;
  vendedor: string;
  disenador: string | null;
  estado: string;
  total_prendas: number;
  fecha_entrega: string;
  prendas: Record<string, number>;
};
type DetalleDia = { fecha: string; contratos: ContratoDia[] };

const VACIO: Cronograma = {
  generado_at: "",
  rango: { desde: "", hasta: "" },
  capacidad_defecto: 100,
  dias: [],
  capacidades: [],
  mockups_pendientes: [],
};

function isoLocal(d: Date) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function rangoQuincena() {
  const hoy = new Date();
  const fin = new Date(hoy);
  fin.setDate(fin.getDate() + 13);
  return { desde: isoLocal(hoy), hasta: isoLocal(fin) };
}

export default function CronogramaProduccionCliente({ esAdmin }: { esAdmin: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const inicial = useMemo(rangoQuincena, []);
  const [desde, setDesde] = useState(inicial.desde);
  const [hasta, setHasta] = useState(inicial.hasta);
  const [aplicado, setAplicado] = useState(inicial);
  const [datos, setDatos] = useState<Cronograma>(VACIO);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [diaAbierto, setDiaAbierto] = useState<string | null>(null);
  const [detalle, setDetalle] = useState<DetalleDia | null>(null);
  const [cargandoDetalle, setCargandoDetalle] = useState(false);

  const [capacidadEdit, setCapacidadEdit] = useState<Record<string, string>>({});
  const [guardandoCapacidad, setGuardandoCapacidad] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const { data, error: err } = await supabase.rpc("cronograma_produccion_v96", {
      p_desde: aplicado.desde,
      p_hasta: aplicado.hasta,
    });
    if (err) {
      setError(err.message.includes("cronograma_produccion_v96") ? "Falta instalar v96 en Supabase." : err.message);
    } else {
      setDatos(data as Cronograma);
    }
    setCargando(false);
  }, [aplicado, supabase]);

  useEffect(() => {
    void cargar();
  }, [cargar]);

  function aplicar() {
    if (!desde || !hasta || hasta < desde) return;
    setDiaAbierto(null);
    setAplicado({ desde, hasta });
  }

  async function abrirDia(fechaDia: string) {
    if (diaAbierto === fechaDia) {
      setDiaAbierto(null);
      setDetalle(null);
      return;
    }
    setDiaAbierto(fechaDia);
    setCargandoDetalle(true);
    const { data, error: err } = await supabase.rpc("detalle_dia_produccion_v96", { p_dia: fechaDia });
    if (!err) setDetalle(data as DetalleDia);
    setCargandoDetalle(false);
  }

  async function guardarCapacidad(prenda: string) {
    const valor = Number(capacidadEdit[prenda]);
    if (!Number.isFinite(valor) || valor <= 0) return;
    setGuardandoCapacidad(prenda);
    const { error: err } = await supabase.rpc("guardar_capacidad_produccion_v96", {
      p_prenda: prenda,
      p_capacidad_dia: Math.trunc(valor),
    });
    setGuardandoCapacidad(null);
    if (!err) {
      setCapacidadEdit((prev) => ({ ...prev, [prenda]: "" }));
      void cargar();
    }
  }

  const maxTotalDia = Math.max(1, ...datos.dias.map((d) => d.total_prendas));

  return (
    <>
      <div className="header-row">
        <div>
          <h2 style={{ color: "#1f3864", margin: 0 }}>Cronograma y capacidad</h2>
          <p className="conteo">Carga diaria de producción por prenda, comparada contra la capacidad del taller.</p>
        </div>
        <button onClick={() => void cargar()} disabled={cargando}>{cargando ? "Actualizando…" : "Actualizar"}</button>
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
          <button onClick={aplicar}>Aplicar</button>
        </div>
      </div>

      {error && <div className="error-box">{error}</div>}

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Línea de tiempo</h3>
        {cargando ? (
          <div className="vacio">Calculando…</div>
        ) : datos.dias.length ? (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Día</th>
                  <th className="num">Contratos</th>
                  <th className="num">Prendas</th>
                  <th>Carga</th>
                  <th>Detalle</th>
                </tr>
              </thead>
              <tbody>
                {datos.dias.map((d) => (
                  <Fragment key={d.fecha}>
                    <tr>
                      <td>{fecha(d.fecha)}</td>
                      <td className="num">{d.contratos}</td>
                      <td className="num">{d.total_prendas}</td>
                      <td>
                        <div style={{ background: "#e5e7eb", borderRadius: 4, height: 10, width: 140, overflow: "hidden" }}>
                          <div
                            style={{
                              height: "100%",
                              width: `${Math.max(3, (d.total_prendas * 100) / maxTotalDia)}%`,
                              background: d.excede ? "#dc2626" : "#0f766e",
                            }}
                          />
                        </div>
                        {d.excede && <span className="badge estado-rechazado" style={{ marginLeft: 6 }}>Sobrecarga</span>}
                      </td>
                      <td>
                        <button className="secondary btn-mini" onClick={() => void abrirDia(d.fecha)}>
                          {diaAbierto === d.fecha ? "Ocultar ▲" : "Ver ▼"}
                        </button>
                      </td>
                    </tr>
                    {diaAbierto === d.fecha && (
                      <tr key={`${d.fecha}-detalle`}>
                        <td colSpan={5}>
                          <div style={{ display: "flex", gap: 24, flexWrap: "wrap", margin: "6px 0" }}>
                            <div>
                              <strong>Por prenda</strong>
                              <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
                                {d.prendas.map((p) => (
                                  <li key={p.prenda} style={{ color: p.excede ? "#dc2626" : undefined }}>
                                    {p.prenda}: {p.cantidad} / {p.capacidad}
                                    {esAdmin && (
                                      <span style={{ marginLeft: 8 }}>
                                        <input
                                          type="number"
                                          min={1}
                                          placeholder="nueva capacidad"
                                          value={capacidadEdit[p.prenda] ?? ""}
                                          onChange={(e) => setCapacidadEdit((prev) => ({ ...prev, [p.prenda]: e.target.value }))}
                                          style={{ width: 90 }}
                                        />
                                        <button
                                          className="secondary btn-mini"
                                          disabled={guardandoCapacidad === p.prenda}
                                          onClick={() => void guardarCapacidad(p.prenda)}
                                        >
                                          Guardar
                                        </button>
                                      </span>
                                    )}
                                  </li>
                                ))}
                              </ul>
                            </div>
                            <div>
                              <strong>Contratos del día</strong>
                              {cargandoDetalle ? (
                                <div className="vacio">Cargando…</div>
                              ) : (
                                <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
                                  {(detalle?.contratos ?? []).map((c) => (
                                    <li key={c.numero}>
                                      <strong>{c.numero}</strong> — {c.cliente} · {c.disenador || "sin diseñador"} · {c.total_prendas} prendas
                                    </li>
                                  ))}
                                  {!detalle?.contratos?.length && <li>Sin contratos.</li>}
                                </ul>
                              )}
                            </div>
                          </div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="vacio">No hay contratos con fecha de inicio de producción en este rango.</div>
        )}
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Mockups pendientes de aprobar en el rango</h3>
        {datos.mockups_pendientes.length ? (
          <ul style={{ margin: 0, paddingLeft: 18 }}>
            {datos.mockups_pendientes.map((m, idx) => (
              <li key={`${m.numero}-${idx}`}>
                <strong>{m.numero}</strong> — {m.cliente} · entrega {fecha(m.fecha_entrega)} ·{" "}
                <a href={m.url} target="_blank" rel="noreferrer">{m.descripcion || "ver mockup"}</a>
              </li>
            ))}
          </ul>
        ) : (
          <div className="vacio">Sin mockups pendientes en este rango.</div>
        )}
      </div>
    </>
  );
}
