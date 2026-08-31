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
  ETIQUETA_NOVEDAD,
  type Empleado,
  type Empresa,
} from "./lib";
import NovedadImpresion from "./NovedadImpresion";
import SelectorDocumento from "./SelectorDocumento";

type Novedad = {
  novedad_id: string;
  empleado_id: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  empresa: string;
  ruc: string;
  referencia: string | null;
  tipo: string;
  estado: string;
  fecha_hechos: string;
  asunto: string;
  notificado_at: string | null;
  forma_notificacion: string | null;
  tiene_descargo: boolean;
  genera_descuento: boolean;
  monto_descuento: number | null;
  descuento_aplicado: boolean;
  genero_suspension: boolean;
};

export default function NovedadesTab({
  puedeEscribir,
  esAdmin,
  empleados,
  empresas,
}: {
  puedeEscribir: boolean;
  esAdmin: boolean;
  empleados: Empleado[];
  empresas: Empresa[];
}) {
  const supabase = createClient();
  const [filas, setFilas] = useState<Novedad[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [imprimir, setImprimir] = useState<string | null>(null);

  const [filtroEstado, setFiltroEstado] = useState("");
  const [busqueda, setBusqueda] = useState("");
  const [mostrarForm, setMostrarForm] = useState(false);

  const [form, setForm] = useState({
    empleado_id: "",
    empresa_id: "",
    tipo: "llamado_atencion",
    fecha_hechos: hoyISO(),
    asunto: "",
    hechos: "",
    base_reglamento: "",
    base_legal: "",
    genera_descuento: false,
    monto_descuento: "",
  });
  const [tope, setTope] = useState<number | null>(null);
  const [multa, setMulta] = useState({
    novedad_id: "",
    empleado_id: "",
    cuotas: "1",
    mes_inicio: hoyISO().slice(0, 7),
    documento_respaldo_id: null as string | null,
  });

  async function cargar() {
    setCargando(true);
    const { data, error } = await supabase
      .from("vista_novedades_v28")
      .select("*")
      .order("fecha_hechos", { ascending: false });
    if (error) setError(error.message);
    else setFilas((data as Novedad[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Al elegir persona se sugiere su RUC afiliador y se consulta el tope de multa.
  useEffect(() => {
    if (!form.empleado_id) return setTope(null);
    const emp = empleados.find((e) => e.empleado_id === form.empleado_id);
    const sugerida = emp?.empresa_afiliacion_id ?? emp?.empresa_pagadora_id ?? "";
    setForm((f) => ({ ...f, empresa_id: f.empresa_id || sugerida }));

    supabase
      .rpc("tope_multa_empleado_v28", {
        p_empleado_id: form.empleado_id,
        p_fecha: form.fecha_hechos,
      })
      .then(({ data }) => setTope(data === null ? null : Number(data)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form.empleado_id, form.fecha_hechos]);

  async function guardarYEmitir() {
    if (!form.empleado_id || !form.empresa_id) return setError("Falta persona o empresa.");
    if (!form.asunto.trim() || !form.hechos.trim())
      return setError("El asunto y los hechos son obligatorios.");

    setGuardando(true);
    setError(null);
    const { data: novedadId, error: errGuardar } = await supabase.rpc(
      "guardar_novedad_v28",
      {
        p_novedad_id: null,
        p_empleado_id: form.empleado_id,
        p_empresa_id: form.empresa_id,
        p_tipo: form.tipo,
        p_fecha_hechos: form.fecha_hechos,
        p_asunto: form.asunto,
        p_hechos: form.hechos,
        p_base_reglamento: form.base_reglamento || null,
        p_base_legal: form.base_legal || null,
        p_genera_descuento: form.genera_descuento,
        p_monto_descuento: form.genera_descuento ? Number(form.monto_descuento) : null,
        p_idempotency_key: nuevaClaveIdempotencia(),
      }
    );
    if (errGuardar) {
      setGuardando(false);
      return setError(mensajeError(errGuardar));
    }

    // Emitir asigna el correlativo y congela el contenido.
    const { data: emitida, error: errEmitir } = await supabase.rpc("emitir_novedad_v28", {
      p_novedad_id: novedadId,
      p_fecha_emision: hoyISO(),
    });
    setGuardando(false);
    if (errEmitir) return setError(mensajeError(errEmitir));

    setAviso(`Novedad emitida con el número ${(emitida as any)?.referencia ?? ""}.`);
    setMostrarForm(false);
    setForm({
      ...form,
      asunto: "",
      hechos: "",
      base_reglamento: "",
      base_legal: "",
      genera_descuento: false,
      monto_descuento: "",
    });
    cargar();
  }

  async function notificar(id: string) {
    const forma = window.prompt(
      "Forma de notificación: fisica, correo, testigos o negativa_recibir",
      "fisica"
    );
    if (!forma) return;
    let observacion: string | null = null;
    if (forma === "testigos") {
      observacion = window.prompt("¿Quiénes fueron los testigos?");
      if (!observacion?.trim()) return setError("La notificación con testigos exige constancia.");
    }
    setGuardando(true);
    const { error } = await supabase.rpc("notificar_novedad_v28", {
      p_novedad_id: id,
      p_forma_notificacion: forma,
      p_firma_empleado_doc_id: null,
      p_observacion: observacion,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Notificación registrada.");
    cargar();
  }

  async function emitirBorrador(id: string) {
    if (!window.confirm("Se asignará el correlativo y el contenido quedará congelado. ¿Emitir?"))
      return;
    setGuardando(true);
    setError(null);
    const { data, error } = await supabase.rpc("emitir_novedad_v28", {
      p_novedad_id: id,
      p_fecha_emision: hoyISO(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(`Novedad emitida con el número ${(data as { referencia?: string })?.referencia ?? ""}.`);
    cargar();
  }

  async function programarMulta() {
    if (!multa.novedad_id) return;
    const cuotas = Number(multa.cuotas);
    if (!Number.isInteger(cuotas) || cuotas < 1 || cuotas > 120)
      return setError("Las cuotas deben estar entre 1 y 120.");
    if (!multa.mes_inicio) return setError("Elige el mes del primer descuento.");
    if (!multa.documento_respaldo_id)
      return setError("Elige la sanción firmada o el documento que autoriza el descuento.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_descuento_multa_v29", {
      p_novedad_id: multa.novedad_id,
      p_cuotas: cuotas,
      p_fecha_inicio: `${multa.mes_inicio}-01`,
      p_documento_respaldo_id: multa.documento_respaldo_id,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setMulta({
      novedad_id: "",
      empleado_id: "",
      cuotas: "1",
      mes_inicio: hoyISO().slice(0, 7),
      documento_respaldo_id: null,
    });
    setAviso("Multa programada; se intentará aplicar desde el rol del mes elegido.");
    cargar();
  }

  async function descargo(id: string) {
    const texto = window.prompt("Descargo del trabajador:");
    if (!texto?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("registrar_descargo_novedad_v28", {
      p_novedad_id: id,
      p_descargo: texto,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Descargo registrado.");
    cargar();
  }

  async function resolver(id: string) {
    const resolucion = window.prompt("Resolución del caso:");
    if (!resolucion?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("resolver_novedad_v28", {
      p_novedad_id: id,
      p_resolucion: resolucion,
      p_ausencia_id: null,
      p_documento_pdf_id: null,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Novedad resuelta y archivada.");
    cargar();
  }

  // Deshace el descuento que la multa dejó programado. Es el paso previo
  // obligatorio para anular: anular_novedad_v28 se niega mientras la novedad
  // tenga un descuento colgado.
  async function revertirMulta(id: string) {
    const motivo = window.prompt("Motivo para revertir la multa:");
    if (!motivo?.trim()) return;
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("revertir_descuento_multa_v29", {
      p_novedad_id: id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Multa revertida: el descuento deja de aplicarse y la novedad ya se puede anular.");
    cargar();
  }

  async function anular(id: string) {
    const motivo = window.prompt("Motivo de la anulación:");
    if (!motivo?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("anular_novedad_v28", {
      p_novedad_id: id,
      p_motivo: motivo,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Novedad anulada; el número queda quemado.");
    cargar();
  }

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return filas.filter((f) => {
      if (filtroEstado && f.estado !== filtroEstado) return false;
      if (!q) return true;
      return (
        f.nombre_completo.toLowerCase().includes(q) ||
        f.identificacion.includes(q) ||
        (f.referencia ?? "").includes(q)
      );
    });
  }, [filas, filtroEstado, busqueda]);

  // Tres o más sanciones en 12 meses: base para un visto bueno (Art. 172 CT).
  const reincidentes = useMemo(() => {
    const corte = new Date();
    corte.setFullYear(corte.getFullYear() - 1);
    const conteo = new Map<string, { nombre: string; n: number }>();
    filas
      .filter(
        (f) =>
          ["emitida", "notificada", "con_descargo", "archivada"].includes(f.estado) &&
          ["llamado_atencion", "amonestacion_escrita", "sancion_economica", "solicitud_visto_bueno"].includes(f.tipo) &&
          new Date(f.fecha_hechos) >= corte
      )
      .forEach((f) => {
        const prev = conteo.get(f.empleado_id);
        conteo.set(f.empleado_id, {
          nombre: f.nombre_completo,
          n: (prev?.n ?? 0) + 1,
        });
      });
    return [...conteo.values()].filter((v) => v.n >= 3);
  }, [filas]);

  if (imprimir) {
    return <NovedadImpresion novedadId={imprimir} onCerrar={() => setImprimir(null)} />;
  }

  if (cargando) return <p className="ayuda">Cargando novedades…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      {reincidentes.length > 0 && (
        <p className="aviso">
          <strong>{reincidentes.length}</strong> persona(s) acumulan tres o más sanciones
          en los últimos 12 meses:{" "}
          {reincidentes.map((r) => `${r.nombre} (${r.n})`).join(", ")}. Es el supuesto del
          Art. 172 del Código del Trabajo; la decisión sigue siendo del empleador.
        </p>
      )}

      {multa.novedad_id && puedeEscribir && (
        <div className="card-interna">
          <h4>Programar multa en el rol</h4>
          <p className="ayuda">
            La novedad ya fue notificada. El respaldo debe pertenecer al expediente de la
            misma persona; el motor de nómina seguirá respetando los topes y el neto disponible.
          </p>
          <div className="form-grid">
            <label>
              Cuotas
              <input
                type="number"
                min="1"
                max="120"
                value={multa.cuotas}
                onChange={(e) => setMulta({ ...multa, cuotas: e.target.value })}
              />
            </label>
            <label>
              Aplicar desde el rol de
              <input
                type="month"
                value={multa.mes_inicio}
                onChange={(e) => setMulta({ ...multa, mes_inicio: e.target.value })}
              />
            </label>
            <div className="ancho-total">
              <SelectorDocumento
                empleadoId={multa.empleado_id || null}
                valor={multa.documento_respaldo_id}
                onCambio={(id) => setMulta({ ...multa, documento_respaldo_id: id })}
                tipoSugerido="otro"
                etiqueta="Sanción firmada o autorización"
                requerido
              />
            </div>
          </div>
          <button onClick={programarMulta} disabled={guardando}>Programar descuento</button>
          <button
            className="secondary"
            onClick={() => setMulta({ ...multa, novedad_id: "", empleado_id: "", documento_respaldo_id: null })}
            disabled={guardando}
          >
            Cancelar
          </button>
        </div>
      )}

      <div className="filtros">
        {puedeEscribir && (
          <button onClick={() => setMostrarForm(!mostrarForm)}>
            {mostrarForm ? "Cancelar" : "Nueva novedad"}
          </button>
        )}
        <select value={filtroEstado} onChange={(e) => setFiltroEstado(e.target.value)}>
          <option value="">Todos los estados</option>
          <option value="emitida">Emitidas</option>
          <option value="notificada">Notificadas</option>
          <option value="con_descargo">Con descargo</option>
          <option value="archivada">Archivadas</option>
          <option value="anulada">Anuladas</option>
        </select>
        <input
          type="search"
          placeholder="Buscar por nombre, cédula o número"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <button className="secondary" onClick={() => exportarCSV("novedades", visibles)}>
          Exportar
        </button>
      </div>

      {mostrarForm && puedeEscribir && (
        <div className="card-interna">
          <h4>Nueva novedad</h4>
          <p className="ayuda">
            Al guardar se emite y se asigna el número correlativo del RUC. Desde ese
            momento el contenido queda congelado: si está mal, se anula y se emite otra.
          </p>
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
              Se emite bajo el RUC
              <select
                value={form.empresa_id}
                onChange={(e) => setForm({ ...form, empresa_id: e.target.value })}
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
              Tipo
              <select value={form.tipo} onChange={(e) => setForm({ ...form, tipo: e.target.value })}>
                {Object.entries(ETIQUETA_NOVEDAD).map(([k, v]) => (
                  <option key={k} value={k}>
                    {v}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Fecha de los hechos
              <input
                type="date"
                value={form.fecha_hechos}
                max={hoyISO()}
                onChange={(e) => setForm({ ...form, fecha_hechos: e.target.value })}
              />
            </label>
            <label className="ancho-total">
              Asunto
              <input
                type="text"
                value={form.asunto}
                onChange={(e) => setForm({ ...form, asunto: e.target.value })}
              />
            </label>
            <label className="ancho-total">
              Hechos
              <textarea
                rows={4}
                value={form.hechos}
                onChange={(e) => setForm({ ...form, hechos: e.target.value })}
              />
            </label>
            <label>
              Artículo del reglamento interno
              <input
                type="text"
                placeholder="Ej. Art. 22 literal c)"
                value={form.base_reglamento}
                onChange={(e) => setForm({ ...form, base_reglamento: e.target.value })}
              />
            </label>
            <label>
              Base legal
              <input
                type="text"
                placeholder="Ej. Art. 45 Código del Trabajo"
                value={form.base_legal}
                onChange={(e) => setForm({ ...form, base_legal: e.target.value })}
              />
            </label>
            {form.tipo !== "felicitacion" && (
              <>
                <label>
                  <input
                    type="checkbox"
                    checked={form.genera_descuento}
                    onChange={(e) =>
                      setForm({ ...form, genera_descuento: e.target.checked })
                    }
                  />{" "}
                  Aplica multa
                </label>
                {form.genera_descuento && (
                  <label>
                    Monto de la multa
                    <input
                      type="number"
                      step="0.01"
                      min="0"
                      max={tope ?? undefined}
                      value={form.monto_descuento}
                      onChange={(e) =>
                        setForm({ ...form, monto_descuento: e.target.value })
                      }
                    />
                    <small>
                      {tope === null
                        ? "Sin sueldo vigente: no se puede calcular el tope."
                        : `Tope permitido: ${dinero(tope)}. Solo procede si está prevista en el reglamento interno aprobado por el MDT.`}
                    </small>
                  </label>
                )}
              </>
            )}
          </div>
          <button onClick={guardarYEmitir} disabled={guardando}>
            {guardando ? "Emitiendo…" : "Emitir novedad"}
          </button>
        </div>
      )}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>N.º</th>
              <th>Persona</th>
              <th>Tipo</th>
              <th>Hechos</th>
              <th>RUC emisor</th>
              <th>Estado</th>
              <th className="num">Multa</th>
              <th>Acciones</th>
            </tr>
          </thead>
          <tbody>
            {visibles.map((f) => (
              <tr key={f.novedad_id} className={f.estado === "anulada" ? "fila-anulada" : ""}>
                <td>{f.referencia ?? "—"}</td>
                <td>{f.nombre_completo}</td>
                <td>
                  {ETIQUETA_NOVEDAD[f.tipo] ?? f.tipo}
                  {f.genero_suspension && (
                    <span className="badge ajuste" title="Generó suspensión">
                      suspensión
                    </span>
                  )}
                </td>
                <td>
                  {soloFecha(f.fecha_hechos)}
                  <br />
                  <small>{f.asunto}</small>
                </td>
                <td>{f.empresa}</td>
                <td>
                  <span className={`badge estado-${f.estado}`}>{f.estado}</span>
                  {f.tiene_descargo && <span className="badge ok">descargo</span>}
                </td>
                <td className="num">
                  {f.genera_descuento ? (
                    <>
                      {dinero(f.monto_descuento)}
                      {!f.descuento_aplicado && (
                        <span className="badge bajo" title="Aún sin descuento programado">
                          pendiente
                        </span>
                      )}
                    </>
                  ) : (
                    "—"
                  )}
                </td>
                <td>
                  {f.referencia && (
                    <button className="btn-mini secondary" onClick={() => setImprimir(f.novedad_id)}>
                      Imprimir
                    </button>
                  )}
                  {puedeEscribir && f.estado === "borrador" && (
                    <button className="btn-mini" disabled={guardando} onClick={() => emitirBorrador(f.novedad_id)}>
                      Revisar y emitir
                    </button>
                  )}
                  {puedeEscribir && f.estado === "emitida" && (
                    <button className="btn-mini" disabled={guardando} onClick={() => notificar(f.novedad_id)}>
                      Notificar
                    </button>
                  )}
                  {puedeEscribir && f.estado === "notificada" && (
                    <>
                      <button className="btn-mini" disabled={guardando} onClick={() => descargo(f.novedad_id)}>
                        Descargo
                      </button>
                      <button className="btn-mini" disabled={guardando} onClick={() => resolver(f.novedad_id)}>
                        Resolver
                      </button>
                    </>
                  )}
                  {puedeEscribir && f.estado === "con_descargo" && (
                    <button className="btn-mini" disabled={guardando} onClick={() => resolver(f.novedad_id)}>
                      Resolver
                    </button>
                  )}
                  {puedeEscribir && f.genera_descuento && !f.descuento_aplicado &&
                    ["notificada", "con_descargo", "archivada"].includes(f.estado) && (
                    <button
                      className="btn-mini"
                      disabled={guardando}
                      onClick={() => setMulta({
                        novedad_id: f.novedad_id,
                        empleado_id: f.empleado_id,
                        cuotas: "1",
                        mes_inicio: hoyISO().slice(0, 7),
                        documento_respaldo_id: null,
                      })}
                    >
                      Llevar al rol
                    </button>
                  )}
                  {/* Sin este botón una novedad con multa no se podía anular:
                      anular_novedad_v28 se niega mientras exista el descuento. */}
                  {puedeEscribir && f.descuento_aplicado && f.estado !== "anulada" && (
                    <button
                      className="btn-mini secondary"
                      disabled={guardando}
                      onClick={() => revertirMulta(f.novedad_id)}
                    >
                      Revertir multa
                    </button>
                  )}
                  {esAdmin && !["anulada", "archivada"].includes(f.estado) && (
                    <button
                      className="btn-mini secondary"
                      disabled={guardando}
                      onClick={() => anular(f.novedad_id)}
                    >
                      Anular
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {!visibles.length && (
              <tr>
                <td colSpan={8} className="vacio">
                  Sin novedades registradas.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
