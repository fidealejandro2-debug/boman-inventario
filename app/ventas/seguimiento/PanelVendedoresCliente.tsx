"use client";

/* eslint-disable @next/next/no-img-element */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import ExpedienteContrato, { type Expediente } from "@/app/produccion/contratos/ExpedienteContrato";
import estilos from "./Seguimiento.module.css";

type Prenda = { prenda: string; calidad: string | null; cantidad: number };
type Fila = {
  id: string; numero: string; cliente: string; vendedor: string; estado: string;
  prioridad: string; tipo_contrato: string; fecha_ingreso: string;
  fecha_inicio_produccion: string | null; fecha_entrega: string | null;
  total_prendas: number; presupuesto: number; abono: number; saldo: number;
  atrasado: boolean; dias_para_entrega: number | null;
  mockup_drive_id: string | null; mockup_url: string | null; prendas: Prenda[];
};
type Respuesta = {
  hoy: string;
  filtros: { desde: string; hasta: string };
  catalogos: { vendedores: string[]; estados: string[]; prioridades: string[] };
  kpis: { contratos: number; prendas: number; presupuesto: number; abono: number; saldo: number; atrasados: number };
  total: number; pagina: number; por_pagina: number; filas: Fila[];
};
type Filtros = { vendedores: string[]; desde: string; hasta: string; estado: string; prioridad: string; cliente: string };

const POR_PAGINA = 30;
const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const ENTERO = new Intl.NumberFormat("es-EC");
const VACIA: Respuesta = {
  hoy: "", filtros: { desde: "", hasta: "" },
  catalogos: { vendedores: [], estados: [], prioridades: [] },
  kpis: { contratos: 0, prendas: 0, presupuesto: 0, abono: 0, saldo: 0, atrasados: 0 },
  total: 0, pagina: 1, por_pagina: POR_PAGINA, filas: [],
};

function isoLocal(desplazamiento = 0) {
  const d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() + desplazamiento);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function fecha(valor: string | null) {
  if (!valor) return "Sin fecha";
  return new Intl.DateTimeFormat("es-EC", { dateStyle: "medium", timeZone: "UTC" }).format(new Date(`${valor.slice(0, 10)}T12:00:00Z`));
}
function imagen(fila: Fila) {
  if (fila.mockup_drive_id) return `https://drive.google.com/thumbnail?id=${fila.mockup_drive_id}&sz=w700`;
  return fila.mockup_url || "";
}
function etiquetaEntrega(fila: Fila) {
  if (fila.dias_para_entrega === null) return "Sin fecha";
  if (fila.atrasado) return `${Math.abs(fila.dias_para_entrega)} día${Math.abs(fila.dias_para_entrega) === 1 ? "" : "s"} atrasado`;
  if (fila.dias_para_entrega === 0) return "Entrega hoy";
  return `Faltan ${fila.dias_para_entrega} día${fila.dias_para_entrega === 1 ? "" : "s"}`;
}

function SelectorVendedores({ opciones, valor, cambiar }: { opciones: string[]; valor: string[]; cambiar: (v: string[]) => void }) {
  const [buscar, setBuscar] = useState("");
  const visibles = opciones.filter((x) => x.toLocaleLowerCase("es").includes(buscar.trim().toLocaleLowerCase("es")));
  const resumen = valor.length === 0 ? "Todos los vendedores" : valor.length === 1 ? valor[0] : `${valor.length} vendedores`;
  function alternar(nombre: string) { cambiar(valor.includes(nombre) ? valor.filter((x) => x !== nombre) : [...valor, nombre]); }
  return <details className={estilos.multi}>
    <summary>{resumen}</summary>
    <div className={estilos.multiPanel}>
      <input type="search" value={buscar} onChange={(e) => setBuscar(e.target.value)} placeholder="Buscar vendedor…" />
      <button type="button" className={estilos.todos} onClick={() => cambiar([])}>
        <span className={valor.length === 0 ? estilos.checkActivo : estilos.check}>✓</span> Todos los vendedores
      </button>
      <div className={estilos.opciones}>
        {visibles.map((nombre) => <label key={nombre}>
          <input type="checkbox" checked={valor.includes(nombre)} onChange={() => alternar(nombre)} />
          <span>{nombre}</span>
        </label>)}
        {!visibles.length && <small>No hay coincidencias.</small>}
      </div>
      <div className={estilos.multiPie}>{valor.length ? `${valor.length} seleccionado${valor.length === 1 ? "" : "s"}` : "Sin filtro"}</div>
    </div>
  </details>;
}

export default function PanelVendedoresCliente() {
  const supabase = useRef(createClient()).current;
  const inicial = useMemo<Filtros>(() => ({ vendedores: [], desde: isoLocal(), hasta: isoLocal(14), estado: "", prioridad: "", cliente: "" }), []);
  const [filtros, setFiltros] = useState<Filtros>(inicial);
  const [aplicados, setAplicados] = useState<Filtros>(inicial);
  const [datos, setDatos] = useState<Respuesta>(VACIA);
  const [pagina, setPagina] = useState(1);
  const [cargando, setCargando] = useState(true);
  const [expediente, setExpediente] = useState<Expediente | null>(null);
  const [abriendo, setAbriendo] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    const { data, error } = await supabase.rpc("panel_vendedores_v111", {
      p_vendedores: aplicados.vendedores.length ? aplicados.vendedores : null,
      p_desde: aplicados.desde || null,
      p_hasta: aplicados.hasta || null,
      p_estados: aplicados.estado ? [aplicados.estado] : null,
      p_prioridades: aplicados.prioridad ? [aplicados.prioridad] : null,
      p_cliente: aplicados.cliente.trim() || null,
      p_pagina: pagina,
      p_por_pagina: POR_PAGINA,
    });
    setCargando(false);
    if (error) {
      await mostrarAvisoDialogo(error.message, "No se pudo cargar el panel de vendedores", true);
      return;
    }
    setDatos(data as Respuesta);
  }, [aplicados, pagina, supabase]);

  useEffect(() => { void cargar(); }, [cargar]);
  useEffect(() => {
    const cerrar = (e: KeyboardEvent) => { if (e.key === "Escape") setExpediente(null); };
    document.addEventListener("keydown", cerrar); return () => document.removeEventListener("keydown", cerrar);
  }, []);

  function aplicar(nuevos = filtros) { setPagina(1); setFiltros(nuevos); setAplicados({ ...nuevos, vendedores: [...nuevos.vendedores] }); }
  function rango(desde: string, hasta: string) { aplicar({ ...filtros, desde, hasta }); }
  async function abrirBrief(id: string) {
    setAbriendo(id);
    const { data, error } = await supabase.rpc("obtener_brief_vendedor_v111", { p_contrato_id: id });
    setAbriendo(null);
    if (error) return mostrarAvisoDialogo(error.message, "No se pudo abrir el brief", true);
    setExpediente(data as Expediente);
  }

  const totalPaginas = Math.max(1, Math.ceil(datos.total / POR_PAGINA));
  return <>
    <div className={estilos.noPrint}>
      <header className={estilos.cabecera}>
        <div><span className="eyebrow">VENTAS · v111</span><h1>Panel de vendedores</h1><p>Entregas, mockups, prendas y cartera de contratos en una vista comercial.</p></div>
        <button className="secondary" onClick={() => void cargar()} disabled={cargando}>{cargando ? "Actualizando…" : "Actualizar"}</button>
      </header>

      <section className={`card ${estilos.filtros}`}>
        <div className="field"><label>Vendedores</label><SelectorVendedores opciones={datos.catalogos.vendedores} valor={filtros.vendedores} cambiar={(v) => setFiltros((x) => ({ ...x, vendedores: v }))} /></div>
        <div className="field"><label>Entrega desde</label><input type="date" value={filtros.desde} onChange={(e) => setFiltros((x) => ({ ...x, desde: e.target.value }))} /></div>
        <div className="field"><label>Entrega hasta</label><input type="date" value={filtros.hasta} onChange={(e) => setFiltros((x) => ({ ...x, hasta: e.target.value }))} /></div>
        <div className="field"><label>Estado</label><select value={filtros.estado} onChange={(e) => setFiltros((x) => ({ ...x, estado: e.target.value }))}><option value="">Todos</option>{datos.catalogos.estados.map((x) => <option key={x}>{x}</option>)}</select></div>
        <div className="field"><label>Prioridad</label><select value={filtros.prioridad} onChange={(e) => setFiltros((x) => ({ ...x, prioridad: e.target.value }))}><option value="">Todas</option>{datos.catalogos.prioridades.map((x) => <option key={x}>{x}</option>)}</select></div>
        <div className={`field ${estilos.cliente}`}><label>Cliente o contrato</label><input value={filtros.cliente} onChange={(e) => setFiltros((x) => ({ ...x, cliente: e.target.value }))} onKeyDown={(e) => { if (e.key === "Enter") aplicar(); }} placeholder="Cliente o BOM-2026-…" /></div>
        <button onClick={() => aplicar()} disabled={cargando}>Aplicar filtros</button>
        <div className={estilos.atajos}>
          <button className="secondary" onClick={() => rango(isoLocal(), isoLocal())}>Hoy</button>
          <button className="secondary" onClick={() => rango(isoLocal(), isoLocal(7))}>7 días</button>
          <button className="secondary" onClick={() => rango(isoLocal(), isoLocal(14))}>14 días</button>
          <button className="secondary" onClick={() => rango("2020-01-01", isoLocal(-1))}>Atrasados</button>
        </div>
      </section>

      <section className={estilos.kpis}>
        <article><span>Contratos</span><strong>{ENTERO.format(datos.kpis.contratos)}</strong><small>en el filtro</small></article>
        <article><span>Prendas</span><strong>{ENTERO.format(datos.kpis.prendas)}</strong><small>unidades comprometidas</small></article>
        <article><span>Presupuesto</span><strong>{DINERO.format(datos.kpis.presupuesto)}</strong><small>valor contratado</small></article>
        <article><span>Abonado</span><strong>{DINERO.format(datos.kpis.abono)}</strong><small>valor recibido</small></article>
        <article><span>Saldo</span><strong>{DINERO.format(datos.kpis.saldo)}</strong><small>pendiente de cobro</small></article>
        <article className={datos.kpis.atrasados ? estilos.kpiAlerta : estilos.kpiOk}><span>Atrasados</span><strong>{ENTERO.format(datos.kpis.atrasados)}</strong><small>{datos.kpis.atrasados ? "requieren atención" : "todo al día"}</small></article>
      </section>

      <div className={estilos.resultadoCabecera}><div><h2>Entregas del período</h2><p>{datos.total} contrato(s) · {fecha(aplicados.desde)} a {fecha(aplicados.hasta)}</p></div></div>
      {cargando ? <div className={estilos.cargando}>Cargando contratos…</div> : <section className={estilos.tarjetas}>
        {datos.filas.map((fila) => {
          const src = imagen(fila); const avance = fila.presupuesto > 0 ? Math.min(100, Math.round((fila.abono / fila.presupuesto) * 100)) : 0;
          return <article className={`${estilos.tarjeta} ${fila.atrasado ? estilos.tarjetaAtrasada : ""}`} key={fila.id}>
            <button className={estilos.mockup} onClick={() => void abrirBrief(fila.id)} aria-label={`Abrir brief ${fila.numero}`}>
              {src ? <img src={src} alt={`Mockup de ${fila.numero}`} loading="lazy" /> : <span>Sin mockup</span>}
              {fila.atrasado && <b>ATRASADO</b>}
            </button>
            <div className={estilos.cuerpo}>
              <div className={estilos.identidad}><div><strong>{fila.numero}</strong><h3>{fila.cliente}</h3><span>👤 {fila.vendedor || "Sin vendedor"}</span></div><span className={`${estilos.badge} ${fila.prioridad === "Urgente" ? estilos.urgente : ""}`}>{fila.prioridad}</span></div>
              <div className={estilos.entrega}><div><small>Entrega comprometida</small><strong>{fecha(fila.fecha_entrega)}</strong></div><span className={fila.atrasado ? estilos.textoAlerta : ""}>{etiquetaEntrega(fila)}</span></div>
              <div className={estilos.prendas}>{fila.prendas.slice(0, 5).map((p, i) => <span key={`${p.prenda}-${p.calidad}-${i}`}><b>{p.cantidad}</b> {p.prenda}{p.calidad ? ` · ${p.calidad}` : ""}</span>)}{fila.prendas.length > 5 && <span>+{fila.prendas.length - 5} líneas</span>}{!fila.prendas.length && <span>{fila.total_prendas} prendas · sin desglose</span>}</div>
              <div className={estilos.finanzas}><div><span>Presupuesto</span><strong>{DINERO.format(fila.presupuesto)}</strong></div><div><span>Abono</span><strong>{DINERO.format(fila.abono)}</strong></div><div><span>Saldo</span><strong className={fila.saldo > 0 ? estilos.saldo : ""}>{DINERO.format(fila.saldo)}</strong></div></div>
              <div className={estilos.barra}><i style={{ width: `${avance}%` }} /></div>
              <div className={estilos.pie}><span className="badge ok">{fila.estado}</span><button disabled={abriendo === fila.id} onClick={() => void abrirBrief(fila.id)}>{abriendo === fila.id ? "Abriendo…" : "Abrir brief"}</button></div>
            </div>
          </article>;
        })}
        {!datos.filas.length && <div className={estilos.vacio}><strong>Sin contratos</strong><span>No hay entregas que coincidan con estos filtros.</span></div>}
      </section>}
      {totalPaginas > 1 && <nav className={estilos.paginacion} aria-label="Paginación"><button className="secondary" disabled={pagina <= 1 || cargando} onClick={() => setPagina((x) => x - 1)}>Anterior</button><span>Página {pagina} de {totalPaginas}</span><button className="secondary" disabled={pagina >= totalPaginas || cargando} onClick={() => setPagina((x) => x + 1)}>Siguiente</button></nav>}
    </div>

    {expediente && <div className={estilos.modal} role="dialog" aria-modal="true" aria-label={`Brief ${expediente.contrato.numero}`}>
      <div className={estilos.modalCuerpo}>
        <div className={`${estilos.modalBarra} ${estilos.noPrint}`}><div><strong>{expediente.contrato.numero}</strong><span>{expediente.contrato.cliente}</span></div><div><button className="secondary" onClick={() => window.print()}>Imprimir</button><button onClick={() => setExpediente(null)}>Cerrar</button></div></div>
        <ExpedienteContrato datos={expediente} />
      </div>
    </div>}
  </>;
}
