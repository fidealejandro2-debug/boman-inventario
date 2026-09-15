"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import estilos from "./supervision.module.css";

type Estado = "cerrado" | "pendiente" | "abierto_hoy" | "descuadre" | "reabierto" | "sin_actividad";
type Local = { id: string; codigo: string; nombre: string; clase: string };
type Fila = {
  almacen_id: string; codigo: string; nombre: string; clase: string;
  fecha: string; cierre_id: string | null; cierre_estado: string | null;
  cerrado_at: string | null; cierre_nota: string | null; cierre_responsable: string | null;
  ingresos: number; egresos: number; resultado: number; efectivo: number;
  transferencias: number; tarjetas: number; operaciones_ingreso: number; operaciones_egreso: number;
  ultimo_registro: string | null; ultimo_responsable: string | null;
  saldo_inicial_efectivo: number | null; saldo_esperado_efectivo: number | null;
  efectivo_contado: number | null; diferencia: number | null; depositado: number;
  depositos_pendientes: number; depositos_confirmados: number; estado_supervision: Estado;
};
type Resumen = {
  locales: number; jornadas: number; ingresos: number; egresos: number; resultado: number;
  efectivo: number; transferencias: number; tarjetas: number; cierres_cuadrados: number;
  cierres_pendientes: number; abiertos_hoy: number; descuadres: number; reabiertos: number;
  diferencia_absoluta: number; depositado: number; depositos_pendientes: number;
};
type Respuesta = { desde: string; hasta: string; generado_en: string; resumen: Resumen; locales: Local[]; filas: Fila[] };

const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const FECHA = new Intl.DateTimeFormat("es-EC", { day: "2-digit", month: "short", year: "numeric", timeZone: "UTC" });
const HORA = new Intl.DateTimeFormat("es-EC", { hour: "2-digit", minute: "2-digit", timeZone: "America/Guayaquil" });
const ETIQUETAS: Record<Estado, string> = {
  cerrado: "Cerrado y cuadrado", pendiente: "Cierre pendiente", abierto_hoy: "Abierto hoy",
  descuadre: "Con diferencia", reabierto: "Reabierto", sin_actividad: "Sin actividad",
};

function fechaEcuador(diasAtras = 0) {
  const base = new Date();
  base.setDate(base.getDate() - diasAtras);
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric", month: "2-digit", day: "2-digit", timeZone: "America/Guayaquil",
  }).format(base);
}
function numero(valor: number | null | undefined) { return Number(valor ?? 0); }
function dinero(valor: number | null | undefined) { return DINERO.format(numero(valor)); }
function fechaCorta(valor: string) { return FECHA.format(new Date(`${valor}T00:00:00Z`)); }

export default function PanelSupervisionCliente() {
  const supabase = useMemo(() => createClient(), []);
  const [desde, setDesde] = useState(() => fechaEcuador(6));
  const [hasta, setHasta] = useState(() => fechaEcuador());
  const [almacenId, setAlmacenId] = useState("");
  const [estado, setEstado] = useState<Estado | "todos">("todos");
  const [busqueda, setBusqueda] = useState("");
  const [datos, setDatos] = useState<Respuesta | null>(null);
  const [cargando, setCargando] = useState(true);

  const cargar = useCallback(async (avisar = false) => {
    setCargando(true);
    const { data, error } = await supabase.rpc("panel_supervision_v152", {
      p_desde: desde, p_hasta: hasta, p_almacen_id: almacenId || null,
    });
    setCargando(false);
    if (error) {
      setDatos(null);
      void mostrarAvisoDialogo(
        `${error.message}\n\nConfirma que instalaste v152_paso1_rol_supervisor.sql y v152_paso2_panel_supervision.sql.`,
        "No se pudo cargar Supervisión", true,
      );
      return;
    }
    setDatos(data as Respuesta);
    if (avisar) void mostrarAvisoDialogo("El resumen ya refleja los últimos registros de Caja.", "Panel actualizado");
  }, [almacenId, desde, hasta, supabase]);

  useEffect(() => { void cargar(); }, [cargar]);

  const filas = useMemo(() => {
    const texto = busqueda.trim().toLocaleLowerCase("es");
    return (datos?.filas ?? []).filter((fila) =>
      (estado === "todos" || fila.estado_supervision === estado)
      && (!texto || `${fila.nombre} ${fila.codigo} ${fila.clase} ${fila.cierre_responsable ?? ""} ${fila.ultimo_responsable ?? ""}`.toLocaleLowerCase("es").includes(texto))
    );
  }, [busqueda, datos?.filas, estado]);

  const alertas = useMemo(() => (datos?.filas ?? []).filter((fila) =>
    ["pendiente", "descuadre", "reabierto"].includes(fila.estado_supervision) || fila.depositos_pendientes > 0
  ).slice(0, 8), [datos?.filas]);

  const r = datos?.resumen;
  return <div className={estilos.pagina}>
    <header className={estilos.hero}>
      <div>
        <span>CONTROL DE LOCALES</span>
        <h1>Panel de supervisión</h1>
        <p>Cierres, flujo de Caja, diferencias y depósitos de tiendas propias y franquicias.</p>
      </div>
      <div className={estilos.heroAcciones}>
        <button type="button" className="secondary" onClick={() => window.print()}>Imprimir</button>
        <button type="button" onClick={() => void cargar(true)} disabled={cargando}>{cargando ? "Actualizando…" : "Actualizar"}</button>
      </div>
    </header>

    <section className={estilos.filtros} aria-label="Filtros del panel">
      <div className="field"><label>Desde</label><input type="date" value={desde} max={hasta} onChange={(e) => setDesde(e.target.value)} /></div>
      <div className="field"><label>Hasta</label><input type="date" value={hasta} min={desde} max={fechaEcuador()} onChange={(e) => setHasta(e.target.value)} /></div>
      <div className="field"><label>Local</label><select value={almacenId} onChange={(e) => setAlmacenId(e.target.value)}><option value="">Todos los locales</option>{datos?.locales.map((local) => <option key={local.id} value={local.id}>{local.nombre}</option>)}</select></div>
      <div className="field"><label>Estado</label><select value={estado} onChange={(e) => setEstado(e.target.value as Estado | "todos")}><option value="todos">Todos</option>{Object.entries(ETIQUETAS).map(([valor, etiqueta]) => <option value={valor} key={valor}>{etiqueta}</option>)}</select></div>
      <div className="field"><label>Buscar</label><input value={busqueda} placeholder="Local o responsable" onChange={(e) => setBusqueda(e.target.value)} /></div>
    </section>

    <section className={estilos.kpis} aria-label="Resumen del período">
      <article><span>Ingresos</span><strong>{dinero(r?.ingresos)}</strong><small>{r?.jornadas ?? 0} jornadas con movimiento</small></article>
      <article><span>Egresos</span><strong>{dinero(r?.egresos)}</strong><small>Resultado: {dinero(r?.resultado)}</small></article>
      <article><span>Transferencias</span><strong>{dinero(r?.transferencias)}</strong><small>Efectivo: {dinero(r?.efectivo)} · Tarjeta: {dinero(r?.tarjetas)}</small></article>
      <article className={(r?.cierres_pendientes ?? 0) > 0 ? estilos.kpiAlerta : ""}><span>Cierres pendientes</span><strong>{r?.cierres_pendientes ?? 0}</strong><small>{r?.abiertos_hoy ?? 0} locales siguen abiertos hoy</small></article>
      <article className={(r?.descuadres ?? 0) > 0 ? estilos.kpiCritico : ""}><span>Descuadres</span><strong>{r?.descuadres ?? 0}</strong><small>Diferencia absoluta: {dinero(r?.diferencia_absoluta)}</small></article>
      <article className={(r?.depositos_pendientes ?? 0) > 0 ? estilos.kpiAlerta : ""}><span>Depósitos</span><strong>{dinero(r?.depositado)}</strong><small>{r?.depositos_pendientes ?? 0} pendientes de confirmar</small></article>
    </section>

    {alertas.length > 0 && <section className={estilos.bloque}>
      <div className={estilos.titulo}><div><span>ATENCIÓN INMEDIATA</span><h2>Novedades que requieren seguimiento</h2></div><b>{alertas.length} visibles</b></div>
      <div className={estilos.alertas}>{alertas.map((fila) => <button type="button" key={`${fila.almacen_id}-${fila.fecha}`} onClick={() => { setAlmacenId(fila.almacen_id); setEstado(fila.estado_supervision); }}>
        <span>{fila.nombre} · {fechaCorta(fila.fecha)}</span>
        <strong>{fila.depositos_pendientes > 0 ? `${fila.depositos_pendientes} depósito(s) por confirmar` : ETIQUETAS[fila.estado_supervision]}</strong>
        <small>{fila.estado_supervision === "descuadre" ? `Diferencia ${dinero(fila.diferencia)}` : `Último responsable: ${fila.ultimo_responsable ?? fila.cierre_responsable ?? "Sin registro"}`}</small>
      </button>)}</div>
    </section>}

    <section className={estilos.bloque}>
      <div className={estilos.titulo}>
        <div><span>DETALLE DIARIO</span><h2>Control por local y fecha</h2></div>
        <div className={estilos.enlaces}><span>{filas.length} filas</span><Link href="/franquicias/consolidado">Ver consolidado comercial</Link></div>
      </div>
      <div className={estilos.tablaContenedor}>
        <table className={estilos.tabla}>
          <thead><tr><th>Local / fecha</th><th>Estado del cierre</th><th className="num">Ingresos</th><th className="num">Egresos</th><th className="num">Resultado</th><th>Medios de ingreso</th><th>Control de efectivo</th><th>Depósitos</th><th>Responsable</th></tr></thead>
          <tbody>{filas.map((fila) => <tr key={`${fila.almacen_id}-${fila.fecha}`} className={fila.estado_supervision === "sin_actividad" ? estilos.sinActividad : ""}>
            <td><strong>{fila.nombre}</strong><small>{fila.clase} · {fechaCorta(fila.fecha)}</small></td>
            <td><span className={`${estilos.estado} ${estilos[fila.estado_supervision]}`}>{ETIQUETAS[fila.estado_supervision]}</span>{fila.cerrado_at && <small>Cerró {HORA.format(new Date(fila.cerrado_at))}</small>}</td>
            <td className="num"><strong>{dinero(fila.ingresos)}</strong><small>{fila.operaciones_ingreso} registros</small></td>
            <td className="num"><strong>{dinero(fila.egresos)}</strong><small>{fila.operaciones_egreso} registros</small></td>
            <td className={`num ${fila.resultado < 0 ? estilos.negativo : estilos.positivo}`}><strong>{dinero(fila.resultado)}</strong></td>
            <td><small>Efectivo {dinero(fila.efectivo)}</small><small>Transferencia {dinero(fila.transferencias)}</small><small>Tarjeta {dinero(fila.tarjetas)}</small></td>
            <td>{fila.cierre_id ? <><small>Esperado {dinero(fila.saldo_esperado_efectivo)}</small><small>Contado {dinero(fila.efectivo_contado)}</small><strong className={numero(fila.diferencia) === 0 ? estilos.positivo : estilos.negativo}>Dif. {dinero(fila.diferencia)}</strong></> : <small>Sin cierre registrado</small>}</td>
            <td><strong>{dinero(fila.depositado)}</strong><small>{fila.depositos_confirmados} confirmados</small>{fila.depositos_pendientes > 0 && <small className={estilos.negativo}>{fila.depositos_pendientes} pendientes</small>}</td>
            <td><strong>{fila.cierre_responsable ?? fila.ultimo_responsable ?? "—"}</strong>{fila.ultimo_registro && <small>Último registro {HORA.format(new Date(fila.ultimo_registro))}</small>}</td>
          </tr>)}</tbody>
        </table>
        {!cargando && filas.length === 0 && <div className={estilos.vacio}>No hay filas que coincidan con los filtros.</div>}
        {cargando && <div className={estilos.vacio}>Consultando cierres y movimientos…</div>}
      </div>
    </section>
  </div>;
}
