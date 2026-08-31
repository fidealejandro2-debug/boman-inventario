"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";
import { soloFecha, hoyISO, mensajeError } from "./lib";

type Reingresable = {
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  estado: string;
  vinculos: number;
  ultimo_ingreso: string;
  ultima_salida: string;
  tipo_salida: string | null;
  liquidado: boolean;
  dias_fuera: number;
  puede_conservar_antiguedad: boolean;
  antiguedad_previa: string;
};

type Vinculo = {
  vinculo_id: string;
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  secuencia: number;
  tipo_vinculo: string;
  fecha_ingreso: string;
  fecha_salida: string | null;
  antiguedad_desde: string;
  vigente: boolean;
  tipo_salida: string | null;
  motivo_salida: string | null;
  liquidado: boolean;
  anios_antiguedad: number;
  dias_antiguedad_reconocida: number | null;
  acta_finiquito: string | null;
};

const ETIQUETA_VINCULO: Record<string, string> = {
  inicial: "Vínculo inicial",
  reingreso_continuidad: "Reingreso con antigüedad",
  reingreso_nueva_relacion: "Reingreso desde cero",
};

const ETIQUETA_SALIDA: Record<string, string> = {
  renuncia: "Renuncia",
  despido: "Despido",
  visto_bueno: "Visto bueno",
  fin_contrato: "Fin de contrato",
  abandono: "Abandono",
  mutuo_acuerdo: "Mutuo acuerdo",
};

export default function VinculosTab({ puedeEscribir }: { puedeEscribir: boolean }) {
  const supabase = createClient();
  const [vista, setVista] = useState<"reingresables" | "historial">("reingresables");
  const [reingresables, setReingresables] = useState<Reingresable[]>([]);
  const [vinculos, setVinculos] = useState<Vinculo[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [busqueda, setBusqueda] = useState("");
  const [reingresando, setReingresando] = useState<Reingresable | null>(null);

  const [form, setForm] = useState({
    fecha_ingreso: hoyISO(),
    respeta_antiguedad: false,
    motivo: "",
    cargo: "",
  });

  async function cargar() {
    setCargando(true);
    const [r, v] = await Promise.all([
      supabase.from("vista_reingresables_v33").select("*").order("ultima_salida", { ascending: false }),
      supabase
        .from("vista_vinculos_empleado_v33")
        .select("*")
        .order("nombre_completo")
        .order("secuencia", { ascending: false }),
    ]);
    if (r.error) setError(r.error.message);
    else setReingresables((r.data as Reingresable[]) ?? []);
    if (!v.error) setVinculos((v.data as Vinculo[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function abrirReingreso(r: Reingresable) {
    setReingresando(r);
    setForm({
      fecha_ingreso: hoyISO(),
      // Con finiquito pagado la antigüedad ya se liquidó y no puede conservarse.
      respeta_antiguedad: r.puede_conservar_antiguedad,
      motivo: "",
      cargo: r.cargo ?? "",
    });
    setError(null);
  }

  async function confirmarReingreso() {
    if (!reingresando) return;
    if (!form.motivo.trim()) return setError("El motivo del reingreso es obligatorio.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_reingreso_v33", {
      p_empleado_id: reingresando.empleado_id,
      p_fecha_ingreso: form.fecha_ingreso,
      p_respeta_antiguedad: form.respeta_antiguedad,
      p_motivo: form.motivo,
      p_cargo: form.cargo || null,
      p_documento_ingreso_id: null,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(
      `${reingresando.nombre_completo} reingresó. Ahora registra su afiliación y su sueldo en la pestaña Personal.`
    );
    setReingresando(null);
    cargar();
  }

  async function registrarSalida(empleadoId: string, nombre: string) {
    const tipo = window.prompt(
      "Tipo de salida: renuncia, despido, visto_bueno, fin_contrato, abandono o mutuo_acuerdo",
      "renuncia"
    );
    if (!tipo) return;
    const motivo = window.prompt(`Motivo de la salida de ${nombre}:`);
    if (!motivo?.trim()) return;
    const fecha = window.prompt("Fecha de salida (AAAA-MM-DD):", hoyISO());
    if (!fecha) return;
    const liquidado = window.confirm(
      "¿Se le pagó finiquito?\n\nAceptar = sí, se liquidó (al volver, la antigüedad arranca de cero).\nCancelar = no se liquidó (al volver puede conservar su antigüedad)."
    );
    if (liquidado) {
      window.alert(
        "Un finiquito pagado exige adjuntar el acta. Cárgala primero en el expediente y vuelve a intentarlo."
      );
      return;
    }

    setGuardando(true);
    const { error } = await supabase.rpc("registrar_salida_v33", {
      p_empleado_id: empleadoId,
      p_fecha_salida: fecha,
      p_tipo_salida: tipo,
      p_motivo: motivo,
      p_liquidado: false,
      p_documento_finiquito_id: null,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Salida registrada. La afiliación y el sueldo quedaron cerrados en esa fecha.");
    cargar();
  }

  const reingresablesVisibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return reingresables;
    return reingresables.filter(
      (r) => r.nombre_completo.toLowerCase().includes(q) || r.identificacion.includes(q)
    );
  }, [reingresables, busqueda]);

  const vinculosVisibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return vinculos;
    return vinculos.filter(
      (v) => v.nombre_completo.toLowerCase().includes(q) || v.identificacion.includes(q)
    );
  }, [vinculos, busqueda]);

  const conVarios = vinculos.filter((v) => v.secuencia > 1).length;

  if (cargando) return <p className="ayuda">Cargando vínculos…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      <p className="ayuda">
        Cuando alguien deja de venir y vuelve hay dos casos distintos. Si{" "}
        <strong>nunca se liquidó</strong>, no es un reingreso: es una ausencia, y se
        registra en la pestaña de Ausencias como permiso sin sueldo o falta injustificada.
        Si <strong>hubo salida formal</strong>, se reincorpora desde aquí y la persona
        conserva su expediente, su historial disciplinario y el de sueldos.
      </p>

      <div className="kpis">
        <div className="kpi">
          <span className="valor">{reingresables.length}</span>
          <span className="label">Salieron y pueden volver</span>
        </div>
        <div className="kpi">
          <span className="valor">{conVarios}</span>
          <span className="label">Reingresos registrados</span>
        </div>
        <div className="kpi">
          <span className="valor">
            {reingresables.filter((r) => r.puede_conservar_antiguedad).length}
          </span>
          <span className="label">Sin liquidar (conservan antigüedad)</span>
        </div>
      </div>

      {reingresando && (
        <div className="card-interna">
          <h4>Reingreso de {reingresando.nombre_completo}</h4>
          <p className="ayuda">
            Salió el {soloFecha(reingresando.ultima_salida)} (
            {ETIQUETA_SALIDA[reingresando.tipo_salida ?? ""] ?? reingresando.tipo_salida}),
            hace {reingresando.dias_fuera} días.{" "}
            {reingresando.liquidado
              ? "Se le pagó finiquito, así que la antigüedad ya se liquidó y arranca de cero."
              : "No se le pagó finiquito, así que puede conservar su antigüedad."}
          </p>
          <div className="form-grid">
            <label>
              Fecha de reingreso
              <input
                type="date"
                value={form.fecha_ingreso}
                max={hoyISO()}
                onChange={(e) => setForm({ ...form, fecha_ingreso: e.target.value })}
              />
            </label>
            <label>
              Cargo
              <input
                type="text"
                value={form.cargo}
                onChange={(e) => setForm({ ...form, cargo: e.target.value })}
              />
            </label>
            <label>
              <input
                type="checkbox"
                checked={form.respeta_antiguedad}
                disabled={reingresando.liquidado}
                onChange={(e) =>
                  setForm({ ...form, respeta_antiguedad: e.target.checked })
                }
              />{" "}
              Conserva la antigüedad anterior
              <small>
                {reingresando.liquidado
                  ? "No disponible: el finiquito ya cerró la antigüedad."
                  : `Contaría desde ${soloFecha(reingresando.antiguedad_previa)} para vacaciones y décimos.`}
              </small>
            </label>
            <label className="ancho-total">
              Motivo del reingreso
              <input
                type="text"
                value={form.motivo}
                onChange={(e) => setForm({ ...form, motivo: e.target.value })}
              />
            </label>
          </div>
          <div className="filtros">
            <button onClick={confirmarReingreso} disabled={guardando}>
              {guardando ? "Registrando…" : "Confirmar reingreso"}
            </button>
            <button className="secondary" onClick={() => setReingresando(null)}>
              Cancelar
            </button>
          </div>
        </div>
      )}

      <div className="filtros">
        <select value={vista} onChange={(e) => setVista(e.target.value as any)}>
          <option value="reingresables">Personal que salió</option>
          <option value="historial">Historial de vínculos</option>
        </select>
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
              vista === "reingresables" ? "personal_salido" : "vinculos_laborales",
              vista === "reingresables" ? reingresablesVisibles : vinculosVisibles
            )
          }
        >
          Exportar
        </button>
      </div>

      {vista === "reingresables" ? (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Persona</th>
                <th>Cargo</th>
                <th>Salió</th>
                <th>Motivo</th>
                <th className="num">Días fuera</th>
                <th>Finiquito</th>
                <th>Antigüedad</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {reingresablesVisibles.map((r) => (
                <tr key={r.empleado_id}>
                  <td>{r.nombre_completo}</td>
                  <td>{r.cargo ?? "—"}</td>
                  <td>{soloFecha(r.ultima_salida)}</td>
                  <td>{ETIQUETA_SALIDA[r.tipo_salida ?? ""] ?? r.tipo_salida ?? "—"}</td>
                  <td className="num">{r.dias_fuera}</td>
                  <td>
                    {r.liquidado ? (
                      <span className="badge ok">pagado</span>
                    ) : (
                      <span className="badge bajo">sin liquidar</span>
                    )}
                  </td>
                  <td>
                    {r.puede_conservar_antiguedad
                      ? `puede conservar desde ${soloFecha(r.antiguedad_previa)}`
                      : "arranca de cero"}
                  </td>
                  {puedeEscribir && (
                    <td>
                      <button
                        className="btn-mini"
                        disabled={guardando}
                        onClick={() => abrirReingreso(r)}
                      >
                        Reingresar
                      </button>
                    </td>
                  )}
                </tr>
              ))}
              {!reingresablesVisibles.length && (
                <tr>
                  <td colSpan={puedeEscribir ? 8 : 7} className="vacio">
                    Nadie ha salido todavía.
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
                <th className="num">#</th>
                <th>Tipo</th>
                <th>Ingreso</th>
                <th>Salida</th>
                <th>Antigüedad desde</th>
                <th className="num">Años</th>
                <th>Estado</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {vinculosVisibles.map((v) => (
                <tr key={v.vinculo_id}>
                  <td>{v.nombre_completo}</td>
                  <td className="num">{v.secuencia}</td>
                  <td>
                    {ETIQUETA_VINCULO[v.tipo_vinculo] ?? v.tipo_vinculo}
                    {v.dias_antiguedad_reconocida ? (
                      <span
                        className="badge ok"
                        title="Días de antigüedad reconocidos del vínculo anterior"
                      >
                        +{v.dias_antiguedad_reconocida} d
                      </span>
                    ) : null}
                  </td>
                  <td>{soloFecha(v.fecha_ingreso)}</td>
                  <td>
                    {v.fecha_salida ? (
                      <>
                        {soloFecha(v.fecha_salida)}
                        {v.liquidado && <span className="badge ok">liquidado</span>}
                      </>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td>{soloFecha(v.antiguedad_desde)}</td>
                  <td className="num">{v.anios_antiguedad}</td>
                  <td>
                    {v.vigente ? (
                      <span className="badge ok">vigente</span>
                    ) : (
                      <span className="badge cero">cerrado</span>
                    )}
                  </td>
                  {puedeEscribir && (
                    <td>
                      {v.vigente && (
                        <button
                          className="btn-mini secondary"
                          disabled={guardando}
                          onClick={() => registrarSalida(v.empleado_id, v.nombre_completo)}
                        >
                          Registrar salida
                        </button>
                      )}
                    </td>
                  )}
                </tr>
              ))}
              {!vinculosVisibles.length && (
                <tr>
                  <td colSpan={puedeEscribir ? 9 : 8} className="vacio">
                    Sin vínculos registrados.
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
