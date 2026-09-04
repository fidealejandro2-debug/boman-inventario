"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";

export type Etapa = {
  nombre: string; etiqueta: string; emoji: string; bg: string; fg: string;
  area: string; sub: string; hechos: number; exterior?: boolean;
};

export type Fila = {
  numero: string; corto: string; cliente: string; vendedor: string;
  mks: { i: string; d: string }[];
  prendas: number; prendasTxt: string; calidad: string[];
  urgente: boolean; atrasado: boolean; esExterior: boolean;
  ingreso: string; entrega: string; entregaMs: number; inicio: string;
  disenador: string; autorMockup: string; fabrica: number;
  obs: string; maquila: string; marca: string;
  muestras: { tpu: boolean; dtf: boolean };
  hechas: boolean[];
};

export type DatosTablero = { etapas: Etapa[]; filas: Fila[]; total: number; hora: string };

type Filtro = "pend" | "todos" | "urg" | "tarde" | "fab2" | "muestras";

const FILTROS: { valor: Filtro; etiqueta: string }[] = [
  { valor: "pend", etiqueta: "Pendientes" },
  { valor: "todos", etiqueta: "Todos" },
  { valor: "urg", etiqueta: "🔴 Urgentes" },
  { valor: "tarde", etiqueta: "⚠️ Atrasados" },
  { valor: "fab2", etiqueta: "🏭 Fábrica 2" },
  { valor: "muestras", etiqueta: "🧪 Faltan muestras" },
];

export default function TableroCliente({ datos }: { datos: DatosTablero | { error: string } }) {
  const router = useRouter();
  const [refrescando, refrescar] = useTransition();
  const [busqueda, setBusqueda] = useState("");
  const [filtro, setFiltro] = useState<Filtro>("pend");
  const [orden, setOrden] = useState<"entrega" | "numero">("entrega");

  const hayError = "error" in datos;
  const etapas = hayError ? [] : datos.etapas;
  const filas = hayError ? [] : datos.filas;

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    const lista = filas.filter((f) => {
      if (filtro === "urg" && !f.urgente) return false;
      if (filtro === "tarde" && !f.atrasado) return false;
      if (filtro === "fab2" && f.fabrica !== 2) return false;
      if (filtro === "muestras" && !f.muestras?.tpu && !f.muestras?.dtf) return false;
      // "Pendientes" esconde lo que ya tiene todas las etapas marcadas: es el
      // trabajo que queda, que es para lo que el taller mira este tablero.
      if (filtro === "pend" && f.hechas.every(Boolean)) return false;
      if (!q) return true;
      return [f.numero, f.cliente, f.disenador, f.vendedor, f.prendasTxt]
        .some((campo) => String(campo || "").toLowerCase().includes(q));
    });
    return lista.sort((a, b) => {
      if (orden === "numero") return a.numero.localeCompare(b.numero);
      if (!a.entregaMs && !b.entregaMs) return 0;
      if (!a.entregaMs) return 1;
      if (!b.entregaMs) return -1;
      return a.entregaMs - b.entregaMs;
    });
  }, [filas, busqueda, filtro, orden]);

  if (hayError) {
    return <div className="card"><div className="header-row"><h3 style={{ margin: 0 }}>Tablero de producción</h3></div>
      <p className="conteo">No se pudo leer el tablero desde Boman Sport.</p>
      <div className="badge bajo" style={{ display: "inline-block", whiteSpace: "normal", lineHeight: 1.4 }}>{datos.error}</div>
      <div className="acciones-documento" style={{ marginTop: 12 }}>
        <button onClick={() => refrescar(() => router.refresh())} disabled={refrescando}>{refrescando ? "Reintentando..." : "Reintentar"}</button>
      </div></div>;
  }

  return <>
    <div className="card">
      <div className="header-row">
        <div>
          <h3 style={{ margin: 0 }}>Tablero de producción</h3>
          <p className="conteo">{visibles.length} de {datos.total} contratos · datos de {datos.hora}</p>
        </div>
        <button className="secondary" onClick={() => refrescar(() => router.refresh())} disabled={refrescando}>
          {refrescando ? "Actualizando..." : "🔄 Actualizar"}
        </button>
      </div>

      <div className="grid-2">
        <div className="field">
          <label>Buscar</label>
          <input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Contrato, cliente, diseñador o vendedor" />
        </div>
        <div className="field">
          <label>Ordenar</label>
          <select value={orden} onChange={(e) => setOrden(e.target.value as "entrega" | "numero")}>
            <option value="entrega">Fecha de entrega</option>
            <option value="numero">N.° de contrato</option>
          </select>
        </div>
      </div>

      <div className="filtros">
        {FILTROS.map((f) => (
          <button key={f.valor} className={filtro === f.valor ? "" : "secondary"} onClick={() => setFiltro(f.valor)}>{f.etiqueta}</button>
        ))}
      </div>
    </div>

    <div className="card">
      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th style={{ minWidth: 230 }}>Contrato</th>
              <th style={{ minWidth: 120 }}>Entrega</th>
              <th style={{ minWidth: 110 }}>Diseño</th>
              {etapas.map((et, i) => (
                <th key={`${et.area}-${et.nombre}-${i}`} className="num" style={{ minWidth: 62 }} title={et.area}>
                  <span style={{ background: et.bg, color: et.fg, borderRadius: 4, padding: "1px 5px", display: "inline-block", fontSize: 10 }}>
                    {et.emoji} {et.etiqueta}
                  </span>
                  <div className="conteo" style={{ marginTop: 2 }}>{et.hechos}/{datos.total}</div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {visibles.map((f) => (
              <tr key={f.numero} className={f.atrasado ? "fila-alerta" : ""}>
                <td>
                  <div style={{ display: "flex", gap: 8, alignItems: "flex-start" }}>
                    {f.mks[0]?.i && (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={`https://drive.google.com/thumbnail?id=${f.mks[0].i}&sz=w120`} alt="" loading="lazy"
                        style={{ width: 44, height: 44, objectFit: "cover", borderRadius: 6, flex: "0 0 auto", background: "var(--superficie-suave)" }} />
                    )}
                    <div style={{ minWidth: 0 }}>
                      <strong>{f.urgente ? "🔴 " : ""}{f.numero}</strong>
                      <div>{f.cliente}</div>
                      <div className="conteo">{f.vendedor} · {f.prendas} pr.{f.calidad.length ? ` · ${f.calidad.join(" · ")}` : ""}</div>
                      {f.obs && <div className="badge bajo" style={{ marginTop: 3, whiteSpace: "normal", lineHeight: 1.3 }}>📝 {f.obs}</div>}
                    </div>
                  </div>
                </td>
                <td>
                  <span className={f.atrasado ? "badge bajo" : "badge ok"}>{f.entrega || "sin fecha"}</span>
                  {f.inicio && <div className="conteo">inicia {f.inicio}</div>}
                </td>
                <td>
                  {f.disenador || <span className="conteo">sin asignar</span>}
                  {f.fabrica === 2 && <div className="badge ajuste">Fábrica 2</div>}
                  {f.maquila && <div className="conteo">🏭 {f.maquila}</div>}
                </td>
                {etapas.map((et, i) => (
                  <td key={`${f.numero}-${i}`} className="num">
                    {/* Columnas de Exteriores: un contrato sin chompas no las lleva,
                        y un vacio se confunde con "pendiente". El punto dice "no aplica". */}
                    {et.exterior && !f.esExterior
                      ? <span className="conteo">·</span>
                      : f.hechas[i]
                        ? <span style={{ color: "var(--rol-verde)", fontWeight: 900 }}>✓</span>
                        : <span className="conteo">▫</span>}
                  </td>
                ))}
              </tr>
            ))}
            {!visibles.length && (
              <tr><td colSpan={3 + etapas.length} className="vacio">Sin contratos con ese filtro.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  </>;
}
