"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { exportarCSV } from "@/lib/utils";
import { dinero, mensajeError, pedirMotivo, type Empresa } from "./lib";

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

// Se lee de la tabla y no de vista_rol_real_v31 porque las novedades
// necesitan `version`: guardar_novedades_rol_v30 la exige para no pisar lo
// que otra sesión haya cambiado mientras tanto.
type Linea = {
  id: string;
  empleado_id: string;
  identificacion: string;
  nombres: string;
  apellidos: string;
  cargo: string | null;
  afiliado: boolean;
  empresa_pagadora_id: string | null;
  version: number;
  dias_laborados: number;
  horas_extra_50: number;
  horas_extra_100: number;
  comisiones: number;
  bonos: number;
  vacaciones_pagadas: number;
  otros_ingresos: number;
  nota_novedades: string | null;
  sueldo_proporcional_real: number;
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

const CAMPOS_NOVEDAD = [
  { clave: "horas_extra_50", etiqueta: "Horas extra 50%" },
  { clave: "horas_extra_100", etiqueta: "Horas extra 100%" },
  { clave: "comisiones", etiqueta: "Comisiones" },
  { clave: "bonos", etiqueta: "Bonos" },
  { clave: "vacaciones_pagadas", etiqueta: "Vacaciones pagadas" },
  { clave: "otros_ingresos", etiqueta: "Otros ingresos" },
] as const;

export default function RolesTab({
  puedeEscribir,
  grupoId,
  empresas,
}: {
  puedeEscribir: boolean;
  grupoId: string;
  empresas: Empresa[];
}) {
  const supabase = createClient();
  const [periodos, setPeriodos] = useState<Periodo[]>([]);
  const [activo, setActivo] = useState<string>("");
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [busqueda, setBusqueda] = useState("");
  const [cargando, setCargando] = useState(true);
  const [cargandoLineas, setCargandoLineas] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [ocupado, setOcupado] = useState(false);

  const hoy = new Date();
  const [nuevo, setNuevo] = useState({
    anio: hoy.getFullYear(),
    mes: hoy.getMonth() + 1,
  });
  const [editando, setEditando] = useState<Linea | null>(null);
  const [form, setForm] = useState<Record<string, string>>({});
  const [empresaNov, setEmpresaNov] = useState("");
  const [notaNov, setNotaNov] = useState("");

  async function cargarPeriodos(seleccionar?: string) {
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
      const destino = seleccionar ?? (filas.length ? filas[0].periodo_id : "");
      setActivo(destino);
    }
    setCargando(false);
  }

  useEffect(() => {
    cargarPeriodos();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function cargarLineas() {
    if (!activo) {
      setLineas([]);
      setCargandoLineas(false);
      return;
    }
    setCargandoLineas(true);
    const { data, error } = await supabase
      .from("nomina_rol_lineas")
      .select(
        "id, empleado_id, identificacion, nombres, apellidos, cargo, afiliado, empresa_pagadora_id, version, dias_laborados, horas_extra_50, horas_extra_100, comisiones, bonos, vacaciones_pagadas, otros_ingresos, nota_novedades, sueldo_proporcional_real, total_ingresos_real, aporte_personal, anticipos_cuota, multas, retencion_judicial, total_egresos, neto_real"
      )
      .eq("periodo_id", activo)
      .order("apellidos");
    if (error) setError(error.message);
    else setLineas((data as Linea[]) ?? []);
    setCargandoLineas(false);
  }

  useEffect(() => {
    cargarLineas();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activo]);

  const periodo = periodos.find((p) => p.periodo_id === activo);

  async function abrirPeriodo() {
    if (!grupoId) return setError("No se pudo determinar el grupo económico.");
    setOcupado(true);
    setError(null);
    const { data, error } = await supabase.rpc("abrir_periodo_nomina_v30", {
      p_grupo_id: grupoId,
      p_anio: nuevo.anio,
      p_mes: nuevo.mes,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setOcupado(false);
    if (error) return setError(mensajeError(error));
    setAviso(
      `Período ${MESES[nuevo.mes - 1]} ${nuevo.anio} abierto con una línea por persona activa. Ahora carga las novedades y calcula.`
    );
    cargarPeriodos((data as any)?.periodo_id ?? (data as any)?.id);
  }

  async function calcular() {
    if (!activo) return;
    setOcupado(true);
    setError(null);
    const { error } = await supabase.rpc("calcular_rol_v30", {
      p_periodo_id: activo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setOcupado(false);
    if (error) return setError(mensajeError(error));
    setAviso("Rol calculado. Revisa los netos antes de cerrar.");
    await cargarPeriodos(activo);
    cargarLineas();
  }

  async function cerrar() {
    const { motivo, error: errMotivo } = pedirMotivo(
      "Motivo del cierre (queda registrado y el período pasa a ser inmutable):"
    );
    if (errMotivo) return setError(errMotivo);
    if (!motivo) return;
    setError(null);
    setOcupado(true);
    const { error } = await supabase.rpc("cerrar_periodo_nomina_v30", {
      p_periodo_id: activo,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setOcupado(false);
    if (error) return setError(mensajeError(error));
    setAviso("Período cerrado. Cualquier corrección va como ajuste en un período nuevo.");
    cargarPeriodos(activo);
  }

  async function reabrir() {
    const { motivo, error: errMotivo } = pedirMotivo("Motivo para reabrir el período:");
    if (errMotivo) return setError(errMotivo);
    if (!motivo) return;
    setError(null);
    setOcupado(true);
    const { error } = await supabase.rpc("reabrir_periodo_nomina_v30", {
      p_periodo_id: activo,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setOcupado(false);
    if (error) return setError(mensajeError(error));
    setAviso("Período reabierto.");
    cargarPeriodos(activo);
  }

  function abrirNovedades(l: Linea) {
    setEditando(l);
    setForm(
      Object.fromEntries(CAMPOS_NOVEDAD.map((c) => [c.clave, String(l[c.clave] ?? 0)]))
    );
    setEmpresaNov(l.empresa_pagadora_id ?? "");
    setNotaNov(l.nota_novedades ?? "");
    setError(null);
  }

  async function guardarNovedades() {
    if (!editando) return;
    setOcupado(true);
    setError(null);
    const datos: Record<string, unknown> = {};
    for (const c of CAMPOS_NOVEDAD) datos[c.clave] = Number(form[c.clave] || 0);
    if (empresaNov) datos.empresa_pagadora_id = empresaNov;
    datos.nota = notaNov;

    const { error } = await supabase.rpc("guardar_novedades_rol_v30", {
      p_rol_linea_id: editando.id,
      p_datos: datos,
      p_version: editando.version,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setOcupado(false);
    if (error) return setError(mensajeError(error));
    setAviso("Novedades guardadas. Vuelve a calcular para que se reflejen en el neto.");
    setEditando(null);
    cargarLineas();
  }

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return lineas;
    return lineas.filter(
      (l) =>
        `${l.apellidos} ${l.nombres}`.toLowerCase().includes(q) ||
        l.identificacion.includes(q)
    );
  }, [lineas, busqueda]);

  const abierto = periodo?.estado === "abierto";
  const calculado = periodo?.estado === "calculado";
  const cerrado = periodo?.estado === "cerrado";

  if (cargando) return <p className="ayuda">Cargando períodos…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      {puedeEscribir && (
        <div className="form-inline">
          <strong>Abrir período:</strong>
          <select
            value={nuevo.mes}
            onChange={(e) => setNuevo({ ...nuevo, mes: Number(e.target.value) })}
          >
            {MESES.map((m, i) => (
              <option key={m} value={i + 1}>
                {m}
              </option>
            ))}
          </select>
          <input
            type="number"
            min="2020"
            max="2100"
            value={nuevo.anio}
            onChange={(e) => setNuevo({ ...nuevo, anio: Number(e.target.value) })}
            style={{ width: 90 }}
          />
          <button onClick={abrirPeriodo} disabled={ocupado || !grupoId}>
            Abrir
          </button>
          <small>
            Crea una línea por persona activa con su sueldo y afiliación congelados.
          </small>
        </div>
      )}

      {!periodos.length ? (
        <p className="ayuda">
          Todavía no hay ningún período. Abre el primero con el formulario de arriba: se
          genera una línea por persona activa, luego cargas las novedades y calculas.
        </p>
      ) : (
        <>
          <div className="filtros">
            <select value={activo} onChange={(e) => setActivo(e.target.value)}>
              {periodos.map((p) => (
                <option key={p.periodo_id} value={p.periodo_id}>
                  {MESES[p.mes - 1]} {p.anio} — {p.estado}
                </option>
              ))}
            </select>
            {puedeEscribir && (abierto || calculado) && (
              <button onClick={calcular} disabled={ocupado}>
                {calculado ? "Recalcular" : "Calcular rol"}
              </button>
            )}
            {puedeEscribir && calculado && (
              <button onClick={cerrar} disabled={ocupado}>
                Cerrar período
              </button>
            )}
            {puedeEscribir && cerrado && (
              <button className="secondary" onClick={reabrir} disabled={ocupado}>
                Reabrir
              </button>
            )}
            <input
              type="search"
              placeholder="Buscar persona en el rol"
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
            />
            <button
              className="secondary"
              onClick={() => exportarCSV("rol_real", visibles)}
              disabled={!visibles.length}
            >
              Exportar
            </button>
          </div>

          {periodo && (
            <div className="kpis">
              <div className="kpi">
                <span className="valor">{periodo.personas}</span>
                <span className="label">
                  Personas ({periodo.no_afiliados} sin afiliar)
                </span>
              </div>
              <div className="kpi">
                <span className="valor">{dinero(periodo.neto_a_pagar)}</span>
                <span className="label">Neto a pagar</span>
              </div>
              <div className="kpi">
                <span className="valor">{dinero(periodo.neto_declarado)}</span>
                <span className="label">Neto declarado</span>
              </div>
              <div className="kpi">
                <span className="valor">{dinero(periodo.brecha_total)}</span>
                <span className="label">Brecha del período</span>
              </div>
              <div className="kpi">
                <span className="valor">{dinero(periodo.aportes_iess)}</span>
                <span className="label">Aportes IESS</span>
              </div>
              <div className="kpi">
                <span className="valor">{dinero(periodo.costo_empleador_real)}</span>
                <span className="label">Costo empleador real</span>
              </div>
            </div>
          )}

          {abierto && (
            <p className="ayuda">
              Período <strong>abierto</strong>: carga las horas extra, comisiones y bonos
              con el botón <em>Novedades</em> de cada fila, y después pulsa{" "}
              <strong>Calcular rol</strong>.
            </p>
          )}
          {cerrado && (
            <p className="ayuda">
              Período <strong>cerrado</strong>: es inmutable. Cualquier corrección va como
              ajuste en un período nuevo.
            </p>
          )}

          {editando && (
            <div className="card-interna">
              <h4>
                Novedades de {editando.apellidos} {editando.nombres}
              </h4>
              <p className="ayuda">
                Son las entradas variables del mes. Al guardar hay que{" "}
                <strong>volver a calcular</strong> para que entren en el neto.
              </p>
              <div className="form-grid">
                {CAMPOS_NOVEDAD.map((c) => (
                  <label key={c.clave}>
                    {c.etiqueta}
                    <input
                      type="number"
                      step="0.01"
                      min="0"
                      value={form[c.clave] ?? "0"}
                      onChange={(e) =>
                        setForm({ ...form, [c.clave]: e.target.value })
                      }
                    />
                  </label>
                ))}
                <label>
                  Empresa que paga
                  <select
                    value={empresaNov}
                    onChange={(e) => setEmpresaNov(e.target.value)}
                  >
                    <option value="">Mantener la actual</option>
                    {empresas.map((e) => (
                      <option key={e.id} value={e.id}>
                        {e.razon_social}
                      </option>
                    ))}
                  </select>
                  <small>Puede diferir del RUC que afilia.</small>
                </label>
                <label className="ancho-total">
                  Nota
                  <input
                    type="text"
                    value={notaNov}
                    onChange={(e) => setNotaNov(e.target.value)}
                  />
                </label>
              </div>
              <div className="filtros">
                <button onClick={guardarNovedades} disabled={ocupado}>
                  {ocupado ? "Guardando…" : "Guardar novedades"}
                </button>
                <button className="secondary" onClick={() => setEditando(null)}>
                  Cancelar
                </button>
              </div>
            </div>
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
                    {puedeEscribir && abierto && <th></th>}
                  </tr>
                </thead>
                <tbody>
                  {visibles.map((l) => (
                    <tr key={l.id}>
                      <td>{l.identificacion}</td>
                      <td>
                        {l.apellidos} {l.nombres}
                        {!l.afiliado && (
                          <span className="badge bajo" title="No consta en planilla IESS">
                            no afiliado
                          </span>
                        )}
                      </td>
                      <td className="num">{l.dias_laborados}</td>
                      <td className="num">{dinero(l.sueldo_proporcional_real)}</td>
                      <td className="num">
                        {l.horas_extra_50 + l.horas_extra_100 > 0
                          ? `${l.horas_extra_50 + l.horas_extra_100} h`
                          : "—"}
                      </td>
                      <td className="num">{dinero(l.comisiones + l.bonos)}</td>
                      <td className="num">{dinero(l.total_ingresos_real)}</td>
                      <td className="num">{dinero(l.aporte_personal)}</td>
                      <td className="num">{dinero(l.anticipos_cuota)}</td>
                      <td className="num">{dinero(l.multas + l.retencion_judicial)}</td>
                      <td className="num">{dinero(l.total_egresos)}</td>
                      <td className="num">
                        <strong>{dinero(l.neto_real)}</strong>
                      </td>
                      {puedeEscribir && abierto && (
                        <td>
                          <button
                            className="btn-mini secondary"
                            onClick={() => abrirNovedades(l)}
                          >
                            Novedades
                          </button>
                        </td>
                      )}
                    </tr>
                  ))}
                  {!visibles.length && (
                    <tr>
                      <td colSpan={puedeEscribir && abierto ? 13 : 12} className="vacio">
                        El período no tiene líneas. Si acabas de abrirlo y sigue vacío,
                        revisa que haya personal activo con afiliación y sueldo vigentes.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </>
  );
}
