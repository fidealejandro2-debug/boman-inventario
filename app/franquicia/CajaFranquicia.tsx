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

type Cierre = {
  id: string;
  fecha: string;
  estado: "cerrado" | "reabierto";
  saldo_inicial_efectivo: number;
  ingresos_efectivo: number;
  egresos_efectivo: number;
  saldo_esperado_efectivo: number;
  efectivo_contado: number;
  diferencia: number;
  ingresos_total: number;
  egresos_total: number;
  nota: string | null;
  motivo_reapertura: string | null;
  cerrado_at: string;
};

type ResumenDia = {
  ingresos_total: number;
  egresos_total: number;
  ingresos_efectivo: number;
  egresos_efectivo: number;
};

export default function CajaFranquicia({
  franquicia,
  soloLectura = false,
}: {
  franquicia: Franquicia;
  /** Admin y Control revisan la caja del local; operarla es del titular. */
  soloLectura?: boolean;
}) {
  const supabase = createClient();
  const [movs, setMovs] = useState<Movimiento[]>([]);
  const [cierres, setCierres] = useState<Cierre[]>([]);
  const [resumenDia, setResumenDia] = useState<ResumenDia>({
    ingresos_total: 0,
    egresos_total: 0,
    ingresos_efectivo: 0,
    egresos_efectivo: 0,
  });
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  const primerDia = `${hoyLocalISO().slice(0, 7)}-01`;
  const [desde, setDesde] = useState(primerDia);
  const [hasta, setHasta] = useState(hoyLocalISO());
  const [fechaCierre, setFechaCierre] = useState(hoyLocalISO());
  const [saldoInicial, setSaldoInicial] = useState("");
  // null = es el primer cierre del local y hay que declararlo a mano.
  const [saldoDerivado, setSaldoDerivado] = useState<number | null>(null);
  const [efectivoContado, setEfectivoContado] = useState("");
  const [notaCierre, setNotaCierre] = useState("");

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
    const [movimientos, historial, resumen] = await Promise.all([
      supabase
        .from("vista_caja_franquicia_v42")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .gte("fecha", desde)
        .lte("fecha", hasta)
        .order("fecha", { ascending: false })
        .order("created_at", { ascending: false }),
      supabase
        .from("franquicia_caja_cierres")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .order("fecha", { ascending: false })
        .limit(60),
      supabase
        .from("vista_resumen_caja_diaria_franquicia_v47")
        .select("ingresos_total, egresos_total, ingresos_efectivo, egresos_efectivo")
        .eq("franquicia_id", franquicia.id)
        .eq("fecha", fechaCierre)
        .maybeSingle(),
    ]);
    if (movimientos.error) setError(movimientos.error.message);
    else setMovs((movimientos.data as Movimiento[]) ?? []);
    if (!historial.error) {
      const lista = (historial.data as Cierre[]) ?? [];
      setCierres(lista);
      const cierreActual = lista.find((c) => c.fecha === fechaCierre);
      if (cierreActual) {
        setSaldoInicial(String(Number(cierreActual.saldo_inicial_efectivo)));
        setEfectivoContado(String(Number(cierreActual.efectivo_contado)));
        setNotaCierre(cierreActual.nota ?? "");
      } else {
        // El saldo inicial ya no se escribe: lo calcula el servidor a partir del
        // ultimo cierre. Si lo eligiera quien cuenta el efectivo, cualquier
        // faltante se podria dejar en cero.
        const { data: derivado } = await supabase.rpc("saldo_inicial_caja_franquicia_v49", {
          p_franquicia_id: franquicia.id, p_fecha: fechaCierre,
        });
        const valor = derivado === null || derivado === undefined ? null : Number(derivado);
        setSaldoDerivado(valor);
        if (valor !== null) setSaldoInicial(String(valor));
      }
    }
    if (!resumen.error) {
      setResumenDia(
        (resumen.data as ResumenDia | null) ?? {
          ingresos_total: 0,
          egresos_total: 0,
          ingresos_efectivo: 0,
          egresos_efectivo: 0,
        }
      );
    }
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [franquicia.id, desde, hasta, fechaCierre]);

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

  const cierreSeleccionado = cierres.find((c) => c.fecha === fechaCierre);
  const saldoEsperado =
    Number(saldoInicial || 0) +
    Number(resumenDia.ingresos_efectivo || 0) -
    Number(resumenDia.egresos_efectivo || 0);
  const diferenciaCierre = Number(efectivoContado || 0) - saldoEsperado;

  async function cerrarCaja() {
    if (cierreSeleccionado?.estado === "cerrado") {
      return setError("La caja de esa fecha ya esta cerrada.");
    }
    if (saldoInicial === "" || Number(saldoInicial) < 0) {
      return setError("Indica el saldo inicial de efectivo.");
    }
    if (efectivoContado === "" || Number(efectivoContado) < 0) {
      return setError("Cuenta el efectivo fisico e indica el valor encontrado.");
    }
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("cerrar_caja_franquicia_v49", {
      p_fecha: fechaCierre,
      p_saldo_inicial_efectivo: Number(saldoInicial),
      p_efectivo_contado: Number(efectivoContado),
      p_nota: notaCierre.trim() || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Caja cerrada. El dia queda bloqueado hasta una reapertura justificada.");
    setNotaCierre("");
    cargar();
  }

  async function reabrirCaja(cierre: Cierre) {
    const motivo = window.prompt(
      "Motivo de reapertura (minimo 10 caracteres). La accion queda auditada:"
    )?.trim();
    if (!motivo) return;
    if (motivo.length < 10) return setError("El motivo debe tener al menos 10 caracteres.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("reabrir_caja_franquicia_v47", {
      p_cierre_id: cierre.id,
      p_motivo: motivo,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso("Caja reabierta. Ya puedes corregir los movimientos y volver a cerrarla.");
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

      <div className={`card-interna fq-caja-cierre ${soloLectura ? "fq-caja-supervision" : ""}`}>
        <div className="fq-caja-cabecera">
          <h4>Cierre diario de efectivo</h4>
          {soloLectura && <span className="badge fq-badge-supervision">Vista de supervisión</span>}
        </div>
        <p className="ayuda">
          El sistema toma solamente los cobros y pagos en efectivo para calcular lo
          esperado. Transferencias y tarjetas quedan en el total del dia, pero no en
          el dinero que debe estar fisicamente en caja.
        </p>
        <div className={`form-grid ${soloLectura ? "fq-fecha-revision" : ""}`}>
          <label>
            {soloLectura ? "Fecha consultada" : "Fecha"}
            <input
              type="date"
              value={fechaCierre}
              max={hoyLocalISO()}
              onChange={(e) => {
                setFechaCierre(e.target.value);
                setSaldoInicial("");
                setEfectivoContado("");
              }}
            />
          </label>
          {!soloLectura && (
            <>
              <label>
                Saldo inicial en efectivo
                <input
                  type="number"
                  step="0.01"
                  min="0"
                  value={saldoInicial}
                  readOnly={saldoDerivado !== null}
                  disabled={cierreSeleccionado?.estado === "cerrado"}
                  onChange={(e) => setSaldoInicial(e.target.value)}
                />
                <small className="ayuda">
                  {saldoDerivado !== null
                    ? "Viene del último cierre del local más el efectivo de los días sin cerrar. No se edita."
                    : "Primer cierre del local: indica con cuánto efectivo arranca la caja."}
                </small>
              </label>
              <label>
                Efectivo contado
                <input
                  type="number"
                  step="0.01"
                  min="0"
                  value={efectivoContado}
                  disabled={cierreSeleccionado?.estado === "cerrado"}
                  onChange={(e) => setEfectivoContado(e.target.value)}
                />
              </label>
              <label className="ancho-total">
                Nota del cierre
                <input
                  type="text"
                  value={notaCierre}
                  disabled={cierreSeleccionado?.estado === "cerrado"}
                  onChange={(e) => setNotaCierre(e.target.value)}
                />
              </label>
            </>
          )}
        </div>
        <div className="kpis compactos fq-caja-kpis">
          <div className="kpi">
            <span className="valor">{dinero(resumenDia.ingresos_efectivo)}</span>
            <span className="label">Ingresos en efectivo</span>
          </div>
          <div className="kpi">
            <span className="valor">{dinero(resumenDia.egresos_efectivo)}</span>
            <span className="label">Egresos en efectivo</span>
          </div>
          <div className="kpi">
            <span className="valor">{dinero(saldoEsperado)}</span>
            <span className="label">Efectivo esperado</span>
          </div>
          <div className={`kpi ${Math.abs(diferenciaCierre) >= 0.01 ? "alerta" : ""}`}>
            <span className="valor">
              {efectivoContado === "" ? "--" : dinero(diferenciaCierre)}
            </span>
            <span className="label">Diferencia</span>
          </div>
        </div>
        {soloLectura ? (
          <div className="info-box fq-aviso-supervision">
            Estás consultando la caja de este local. El titular registra movimientos y
            confirma el cierre; como administrador puedes revisar sus totales e historial.
          </div>
        ) : cierreSeleccionado?.estado === "cerrado" ? (
          <div className="filtros">
            <span className="badge ok">Dia cerrado</span>
            <span>
              Contado {dinero(cierreSeleccionado.efectivo_contado)} · diferencia{" "}
              {dinero(cierreSeleccionado.diferencia)}
            </span>
            <button
              className="secondary"
              disabled={guardando}
              onClick={() => reabrirCaja(cierreSeleccionado)}
            >
              Reabrir con motivo
            </button>
          </div>
        ) : (
          <button onClick={cerrarCaja} disabled={guardando}>
            {guardando ? "Cerrando..." : "Confirmar cierre diario"}
          </button>
        )}
      </div>

      {!soloLectura && <div className="card-interna">
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
              {MEDIOS_PAGO.filter((m) => m.valor !== "mixto").map((m) => (
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
        <button onClick={registrar} disabled={guardando || soloLectura}>
          {guardando ? "Registrando…" : "Registrar movimiento"}
        </button>
      </div>}

      <div className="card-interna">
        <h4>Historial de cierres</h4>
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Estado</th>
                <th className="num">Inicial</th>
                <th className="num">Ingreso efectivo</th>
                <th className="num">Egreso efectivo</th>
                <th className="num">Esperado</th>
                <th className="num">Contado</th>
                <th className="num">Diferencia</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {cierres.map((c) => (
                <tr key={c.id} className={c.estado === "reabierto" ? "fila-anulada" : ""}>
                  <td>{c.fecha.split("-").reverse().join("/")}</td>
                  <td><span className={`badge estado-${c.estado}`}>{c.estado}</span></td>
                  <td className="num">{dinero(c.saldo_inicial_efectivo)}</td>
                  <td className="num">{dinero(c.ingresos_efectivo)}</td>
                  <td className="num">{dinero(c.egresos_efectivo)}</td>
                  <td className="num">{dinero(c.saldo_esperado_efectivo)}</td>
                  <td className="num">{dinero(c.efectivo_contado)}</td>
                  <td className="num"><strong>{dinero(c.diferencia)}</strong></td>
                  <td>
                    {c.estado === "cerrado" && (
                      <button
                        className="btn-mini secondary"
                        disabled={guardando}
                        onClick={() => reabrirCaja(c)}
                      >
                        Reabrir
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {!cierres.length && (
                <tr><td colSpan={9} className="vacio">Todavia no hay cierres diarios.</td></tr>
              )}
            </tbody>
          </table>
        </div>
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
