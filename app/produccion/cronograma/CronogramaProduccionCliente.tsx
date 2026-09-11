"use client";

import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import { fecha } from "@/lib/utils";

type PrendaDia = { prenda: string; cantidad: number; capacidad: number; excede: boolean };
type Dia = { fecha: string; contratos: number; total_prendas: number; excede: boolean; prendas: PrendaDia[] };
type Capacidad = { prenda: string; capacidad_dia: number };
type SinDisenador = {
  id: string; numero: string; cliente: string; vendedor: string; estado: string;
  total_prendas: number; fecha_inicio_produccion: string; fecha_entrega: string;
};
type Cronograma = {
  generado_at: string;
  rango: { desde: string; hasta: string };
  capacidad_defecto: number;
  dias: Dia[];
  capacidades: Capacidad[];
  sin_disenador: SinDisenador[];
  disenadores: string[];
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
type PersonaDiseno = {
  id: string;
  nombre: string;
  cargo: string;
  departamento: string;
  disenador: boolean;
  mockup: boolean;
};

const VACIO: Cronograma = {
  generado_at: "",
  rango: { desde: "", hasta: "" },
  capacidad_defecto: 100,
  dias: [],
  capacidades: [],
  sin_disenador: [],
  disenadores: [],
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

export default function CronogramaProduccionCliente({ esAdmin, puedeEditar = false }: { esAdmin: boolean; puedeEditar?: boolean }) {
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
  const [disenadorEdit, setDisenadorEdit] = useState<Record<string, string>>({});
  const [asignando, setAsignando] = useState<string | null>(null);
  const [personalDiseno, setPersonalDiseno] = useState<PersonaDiseno[] | null>(null);

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

  useEffect(() => {
    let vigente = true;
    void supabase.rpc("listar_personal_diseno_v127").then(({ data, error: err }) => {
      if (!vigente) return;
      setPersonalDiseno(!err && Array.isArray(data) ? data as PersonaDiseno[] : null);
    });
    return () => { vigente = false };
  }, [supabase]);

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

  // El motivo va fijo y no se pregunta: aqui el "por que" es siempre el mismo
  // -el contrato entra a produccion sin diseñador- y quien y a quien ya quedan
  // en el evento. Preguntarlo una vez por contrato haria que nadie lo use.
  async function asignarDisenador(c: SinDisenador) {
    const seleccion = (disenadorEdit[c.id] ?? "").trim();
    if (!seleccion) return;
    setAsignando(c.id);
    const llamada = personalDiseno
      ? supabase.rpc("asignar_personal_diseno_v127", {
          p_contrato_id: c.id,
          p_tipo: "disenador",
          p_empleado_id: seleccion,
          p_motivo: "Asignación de diseñador desde el cronograma de producción",
          p_idempotency_key: crypto.randomUUID(),
        })
      : supabase.rpc("guardar_gestion_contrato_v99", {
          p_contrato_id: c.id,
          p_cambios: { disenador: seleccion },
          p_motivo: "Asignación de diseñador desde el cronograma de producción",
          p_idempotency_key: crypto.randomUUID(),
        });
    const { error: err } = await llamada;
    setAsignando(null);
    if (err) {
      await mostrarAvisoDialogo(
        err.message.includes("asignar_personal_diseno_v127")
          ? "Falta instalar v127 en Supabase."
          : err.message,
        "No se pudo asignar el diseñador",
        true,
      );
      return;
    }
    setDisenadorEdit((prev) => ({ ...prev, [c.id]: "" }));
    void cargar();
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
        <div className="header-row">
          <div>
            <h3 style={{ margin: 0 }}>Contratos sin diseñador asignado</h3>
            <p className="conteo">Entran a producción en este rango y todavía no tienen a quién.</p>
          </div>
          <span className="conteo">{datos.sin_disenador.length} contrato(s)</span>
        </div>
        {datos.sin_disenador.length ? (
          <div className="tabla-scroll">
            {!personalDiseno && (
              <datalist id="lista-disenadores">
                {datos.disenadores.map((d) => <option key={d} value={d} />)}
              </datalist>
            )}
            <table>
              <thead>
                <tr>
                  <th>Contrato</th><th>Inicia</th><th>Entrega</th>
                  <th className="num">Prendas</th>
                  {puedeEditar && <th style={{ minWidth: 230 }}>Diseñador</th>}
                </tr>
              </thead>
              <tbody>
                {datos.sin_disenador.map((c) => (
                  <tr key={c.id}>
                    <td>
                      <strong>{c.numero}</strong>
                      <div>{c.cliente}</div>
                      <div className="conteo">{c.vendedor || "Sin vendedor"} · {c.estado}</div>
                    </td>
                    <td>{fecha(c.fecha_inicio_produccion)}</td>
                    <td>{fecha(c.fecha_entrega)}</td>
                    <td className="num">{c.total_prendas}</td>
                    {puedeEditar && (
                      <td>
                        <div className="form-inline">
                          {personalDiseno ? (
                            <select
                              aria-label={`Diseñador para ${c.numero}`}
                              value={disenadorEdit[c.id] ?? ""}
                              onChange={(e) => setDisenadorEdit((prev) => ({ ...prev, [c.id]: e.target.value }))}
                              style={{ minWidth: 190 }}
                            >
                              <option value="">Selecciona de Nómina</option>
                              {(personalDiseno.some((p) => p.disenador)
                                ? personalDiseno.filter((p) => p.disenador)
                                : personalDiseno
                              ).map((p) => (
                                <option key={p.id} value={p.id}>{p.nombre} · {p.cargo || p.departamento}</option>
                              ))}
                            </select>
                          ) : (
                            <input
                              list="lista-disenadores"
                              placeholder="Escribe o elige"
                              value={disenadorEdit[c.id] ?? ""}
                              onChange={(e) => setDisenadorEdit((prev) => ({ ...prev, [c.id]: e.target.value }))}
                              onKeyDown={(e) => { if (e.key === "Enter") void asignarDisenador(c) }}
                              style={{ minWidth: 140 }}
                            />
                          )}
                          <button
                            className="secondary btn-mini"
                            disabled={asignando === c.id || !(disenadorEdit[c.id] ?? "").trim()}
                            onClick={() => void asignarDisenador(c)}
                          >
                            {asignando === c.id ? "Asignando…" : "Asignar"}
                          </button>
                        </div>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="vacio">Todos los contratos del rango tienen diseñador.</div>
        )}
      </div>
    </>
  );
}
