"use client";

import { useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import {
  mensajeError,
  type Departamento,
  type Empleado,
} from "./lib";

type Props = {
  puedeEscribir: boolean;
  grupoId: string;
  departamentos: Departamento[];
  empleados: Empleado[];
  onCambio: () => Promise<void> | void;
};

const VACIO = {
  departamento_id: "",
  codigo: "",
  nombre: "",
  descripcion: "",
  activo: true,
};

export default function DepartamentosTab({
  puedeEscribir,
  grupoId,
  departamentos,
  empleados,
  onCambio,
}: Props) {
  const supabase = createClient();
  const [form, setForm] = useState(VACIO);
  const [mostrarForm, setMostrarForm] = useState(false);
  const [guardando, setGuardando] = useState(false);
  const [asignando, setAsignando] = useState<string | null>(null);
  const [selecciones, setSelecciones] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [busqueda, setBusqueda] = useState("");

  const ordenados = useMemo(
    () =>
      [...departamentos].sort(
        (a, b) => Number(b.activo) - Number(a.activo) || a.nombre.localeCompare(b.nombre)
      ),
    [departamentos]
  );

  const personas = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return empleados.filter(
      (e) =>
        !q ||
        e.nombre_completo.toLowerCase().includes(q) ||
        e.identificacion.includes(q) ||
        (e.cargo ?? "").toLowerCase().includes(q) ||
        (e.departamento_nombre ?? "").toLowerCase().includes(q)
    );
  }, [empleados, busqueda]);

  function editar(d: Departamento) {
    setForm({
      departamento_id: d.departamento_id,
      codigo: d.codigo,
      nombre: d.nombre,
      descripcion: d.descripcion ?? "",
      activo: d.activo,
    });
    setMostrarForm(true);
    setError(null);
    setMensaje(null);
  }

  async function guardar() {
    setError(null);
    setMensaje(null);
    if (!grupoId) return setError("No se encontro el grupo economico.");
    if (!form.codigo.trim() || !form.nombre.trim())
      return setError("Codigo y nombre son obligatorios.");

    setGuardando(true);
    const { data, error: err } = await supabase.rpc(
      "guardar_departamento_nomina_v34",
      {
        p_departamento_id: form.departamento_id || null,
        p_grupo_id: grupoId,
        p_codigo: form.codigo,
        p_nombre: form.nombre,
        p_descripcion: form.descripcion || null,
        p_activo: form.activo,
        p_idempotency_key: nuevaClaveIdempotencia(),
      }
    );
    setGuardando(false);
    if (err) return setError(mensajeError(err));

    const resultado = data as { mensaje?: string } | null;
    setMensaje(resultado?.mensaje ?? "Departamento guardado correctamente.");
    setForm(VACIO);
    setMostrarForm(false);
    await onCambio();
  }

  async function asignar(empleado: Empleado) {
    const nuevo = selecciones[empleado.empleado_id] ?? empleado.departamento_id ?? "";
    if (nuevo === (empleado.departamento_id ?? "")) return;

    const motivo = window.prompt(
      nuevo ? "Motivo de la asignación o cambio:" : "Motivo para dejarlo sin departamento:",
      "Actualización de estructura organizacional"
    );
    if (motivo === null) return;
    if (!motivo.trim()) return setError("El motivo del cambio es obligatorio.");

    setError(null);
    setMensaje(null);
    setAsignando(empleado.empleado_id);
    const { error: err } = await supabase.rpc(
      "asignar_departamento_empleado_v34",
      {
        p_empleado_id: empleado.empleado_id,
        p_departamento_id: nuevo || null,
        p_motivo: motivo,
        p_idempotency_key: nuevaClaveIdempotencia(),
      }
    );
    setAsignando(null);
    if (err) return setError(mensajeError(err));

    setMensaje(`Departamento actualizado para ${empleado.nombre_completo}.`);
    await onCambio();
  }

  return (
    <>
      <p className="ayuda">
        Los departamentos pertenecen al grupo económico completo, no a un RUC. Cambiar
        el RUC que afilia o paga a una persona no cambia su departamento.
      </p>

      {error && <p className="error">{error}</p>}
      {mensaje && <p className="ok">{mensaje}</p>}

      {puedeEscribir && (
        <div className="filtros">
          <button
            onClick={() => {
              setForm(VACIO);
              setMostrarForm(!mostrarForm);
              setError(null);
            }}
          >
            {mostrarForm ? "Cancelar" : "Nuevo departamento"}
          </button>
        </div>
      )}

      {mostrarForm && puedeEscribir && (
        <div className="card-interna">
          <h4>{form.departamento_id ? "Editar departamento" : "Nuevo departamento"}</h4>
          <div className="form-grid">
            <label>
              Código
              <input
                value={form.codigo}
                maxLength={20}
                onChange={(e) =>
                  setForm({ ...form, codigo: e.target.value.toUpperCase() })
                }
                placeholder="VENTAS"
              />
              <small>Letras, números, guion o guion bajo.</small>
            </label>
            <label>
              Nombre
              <input
                value={form.nombre}
                onChange={(e) => setForm({ ...form, nombre: e.target.value })}
                placeholder="Ventas"
              />
            </label>
            <label className="ancho-total">
              Descripcion
              <textarea
                value={form.descripcion}
                onChange={(e) => setForm({ ...form, descripcion: e.target.value })}
                rows={2}
              />
            </label>
            <label>
              <span>
                <input
                  type="checkbox"
                  checked={form.activo}
                  onChange={(e) => setForm({ ...form, activo: e.target.checked })}
                />{" "}
                Departamento activo
              </span>
              {!form.activo && (
                <small>Solo se puede desactivar cuando no tenga personal activo.</small>
              )}
            </label>
          </div>
          <div className="filtros">
            <button onClick={guardar} disabled={guardando}>
              {guardando ? "Guardando…" : "Guardar departamento"}
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

      <h3>Catálogo</h3>
      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Código</th>
              <th>Departamento</th>
              <th>Descripcion</th>
              <th className="num">Personal activo</th>
              <th>Estado</th>
              {puedeEscribir && <th></th>}
            </tr>
          </thead>
          <tbody>
            {ordenados.map((d) => (
              <tr key={d.departamento_id}>
                <td>{d.codigo}</td>
                <td>{d.nombre}</td>
                <td>{d.descripcion ?? "—"}</td>
                <td className="num">{d.empleados_activos}</td>
                <td>
                  <span className={`badge ${d.activo ? "ok" : "cero"}`}>
                    {d.activo ? "Activo" : "Inactivo"}
                  </span>
                </td>
                {puedeEscribir && (
                  <td>
                    <button className="btn-mini secondary" onClick={() => editar(d)}>
                      Editar
                    </button>
                  </td>
                )}
              </tr>
            ))}
            {!ordenados.length && (
              <tr>
                <td colSpan={puedeEscribir ? 6 : 5} className="vacio">
                  Todavía no hay departamentos. Crea el primero para clasificar al personal.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <h3>Asignación de personal</h3>
      <div className="filtros">
        <input
          type="search"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
          placeholder="Buscar persona, cédula, cargo o departamento"
        />
      </div>
      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Persona</th>
              <th>Cargo</th>
              <th>Departamento actual</th>
              {puedeEscribir && <th>Asignar</th>}
            </tr>
          </thead>
          <tbody>
            {personas.map((e) => {
              const valor = selecciones[e.empleado_id] ?? e.departamento_id ?? "";
              const cambio = valor !== (e.departamento_id ?? "");
              return (
                <tr key={e.empleado_id}>
                  <td>
                    {e.nombre_completo}
                    <small className="ayuda"> {e.identificacion}</small>
                  </td>
                  <td>{e.cargo ?? "—"}</td>
                  <td>{e.departamento_nombre ?? "Sin asignar"}</td>
                  {puedeEscribir && (
                    <td>
                      <select
                        value={valor}
                        onChange={(ev) =>
                          setSelecciones({
                            ...selecciones,
                            [e.empleado_id]: ev.target.value,
                          })
                        }
                      >
                        <option value="">Sin departamento</option>
                        {departamentos
                          .filter((d) => d.activo)
                          .map((d) => (
                            <option key={d.departamento_id} value={d.departamento_id}>
                              {d.nombre}
                            </option>
                          ))}
                      </select>{" "}
                      <button
                        className="btn-mini"
                        disabled={!cambio || asignando === e.empleado_id}
                        onClick={() => asignar(e)}
                      >
                        {asignando === e.empleado_id ? "Guardando…" : "Aplicar"}
                      </button>
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}
