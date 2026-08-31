"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import {
  dinero,
  hoyISO,
  mensajeError,
  type Departamento,
  type EmpleadoEdicion,
  type Empresa,
} from "./lib";

type Props = {
  empresas: Empresa[];
  departamentos: Departamento[];
  grupoId: string;
  empleado?: EmpleadoEdicion | null;
  onListo: () => void;
  onCancelar: () => void;
};

// v34 guarda persona, departamento, afiliación y sueldo en una sola
// transacción. Afiliación y sueldo siguen siendo series historizadas.
export default function EmpleadoForm({
  empresas,
  departamentos,
  grupoId,
  empleado = null,
  onListo,
  onCancelar,
}: Props) {
  const supabase = createClient();
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [motivo, setMotivo] = useState("");
  const editando = empleado !== null;

  const [datos, setDatos] = useState({
    tipo_identificacion: empleado?.tipo_identificacion ?? "cedula",
    identificacion: empleado?.identificacion ?? "",
    nombres: empleado?.nombres ?? "",
    apellidos: empleado?.apellidos ?? "",
    fecha_nacimiento: empleado?.fecha_nacimiento ?? "",
    estado_civil: empleado?.estado_civil ?? "",
    fecha_ingreso_real: empleado?.fecha_ingreso_real ?? hoyISO(),
    cargo: empleado?.cargo ?? "",
    departamento_id: empleado?.departamento_id ?? "",
    tipo_contrato: empleado?.tipo_contrato ?? "indefinido",
    telefono: empleado?.telefono ?? "",
    email: empleado?.email ?? "",
    direccion: empleado?.direccion ?? "",
    contacto_emergencia_nombre: empleado?.contacto_emergencia_nombre ?? "",
    contacto_emergencia_telefono: empleado?.contacto_emergencia_telefono ?? "",
    forma_pago: empleado?.forma_pago ?? "transferencia",
    banco: empleado?.banco ?? "",
    tipo_cuenta: empleado?.tipo_cuenta ?? "ahorros",
    numero_cuenta: empleado?.numero_cuenta ?? "",
    observacion: empleado?.observacion ?? "",
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
    if (!datos.fecha_ingreso_real) return setError("La fecha de ingreso real es obligatoria.");
    if (!datos.cargo.trim()) return setError("El cargo es obligatorio.");
    if (!datos.departamento_id)
      return setError("Selecciona el departamento de la persona.");
    if (
      datos.forma_pago === "transferencia" &&
      (!datos.banco.trim() || !datos.numero_cuenta.trim())
    )
      return setError(
        "Para pagar por transferencia debes indicar el banco y el número de cuenta."
      );
    if (
      !editando &&
      (!compensacion.empresa_pagadora_id ||
        !compensacion.sueldo_real ||
        Number(compensacion.sueldo_real) <= 0)
    )
      return setError("Falta la empresa que paga y el sueldo real.");
    if (
      !editando &&
      afiliacion.afiliado &&
      (!afiliacion.empresa_id ||
        !afiliacion.fecha_afiliacion ||
        !afiliacion.sueldo_declarado ||
        Number(afiliacion.sueldo_declarado) <= 0)
    )
      return setError("Un afiliado necesita RUC afiliador y sueldo declarado.");
    if (
      !editando &&
      afiliacion.afiliado &&
      afiliacion.fecha_afiliacion < datos.fecha_ingreso_real
    )
      return setError("La fecha de afiliación no puede ser anterior al ingreso real.");

    const departamento = departamentos.find(
      (d) => d.departamento_id === datos.departamento_id
    );
    if (
      !departamento ||
      (!departamento.activo && departamento.departamento_id !== empleado?.departamento_id)
    )
      return setError("El departamento seleccionado ya no está disponible.");

    if (editando && !motivo.trim())
      return setError("Explica el motivo de la modificación para dejar trazabilidad.");

    setGuardando(true);

    if (editando) {
      const { error: errEdicion } = await supabase.rpc("guardar_empleado_v35", {
        p_empleado_id: empleado.id,
        p_datos: {
          tipo_identificacion: datos.tipo_identificacion,
          identificacion: datos.identificacion,
          nombres: datos.nombres,
          apellidos: datos.apellidos,
          fecha_nacimiento: datos.fecha_nacimiento || null,
          estado_civil: datos.estado_civil || null,
          direccion: datos.direccion || null,
          telefono: datos.telefono || null,
          email: datos.email || null,
          contacto_emergencia_nombre: datos.contacto_emergencia_nombre || null,
          contacto_emergencia_telefono: datos.contacto_emergencia_telefono || null,
          fecha_ingreso_real: datos.fecha_ingreso_real,
          cargo: datos.cargo,
          tipo_contrato: datos.tipo_contrato,
          forma_pago: datos.forma_pago,
          banco: datos.forma_pago === "transferencia" ? datos.banco || null : null,
          tipo_cuenta:
            datos.forma_pago === "transferencia" ? datos.tipo_cuenta : null,
          numero_cuenta:
            datos.forma_pago === "transferencia" ? datos.numero_cuenta || null : null,
          observacion: datos.observacion || null,
        },
        p_departamento_id: departamento.departamento_id,
        p_motivo: motivo,
        p_idempotency_key: nuevaClaveIdempotencia(),
      });
      setGuardando(false);
      if (errEdicion) return setError(mensajeError(errEdicion));
      onListo();
      return;
    }

    const { error: errEmpleado } = await supabase.rpc(
      "crear_empleado_completo_v34",
      {
        p_datos: {
          grupo_id: grupoId,
          tipo_identificacion: datos.tipo_identificacion,
          identificacion: datos.identificacion,
          nombres: datos.nombres,
          apellidos: datos.apellidos,
          fecha_ingreso_real: datos.fecha_ingreso_real,
          cargo: datos.cargo,
          fecha_nacimiento: datos.fecha_nacimiento || null,
          estado_civil: datos.estado_civil || null,
          direccion: datos.direccion || null,
          telefono: datos.telefono || null,
          email: datos.email || null,
          contacto_emergencia_nombre: datos.contacto_emergencia_nombre || null,
          contacto_emergencia_telefono: datos.contacto_emergencia_telefono || null,
          tipo_contrato: datos.tipo_contrato,
          forma_pago: datos.forma_pago,
          banco:
            datos.forma_pago === "transferencia" ? datos.banco.trim() || null : null,
          tipo_cuenta:
            datos.forma_pago === "transferencia" ? datos.tipo_cuenta : null,
          numero_cuenta:
            datos.forma_pago === "transferencia"
              ? datos.numero_cuenta.trim() || null
              : null,
          observacion: datos.observacion || null,
        },
        p_departamento_id: departamento.departamento_id,
        p_afiliacion: {
          afiliado: afiliacion.afiliado,
          empresa_id: afiliacion.afiliado ? afiliacion.empresa_id : null,
          fecha_afiliacion: afiliacion.afiliado ? afiliacion.fecha_afiliacion : null,
          sueldo_declarado: afiliacion.afiliado
            ? Number(afiliacion.sueldo_declarado)
            : 0,
        },
        p_compensacion: {
          empresa_pagadora_id: compensacion.empresa_pagadora_id,
          sueldo_real: Number(compensacion.sueldo_real),
        },
        p_idempotency_key: nuevaClaveIdempotencia(),
      }
    );
    setGuardando(false);
    if (errEmpleado) {
      return setError(mensajeError(errEmpleado));
    }

    onListo();
  }

  return (
    <div className="card-interna">
      <h4>{editando ? "Editar datos personales" : "Nueva persona"}</h4>
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
        <label>
          Correo
          <input
            type="email"
            value={datos.email}
            onChange={(e) => setDatos({ ...datos, email: e.target.value })}
          />
        </label>
        <label>
          Estado civil
          <select
            value={datos.estado_civil}
            onChange={(e) => setDatos({ ...datos, estado_civil: e.target.value })}
          >
            <option value="">Sin registrar</option>
            <option value="soltero">Soltero/a</option>
            <option value="casado">Casado/a</option>
            <option value="divorciado">Divorciado/a</option>
            <option value="viudo">Viudo/a</option>
            <option value="union_hecho">Unión de hecho</option>
          </select>
        </label>
        <label>
          Dirección
          <input
            type="text"
            value={datos.direccion}
            onChange={(e) => setDatos({ ...datos, direccion: e.target.value })}
          />
        </label>
        <label>
          Contacto de emergencia
          <input
            type="text"
            value={datos.contacto_emergencia_nombre}
            onChange={(e) =>
              setDatos({ ...datos, contacto_emergencia_nombre: e.target.value })
            }
          />
        </label>
        <label>
          Teléfono de emergencia
          <input
            type="text"
            value={datos.contacto_emergencia_telefono}
            onChange={(e) =>
              setDatos({ ...datos, contacto_emergencia_telefono: e.target.value })
            }
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
            disabled={editando}
            onChange={(e) => setDatos({ ...datos, fecha_ingreso_real: e.target.value })}
          />
          <small>Manda para vacaciones, décimos y antigüedad.</small>
          {editando && <small>Se corrige mediante el flujo laboral controlado.</small>}
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
          Departamento
          <select
            value={datos.departamento_id}
            onChange={(e) => setDatos({ ...datos, departamento_id: e.target.value })}
          >
            <option value="">Elegir…</option>
            {departamentos
              .filter(
                (d) => d.activo || d.departamento_id === empleado?.departamento_id
              )
              .map((d) => (
                <option key={d.departamento_id} value={d.departamento_id}>
                  {d.codigo} · {d.nombre}{d.activo ? "" : " (inactivo)"}
                </option>
              ))}
          </select>
          {!departamentos.some((d) => d.activo) && (
            <small>Crea primero un departamento en la pestaña Departamentos.</small>
          )}
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

      <h5>Forma de pago</h5>
      <div className="form-grid">
        <label>
          Forma de pago
          <select
            value={datos.forma_pago}
            onChange={(e) => setDatos({ ...datos, forma_pago: e.target.value })}
          >
            <option value="transferencia">Transferencia bancaria</option>
            <option value="efectivo">Efectivo</option>
            <option value="cheque">Cheque</option>
          </select>
        </label>
        {datos.forma_pago === "transferencia" && (
          <>
            <label>
              Banco
              <input
                type="text"
                value={datos.banco}
                onChange={(e) => setDatos({ ...datos, banco: e.target.value })}
                placeholder="Nombre del banco"
                autoComplete="off"
              />
            </label>
            <label>
              Tipo de cuenta
              <select
                value={datos.tipo_cuenta}
                onChange={(e) => setDatos({ ...datos, tipo_cuenta: e.target.value })}
              >
                <option value="ahorros">Ahorros</option>
                <option value="corriente">Corriente</option>
              </select>
            </label>
            <label>
              Número de cuenta
              <input
                type="text"
                value={datos.numero_cuenta}
                onChange={(e) => setDatos({ ...datos, numero_cuenta: e.target.value })}
                placeholder="Número de cuenta bancaria"
                autoComplete="off"
              />
              <small>Banco y número son obligatorios para transferencias.</small>
            </label>
          </>
        )}
      </div>

      <label>
        Observación
        <textarea
          value={datos.observacion}
          onChange={(e) => setDatos({ ...datos, observacion: e.target.value })}
          rows={2}
        />
      </label>

      {!editando && (
        <>
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
        </>
      )}

      {editando && (
        <label>
          Motivo de la modificación
          <textarea
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
            rows={2}
            placeholder="Ej.: actualización solicitada por la persona"
          />
          <small>Se guarda junto a cada campo modificado en la auditoría.</small>
        </label>
      )}

      <div className="filtros">
        <button onClick={guardar} disabled={guardando}>
          {guardando ? "Guardando…" : editando ? "Guardar cambios" : "Crear persona"}
        </button>
        <button className="secondary" onClick={onCancelar} disabled={guardando}>
          Cancelar
        </button>
      </div>
    </div>
  );
}
