"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { dinero, hoyISO, mensajeError, type Empresa } from "./lib";

type Props = {
  empresas: Empresa[];
  grupoId: string;
  onListo: () => void;
  onCancelar: () => void;
};

// Alta en tres pasos porque así lo exige el modelo: la persona existe una vez,
// su afiliación y su sueldo son series historizadas aparte.
export default function EmpleadoForm({ empresas, grupoId, onListo, onCancelar }: Props) {
  const supabase = createClient();
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [datos, setDatos] = useState({
    tipo_identificacion: "cedula",
    identificacion: "",
    nombres: "",
    apellidos: "",
    fecha_nacimiento: "",
    fecha_ingreso_real: hoyISO(),
    cargo: "",
    area: "",
    tipo_contrato: "indefinido",
    telefono: "",
    email: "",
    direccion: "",
    forma_pago: "transferencia",
    banco: "",
    tipo_cuenta: "ahorros",
    numero_cuenta: "",
  });

  const [afiliacion, setAfiliacion] = useState({
    afiliado: true,
    empresa_id: "",
    fecha_afiliacion: hoyISO(),
    sueldo_declarado: "",
  });

  const [compensacion, setCompensacion] = useState({
    empresa_pagadora_id: "",
    sueldo_real: "",
  });

  const brecha =
    Number(compensacion.sueldo_real || 0) - Number(afiliacion.sueldo_declarado || 0);

  async function guardar() {
    setError(null);
    if (!datos.identificacion.trim() || !datos.nombres.trim() || !datos.apellidos.trim())
      return setError("Identificación, nombres y apellidos son obligatorios.");
    if (!datos.cargo.trim()) return setError("El cargo es obligatorio.");
    if (!compensacion.empresa_pagadora_id || !compensacion.sueldo_real)
      return setError("Falta la empresa que paga y el sueldo real.");
    if (afiliacion.afiliado && (!afiliacion.empresa_id || !afiliacion.sueldo_declarado))
      return setError("Un afiliado necesita RUC afiliador y sueldo declarado.");

    setGuardando(true);

    const { data: empleadoId, error: errEmpleado } = await supabase.rpc(
      "guardar_empleado_v26",
      {
        p_empleado_id: null,
        p_grupo_id: grupoId,
        p_tipo_identificacion: datos.tipo_identificacion,
        p_identificacion: datos.identificacion,
        p_nombres: datos.nombres,
        p_apellidos: datos.apellidos,
        p_fecha_ingreso_real: datos.fecha_ingreso_real,
        p_cargo: datos.cargo,
        p_fecha_nacimiento: datos.fecha_nacimiento || null,
        p_estado_civil: null,
        p_direccion: datos.direccion || null,
        p_telefono: datos.telefono || null,
        p_email: datos.email || null,
        p_contacto_emergencia_nombre: null,
        p_contacto_emergencia_telefono: null,
        p_area: datos.area || null,
        p_tipo_contrato: datos.tipo_contrato,
        p_forma_pago: datos.forma_pago,
        p_banco: datos.banco || null,
        p_tipo_cuenta: datos.forma_pago === "transferencia" ? datos.tipo_cuenta : null,
        p_numero_cuenta: datos.numero_cuenta || null,
        p_observacion: null,
      }
    );
    if (errEmpleado) {
      setGuardando(false);
      return setError(mensajeError(errEmpleado));
    }

    const { error: errAfiliacion } = await supabase.rpc("registrar_afiliacion_v26", {
      p_empleado_id: empleadoId,
      p_afiliado: afiliacion.afiliado,
      p_empresa_id: afiliacion.afiliado ? afiliacion.empresa_id : null,
      p_fecha_afiliacion: afiliacion.afiliado ? afiliacion.fecha_afiliacion : null,
      p_sueldo_declarado: afiliacion.afiliado ? Number(afiliacion.sueldo_declarado) : 0,
      p_fecha_desde: datos.fecha_ingreso_real,
      p_motivo: "Registro inicial",
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    if (errAfiliacion) {
      setGuardando(false);
      // El empleado ya quedó creado: se completa desde su ficha.
      return setError(
        `Se creó la persona pero falló la afiliación: ${mensajeError(errAfiliacion)}`
      );
    }

    const { error: errComp } = await supabase.rpc("registrar_compensacion_v26", {
      p_empleado_id: empleadoId,
      p_empresa_pagadora_id: compensacion.empresa_pagadora_id,
      p_sueldo_real: Number(compensacion.sueldo_real),
      p_fecha_desde: datos.fecha_ingreso_real,
      p_motivo: "Registro inicial",
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (errComp)
      return setError(
        `Se creó la persona y su afiliación pero falló el sueldo: ${mensajeError(errComp)}`
      );

    onListo();
  }

  return (
    <div className="card-interna">
      <h4>Nueva persona</h4>
      {error && <p className="error">{error}</p>}

      <h5>Datos personales</h5>
      <div className="form-grid">
        <label>
          Tipo de documento
          <select
            value={datos.tipo_identificacion}
            onChange={(e) => setDatos({ ...datos, tipo_identificacion: e.target.value })}
          >
            <option value="cedula">Cédula</option>
            <option value="pasaporte">Pasaporte</option>
          </select>
        </label>
        <label>
          Identificación
          <input
            type="text"
            value={datos.identificacion}
            onChange={(e) => setDatos({ ...datos, identificacion: e.target.value })}
          />
          {datos.tipo_identificacion === "cedula" && (
            <small>Se valida el dígito verificador al guardar.</small>
          )}
        </label>
        <label>
          Apellidos
          <input
            type="text"
            value={datos.apellidos}
            onChange={(e) => setDatos({ ...datos, apellidos: e.target.value })}
          />
        </label>
        <label>
          Nombres
          <input
            type="text"
            value={datos.nombres}
            onChange={(e) => setDatos({ ...datos, nombres: e.target.value })}
          />
        </label>
        <label>
          Fecha de nacimiento
          <input
            type="date"
            value={datos.fecha_nacimiento}
            onChange={(e) => setDatos({ ...datos, fecha_nacimiento: e.target.value })}
          />
        </label>
        <label>
          Teléfono
          <input
            type="text"
            value={datos.telefono}
            onChange={(e) => setDatos({ ...datos, telefono: e.target.value })}
          />
        </label>
      </div>

      <h5>Relación laboral</h5>
      <div className="form-grid">
        <label>
          Fecha de ingreso real
          <input
            type="date"
            value={datos.fecha_ingreso_real}
            max={hoyISO()}
            onChange={(e) => setDatos({ ...datos, fecha_ingreso_real: e.target.value })}
          />
          <small>Manda para vacaciones, décimos y antigüedad.</small>
        </label>
        <label>
          Cargo
          <input
            type="text"
            value={datos.cargo}
            onChange={(e) => setDatos({ ...datos, cargo: e.target.value })}
          />
        </label>
        <label>
          Área
          <input
            type="text"
            value={datos.area}
            onChange={(e) => setDatos({ ...datos, area: e.target.value })}
          />
        </label>
        <label>
          Tipo de contrato
          <select
            value={datos.tipo_contrato}
            onChange={(e) => setDatos({ ...datos, tipo_contrato: e.target.value })}
          >
            <option value="indefinido">Indefinido</option>
            <option value="eventual">Eventual</option>
            <option value="ocasional">Ocasional</option>
            <option value="servicios_profesionales">Servicios profesionales</option>
            <option value="aprendizaje">Aprendizaje</option>
          </select>
        </label>
      </div>

      <h5>Afiliación al IESS</h5>
      <div className="form-grid">
        <label>
          <input
            type="checkbox"
            checked={afiliacion.afiliado}
            onChange={(e) => setAfiliacion({ ...afiliacion, afiliado: e.target.checked })}
          />{" "}
          Está afiliado
        </label>
        {afiliacion.afiliado ? (
          <>
            <label>
              RUC que afilia
              <select
                value={afiliacion.empresa_id}
                onChange={(e) => setAfiliacion({ ...afiliacion, empresa_id: e.target.value })}
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
              <small>Manda para fondos de reserva. Puede ser posterior al ingreso.</small>
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
            </label>
          </>
        ) : (
          <p className="ayuda">
            El personal no afiliado igual recibe rol de pago; solo no entra en la planilla
            del IESS.
          </p>
        )}
      </div>

      <h5>Sueldo real y quién paga</h5>
      <div className="form-grid">
        <label>
          Empresa que desembolsa
          <select
            value={compensacion.empresa_pagadora_id}
            onChange={(e) =>
              setCompensacion({ ...compensacion, empresa_pagadora_id: e.target.value })
            }
          >
            <option value="">Elegir…</option>
            {empresas.map((e) => (
              <option key={e.id} value={e.id}>
                {e.razon_social}
              </option>
            ))}
          </select>
          <small>Puede ser distinta del RUC que afilia.</small>
        </label>
        <label>
          Sueldo real
          <input
            type="number"
            step="0.01"
            min="0"
            value={compensacion.sueldo_real}
            onChange={(e) =>
              setCompensacion({ ...compensacion, sueldo_real: e.target.value })
            }
          />
        </label>
        {brecha !== 0 && afiliacion.afiliado && (
          <p className="ayuda">
            Brecha mensual: <strong>{dinero(brecha)}</strong>
          </p>
        )}
      </div>

      <div className="filtros">
        <button onClick={guardar} disabled={guardando}>
          {guardando ? "Guardando…" : "Crear persona"}
        </button>
        <button className="secondary" onClick={onCancelar} disabled={guardando}>
          Cancelar
        </button>
      </div>
    </div>
  );
}
