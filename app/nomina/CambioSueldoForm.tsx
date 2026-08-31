"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import {
  dinero,
  hoyISO,
  mensajeError,
  MOTIVOS_AFILIACION,
  MOTIVOS_SUELDO,
  type Empresa,
} from "./lib";
import SelectorDocumento from "./SelectorDocumento";

/** Cambio de sueldo real o de afiliación sobre una persona ya registrada. */
export default function CambioSueldoForm({
  empleadoId,
  nombre,
  sueldoActual,
  declaradoActual,
  empresaPagadoraActual,
  empresaAfiliacionActual,
  afiliadoActual,
  empresas,
  onListo,
  onCancelar,
}: {
  empleadoId: string;
  nombre: string;
  sueldoActual: number | null;
  declaradoActual: number | null;
  empresaPagadoraActual: string | null;
  empresaAfiliacionActual: string | null;
  afiliadoActual: boolean | null;
  empresas: Empresa[];
  onListo: () => void;
  onCancelar: () => void;
}) {
  const supabase = createClient();
  const [que, setQue] = useState<"sueldo" | "afiliacion">("sueldo");
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [sueldo, setSueldo] = useState({
    sueldo_real: String(sueldoActual ?? ""),
    empresa_pagadora_id: empresaPagadoraActual ?? "",
    fecha_desde: hoyISO(),
    motivo_tipo: "aumento_desempeno",
    motivo: "",
    documento_respaldo_id: null as string | null,
  });

  const [afiliacion, setAfiliacion] = useState({
    afiliado: afiliadoActual ?? true,
    empresa_id: empresaAfiliacionActual ?? "",
    fecha_afiliacion: hoyISO(),
    sueldo_declarado: String(declaradoActual ?? ""),
    fecha_desde: hoyISO(),
    motivo_tipo: "ajuste_sueldo_declarado",
    motivo: "",
    documento_respaldo_id: null as string | null,
  });

  const esReduccion =
    sueldoActual !== null && Number(sueldo.sueldo_real || 0) < sueldoActual;
  const esDesafiliacion = afiliadoActual === true && !afiliacion.afiliado;

  // La base exige motivo y respaldo en estos dos casos: se anticipa aquí para
  // no chocar contra un error después de llenar todo.
  useEffect(() => {
    if (esReduccion && !["reduccion_acordada", "correccion_error"].includes(sueldo.motivo_tipo)) {
      setSueldo((s) => ({ ...s, motivo_tipo: "reduccion_acordada" }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [esReduccion]);

  useEffect(() => {
    if (esDesafiliacion) setAfiliacion((a) => ({ ...a, motivo_tipo: "desafiliacion" }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [esDesafiliacion]);

  async function guardarSueldo() {
    if (!sueldo.motivo.trim()) return setError("El motivo es obligatorio.");
    if (esReduccion && !sueldo.documento_respaldo_id)
      return setError("Una reducción de sueldo exige el documento que la respalda.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_compensacion_v32", {
      p_empleado_id: empleadoId,
      p_empresa_pagadora_id: sueldo.empresa_pagadora_id,
      p_sueldo_real: Number(sueldo.sueldo_real),
      p_fecha_desde: sueldo.fecha_desde,
      p_motivo_tipo: sueldo.motivo_tipo,
      p_motivo: sueldo.motivo,
      p_documento_respaldo_id: sueldo.documento_respaldo_id,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    onListo();
  }

  async function guardarAfiliacion() {
    if (!afiliacion.motivo.trim()) return setError("El motivo es obligatorio.");
    if (esDesafiliacion && !afiliacion.documento_respaldo_id)
      return setError("La desafiliación exige el aviso de salida u otro respaldo.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_afiliacion_v32", {
      p_empleado_id: empleadoId,
      p_afiliado: afiliacion.afiliado,
      p_empresa_id: afiliacion.afiliado ? afiliacion.empresa_id : null,
      p_fecha_afiliacion: afiliacion.afiliado ? afiliacion.fecha_afiliacion : null,
      p_sueldo_declarado: afiliacion.afiliado ? Number(afiliacion.sueldo_declarado) : 0,
      p_fecha_desde: afiliacion.fecha_desde,
      p_motivo_tipo: afiliacion.motivo_tipo,
      p_motivo: afiliacion.motivo,
      p_documento_respaldo_id: afiliacion.documento_respaldo_id,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    onListo();
  }

  return (
    <div className="card-interna">
      <h4>Cambio en {nombre}</h4>
      {error && <p className="error">{error}</p>}

      <div className="tabs">
        <button
          className={`tab ${que === "sueldo" ? "activo" : ""}`}
          onClick={() => setQue("sueldo")}
        >
          Sueldo real
        </button>
        <button
          className={`tab ${que === "afiliacion" ? "activo" : ""}`}
          onClick={() => setQue("afiliacion")}
        >
          Afiliación
        </button>
      </div>

      {que === "sueldo" ? (
        <>
          <div className="form-grid">
            <label>
              Sueldo real
              <input
                type="number"
                step="0.01"
                min="0"
                value={sueldo.sueldo_real}
                onChange={(e) => setSueldo({ ...sueldo, sueldo_real: e.target.value })}
              />
              <small>Actual: {dinero(sueldoActual)}</small>
            </label>
            <label>
              Empresa que paga
              <select
                value={sueldo.empresa_pagadora_id}
                onChange={(e) =>
                  setSueldo({ ...sueldo, empresa_pagadora_id: e.target.value })
                }
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
              Vigente desde
              <input
                type="date"
                value={sueldo.fecha_desde}
                onChange={(e) => setSueldo({ ...sueldo, fecha_desde: e.target.value })}
              />
            </label>
            <label>
              Tipo de motivo
              <select
                value={sueldo.motivo_tipo}
                onChange={(e) => setSueldo({ ...sueldo, motivo_tipo: e.target.value })}
              >
                {MOTIVOS_SUELDO.filter(
                  (m) =>
                    !esReduccion ||
                    ["reduccion_acordada", "correccion_error"].includes(m.valor)
                ).map((m) => (
                  <option key={m.valor} value={m.valor}>
                    {m.etiqueta}
                  </option>
                ))}
              </select>
            </label>
            <label className="ancho-total">
              Motivo
              <input
                type="text"
                value={sueldo.motivo}
                onChange={(e) => setSueldo({ ...sueldo, motivo: e.target.value })}
              />
            </label>
          </div>

          {esReduccion && (
            <p className="aviso">
              Estás bajando la remuneración de {dinero(sueldoActual)} a{" "}
              {dinero(Number(sueldo.sueldo_real))}. El Art. 39 del Código del Trabajo
              consagra la irrenunciabilidad de los derechos del trabajador: hace falta el
              documento que respalde el acuerdo.
            </p>
          )}

          <div className="form-grid">
            <div className="ancho-total">
              <SelectorDocumento
                empleadoId={empleadoId}
                valor={sueldo.documento_respaldo_id}
                onCambio={(id) => setSueldo({ ...sueldo, documento_respaldo_id: id })}
                tipoSugerido="adendum"
                etiqueta="Acta o adendum de respaldo"
                requerido={esReduccion}
              />
            </div>
          </div>

          <div className="filtros">
            <button onClick={guardarSueldo} disabled={guardando}>
              {guardando ? "Guardando…" : "Registrar cambio de sueldo"}
            </button>
            <button className="secondary" onClick={onCancelar}>
              Cancelar
            </button>
          </div>
        </>
      ) : (
        <>
          <div className="form-grid">
            <label>
              <input
                type="checkbox"
                checked={afiliacion.afiliado}
                onChange={(e) =>
                  setAfiliacion({ ...afiliacion, afiliado: e.target.checked })
                }
              />{" "}
              Está afiliado
            </label>
            {afiliacion.afiliado && (
              <>
                <label>
                  RUC que afilia
                  <select
                    value={afiliacion.empresa_id}
                    onChange={(e) =>
                      setAfiliacion({ ...afiliacion, empresa_id: e.target.value })
                    }
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
                  Fecha de afiliación
                  <input
                    type="date"
                    value={afiliacion.fecha_afiliacion}
                    onChange={(e) =>
                      setAfiliacion({ ...afiliacion, fecha_afiliacion: e.target.value })
                    }
                  />
                </label>
                <label>
                  Sueldo declarado
                  <input
                    type="number"
                    step="0.01"
                    min="0"
                    value={afiliacion.sueldo_declarado}
                    onChange={(e) =>
                      setAfiliacion({ ...afiliacion, sueldo_declarado: e.target.value })
                    }
                  />
                  <small>Actual: {dinero(declaradoActual)}</small>
                </label>
              </>
            )}
            <label>
              Vigente desde
              <input
                type="date"
                value={afiliacion.fecha_desde}
                onChange={(e) =>
                  setAfiliacion({ ...afiliacion, fecha_desde: e.target.value })
                }
              />
            </label>
            <label>
              Tipo de motivo
              <select
                value={afiliacion.motivo_tipo}
                onChange={(e) =>
                  setAfiliacion({ ...afiliacion, motivo_tipo: e.target.value })
                }
              >
                {MOTIVOS_AFILIACION.filter(
                  (m) => !esDesafiliacion || m.valor === "desafiliacion"
                ).map((m) => (
                  <option key={m.valor} value={m.valor}>
                    {m.etiqueta}
                  </option>
                ))}
              </select>
            </label>
            <label className="ancho-total">
              Motivo
              <input
                type="text"
                value={afiliacion.motivo}
                onChange={(e) => setAfiliacion({ ...afiliacion, motivo: e.target.value })}
              />
            </label>
          </div>

          {esDesafiliacion && (
            <p className="aviso">
              Vas a dar de baja la afiliación al IESS. Hace falta el aviso de salida u
              otro documento que lo respalde.
            </p>
          )}

          <div className="form-grid">
            <div className="ancho-total">
              <SelectorDocumento
                empleadoId={empleadoId}
                valor={afiliacion.documento_respaldo_id}
                onCambio={(id) =>
                  setAfiliacion({ ...afiliacion, documento_respaldo_id: id })
                }
                tipoSugerido={esDesafiliacion ? "aviso_entrada_iess" : "adendum"}
                etiqueta="Documento de respaldo"
                requerido={esDesafiliacion}
              />
            </div>
          </div>

          <div className="filtros">
            <button onClick={guardarAfiliacion} disabled={guardando}>
              {guardando ? "Guardando…" : "Registrar cambio de afiliación"}
            </button>
            <button className="secondary" onClick={onCancelar}>
              Cancelar
            </button>
          </div>
        </>
      )}
    </div>
  );
}
