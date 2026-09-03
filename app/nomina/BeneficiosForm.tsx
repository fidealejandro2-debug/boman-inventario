"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { mensajeError } from "./lib";
import Aviso from "@/components/Aviso";

/**
 * Décimos y fondos de reserva: mensualizados o acumulados.
 *
 * Va aparte del formulario de la persona y no dentro de él porque el RPC exige
 * motivo y deja evento auditado, igual que un cambio de sueldo. Es una decisión
 * del trabajador que conviene tener fechada y justificada por separado, no
 * mezclada con la edición de un teléfono.
 */
export default function BeneficiosForm({
  empleadoId,
  nombre,
  afiliado,
  decimoTerceroActual,
  decimoCuartoActual,
  fondosMensualActual,
  onListo,
  onCancelar,
}: {
  empleadoId: string;
  nombre: string;
  /** Los fondos de reserva solo existen para quien está afiliado al IESS. */
  afiliado: boolean | null;
  decimoTerceroActual: boolean | null;
  decimoCuartoActual: boolean | null;
  fondosMensualActual: boolean | null;
  onListo: () => void;
  onCancelar: () => void;
}) {
  const supabase = createClient();
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({
    decimoTercero: Boolean(decimoTerceroActual),
    decimoCuarto: Boolean(decimoCuartoActual),
    // El default de la base es true, pero solo aplica a afiliados.
    fondosMensual: fondosMensualActual ?? true,
    motivo: "",
  });

  const esAfiliado = Boolean(afiliado);

  async function guardar() {
    if (form.motivo.trim().length < 10) {
      return setError("Explica el motivo con al menos 10 caracteres: queda auditado.");
    }
    setGuardando(true);
    setError(null);
    const { error: fallo } = await supabase.rpc("configurar_beneficios_empleado_v30", {
      p_empleado_id: empleadoId,
      p_mensualiza_decimo_tercero: form.decimoTercero,
      p_mensualiza_decimo_cuarto: form.decimoCuarto,
      // Sin afiliación no hay fondos de reserva que mensualizar; se manda el
      // default para no dejar el campo en un estado que la pantalla no mostró.
      p_paga_fondos_reserva_mensual: esAfiliado ? form.fondosMensual : true,
      p_motivo: form.motivo.trim(),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (fallo) return setError(mensajeError(fallo));
    onListo();
  }

  return (
    <div className="card-interna">
      <Aviso
        error={error}
        aviso={null}
        titulo="Listo"
        onCerrar={() => setError(null)}
      />
      <h4>Décimos y fondos de reserva — {nombre}</h4>
      <p className="ayuda">
        Define si estos beneficios se pagan <strong>cada mes junto al sueldo</strong> o se
        acumulan para pagarse en su fecha. El décimo tercero acumulado se paga hasta el 24
        de diciembre; el décimo cuarto, hasta el 15 de marzo en la Costa e Insular y el 15
        de agosto en la Sierra y Amazonía. Es una decisión del trabajador.
      </p>

      <div className="form-grid">
        <label className="check-inline">
          <input
            type="checkbox"
            checked={form.decimoTercero}
            onChange={(e) => setForm({ ...form, decimoTercero: e.target.checked })}
          />
          Mensualizar décimo tercero
          <small className="ayuda">
            {form.decimoTercero
              ? "Se paga cada mes junto al sueldo."
              : "Se acumula y se paga hasta el 24 de diciembre."}
          </small>
        </label>

        <label className="check-inline">
          <input
            type="checkbox"
            checked={form.decimoCuarto}
            onChange={(e) => setForm({ ...form, decimoCuarto: e.target.checked })}
          />
          Mensualizar décimo cuarto
          <small className="ayuda">
            {form.decimoCuarto
              ? "Se paga cada mes junto al sueldo."
              : "Se acumula y se paga según la región del trabajador."}
          </small>
        </label>

        {esAfiliado ? (
          <label className="check-inline">
            <input
              type="checkbox"
              checked={form.fondosMensual}
              onChange={(e) => setForm({ ...form, fondosMensual: e.target.checked })}
            />
            Pagar fondos de reserva cada mes
            <small className="ayuda">
              {form.fondosMensual
                ? "Se pagan con el sueldo, a partir del año de afiliación."
                : "Los acumula el IESS; no salen en el rol mensual."}
            </small>
          </label>
        ) : (
          <p className="aviso ancho-total">
            Esta persona no está afiliada al IESS, así que no hay fondos de reserva que
            configurar. Los décimos sí se mantienen: son un derecho de todo trabajador.
          </p>
        )}

        <label className="ancho-total">
          Motivo (mínimo 10 caracteres)
          <input
            type="text"
            placeholder="Ej. El trabajador solicita mensualizar por escrito el 03/09/2026"
            value={form.motivo}
            onChange={(e) => setForm({ ...form, motivo: e.target.value })}
          />
        </label>
      </div>

      <div className="filtros">
        <button onClick={guardar} disabled={guardando}>
          {guardando ? "Guardando…" : "Guardar beneficios"}
        </button>
        <button className="secondary" onClick={onCancelar} disabled={guardando}>
          Cancelar
        </button>
      </div>
    </div>
  );
}
