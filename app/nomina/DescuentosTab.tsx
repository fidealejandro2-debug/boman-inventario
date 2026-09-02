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
  pedirMotivo,
  ETIQUETA_ORIGEN_DESCUENTO,
  type Empleado,
  type Empresa,
} from "./lib";
import SelectorDocumento from "./SelectorDocumento";
import ActaDescuento, { type DatosActa } from "./ActaDescuento";
import Aviso from "@/components/Aviso";

type Anticipo = {
  id: string;
  empleado_id: string;
  identificacion: string;
  apellidos: string;
  nombres: string;
  empresa_pagadora: string;
  fecha: string;
  monto: number;
  motivo: string;
  cuotas: number;
  fecha_primera_cuota: string;
  estado: string;
  saldo: number | null;
};

type Descuento = {
  id: string;
  empleado_id: string;
  identificacion: string;
  apellidos: string;
  nombres: string;
  empresa_acreedora: string | null;
  origen: string;
  descripcion: string;
  monto_total: number;
  monto_aplicado: number;
  saldo: number;
  cuotas_total: number;
  cuotas_pagadas: number;
  monto_cuota: number;
  fecha_inicio: string;
  estado: string;
  prioridad: number;
  cuotas_pendientes: number;
  cuota_pendiente_mas_antigua: string | null;
};

export default function DescuentosTab({
  puedeEscribir,
  empleados,
  empresas,
}: {
  puedeEscribir: boolean;
  empleados: Empleado[];
  empresas: Empresa[];
}) {
  const supabase = createClient();
  const [vista, setVista] = useState<"anticipos" | "descuentos">("anticipos");
  const [anticipos, setAnticipos] = useState<Anticipo[]>([]);
  const [pendientes, setPendientes] = useState<
    { anticipo_id: string; empleado: string; monto: number; dias_pendiente: number; antiguedad: string }[]
  >([]);
  const [acta, setActa] = useState<DatosActa | null>(null);
  const [descuentos, setDescuentos] = useState<Descuento[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [busqueda, setBusqueda] = useState("");
  const [mostrarForm, setMostrarForm] = useState(false);

  const [form, setForm] = useState({
    empleado_id: "",
    empresa_pagadora_id: "",
    fecha: hoyISO(),
    monto: "",
    motivo: "",
    cuotas: "1",
    fecha_primera_cuota: hoyISO().slice(0, 7),
    documento_respaldo_id: null as string | null,
  });

  const [formDescuento, setFormDescuento] = useState({
    empleado_id: "",
    empresa_acreedora_id: "",
    origen: "prestamo_empresa",
    descripcion: "",
    monto_total: "",
    cuotas: "1",
    mes_inicio: hoyISO().slice(0, 7),
    documento_respaldo_id: null as string | null,
  });

  async function cargar() {
    setCargando(true);
    const [a, d, p] = await Promise.all([
      supabase.from("vista_anticipos_v29").select("*").order("fecha", { ascending: false }),
      supabase
        .from("vista_descuentos_programados_v29")
        .select("*")
        .order("prioridad")
        .order("fecha_inicio", { ascending: false }),
      supabase
        .from("vista_anticipos_respaldo_pendiente_v55")
        .select("anticipo_id, empleado, monto, dias_pendiente, antiguedad")
        .order("dias_pendiente", { ascending: false }),
    ]);
    if (a.error) setError(a.error.message);
    else setAnticipos((a.data as Anticipo[]) ?? []);
    if (!d.error) setDescuentos((d.data as Descuento[]) ?? []);
    // Si v55 aun no esta instalada la vista no existe: el aviso simplemente no
    // aparece, en vez de romper toda la pestana.
    if (!p.error) setPendientes((p.data as typeof pendientes) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!form.empleado_id || form.empresa_pagadora_id) return;
    const emp = empleados.find((e) => e.empleado_id === form.empleado_id);
    if (emp?.empresa_pagadora_id)
      setForm((f) => ({ ...f, empresa_pagadora_id: emp.empresa_pagadora_id! }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form.empleado_id]);

  useEffect(() => {
    const mesAnticipo = form.fecha.slice(0, 7);
    if (form.fecha_primera_cuota < mesAnticipo) {
      setForm((f) => ({ ...f, fecha_primera_cuota: mesAnticipo }));
    }
  }, [form.fecha, form.fecha_primera_cuota]);

  useEffect(() => {
    if (!formDescuento.empleado_id || formDescuento.empresa_acreedora_id) return;
    const emp = empleados.find((e) => e.empleado_id === formDescuento.empleado_id);
    if (emp?.empresa_pagadora_id) {
      setFormDescuento((f) => ({
        ...f,
        empresa_acreedora_id: emp.empresa_pagadora_id!,
      }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [formDescuento.empleado_id]);

  async function solicitar() {
    if (!form.empleado_id || !form.empresa_pagadora_id)
      return setError("Falta la persona o la empresa que desembolsa.");
    if (!form.motivo.trim()) return setError("El motivo es obligatorio.");
    if (Number(form.monto) <= 0) return setError("El monto debe ser mayor a cero.");
    if (!Number.isInteger(Number(form.cuotas)) || Number(form.cuotas) < 1)
      return setError("El número de cuotas no es válido.");
    if (!form.fecha_primera_cuota)
      return setError("Elige el mes de la primera cuota.");
    // El papel se firma despues, asi que exigirlo aqui trababa el anticipo o
    // empujaba a adjuntar cualquier archivo con tal de avanzar. Se avisa una
    // vez y queda como respaldo pendiente hasta que se suba.
    if (!form.documento_respaldo_id) {
      const seguir = window.confirm(
        `Vas a registrar el anticipo SIN la solicitud firmada.

Queda marcado como respaldo pendiente y aparecerá en la lista de documentos por subir hasta que lo adjuntes. Sin ese papel el descuento no tiene sustento documental frente a una inspección.

¿Continuar?`
      );
      if (!seguir) return;
    }
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("solicitar_anticipo_v29", {
      p_empleado_id: form.empleado_id,
      p_empresa_pagadora_id: form.empresa_pagadora_id,
      p_fecha: form.fecha,
      p_monto: Number(form.monto),
      p_motivo: form.motivo,
      p_cuotas: Number(form.cuotas),
      p_fecha_primera_cuota: `${form.fecha_primera_cuota}-01`,
      p_documento_respaldo_id: form.documento_respaldo_id,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(
      form.documento_respaldo_id
        ? "Anticipo solicitado."
        : "Anticipo solicitado SIN respaldo. Sube la solicitud firmada en cuanto la tengas: queda pendiente en el expediente."
    );
    setMostrarForm(false);
    setForm({
      ...form,
      monto: "",
      motivo: "",
      cuotas: "1",
      documento_respaldo_id: null,
    });
    cargar();
  }

  async function anularDescuento(d: Descuento) {
    const { motivo, error: errMotivo } = pedirMotivo(
      `Vas a ANULAR el descuento de ${d.apellidos} ${d.nombres} por ${dinero(d.monto_total)}.

Se usa cuando el descuento nunca debio existir: por ejemplo, la persona devolvió el anticipo antes de que corriera el rol. Se cancelan las cuotas pendientes para que el próximo cierre no las aplique.

Motivo de la anulación:`
    );
    if (errMotivo) return setError(errMotivo);
    if (!motivo) return;
    setGuardando(true);
    setError(null);
    const { data, error } = await supabase.rpc("anular_descuento_v56", {
      p_descuento_id: d.id, p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso((data as { mensaje?: string } | null)?.mensaje ?? "Descuento anulado.");
    cargar();
  }

  async function archivarDescuento(id: string, estado: string) {
    const { motivo, error: errMotivo } = pedirMotivo(
      `Vas a archivar un descuento en estado "${estado}".

No se borra: queda en el historial como prueba de lo que se le retuvo a la persona, pero deja de aparecer en la lista activa.

Motivo del archivo:`
    );
    if (errMotivo) return setError(errMotivo);
    if (!motivo) return;
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("archivar_descuento_v56", {
      p_descuento_id: id, p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Descuento archivado. Sigue disponible en el historial.");
    cargar();
  }

  async function registrarDescuento() {
    if (!formDescuento.empleado_id)
      return setError("Elige a la persona del descuento.");
    if (!formDescuento.descripcion.trim())
      return setError("Describe claramente el descuento.");
    if (Number(formDescuento.monto_total) <= 0)
      return setError("El monto debe ser mayor a cero.");
    if (
      !Number.isInteger(Number(formDescuento.cuotas)) ||
      Number(formDescuento.cuotas) < 1 ||
      Number(formDescuento.cuotas) > 120
    ) {
      return setError("Las cuotas deben estar entre 1 y 120.");
    }
    if (!formDescuento.mes_inicio)
      return setError("Elige el mes en que empieza el descuento.");
    if (!formDescuento.documento_respaldo_id)
      return setError("Adjunta la autorización u orden que respalda el descuento.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_descuento_programado_v29", {
      p_empleado_id: formDescuento.empleado_id,
      p_empresa_acreedora_id: formDescuento.empresa_acreedora_id || null,
      p_origen: formDescuento.origen,
      p_origen_id: null,
      p_descripcion: formDescuento.descripcion.trim(),
      p_monto_total: Number(formDescuento.monto_total),
      p_cuotas: Number(formDescuento.cuotas),
      p_fecha_inicio: `${formDescuento.mes_inicio}-01`,
      p_documento_respaldo_id: formDescuento.documento_respaldo_id,
      p_prioridad: null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Descuento programado. Su cuota aparecerá al calcular el rol del mes elegido.");
    setMostrarForm(false);
    setFormDescuento({
      ...formDescuento,
      descripcion: "",
      monto_total: "",
      cuotas: "1",
      documento_respaldo_id: null,
    });
    cargar();
  }

  async function resolverAnticipo(id: string, aprobar: boolean) {
    const motivo = window.prompt(
      aprobar ? "Observación de la aprobación:" : "Motivo del rechazo:"
    );
    if (!aprobar && !motivo?.trim()) return;
    setGuardando(true);
    const { error } = await supabase.rpc("resolver_anticipo_v29", {
      p_anticipo_id: id,
      p_aprobar: aprobar,
      p_motivo: motivo || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(aprobar ? "Anticipo aprobado." : "Anticipo rechazado.");
    cargar();
  }

  async function desembolsar(id: string) {
    const forma = window.prompt("Forma de desembolso (transferencia, efectivo, cheque):", "transferencia");
    if (!forma) return;
    const referencia = window.prompt("Referencia del pago (opcional):");
    setGuardando(true);
    const { error } = await supabase.rpc("desembolsar_anticipo_v29", {
      p_anticipo_id: id,
      p_forma_desembolso: forma,
      p_referencia: referencia || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Anticipo desembolsado; su descuento queda programado.");
    cargar();
  }

  async function anularAnticipo(id: string) {
    const { motivo, error: errMotivo } = pedirMotivo("Motivo de la anulación:");
    if (errMotivo) return setError(errMotivo);
    if (!motivo) return;
    setGuardando(true);
    const { error } = await supabase.rpc("anular_anticipo_v29", {
      p_anticipo_id: id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Anticipo anulado.");
    cargar();
  }

  async function accionDescuento(id: string, accion: string) {
    const { motivo, error: errMotivo } = pedirMotivo(`Motivo para ${accion} este descuento:`);
    if (errMotivo) return setError(errMotivo);
    if (!motivo) return;
    setGuardando(true);
    const { error } = await supabase.rpc("resolver_descuento_programado_v29", {
      p_descuento_id: id,
      p_accion: accion,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Descuento actualizado.");
    cargar();
  }

  const anticiposVisibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return anticipos;
    return anticipos.filter(
      (a) =>
        `${a.apellidos} ${a.nombres}`.toLowerCase().includes(q) ||
        a.identificacion.includes(q)
    );
  }, [anticipos, busqueda]);

  const descuentosVisibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return descuentos;
    return descuentos.filter(
      (d) =>
        `${d.apellidos} ${d.nombres}`.toLowerCase().includes(q) ||
        d.identificacion.includes(q)
    );
  }, [descuentos, busqueda]);

  const saldoVigente = descuentos
    .filter((d) => d.estado === "vigente")
    .reduce((s, d) => s + Number(d.saldo), 0);

  // El acta ocupa la pantalla: al imprimir, globals.css oculta lo demas.
  if (acta) return <ActaDescuento datos={acta} onCerrar={() => setActa(null)} />;

  if (cargando) return <p className="ayuda">Cargando anticipos y descuentos…</p>;

  return (
    <>
      <Aviso error={error} aviso={aviso} onCerrar={(cual) => (cual === "error" ? setError(null) : setAviso(null))} />
      {pendientes.length > 0 && (
        <div className="aviso">
          <strong>
            {pendientes.length} anticipo(s) sin respaldo documental.
          </strong>{" "}
          Sube la solicitud firmada al expediente: sin ese papel el descuento no
          tiene sustento frente a una inspección.
          <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>
            {pendientes.slice(0, 5).map((p) => (
              <li key={p.anticipo_id}>
                {p.empleado} · {dinero(p.monto)} ·{" "}
                <strong>{p.dias_pendiente} día(s)</strong>
                {p.antiguedad === "vencido" ? " — vencido" : ""}
              </li>
            ))}
            {pendientes.length > 5 && <li>y {pendientes.length - 5} más…</li>}
          </ul>
        </div>
      )}

      <div className="kpis">
        <div className="kpi">
          <span className="valor">
            {anticipos.filter((a) => a.estado === "solicitado").length}
          </span>
          <span className="label">Anticipos por aprobar</span>
        </div>
        <div className="kpi">
          <span className="valor">
            {anticipos.filter((a) => a.estado === "aprobado").length}
          </span>
          <span className="label">Aprobados sin desembolsar</span>
        </div>
        <div className="kpi">
          <span className="valor">{dinero(saldoVigente)}</span>
          <span className="label">Saldo por descontar</span>
        </div>
      </div>

      <div className="filtros">
        <select
          value={vista}
          onChange={(e) => {
            setVista(e.target.value as "anticipos" | "descuentos");
            setMostrarForm(false);
          }}
        >
          <option value="anticipos">Anticipos</option>
          <option value="descuentos">Descuentos programados</option>
        </select>
        {puedeEscribir && (
          <button onClick={() => setMostrarForm(!mostrarForm)}>
            {mostrarForm
              ? "Cancelar"
              : vista === "anticipos"
                ? "Nuevo anticipo"
                : "Nuevo descuento"}
          </button>
        )}
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
              vista === "anticipos" ? "anticipos" : "descuentos",
              vista === "anticipos" ? anticiposVisibles : descuentosVisibles
            )
          }
        >
          Exportar
        </button>
      </div>

      <p className="ayuda">
        El anticipo se solicita y desembolsa primero; recién entonces crea sus cuotas.
        Los demás descuentos se programan directamente con respaldo. La fecha de inicio
        determina en qué rol mensual se intenta aplicar la primera cuota.
      </p>

      {mostrarForm && puedeEscribir && vista === "anticipos" && (
        <div className="card-interna">
          <h4>Nuevo anticipo</h4>
          <div className="form-grid">
            <label>
              Persona
              <select
                value={form.empleado_id}
                onChange={(e) =>
                  setForm({
                    ...form,
                    empleado_id: e.target.value,
                    empresa_pagadora_id: "",
                    documento_respaldo_id: null,
                  })
                }
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
              Empresa que desembolsa
              <select
                value={form.empresa_pagadora_id}
                onChange={(e) => setForm({ ...form, empresa_pagadora_id: e.target.value })}
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
              Fecha
              <input
                type="date"
                value={form.fecha}
                onChange={(e) => setForm({ ...form, fecha: e.target.value })}
              />
            </label>
            <label>
              Monto
              <input
                type="number"
                step="0.01"
                min="0"
                value={form.monto}
                onChange={(e) => setForm({ ...form, monto: e.target.value })}
              />
            </label>
            <label>
              Cuotas
              <input
                type="number"
                min="1"
                value={form.cuotas}
                onChange={(e) => setForm({ ...form, cuotas: e.target.value })}
              />
            </label>
            <label>
              Primera cuota
              <input
                type="month"
                min={form.fecha.slice(0, 7)}
                value={form.fecha_primera_cuota}
                onChange={(e) => setForm({ ...form, fecha_primera_cuota: e.target.value })}
              />
            </label>
            <label className="ancho-total">
              Motivo
              <input
                type="text"
                value={form.motivo}
                onChange={(e) => setForm({ ...form, motivo: e.target.value })}
              />
            </label>
            <div className="ancho-total">
              <SelectorDocumento
                empleadoId={form.empleado_id || null}
                valor={form.documento_respaldo_id}
                onCambio={(id) => setForm({ ...form, documento_respaldo_id: id })}
                tipoSugerido="otro"
                etiqueta="Solicitud o autorización firmada (recomendado)"
              />
              <p className="ayuda">
                Si todavía no la tienes, puedes continuar: el anticipo queda con{" "}
                <strong>respaldo pendiente</strong> y figura en la lista de documentos
                por subir hasta que la adjuntes.
              </p>
            </div>
          </div>
          <button onClick={solicitar} disabled={guardando}>
            Solicitar anticipo
          </button>
        </div>
      )}

      {mostrarForm && puedeEscribir && vista === "descuentos" && (
        <div className="card-interna">
          <h4>Nuevo descuento programado</h4>
          <p className="ayuda">
            No uses este formulario para anticipos ni multas disciplinarias: esos tienen
            su propio flujo y controles.
          </p>
          <div className="form-grid">
            <label>
              Persona
              <select
                value={formDescuento.empleado_id}
                onChange={(e) =>
                  setFormDescuento({
                    ...formDescuento,
                    empleado_id: e.target.value,
                    empresa_acreedora_id: "",
                    documento_respaldo_id: null,
                  })
                }
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
              Tipo
              <select
                value={formDescuento.origen}
                onChange={(e) =>
                  setFormDescuento({ ...formDescuento, origen: e.target.value })
                }
              >
                {[
                  "prestamo_empresa",
                  "prestamo_iess",
                  "prestamo_quirografario",
                  "prestamo_hipotecario",
                  "judicial",
                  "uniforme",
                  "consumo_interno",
                  "otro",
                ].map((origen) => (
                  <option key={origen} value={origen}>
                    {ETIQUETA_ORIGEN_DESCUENTO[origen] ?? origen}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Empresa acreedora (si aplica)
              <select
                value={formDescuento.empresa_acreedora_id}
                onChange={(e) =>
                  setFormDescuento({
                    ...formDescuento,
                    empresa_acreedora_id: e.target.value,
                  })
                }
              >
                <option value="">Sin empresa acreedora</option>
                {empresas.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.razon_social}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Monto total
              <input
                type="number"
                step="0.01"
                min="0.01"
                value={formDescuento.monto_total}
                onChange={(e) =>
                  setFormDescuento({ ...formDescuento, monto_total: e.target.value })
                }
              />
            </label>
            <label>
              Cuotas mensuales
              <input
                type="number"
                min="1"
                max="120"
                value={formDescuento.cuotas}
                onChange={(e) =>
                  setFormDescuento({ ...formDescuento, cuotas: e.target.value })
                }
              />
            </label>
            <label>
              Aplicar desde el rol de
              <input
                type="month"
                value={formDescuento.mes_inicio}
                onChange={(e) =>
                  setFormDescuento({ ...formDescuento, mes_inicio: e.target.value })
                }
              />
            </label>
            <label className="ancho-total">
              Descripción
              <input
                type="text"
                value={formDescuento.descripcion}
                onChange={(e) =>
                  setFormDescuento({ ...formDescuento, descripcion: e.target.value })
                }
              />
            </label>
            <div className="ancho-total">
              <SelectorDocumento
                empleadoId={formDescuento.empleado_id || null}
                valor={formDescuento.documento_respaldo_id}
                onCambio={(id) =>
                  setFormDescuento({ ...formDescuento, documento_respaldo_id: id })
                }
                tipoSugerido="otro"
                etiqueta="Autorización u orden de descuento"
                requerido
              />
            </div>
          </div>
          <button onClick={registrarDescuento} disabled={guardando}>
            Programar descuento
          </button>
        </div>
      )}

      {vista === "anticipos" ? (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Persona</th>
                <th>Desembolsa</th>
                <th>Motivo</th>
                <th className="num">Monto</th>
                <th className="num">Cuotas</th>
                <th>Primera cuota</th>
                <th className="num">Saldo</th>
                <th>Estado</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {anticiposVisibles.map((a) => (
                <tr key={a.id}>
                  <td>{soloFecha(a.fecha)}</td>
                  <td>
                    {a.apellidos} {a.nombres}
                  </td>
                  <td>{a.empresa_pagadora}</td>
                  <td>{a.motivo}</td>
                  <td className="num">{dinero(a.monto)}</td>
                  <td className="num">{a.cuotas}</td>
                  <td>{soloFecha(a.fecha_primera_cuota)}</td>
                  <td className="num">{a.saldo === null ? "—" : dinero(a.saldo)}</td>
                  <td>
                    <span className={`badge estado-${a.estado}`}>{a.estado}</span>
                  </td>
                  {puedeEscribir && (
                    <td>
                      {a.estado === "solicitado" && (
                        <>
                          <button
                            className="btn-mini"
                            disabled={guardando}
                            onClick={() => resolverAnticipo(a.id, true)}
                          >
                            Aprobar
                          </button>
                          <button
                            className="btn-mini secondary"
                            disabled={guardando}
                            onClick={() => resolverAnticipo(a.id, false)}
                          >
                            Rechazar
                          </button>
                        </>
                      )}
                      {a.estado === "aprobado" && (
                        <button
                          className="btn-mini"
                          disabled={guardando}
                          onClick={() => desembolsar(a.id)}
                        >
                          Desembolsar
                        </button>
                      )}
                      {["solicitado", "aprobado"].includes(a.estado) && (
                        <button
                          className="btn-mini secondary"
                          disabled={guardando}
                          onClick={() => anularAnticipo(a.id)}
                        >
                          Anular
                        </button>
                      )}
                      <button
                        className="btn-mini secondary"
                        onClick={() =>
                          setActa({
                            clase: "anticipo",
                            empleado: `${a.apellidos} ${a.nombres}`,
                            identificacion: a.identificacion,
                            empresa: a.empresa_pagadora,
                            fecha: a.fecha,
                            monto: Number(a.monto),
                            cuotas: a.cuotas,
                            montoCuota: Math.round((Number(a.monto) / a.cuotas) * 100) / 100,
                            fechaPrimeraCuota: a.fecha_primera_cuota,
                            concepto: a.motivo,
                          })
                        }
                      >
                        Acta
                      </button>
                    </td>
                  )}
                </tr>
              ))}
              {!anticiposVisibles.length && (
                <tr>
                  <td colSpan={puedeEscribir ? 10 : 9} className="vacio">
                    Sin anticipos registrados.
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
                <th className="num">Prio.</th>
                <th>Persona</th>
                <th>Origen</th>
                <th>Descripción</th>
                <th className="num">Total</th>
                <th className="num">Aplicado</th>
                <th className="num">Saldo</th>
                <th className="num">Cuota</th>
                <th className="num">Cuotas</th>
                <th>Inicio</th>
                <th>Estado</th>
                {puedeEscribir && <th>Acciones</th>}
              </tr>
            </thead>
            <tbody>
              {descuentosVisibles.map((d) => (
                <tr key={d.id}>
                  <td className="num">{d.prioridad}</td>
                  <td>
                    {d.apellidos} {d.nombres}
                  </td>
                  <td>
                    {ETIQUETA_ORIGEN_DESCUENTO[d.origen] ?? d.origen}
                    {d.origen === "judicial" && (
                      <span className="badge bajo" title="Se aplica antes que cualquier otro descuento">
                        prioritario
                      </span>
                    )}
                  </td>
                  <td>{d.descripcion}</td>
                  <td className="num">{dinero(d.monto_total)}</td>
                  <td className="num">{dinero(d.monto_aplicado)}</td>
                  <td className="num">
                    <strong>{dinero(d.saldo)}</strong>
                  </td>
                  <td className="num">{dinero(d.monto_cuota)}</td>
                  <td className="num">
                    {d.cuotas_pagadas}/{d.cuotas_total}
                  </td>
                  <td>{soloFecha(d.fecha_inicio)}</td>
                  <td>
                    <span className={`badge estado-${d.estado}`}>{d.estado}</span>
                  </td>
                  {puedeEscribir && (
                    <td>
                      {d.estado === "vigente" && (
                        <>
                          <button
                            className="btn-mini secondary"
                            disabled={guardando}
                            onClick={() => accionDescuento(d.id, "suspender")}
                          >
                            Suspender
                          </button>
                          <button
                            className="btn-mini secondary"
                            disabled={guardando}
                            onClick={() => accionDescuento(d.id, "condonar")}
                          >
                            Condonar
                          </button>
                        </>
                      )}
                      {d.estado === "suspendido" && (
                        <button
                          className="btn-mini"
                          disabled={guardando}
                          onClick={() => accionDescuento(d.id, "reactivar")}
                        >
                          Reactivar
                        </button>
                      )}
                      {/* Nada aplicado todavia: el descuento puede no haber
                          existido nunca (devolvió el anticipo el mismo mes). */}
                      {d.monto_aplicado === 0 && d.estado !== "anulado" && (
                        <button
                          className="btn-mini peligro"
                          disabled={guardando}
                          onClick={() => anularDescuento(d)}
                        >
                          Anular
                        </button>
                      )}
                      {/* Un descuento con valores ya aplicados se archiva, nunca
                          se borra: es la prueba de lo que se le retuvo. */}
                      {["pagado", "condonado", "anulado"].includes(d.estado) && (
                        <button
                          className="btn-mini secondary"
                          disabled={guardando}
                          onClick={() => archivarDescuento(d.id, d.estado)}
                        >
                          Archivar
                        </button>
                      )}
                      <button
                        className="btn-mini secondary"
                        onClick={() =>
                          setActa({
                            clase: "descuento",
                            empleado: `${d.apellidos} ${d.nombres}`,
                            identificacion: d.identificacion,
                            empresa: d.empresa_acreedora ?? "",
                            fecha: d.fecha_inicio,
                            monto: Number(d.monto_total),
                            cuotas: d.cuotas_total,
                            montoCuota: Number(d.monto_cuota),
                            fechaPrimeraCuota: d.fecha_inicio,
                            concepto: d.descripcion,
                            origen: d.origen,
                          })
                        }
                      >
                        Acta
                      </button>
                    </td>
                  )}
                </tr>
              ))}
              {!descuentosVisibles.length && (
                <tr>
                  <td colSpan={puedeEscribir ? 12 : 11} className="vacio">
                    Sin descuentos programados.
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
