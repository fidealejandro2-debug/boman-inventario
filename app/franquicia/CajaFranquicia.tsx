"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { exportarCSV } from "@/lib/utils";
import type { Franquicia } from "./FranquiciaCliente";
import {
  CATEGORIAS_CAJA,
  MEDIOS_PAGO,
  dinero,
  hoyLocalISO,
  mensajeError,
} from "./lib";

type Movimiento = {
  id: string;
  fecha: string;
  tipo: "ingreso" | "egreso";
  categoria: string;
  concepto: string;
  monto: number;
  medio_pago: string;
  referencia: string | null;
  estado: string;
  venta_id: string | null;
  reversa_de_id: string | null;
  motivo_reversa: string | null;
  saldo_acumulado: number;
  created_at: string;
};

export default function CajaFranquicia({ franquicia }: { franquicia: Franquicia }) {
  const supabase = createClient();
  const [movs, setMovs] = useState<Movimiento[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  const primerDia = `${hoyLocalISO().slice(0, 7)}-01`;
  const [desde, setDesde] = useState(primerDia);
  const [hasta, setHasta] = useState(hoyLocalISO());

  const [form, setForm] = useState({
    fecha: hoyLocalISO(),
    tipo: "egreso" as "ingreso" | "egreso",
    categoria: "otro_egreso",
    concepto: "",
    monto: "",
    medio_pago: "efectivo",
    referencia: "",
  });

  async function cargar() {
    setCargando(true);
    const { data, error } = await supabase
      .from("vista_caja_franquicia_v42")
      .select("*")
      .eq("franquicia_id", franquicia.id)
      .gte("fecha", desde)
      .lte("fecha", hasta)
      .order("fecha", { ascending: false })
      .order("created_at", { ascending: false });
    if (error) setError(error.message);
    else setMovs((data as Movimiento[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [franquicia.id, desde, hasta]);

  const categorias = CATEGORIAS_CAJA.filter((c) => c.tipo === form.tipo);

  async function registrar() {
    if (!form.concepto.trim()) return setError("Escribe el concepto del movimiento.");
    if (Number(form.monto) <= 0) return setError("El monto debe ser mayor a cero.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_caja_franquicia_v42", {
      p_fecha: form.fecha,
      p_tipo: form.tipo,
      p_categoria: form.categoria,
      p_concepto: form.concepto,
      p_monto: Number(form.monto),
      p_medio_pago: form.medio_pago,
      p_referencia: form.referencia || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Movimiento registrado en la caja.");
    setForm({ ...form, concepto: "", monto: "", referencia: "" });
    cargar();
  }

  // No se borra: se emite una contrapartida que deja ambas filas a la vista.
  async function revertir(m: Movimiento) {
    if (m.venta_id) {
      return setError(
        "Este movimiento viene de una venta. Se corrige anulando la venta, no la caja."
      );
    }
    const motivo = window.prompt("Motivo de la reversión:");
    if (!motivo?.trim()) return;
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("revertir_caja_franquicia_v42", {
      p_movimiento_id: m.id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Movimiento revertido; queda su contrapartida en el diario.");
    cargar();
  }

  const totales = useMemo(() => {
    // El original revertido ya sale del saldo; su contrapartida es evidencia
    // en el diario, no un movimiento mas, o la reversa restaria dos veces.
    const vig = movs.filter((m) => m.estado === "vigente" && !m.reversa_de_id);
    const ing = vig.filter((m) => m.tipo === "ingreso").reduce((s, m) => s + Number(m.monto), 0);
    const egr = vig.filter((m) => m.tipo === "egreso").reduce((s, m) => s + Number(m.monto), 0);
    return { ing, egr, saldo: ing - egr };
  }, [movs]);

  if (cargando) return <p className="ayuda">Cargando caja…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      <p className="ayuda">
        Diario operativo del local para saber cuánto entra y cuánto sale. Es control
        interno del negocio: <strong>no sustituye la contabilidad</strong> ni los
        registros tributarios. Las ventas entran solas.
      </p>

      <div className="kpis">
        <div className="kpi">
          <span className="valor">{dinero(totales.ing)}</span>
          <span className="label">Ingresos del período</span>
        </div>
        <div className="kpi">
          <span className="valor">{dinero(totales.egr)}</span>
          <span className="label">Egresos del período</span>
        </div>
        <div className={`kpi ${totales.saldo < 0 ? "alerta" : ""}`}>
          <span className="valor">{dinero(totales.saldo)}</span>
          <span className="label">Saldo del período</span>
        </div>
      </div>

      <div className="card-interna">
        <h4>Registrar movimiento</h4>
        <div className="form-grid">
          <label>
            Tipo
            <select
              value={form.tipo}
              onChange={(e) => {
                const tipo = e.target.value as "ingreso" | "egreso";
                const cats = CATEGORIAS_CAJA.filter((c) => c.tipo === tipo);
                setForm({ ...form, tipo, categoria: cats[0].valor });
              }}
            >
              <option value="egreso">Egreso</option>
              <option value="ingreso">Ingreso</option>
            </select>
          </label>
          <label>
            Categoría
            <select
              value={form.categoria}
              onChange={(e) => setForm({ ...form, categoria: e.target.value })}
            >
              {categorias.map((c) => (
                <option key={c.valor} value={c.valor}>
                  {c.etiqueta}
                </option>
              ))}
            </select>
          </label>
          <label>
            Fecha
            <input
              type="date"
              value={form.fecha}
              max={hoyLocalISO()}
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
            Medio de pago
            <select
              value={form.medio_pago}
              onChange={(e) => setForm({ ...form, medio_pago: e.target.value })}
            >
              {MEDIOS_PAGO.map((m) => (
                <option key={m.valor} value={m.valor}>
                  {m.etiqueta}
                </option>
              ))}
            </select>
          </label>
          <label>
            Referencia
            <input
              type="text"
              value={form.referencia}
              onChange={(e) => setForm({ ...form, referencia: e.target.value })}
            />
          </label>
          <label className="ancho-total">
            Concepto
            <input
              type="text"
              placeholder="Ej. Pago de arriendo de septiembre"
              value={form.concepto}
              onChange={(e) => setForm({ ...form, concepto: e.target.value })}
            />
          </label>
        </div>
        <button onClick={registrar} disabled={guardando}>
          {guardando ? "Registrando…" : "Registrar movimiento"}
        </button>
      </div>

      <div className="filtros">
        <label className="check-inline">
          Desde
          <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} />
        </label>
        <label className="check-inline">
          Hasta
          <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} />
        </label>
        <button
          className="secondary"
          onClick={() => exportarCSV("caja_franquicia", movs)}
          disabled={!movs.length}
        >
          Exportar
        </button>
      </div>

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Fecha</th>
              <th>Concepto</th>
              <th>Categoría</th>
              <th>Medio</th>
              <th className="num">Ingreso</th>
              <th className="num">Egreso</th>
              <th className="num">Saldo</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {movs.map((m) => (
              <tr key={m.id} className={m.estado !== "vigente" ? "fila-anulada" : ""}>
                <td>{m.fecha.split("-").reverse().join("/")}</td>
                <td>
                  {m.concepto}
                  {m.venta_id && <span className="badge ok">venta</span>}
                  {m.motivo_reversa && (
                    <div className="fq-alerta">Revertido: {m.motivo_reversa}</div>
                  )}
                </td>
                <td>{m.categoria}</td>
                <td>{m.medio_pago}</td>
                <td className="num">{m.tipo === "ingreso" ? dinero(m.monto) : "—"}</td>
                <td className="num">{m.tipo === "egreso" ? dinero(m.monto) : "—"}</td>
                <td className="num">{dinero(m.saldo_acumulado)}</td>
                <td>
                  {m.estado === "vigente" && !m.venta_id && (
                    <button
                      className="btn-mini secondary"
                      disabled={guardando}
                      onClick={() => revertir(m)}
                    >
                      Revertir
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {!movs.length && (
              <tr>
                <td colSpan={8} className="vacio">
                  Sin movimientos en el período seleccionado.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
