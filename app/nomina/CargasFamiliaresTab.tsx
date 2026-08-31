"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { hoyISO, mensajeError, soloFecha, type Empleado } from "./lib";
import SelectorDocumento from "./SelectorDocumento";

type CargaFamiliar = {
  id: string;
  empleado_id: string;
  empleado_identificacion: string;
  empleado_nombre: string;
  empleado_estado: string;
  tipo: "conyuge" | "conviviente_union_hecho" | "hijo";
  tipo_identificacion: string;
  identificacion: string | null;
  nombres: string;
  apellidos: string;
  fecha_nacimiento: string | null;
  edad_hoy: number | null;
  tiene_discapacidad: boolean;
  porcentaje_discapacidad: number | null;
  fecha_desde: string;
  fecha_hasta: string | null;
  fecha_acreditacion: string;
  documento_parentesco_id: string;
  documento_parentesco: string;
  documento_discapacidad_id: string | null;
  documento_discapacidad: string | null;
  observacion: string | null;
  vigente_hoy: boolean;
  elegible_utilidades_ejercicio_actual: boolean;
  cumple_18_at: string | null;
};

const ETIQUETA_TIPO: Record<string, string> = {
  conyuge: "Cónyuge",
  conviviente_union_hecho: "Conviviente en unión de hecho",
  hijo: "Hijo/a",
};

const VACIO = {
  id: "",
  empleado_id: "",
  tipo: "hijo" as CargaFamiliar["tipo"],
  tipo_identificacion: "cedula",
  identificacion: "",
  nombres: "",
  apellidos: "",
  fecha_nacimiento: "",
  tiene_discapacidad: false,
  porcentaje_discapacidad: "",
  fecha_desde: hoyISO(),
  fecha_acreditacion: hoyISO(),
  documento_parentesco_id: null as string | null,
  documento_discapacidad_id: null as string | null,
  observacion: "",
};

export default function CargasFamiliaresTab({
  puedeEscribir,
  empleados,
}: {
  puedeEscribir: boolean;
  empleados: Empleado[];
}) {
  const supabase = createClient();
  const [cargas, setCargas] = useState<CargaFamiliar[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [mostrarForm, setMostrarForm] = useState(false);
  const [form, setForm] = useState(VACIO);
  const [busqueda, setBusqueda] = useState("");
  const [filtro, setFiltro] = useState<"vigentes" | "elegibles" | "todas">("vigentes");
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);

  async function cargar() {
    setCargando(true);
    const { data, error: err } = await supabase
      .from("vista_cargas_familiares_v36")
      .select("*")
      .order("empleado_nombre")
      .order("fecha_desde", { ascending: false });
    if (err) setError(err.message);
    else setCargas((data as CargaFamiliar[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    void cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return cargas.filter((c) => {
      if (filtro === "vigentes" && !c.vigente_hoy) return false;
      if (filtro === "elegibles" && !c.elegible_utilidades_ejercicio_actual) return false;
      if (!q) return true;
      return (
        c.empleado_nombre.toLowerCase().includes(q) ||
        c.empleado_identificacion.includes(q) ||
        `${c.apellidos} ${c.nombres}`.toLowerCase().includes(q) ||
        (c.identificacion ?? "").includes(q)
      );
    });
  }, [cargas, filtro, busqueda]);

  const vigentes = cargas.filter((c) => c.vigente_hoy);
  const elegibles = cargas.filter((c) => c.elegible_utilidades_ejercicio_actual);
  const porCumplir18 = vigentes.filter((c) => {
    if (!c.cumple_18_at) return false;
    const dias =
      (new Date(`${c.cumple_18_at.slice(0, 10)}T00:00:00`).getTime() -
        new Date(`${hoyISO()}T00:00:00`).getTime()) /
      86400000;
    return dias >= 0 && dias <= 120;
  });

  function nueva() {
    setForm({ ...VACIO, fecha_desde: hoyISO(), fecha_acreditacion: hoyISO() });
    setMostrarForm(true);
    setError(null);
    setMensaje(null);
  }

  function editar(c: CargaFamiliar) {
    setForm({
      id: c.id,
      empleado_id: c.empleado_id,
      tipo: c.tipo,
      tipo_identificacion: c.tipo_identificacion,
      identificacion: c.identificacion ?? "",
      nombres: c.nombres,
      apellidos: c.apellidos,
      fecha_nacimiento: c.fecha_nacimiento ?? "",
      tiene_discapacidad: c.tiene_discapacidad,
      porcentaje_discapacidad: c.porcentaje_discapacidad?.toString() ?? "",
      fecha_desde: c.fecha_desde,
      fecha_acreditacion: c.fecha_acreditacion,
      documento_parentesco_id: c.documento_parentesco_id,
      documento_discapacidad_id: c.documento_discapacidad_id,
      observacion: c.observacion ?? "",
    });
    setMostrarForm(true);
    setError(null);
    setMensaje(null);
  }

  async function guardar() {
    setError(null);
    setMensaje(null);
    if (!form.empleado_id) return setError("Elige a la persona trabajadora.");
    if (!form.nombres.trim() || !form.apellidos.trim())
      return setError("Nombres y apellidos de la carga son obligatorios.");
    if (form.tipo === "hijo" && !form.fecha_nacimiento)
      return setError("La fecha de nacimiento del hijo es obligatoria.");
    if (form.tipo_identificacion !== "sin_identificacion" && !form.identificacion.trim())
      return setError("Escribe la identificación o marca sin identificación.");
    if (!form.documento_parentesco_id)
      return setError("Selecciona o sube el respaldo de parentesco.");
    if (form.tiene_discapacidad && !form.documento_discapacidad_id)
      return setError("La discapacidad necesita su documento de respaldo.");

    setGuardando(true);
    const { data, error: err } = await supabase.rpc("guardar_carga_familiar_v36", {
      p_carga_id: form.id || null,
      p_empleado_id: form.empleado_id,
      p_tipo: form.tipo,
      p_tipo_identificacion: form.tipo_identificacion,
      p_identificacion:
        form.tipo_identificacion === "sin_identificacion" ? null : form.identificacion,
      p_nombres: form.nombres,
      p_apellidos: form.apellidos,
      p_fecha_nacimiento: form.fecha_nacimiento || null,
      p_tiene_discapacidad: form.tiene_discapacidad,
      p_porcentaje_discapacidad: form.porcentaje_discapacidad
        ? Number(form.porcentaje_discapacidad)
        : null,
      p_fecha_desde: form.fecha_desde,
      p_fecha_acreditacion: form.fecha_acreditacion,
      p_documento_parentesco_id: form.documento_parentesco_id,
      p_documento_discapacidad_id: form.tiene_discapacidad
        ? form.documento_discapacidad_id
        : null,
      p_observacion: form.observacion || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (err) return setError(mensajeError(err));

    const resultado = data as { mensaje?: string } | null;
    setMensaje(resultado?.mensaje ?? "Carga familiar guardada.");
    setMostrarForm(false);
    setForm(VACIO);
    await cargar();
  }

  async function cerrar(c: CargaFamiliar) {
    const fecha = window.prompt(
      "Fecha final de vigencia (AAAA-MM-DD):",
      hoyISO()
    );
    if (!fecha) return;
    const motivo = window.prompt(
      "Motivo del cierre (divorcio, fin de unión, fallecimiento, corrección, etc.):"
    );
    if (!motivo?.trim()) return;

    setGuardando(true);
    setError(null);
    const { error: err } = await supabase.rpc("cerrar_carga_familiar_v36", {
      p_carga_id: c.id,
      p_fecha_hasta: fecha,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (err) return setError(mensajeError(err));
    setMensaje("La vigencia se cerró sin borrar el historial.");
    await cargar();
  }

  if (cargando) return <p className="ayuda">Cargando cargas familiares…</p>;

  return (
    <>
      <p className="ayuda">
        Registra aquí el parentesco acreditado. Para utilidades se consideran el cónyuge
        o conviviente, los hijos menores de 18 años al cierre del ejercicio y los hijos
        con discapacidad de cualquier edad. El sistema conserva cada vigencia.
      </p>

      {error && <p className="error">{error}</p>}
      {mensaje && <p className="ok">{mensaje}</p>}

      <div className="kpis compactos">
        <div className="kpi">
          <span className="label">Cargas vigentes</span>
          <span className="valor">{vigentes.length}</span>
        </div>
        <div className="kpi ok">
          <span className="label">Elegibles para utilidades {hoyISO().slice(0, 4)}</span>
          <span className="valor">{elegibles.length}</span>
        </div>
        <div className={`kpi ${porCumplir18.length ? "alerta" : ""}`}>
          <span className="label">Cumplen 18 en 120 días</span>
          <span className="valor">{porCumplir18.length}</span>
        </div>
      </div>

      <div className="filtros">
        {puedeEscribir && <button onClick={nueva}>Nueva carga familiar</button>}
        <select value={filtro} onChange={(e) => setFiltro(e.target.value as typeof filtro)}>
          <option value="vigentes">Vigentes</option>
          <option value="elegibles">Elegibles para utilidades</option>
          <option value="todas">Todo el historial</option>
        </select>
        <input
          type="search"
          placeholder="Buscar trabajador, familiar o identificación"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
      </div>

      {mostrarForm && puedeEscribir && (
        <div className="card-interna">
          <h4>{form.id ? "Editar carga familiar" : "Nueva carga familiar"}</h4>
          <div className="form-grid">
            <label>
              Persona trabajadora
              <select
                value={form.empleado_id}
                disabled={!!form.id}
                onChange={(e) => setForm({ ...form, empleado_id: e.target.value })}
              >
                <option value="">Selecciona…</option>
                {empleados.map((e) => (
                  <option key={e.empleado_id} value={e.empleado_id}>
                    {e.nombre_completo} · {e.identificacion}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Parentesco
              <select
                value={form.tipo}
                onChange={(e) =>
                  setForm({ ...form, tipo: e.target.value as CargaFamiliar["tipo"] })
                }
              >
                {Object.entries(ETIQUETA_TIPO).map(([valor, etiqueta]) => (
                  <option key={valor} value={valor}>{etiqueta}</option>
                ))}
              </select>
            </label>
            <label>
              Tipo de identificación
              <select
                value={form.tipo_identificacion}
                onChange={(e) =>
                  setForm({
                    ...form,
                    tipo_identificacion: e.target.value,
                    identificacion:
                      e.target.value === "sin_identificacion" ? "" : form.identificacion,
                  })
                }
              >
                <option value="cedula">Cédula</option>
                <option value="pasaporte">Pasaporte</option>
                <option value="partida_nacimiento">Partida de nacimiento</option>
                <option value="otro">Otra identificación</option>
                <option value="sin_identificacion">Sin identificación</option>
              </select>
            </label>
            <label>
              Identificación
              <input
                value={form.identificacion}
                disabled={form.tipo_identificacion === "sin_identificacion"}
                onChange={(e) => setForm({ ...form, identificacion: e.target.value })}
              />
            </label>
            <label>
              Nombres
              <input
                value={form.nombres}
                onChange={(e) => setForm({ ...form, nombres: e.target.value })}
              />
            </label>
            <label>
              Apellidos
              <input
                value={form.apellidos}
                onChange={(e) => setForm({ ...form, apellidos: e.target.value })}
              />
            </label>
            <label>
              Fecha de nacimiento {form.tipo === "hijo" && "*"}
              <input
                type="date"
                max={hoyISO()}
                value={form.fecha_nacimiento}
                onChange={(e) => {
                  const nacimiento = e.target.value;
                  setForm({
                    ...form,
                    fecha_nacimiento: nacimiento,
                    fecha_desde:
                      form.tipo === "hijo" && !form.id ? nacimiento : form.fecha_desde,
                  });
                }}
              />
            </label>
            <label>
              Inicio de vigencia
              <input
                type="date"
                max={hoyISO()}
                value={form.fecha_desde}
                onChange={(e) => setForm({ ...form, fecha_desde: e.target.value })}
              />
              <small>Nacimiento, matrimonio o inicio reconocido de la unión.</small>
            </label>
            <label>
              Fecha de acreditación
              <input
                type="date"
                max={hoyISO()}
                value={form.fecha_acreditacion}
                onChange={(e) => setForm({ ...form, fecha_acreditacion: e.target.value })}
              />
              <small>Fecha real en que la empresa recibió el respaldo.</small>
            </label>
            <label>
              <span>
                <input
                  type="checkbox"
                  checked={form.tiene_discapacidad}
                  onChange={(e) =>
                    setForm({
                      ...form,
                      tiene_discapacidad: e.target.checked,
                      porcentaje_discapacidad: e.target.checked
                        ? form.porcentaje_discapacidad
                        : "",
                      documento_discapacidad_id: e.target.checked
                        ? form.documento_discapacidad_id
                        : null,
                    })
                  }
                />{" "}
                Discapacidad acreditada
              </span>
            </label>
            {form.tiene_discapacidad && (
              <label>
                Porcentaje (opcional)
                <input
                  type="number"
                  min="0.01"
                  max="100"
                  step="0.01"
                  value={form.porcentaje_discapacidad}
                  onChange={(e) =>
                    setForm({ ...form, porcentaje_discapacidad: e.target.value })
                  }
                />
              </label>
            )}
            <label className="ancho-total">
              Observación
              <textarea
                rows={2}
                value={form.observacion}
                onChange={(e) => setForm({ ...form, observacion: e.target.value })}
              />
            </label>
          </div>

          {form.empleado_id && (
            <div className="form-grid">
              <SelectorDocumento
                empleadoId={form.empleado_id}
                valor={form.documento_parentesco_id}
                onCambio={(id) => setForm({ ...form, documento_parentesco_id: id })}
                tipoSugerido="carga_familiar"
                etiqueta="Respaldo de parentesco"
                requerido
              />
              {form.tiene_discapacidad && (
                <SelectorDocumento
                  empleadoId={form.empleado_id}
                  valor={form.documento_discapacidad_id}
                  onCambio={(id) =>
                    setForm({ ...form, documento_discapacidad_id: id })
                  }
                  tipoSugerido="carga_familiar"
                  etiqueta="Respaldo de discapacidad"
                  requerido
                />
              )}
            </div>
          )}

          <div className="filtros">
            <button onClick={guardar} disabled={guardando}>
              {guardando ? "Guardando…" : "Guardar carga familiar"}
            </button>
            <button
              className="secondary"
              onClick={() => setMostrarForm(false)}
              disabled={guardando}
            >
              Cancelar
            </button>
          </div>
        </div>
      )}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Persona trabajadora</th>
              <th>Parentesco</th>
              <th>Carga familiar</th>
              <th>Nacimiento / edad</th>
              <th>Discapacidad</th>
              <th>Acreditación</th>
              <th>Vigencia</th>
              <th>Utilidades</th>
              <th>Respaldos</th>
              {puedeEscribir && <th>Acciones</th>}
            </tr>
          </thead>
          <tbody>
            {visibles.map((c) => (
              <tr key={c.id}>
                <td>
                  {c.empleado_nombre}
                  <small className="ayuda"> {c.empleado_identificacion}</small>
                </td>
                <td>{ETIQUETA_TIPO[c.tipo]}</td>
                <td>
                  {c.apellidos} {c.nombres}
                  <small className="ayuda"> {c.identificacion ?? "sin identificación"}</small>
                </td>
                <td>
                  {soloFecha(c.fecha_nacimiento)}
                  {c.edad_hoy !== null && ` · ${c.edad_hoy} años`}
                </td>
                <td>
                  {c.tiene_discapacidad
                    ? `Sí${c.porcentaje_discapacidad ? ` · ${c.porcentaje_discapacidad}%` : ""}`
                    : "No"}
                </td>
                <td>{soloFecha(c.fecha_acreditacion)}</td>
                <td>
                  <span className={`badge ${c.vigente_hoy ? "ok" : "cero"}`}>
                    {c.vigente_hoy ? "Vigente" : `Hasta ${soloFecha(c.fecha_hasta)}`}
                  </span>
                </td>
                <td>
                  <span
                    className={`badge ${
                      c.elegible_utilidades_ejercicio_actual ? "ok" : "cero"
                    }`}
                  >
                    {c.elegible_utilidades_ejercicio_actual ? "Sí" : "No"}
                  </span>
                </td>
                <td>
                  {c.documento_parentesco}
                  {c.documento_discapacidad && ` · ${c.documento_discapacidad}`}
                </td>
                {puedeEscribir && (
                  <td>
                    {c.vigente_hoy && (
                      <>
                        <button className="btn-mini secondary" onClick={() => editar(c)}>
                          Editar
                        </button>{" "}
                        <button
                          className="btn-mini danger"
                          onClick={() => cerrar(c)}
                          disabled={guardando}
                        >
                          Cerrar vigencia
                        </button>
                      </>
                    )}
                  </td>
                )}
              </tr>
            ))}
            {!visibles.length && (
              <tr>
                <td colSpan={puedeEscribir ? 10 : 9} className="vacio">
                  No hay cargas familiares que coincidan con el filtro.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
