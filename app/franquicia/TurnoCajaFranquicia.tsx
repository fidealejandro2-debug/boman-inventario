"use client";

import { useEffect, useMemo, useState } from "react";
import {
  confirmarDialogo,
  mostrarAvisoDialogo,
  pedirMotivoDialogo,
} from "@/components/Dialogo";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { createClient } from "@/lib/supabase/client";
import { dinero, hoyLocalISO, mensajeError } from "./lib";
import type { Franquicia } from "./FranquiciaCliente";

type Turno = {
  id: string;
  caja_codigo: string;
  turno: string;
  estado: "abierto" | "cerrado" | "reabierto";
  saldo_inicial: number;
  abierto_por: string;
  abierto_at: string;
  operador: string;
  ingresos_total: number | null;
  egresos_total: number | null;
  efectivo_esperado: number | null;
  efectivo_contado: number | null;
  diferencia: number | null;
};

function esDeHoy(fecha: string) {
  const partes = new Intl.DateTimeFormat("es-EC", {
    timeZone: "America/Guayaquil",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(fecha));
  const valor = (tipo: Intl.DateTimeFormatPartTypes) =>
    partes.find((parte) => parte.type === tipo)?.value ?? "";
  return `${valor("year")}-${valor("month")}-${valor("day")}` === hoyLocalISO();
}

export default function TurnoCajaFranquicia({
  franquicia,
  soloLectura = false,
  puedeAutorizarReapertura = false,
}: {
  franquicia: Franquicia;
  soloLectura?: boolean;
  puedeAutorizarReapertura?: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [turnos, setTurnos] = useState<Turno[]>([]);
  const [uid, setUid] = useState("");
  const [caja, setCaja] = useState("CAJA-1");
  const [nombre, setNombre] = useState("Mañana");
  const [inicial, setInicial] = useState("0");
  const [contado, setContado] = useState("");
  const [nota, setNota] = useState("");
  const [procesando, setProcesando] = useState(false);

  async function avisarError(error: unknown, titulo = "No se pudo completar la acción") {
    await mostrarAvisoDialogo(
      mensajeError(error as { message?: string } | null),
      titulo,
      true
    );
  }

  async function cargar() {
    const [{ data: usuario }, { data, error }] = await Promise.all([
      supabase.auth.getUser(),
      supabase
        .from("vista_turnos_caja_franquicia_v81")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .order("abierto_at", { ascending: false })
        .limit(30),
    ]);
    setUid(usuario.user?.id ?? "");
    if (error) await avisarError(error, "No se pudieron consultar los turnos");
    else setTurnos((data ?? []) as Turno[]);
  }

  useEffect(() => {
    void cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [franquicia.id]);

  const activoPropio = turnos.find(
    (item) => item.abierto_por === uid && ["abierto", "reabierto"].includes(item.estado)
  );
  const cajaElegida = caja.trim().toUpperCase();
  const activoEnCaja = turnos.find(
    (item) =>
      item.caja_codigo === cajaElegida && ["abierto", "reabierto"].includes(item.estado)
  );
  const cerradoPropioHoy = turnos.find(
    (item) => item.abierto_por === uid && item.estado === "cerrado" && esDeHoy(item.abierto_at)
  );

  async function abrir() {
    if (!cajaElegida || !nombre.trim() || inicial === "" || Number(inicial) < 0) {
      return mostrarAvisoDialogo(
        "Indica la caja, el turno y un saldo inicial válido.",
        "Faltan datos",
        true
      );
    }
    if (activoEnCaja && activoEnCaja.abierto_por !== uid) {
      return mostrarAvisoDialogo(
        `${activoEnCaja.caja_codigo} ya está abierta por ${activoEnCaja.operador}. Esa persona debe cerrar su turno antes de que otro vendedor use la misma caja.`,
        "Caja ocupada",
        true
      );
    }
    if (cerradoPropioHoy) {
      return mostrarAvisoDialogo(
        "Ya cerraste tu turno de hoy. Para volver a operar, el franquiciado o un administrador debe autorizar la reapertura del turno cerrado.",
        "Reapertura requerida",
        true
      );
    }
    setProcesando(true);
    const { error } = await supabase.rpc("abrir_turno_caja_v81", {
      p_caja_codigo: cajaElegida,
      p_turno: nombre.trim(),
      p_saldo: Number(inicial),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) return avisarError(error, "No se pudo abrir la caja");
    await cargar();
  }

  async function cerrar() {
    if (!activoPropio || contado === "" || Number(contado) < 0) {
      return mostrarAvisoDialogo(
        "Cuenta el efectivo físico e indica el valor encontrado.",
        "Falta el efectivo contado",
        true
      );
    }
    if (!(await confirmarDialogo(
      `Vas a cerrar ${activoPropio.caja_codigo} · ${activoPropio.turno} con ${dinero(Number(contado))} en efectivo contado. Después necesitarás autorización del franquiciado o de un administrador para reabrir este turno.`,
      true
    ))) return;
    setProcesando(true);
    const { error } = await supabase.rpc("cerrar_turno_caja_v81", {
      p_turno_id: activoPropio.id,
      p_efectivo_contado: Number(contado),
      p_nota: nota.trim() || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) return avisarError(error, "No se pudo cerrar la caja");
    setContado("");
    setNota("");
    await mostrarAvisoDialogo("Tu turno quedó cerrado y auditado.", "Turno cerrado");
    await cargar();
  }

  async function autorizarReapertura(turno: Turno) {
    const motivo = await pedirMotivoDialogo(
      `Autorizar la reapertura de ${turno.caja_codigo} · ${turno.turno}, operada por ${turno.operador}.`,
      10,
      "Motivo de la autorización"
    );
    if (!motivo) return;
    setProcesando(true);
    const { error } = await supabase.rpc("reabrir_turno_caja_v106", {
      p_turno_id: turno.id,
      p_motivo: motivo,
    });
    setProcesando(false);
    if (error) return avisarError(error, "No se pudo autorizar la reapertura");
    await mostrarAvisoDialogo(
      `${turno.caja_codigo} quedó reabierta para ${turno.operador}.`,
      "Reapertura autorizada"
    );
    await cargar();
  }

  return (
    <div className="card-interna">
      <h4>Apertura y cierre de mi turno</h4>
      {!soloLectura && activoPropio ? (
        <>
          <p className="ayuda">
            <strong>{activoPropio.caja_codigo} · {activoPropio.turno}</strong> está abierta
            a tu nombre. Todas tus ventas y movimientos quedan dentro de este turno.
          </p>
          <div className="form-inline">
            <label>
              Efectivo contado
              <input type="number" min="0" step="0.01" value={contado} onChange={(e) => setContado(e.target.value)} />
            </label>
            <label>
              Nota
              <input value={nota} onChange={(e) => setNota(e.target.value)} />
            </label>
            <button onClick={cerrar} disabled={procesando}>
              {procesando ? "Cerrando…" : "Cerrar mi turno"}
            </button>
          </div>
        </>
      ) : !soloLectura && cerradoPropioHoy ? (
        <div className="info-box">
          Tu turno de hoy ya está cerrado. No puedes abrir otro para evadir ese cierre;
          solicita al franquiciado o a un administrador que autorice su reapertura.
        </div>
      ) : !soloLectura ? (
        <>
          <p className="ayuda">
            Abre un turno antes de vender. Una caja física solo puede estar abierta por
            una persona a la vez.
          </p>
          {activoEnCaja && activoEnCaja.abierto_por !== uid && (
            <div className="info-box">
              <strong>{activoEnCaja.caja_codigo}</strong> está abierta por {activoEnCaja.operador}.
              Elige otra caja o espera a que cierre su turno.
            </div>
          )}
          <div className="form-inline">
            <label>
              Caja
              <input value={caja} onChange={(e) => setCaja(e.target.value.toUpperCase())} />
            </label>
            <label>
              Turno
              <input value={nombre} onChange={(e) => setNombre(e.target.value)} />
            </label>
            <label>
              Saldo inicial
              <input type="number" min="0" step="0.01" value={inicial} onChange={(e) => setInicial(e.target.value)} />
            </label>
            <button onClick={abrir} disabled={procesando || Boolean(activoEnCaja)}>
              {procesando ? "Abriendo…" : "Abrir turno"}
            </button>
          </div>
        </>
      ) : (
        <p className="ayuda">Vista de supervisión por caja física, turno y operador.</p>
      )}

      {turnos.length > 0 && (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Caja / turno</th><th>Operador</th><th>Estado</th>
                <th className="num">Ingresos</th><th className="num">Contado</th>
                <th className="num">Diferencia</th><th></th>
              </tr>
            </thead>
            <tbody>
              {turnos.slice(0, 12).map((item) => (
                <tr key={item.id}>
                  <td>{item.caja_codigo} · {item.turno}</td>
                  <td>{item.operador}</td>
                  <td><span className={`badge estado-${item.estado}`}>{item.estado}</span></td>
                  <td className="num">{dinero(item.ingresos_total ?? 0)}</td>
                  <td className="num">{dinero(item.efectivo_contado)}</td>
                  <td className="num">{dinero(item.diferencia)}</td>
                  <td>
                    {puedeAutorizarReapertura && item.estado === "cerrado" && esDeHoy(item.abierto_at) && (
                      <button className="btn-mini secondary" disabled={procesando} onClick={() => autorizarReapertura(item)}>
                        Autorizar reapertura
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
  );
}
