"use client";

// Pestaña "Egresos" del panel de tienda propia. Se escribió aparte en vez de
// extraer el formulario de CajaFranquicia.tsx: ese archivo ya funciona en
// producción (lo reusa CajaTiendaCliente tal cual) y su formulario de
// movimiento está entrelazado con el cierre/depósitos — separarlo era más
// riesgo que beneficio para lo que se pidió (que Egresos sea su propia
// pestaña, no enterrada dentro de Caja). Los egresos que se registran aquí
// y los que se registran desde la pestaña Caja son el mismo dato
// (franquicia_caja_movimientos vía registrar_caja_franquicia_v42): esta
// pantalla es otra puerta de entrada, no una tabla paralela.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { CATEGORIAS_CAJA, MEDIOS_PAGO, dinero, hoyLocalISO, mensajeError } from "@/app/franquicia/lib";
import { pedirMotivoDialogo } from "@/components/Dialogo";

const CATEGORIAS_EGRESO = CATEGORIAS_CAJA.filter((c) => c.tipo === "egreso");

type Egreso = {
  id: string;
  fecha: string;
  categoria: string;
  concepto: string;
  monto: number;
  medio_pago: string;
  referencia: string | null;
  estado: string;
  created_at: string;
};

export default function EgresosTienda({ almacenId, soloLectura = false }: { almacenId: string; soloLectura?: boolean }) {
  const supabase = createClient();
  const [egresos, setEgresos] = useState<Egreso[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [form, setForm] = useState({
    fecha: hoyLocalISO(),
    categoria: CATEGORIAS_EGRESO[0].valor,
    concepto: "",
    monto: "",
    medio_pago: "efectivo",
    referencia: "",
  });

  async function cargar() {
    setCargando(true);
    const { data, error: fallo } = await supabase
      .from("franquicia_caja_movimientos")
      .select("id, fecha, categoria, concepto, monto, medio_pago, referencia, estado, created_at")
      .eq("almacen_id", almacenId)
      .eq("tipo", "egreso")
      .order("fecha", { ascending: false })
      .order("created_at", { ascending: false })
      .limit(100);
    if (fallo) setError(mensajeError(fallo));
    else setEgresos((data as Egreso[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    void cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [almacenId]);

  async function registrar() {
    if (!form.concepto.trim()) return setError("Describe el egreso.");
    const monto = Number(form.monto);
    if (!Number.isFinite(monto) || monto <= 0) return setError("El monto debe ser mayor que cero.");
    if (["transferencia", "tarjeta"].includes(form.medio_pago) && !form.referencia.trim()) {
      return setError("Transferencia y tarjeta requieren número de referencia.");
    }
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_caja_franquicia_v42", {
      p_fecha: form.fecha,
      p_tipo: "egreso",
      p_categoria: form.categoria,
      p_concepto: form.concepto.trim(),
      p_monto: monto,
      p_medio_pago: form.medio_pago,
      p_referencia: form.referencia.trim() || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
      p_almacen_id: almacenId,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setForm({ fecha: hoyLocalISO(), categoria: CATEGORIAS_EGRESO[0].valor, concepto: "", monto: "", medio_pago: "efectivo", referencia: "" });
    void cargar();
  }

  async function revertir(e: Egreso) {
    const motivo = (await pedirMotivoDialogo(`Motivo para revertir el egreso "${e.concepto}" (mínimo 10 caracteres).`))?.trim();
    if (!motivo) return;
    if (motivo.length < 10) return setError("El motivo debe tener al menos 10 caracteres.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("revertir_caja_franquicia_v42", {
      p_movimiento_id: e.id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    void cargar();
  }

  return (
    <div>
      {error && <div className="error-box">{error}</div>}

      {!soloLectura && (
        <div className="card-interna">
          <h4>Registrar egreso</h4>
          <div className="form-grid">
            <label>
              Categoría
              <select value={form.categoria} onChange={(e) => setForm({ ...form, categoria: e.target.value })}>
                {CATEGORIAS_EGRESO.map((c) => (
                  <option key={c.valor} value={c.valor}>{c.etiqueta}</option>
                ))}
              </select>
            </label>
            <label>
              Fecha
              <input type="date" value={form.fecha} max={hoyLocalISO()} onChange={(e) => setForm({ ...form, fecha: e.target.value })} />
            </label>
            <label>
              Monto
              <input type="number" step="0.01" min="0" value={form.monto} onChange={(e) => setForm({ ...form, monto: e.target.value })} />
            </label>
            <label>
              Medio de pago
              <select value={form.medio_pago} onChange={(e) => setForm({ ...form, medio_pago: e.target.value })}>
                {MEDIOS_PAGO.filter((m) => m.valor !== "mixto").map((m) => (
                  <option key={m.valor} value={m.valor}>{m.etiqueta}</option>
                ))}
              </select>
            </label>
            {["transferencia", "tarjeta"].includes(form.medio_pago) && (
              <label>
                Referencia
                <input type="text" value={form.referencia} onChange={(e) => setForm({ ...form, referencia: e.target.value })} />
              </label>
            )}
            <label className="ancho-total">
              Concepto
              <input type="text" placeholder="Ej: Arriendo de octubre" value={form.concepto} onChange={(e) => setForm({ ...form, concepto: e.target.value })} />
            </label>
          </div>
          <button type="button" onClick={registrar} disabled={guardando}>
            {guardando ? "Guardando…" : "Registrar egreso"}
          </button>
        </div>
      )}

      <div className="card-interna">
        <h4>Últimos egresos</h4>
        {cargando ? (
          <p className="ayuda">Cargando…</p>
        ) : !egresos.length ? (
          <p className="ayuda">Todavía no hay egresos registrados en este local.</p>
        ) : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th><th>Categoría</th><th>Concepto</th>
                  <th className="num">Monto</th><th>Medio</th><th>Estado</th><th></th>
                </tr>
              </thead>
              <tbody>
                {egresos.map((e) => (
                  <tr key={e.id} className={e.estado === "revertido" ? "fila-anulada" : ""}>
                    <td>{e.fecha.split("-").reverse().join("/")}</td>
                    <td>{CATEGORIAS_EGRESO.find((c) => c.valor === e.categoria)?.etiqueta ?? e.categoria}</td>
                    <td>{e.concepto}</td>
                    <td className="num">{dinero(e.monto)}</td>
                    <td>{MEDIOS_PAGO.find((m) => m.valor === e.medio_pago)?.etiqueta ?? e.medio_pago}</td>
                    <td>{e.estado === "revertido" ? "Revertido" : "Vigente"}</td>
                    <td>
                      {!soloLectura && e.estado === "vigente" && (
                        <button type="button" className="secondary btn-mini" onClick={() => revertir(e)} disabled={guardando}>
                          Revertir
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
