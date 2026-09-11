"use client";

import { useMemo, useState, useTransition } from "react";
import { confirmarDialogo, mostrarAvisoDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import estilos from "./Tablero.module.css";

export type Etapa = {
  nombre: string; etiqueta: string; emoji: string; bg: string; fg: string;
  area: string; sub: string; hechos: number; exterior?: boolean;
};

export type Fila = {
  id: string;
  numero: string; corto: string; cliente: string; vendedor: string;
  mks: { i: string; d: string }[];
  prendas: number; prendasTxt: string; calidad: string[];
  urgente: boolean; atrasado: boolean; esExterior: boolean;
  ingreso: string; entrega: string; entregaISO: string | null; entregaMs: number;
  inicio: string; inicioISO: string | null;
  disenador: string; autorMockup: string; fabrica: number;
  obs: string; maquila: string; marca: string;
  muestras: { tpu: boolean; dtf: boolean };
  hechas: boolean[];
};

export type DatosTablero = { etapas: Etapa[]; filas: Fila[]; total: number; hora: string;
  disenadores?: string[]; autoresMockup?: string[] };

type Filtro = "pend" | "todos" | "urg" | "tarde" | "fab2" | "muestras";

const FILTROS: { valor: Filtro; etiqueta: string }[] = [
  { valor: "pend", etiqueta: "Pendientes" },
  { valor: "todos", etiqueta: "Todos" },
  { valor: "urg", etiqueta: "🔴 Urgentes" },
  { valor: "tarde", etiqueta: "⚠️ Atrasados" },
  { valor: "fab2", etiqueta: "🏭 Fábrica 2" },
  { valor: "muestras", etiqueta: "🧪 Faltan muestras" },
];

type FilaPrenda = { prenda: string; calidad: string; cantidad: number };

export default function TableroCliente({ datos, puedeMarcar = false, puedeEditar = false, puedeEditarContenido = false, estacionesPermitidas }: {
  datos: DatosTablero | { error: string };
  puedeMarcar?: boolean;
  /** v122. Habilita el modo edicion: diseñador, autor de mockup, observacion
   *  y fechas se cambian en la propia fila. */
  puedeEditar?: boolean;
  /** v123. Corregir cantidades de prendas: reescribe contrato_prendas, asi que
   *  va con el permiso estrecho, no con el de editar un dato suelto. */
  puedeEditarContenido?: boolean;
  /** v117. Con valores, la pantalla es la de un operario: solo sus estaciones
   *  y sin la opcion de ver el taller completo. Sin valores, tablero normal. */
  estacionesPermitidas?: string[];
}) {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const [refrescando, refrescar] = useTransition();
  const [marcando, setMarcando] = useState("");
  const [edicion, setEdicion] = useState(false);
  const [forzarTarjetas, setForzarTarjetas] = useState(false);
  const [editandoPrendas, setEditandoPrendas] = useState<Fila | null>(null);
  const [filasPrenda, setFilasPrenda] = useState<FilaPrenda[]>([]);
  const [detalladas, setDetalladas] = useState(false);
  const [cargandoPrendas, setCargandoPrendas] = useState(false);
  const [guardando, setGuardando] = useState("");

  // Todos los cambios de la fila pasan por la MISMA funcion que el editor del
  // expediente (v99): las validaciones, el evento en el historial y el control
  // de permiso viven en un solo sitio, no en dos que puedan discrepar.
  //
  // El motivo va fijo y no se pregunta. Aqui se corrige un dato suelto sobre la
  // marcha; pedir diez caracteres por cada fecha haria que nadie use el tablero
  // y se siga corrigiendo en la hoja. Quien cambio que y cuando si queda.
  async function guardarCampo(f: Fila, cambios: Record<string, string>, etiqueta: string) {
    if (!puedeEditar || guardando) return;
    setGuardando(f.numero + etiqueta);
    const { error } = await supabase.rpc("guardar_gestion_contrato_v99", {
      p_contrato_id: f.id,
      p_cambios: cambios,
      p_motivo: "Cambio rápido desde el tablero de producción",
      p_idempotency_key: crypto.randomUUID(),
    });
    setGuardando("");
    if (error) {
      await mostrarAvisoDialogo(
        error.message.includes("guardar_gestion_contrato_v99") ? "Falta instalar v99 en Supabase." : error.message,
        `No se pudo cambiar ${etiqueta}`, true);
      return;
    }
    refrescar(() => router.refresh());
  }
  // Marcar escribe en Supabase Y devuelve la marca a la hoja, porque las
  // estaciones del taller siguen trabajando en el tablero de Apps Script: si
  // solo se guardara aqui, el operario de Corte no veria el avance. La ruta
  // avisa con `hoja:false` cuando la segunda escritura falla, y eso se muestra:
  // es un desfase recuperable, pero callarlo seria peor.
  async function alternarEtapa(numero: string, et: Etapa, hecha: boolean) {
    if (!puedeMarcar) return;
    const area = et.area || et.etiqueta;
    const clave = `${numero}|${area}|${et.nombre}`;
    if (marcando) return;
    if (hecha) {
      const motivo = await pedirMotivoDialogo(`Explica por qué se quita "${et.etiqueta}" de ${numero}.`, 10, "Quitar marca");
      if (!motivo) return;
      setMarcando(clave);
      const r = await fetch("/api/bomansport/desmarcar-etapa", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ numero, area, etapa: et.nombre, motivo }) });
      const d = await r.json().catch(() => ({ ok: false, error: "Respuesta inválida" }));
      setMarcando("");
      if (!d.ok) return void mostrarAvisoDialogo(d.error || "No se pudo quitar la marca", "Sin cambios", true);
      if (d.aviso) await mostrarAvisoDialogo(d.aviso, "Ojo", true);
    } else {
      if (!await confirmarDialogo(`¿Marcar "${et.etiqueta}" en el contrato ${numero}?`)) return;
      setMarcando(clave);
      const r = await fetch("/api/bomansport/marcar-etapa", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ numero, area, etapa: et.nombre }) });
      const d = await r.json().catch(() => ({ ok: false, error: "Respuesta inválida" }));
      setMarcando("");
      if (!d.ok) return void mostrarAvisoDialogo(d.error || "No se pudo marcar", "Sin cambios", true);
      if (d.aviso) await mostrarAvisoDialogo(d.aviso, "Ojo", true);
    }
    refrescar(() => router.refresh());
  }

  async function abrirPrendas(f: Fila) {
    setEditandoPrendas(f); setFilasPrenda([]); setCargandoPrendas(true);
    const { data, error } = await supabase.rpc("prendas_contrato_v123", { p_contrato_id: f.id });
    setCargandoPrendas(false);
    if (error) { setEditandoPrendas(null); return void mostrarAvisoDialogo(error.message.includes("prendas_contrato_v123") ? "Falta instalar v123 en Supabase." : error.message, "No se pudieron leer las prendas", true) }
    const d = data as { detalladas?: boolean; filas?: FilaPrenda[] };
    setDetalladas(!!d?.detalladas);
    setFilasPrenda((d?.filas ?? []).map((x) => ({ prenda: x.prenda, calidad: x.calidad ?? "", cantidad: Number(x.cantidad) || 0 })));
  }

  async function guardarPrendas(confirmar: boolean) {
    if (!editandoPrendas) return;
    const filasLimpias = filasPrenda
      .map((x) => ({ prenda: x.prenda.trim(), calidad: x.calidad.trim(), cantidad: Number(x.cantidad) || 0 }))
      .filter((x) => x.prenda && x.cantidad > 0);
    if (!filasLimpias.length) return void mostrarAvisoDialogo("Agrega al menos una prenda con cantidad.", "Sin datos", true);
    setGuardando("prendas");
    const { data, error } = await supabase.rpc("editar_prendas_tablero_v123", {
      p_contrato_id: editandoPrendas.id, p_filas: filasLimpias,
      p_confirmar: confirmar, p_idempotency_key: crypto.randomUUID(),
    });
    setGuardando("");
    if (error) return void mostrarAvisoDialogo(error.message, "No se pudieron guardar las prendas", true);
    const r = data as { ok?: boolean; requiere_confirmar?: boolean; mensaje?: string };
    // La base avisa ANTES de escribir si el contrato tenia desglose por talla.
    // Ese aviso se muestra tal cual y solo se reintenta si la persona acepta.
    if (r?.requiere_confirmar) {
      if (await confirmarDialogo(`${r.mensaje}

¿Reemplazar de todas formas?`, true)) await guardarPrendas(true);
      return;
    }
    setEditandoPrendas(null);
    refrescar(() => router.refresh());
  }

  const [busqueda, setBusqueda] = useState("");
  const [filtro, setFiltro] = useState<Filtro>("pend");
  const [orden, setOrden] = useState<"entrega" | "numero">("entrega");
  const restringido = !!estacionesPermitidas?.length;
  const [estacion, setEstacion] = useState(restringido ? estacionesPermitidas![0] : "");

  const hayError = "error" in datos;
  const etapas = hayError ? [] : datos.etapas;
  const filas = hayError ? [] : datos.filas;

  // Las estaciones vienen en los datos: cada etapa dice que area la marca
  // ("Sellos · TPU" -> Sellos). Elegir una deja la tabla como la pantalla de
  // esa estacion en el taller, sin columnas de trabajo ajeno.
  // Sin restriccion se ofrecen las estaciones completas; a un operario se le
  // ofrece exactamente lo que tiene asignado, que puede ser una sub-estacion
  // ("Sellos · TPU") y no toda el area.
  const estaciones = useMemo(
    () => restringido
      ? estacionesPermitidas!
      : Array.from(new Set(etapas.map((e) => String(e.area || "").split(" · ")[0]).filter(Boolean))),
    [etapas, restringido, estacionesPermitidas],
  );
  // Se conserva el indice original porque `f.hechas` va emparejado con
  // datos.etapas, no con las columnas que se pintan. Una estacion completa
  // ("Sellos") cubre sus sub-estaciones; una sub-estacion, solo la suya.
  const columnas = useMemo(
    () => etapas.map((et, i) => ({ et, i })).filter(({ et }) => {
      if (!estacion) return true;
      const area = String(et.area || "");
      return area === estacion || area.split(" · ")[0] === estacion;
    }),
    [etapas, estacion],
  );

  // Tramos de columnas por estacion, para la fila de encabezado que las
  // agrupa. Las etapas ya vienen en orden de proceso, asi que basta con juntar
  // las consecutivas de la misma area.
  const grupos = useMemo(() => {
    const salida: { area: string; ancho: number }[] = [];
    for (const { et } of columnas) {
      const area = String(et.area || "").split(" · ")[0];
      const ultimo = salida[salida.length - 1];
      if (ultimo && ultimo.area === area) ultimo.ancho++;
      else salida.push({ area, ancho: 1 });
    }
    return salida;
  }, [columnas]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    // Una columna de Exteriores en un contrato sin chompas no es trabajo
    // pendiente, es trabajo que no existe. Sin esta excepcion esos contratos
    // no salian NUNCA de "Pendientes" por mucho que el taller los terminara.
    const pendiente = (f: Fila) => columnas.some(({ et, i }) => !f.hechas[i] && !(et.exterior && !f.esExterior));
    const lista = filas.filter((f) => {
      if (filtro === "urg" && !f.urgente) return false;
      if (filtro === "tarde" && !f.atrasado) return false;
      if (filtro === "fab2" && f.fabrica !== 2) return false;
      if (filtro === "muestras" && !f.muestras?.tpu && !f.muestras?.dtf) return false;
      // "Pendientes" esconde lo que ya esta hecho. Con una estacion elegida es
      // lo que le falta a ESA estacion: su cola de trabajo, no la del taller.
      if (filtro === "pend" && !pendiente(f)) return false;
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
  }, [filas, busqueda, filtro, orden, columnas]);

  if (hayError) {
    return <div className="card"><div className="header-row"><h3 style={{ margin: 0 }}>Tablero de producción</h3></div>
      <p className="conteo">No se pudo leer el tablero desde Boman Sport.</p>
      <div className="badge bajo" style={{ display: "inline-block", whiteSpace: "normal", lineHeight: 1.4 }}>{datos.error}</div>
      <div className="acciones-documento" style={{ marginTop: 12 }}>
        <button onClick={() => refrescar(() => router.refresh())} disabled={refrescando}>{refrescando ? "Reintentando..." : "Reintentar"}</button>
      </div></div>;
  }

  return <div className={forzarTarjetas ? estilos.forzarTarjetas : ""}>
    <div className="card">
      <div className="header-row">
        <div>
          <h3 className={estilos.tituloEstacion} style={{ margin: 0 }}>
            Tablero de producción
            {!!estacion && <span className={estilos.chipEstacion}>{estacion}</span>}
          </h3>
          <p className="conteo">{visibles.length} de {datos.total} contratos · datos de {datos.hora}</p>
        </div>
        <div className="form-inline">
          {puedeEditar && (
            <button className={edicion ? "" : "secondary"} onClick={() => setEdicion((x) => !x)}>
              {edicion ? "🔒 Salir de edición" : "✏️ Modo edición"}
            </button>
          )}
          <button className={forzarTarjetas ? "" : "secondary"} onClick={() => setForzarTarjetas((x) => !x)} title="Ver como tarjetas, para el celular">
            📱 Tarjetas
          </button>
          <button className="secondary" onClick={() => refrescar(() => router.refresh())} disabled={refrescando}>
            {refrescando ? "Actualizando..." : "🔄 Actualizar"}
          </button>
        </div>
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
        <div className="field">
          <label>Estación</label>
          <select value={estacion} onChange={(e) => setEstacion(e.target.value)} disabled={restringido && estaciones.length === 1}>
            {!restringido && <option value="">Todo el taller</option>}
            {estaciones.map((a) => <option key={a} value={a}>{a}</option>)}
          </select>
          {!!estacion && <p className="conteo">Solo las etapas de {estacion}.</p>}
        </div>
      </div>

      <div className="filtros">
        {FILTROS.map((f) => (
          <button key={f.valor} className={filtro === f.valor ? "" : "secondary"} onClick={() => setFiltro(f.valor)}>{f.etiqueta}</button>
        ))}
      </div>
    </div>

    {restringido && !columnas.length && (
      <div className="card"><div className="badge bajo" style={{ display: "inline-block", whiteSpace: "normal", lineHeight: 1.4 }}>
        Ninguna etapa del tablero está asignada a {estacion}. Si acaba de configurarse, falta correr <code>sql/v117_estaciones_produccion.sql</code>: sin ella todas las etapas llegan sin estación.
      </div></div>
    )}

    <div className="card">
      {edicion && <>
        <datalist id="tablero-disenadores">{(hayError ? [] : datos.disenadores ?? []).map((d) => <option key={d} value={d} />)}</datalist>
        <datalist id="tablero-autores">{(hayError ? [] : datos.autoresMockup ?? []).map((d) => <option key={d} value={d} />)}</datalist>
        <p className="conteo" style={{ marginTop: 0 }}>Modo edición: los cambios se guardan al salir del campo y quedan en el historial del contrato.</p>
      </>}
      <div className={estilos.tarjetas}>
        {visibles.map((f) => (
          <article key={`c-${f.numero}`} className={`${estilos.tarjeta} ${f.urgente ? estilos.urgente : f.atrasado ? estilos.atrasada : ""}`}>
            <div className={estilos.tFila}>
              {f.mks[0]?.i && (
                // eslint-disable-next-line @next/next/no-img-element
                <img className={estilos.tFoto} src={`https://drive.google.com/thumbnail?id=${f.mks[0].i}&sz=w160`} alt="" loading="lazy" />
              )}
              <div className={estilos.tDatos}>
                <div className={estilos.tNumero}>{f.urgente ? "🔴 " : ""}{f.numero}</div>
                <div className={estilos.tCliente}>{f.cliente}</div>
                <div className={estilos.tMeta}>
                  <span className={f.atrasado ? "badge bajo" : ""}>🚚 {f.entrega || "sin fecha"}</span>
                  <span>🎨 {f.disenador || "sin asignar"}</span>
                  <span>{f.prendas} pr.</span>
                  {f.vendedor && <span>{f.vendedor}</span>}
                </div>
                {f.obs && <div className="badge bajo" style={{ marginTop: 6, whiteSpace: "normal", lineHeight: 1.3 }}>📝 {f.obs}</div>}
              </div>
            </div>
            <div className={estilos.tChips}>
              {columnas.map(({ et, i }) => {
                const noAplica = et.exterior && !f.esExterior;
                const hecha = f.hechas[i];
                const clase = `${estilos.tChip} ${hecha ? estilos.ok : ""}`;
                const estilo = hecha ? { background: et.bg, color: et.fg } : undefined;
                if (noAplica) return null;
                return puedeMarcar
                  ? <button key={`c-${f.numero}-${i}`} className={clase} style={estilo} disabled={marcando !== ""}
                      title={hecha ? `Quitar ${et.etiqueta}` : `Marcar ${et.etiqueta}`}
                      onClick={() => void alternarEtapa(f.numero, et, hecha)}>
                      {et.emoji} {et.etiqueta}{hecha ? " ✓" : ""}
                    </button>
                  : <span key={`c-${f.numero}-${i}`} className={clase} style={estilo}>{et.emoji} {et.etiqueta}{hecha ? " ✓" : ""}</span>;
              })}
            </div>
          </article>
        ))}
        {!visibles.length && <div className="vacio">Sin contratos con ese filtro.</div>}
      </div>

      <div className={`tabla-scroll ${estilos.tabla}`}>
        <table>
          <thead>
            <tr>
              <th className={estilos.colContrato} rowSpan={2}>Contrato</th>
              <th style={{ minWidth: 110 }} rowSpan={2}>Entrega</th>
              <th style={{ minWidth: 105 }} rowSpan={2}>Diseño</th>
              {grupos.map((g, k) => (
                <th key={`${g.area}-${k}`} colSpan={g.ancho} className={`${estilos.grupo} ${g.area ? "" : estilos.grupoSinDueno}`}>
                  {g.area || "Sin estación"}
                </th>
              ))}
            </tr>
            <tr>
              {columnas.map(({ et, i }) => (
                <th key={`${et.area}-${et.nombre}-${i}`} className={estilos.etapaCab} title={et.area || "No la marca el taller"}>
                  <span className={estilos.etapaPill} style={{ background: et.bg, color: et.fg }}>
                    {et.emoji} {et.etiqueta}
                  </span>
                  <div className={estilos.etapaConteo}><b>{et.hechos}</b>/{datos.total}</div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {visibles.map((f) => (
              <tr key={f.numero} className={f.atrasado ? "fila-alerta" : ""}>
                <td className={estilos.colContrato}>
                  <div className={estilos.identidad}>
                    {f.mks[0]?.i && (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img className={estilos.miniatura} src={`https://drive.google.com/thumbnail?id=${f.mks[0].i}&sz=w120`} alt="" loading="lazy" />
                    )}
                    <div className={estilos.datos}>
                      <strong className={estilos.numero}>{f.urgente ? "🔴 " : ""}{f.numero}</strong>
                      <div className={estilos.cliente} title={f.cliente}>{f.cliente}</div>
                      <div className="conteo">
                        {f.vendedor} · {f.prendas} pr.{f.calidad.length ? ` · ${f.calidad.join(" · ")}` : ""}
                        {edicion && puedeEditarContenido && (
                          <button className={estilos.enlaceMini} onClick={() => void abrirPrendas(f)} title="Corregir cantidades de prendas">✏️ prendas</button>
                        )}
                      </div>
                      {edicion ? (
                        <input className={estilos.obsInput} defaultValue={f.obs} placeholder="📝 Observación para producción" disabled={guardando !== ""}
                          onBlur={(e) => { const v = e.target.value.trim(); if (v !== f.obs) void guardarCampo(f, { observacion: v }, "la observación") }}
                          onKeyDown={(e) => { if (e.key === "Enter") e.currentTarget.blur() }} />
                      ) : f.obs ? (
                        <div className="badge bajo" style={{ marginTop: 3, whiteSpace: "normal", lineHeight: 1.3 }}>📝 {f.obs}</div>
                      ) : null}
                    </div>
                  </div>
                </td>
                <td>
                  {edicion ? (
                    <div className={estilos.campos}>
                      <label className={estilos.campoMini}><span>Entrega</span>
                        <input type="date" defaultValue={f.entregaISO ?? ""} disabled={guardando !== ""}
                          onChange={(e) => void guardarCampo(f, { fecha_entrega: e.target.value }, "la entrega")} />
                      </label>
                      <label className={estilos.campoMini}><span>Inicia</span>
                        <input type="date" defaultValue={f.inicioISO ?? ""} disabled={guardando !== ""}
                          onChange={(e) => void guardarCampo(f, { fecha_inicio_produccion: e.target.value }, "el inicio")} />
                      </label>
                    </div>
                  ) : (
                    <>
                      <span className={f.atrasado ? "badge bajo" : "badge ok"}>{f.entrega || "sin fecha"}</span>
                      {f.inicio && <div className="conteo">inicia {f.inicio}</div>}
                    </>
                  )}
                </td>
                <td>
                  {edicion ? (
                    <div className={estilos.campos}>
                      <label className={estilos.campoMini}><span>Diseñador</span>
                        <input list="tablero-disenadores" defaultValue={f.disenador} placeholder="sin asignar" disabled={guardando !== ""}
                          onBlur={(e) => { const v = e.target.value.trim(); if (v !== f.disenador) void guardarCampo(f, { disenador: v }, "el diseñador") }}
                          onKeyDown={(e) => { if (e.key === "Enter") e.currentTarget.blur() }} />
                      </label>
                      <label className={estilos.campoMini}><span>Mockup por</span>
                        <input list="tablero-autores" defaultValue={f.autorMockup} placeholder="sin registrar" disabled={guardando !== ""}
                          onBlur={(e) => { const v = e.target.value.trim(); if (v !== f.autorMockup) void guardarCampo(f, { autor_mockup: v }, "el autor del mockup") }}
                          onKeyDown={(e) => { if (e.key === "Enter") e.currentTarget.blur() }} />
                      </label>
                    </div>
                  ) : (
                    <>
                      {f.disenador || <span className="conteo">sin asignar</span>}
                      {f.autorMockup && <div className="conteo">🖌️ {f.autorMockup}</div>}
                      {f.fabrica === 2 && <div className="badge ajuste">Fábrica 2</div>}
                      {f.maquila && <div className="conteo">🏭 {f.maquila}</div>}
                    </>
                  )}
                </td>
                {columnas.map(({ et, i }) => (
                  <td key={`${f.numero}-${i}`} className={estilos.celda}>
                    {/* Columnas de Exteriores: un contrato sin chompas no las lleva,
                        y un vacio se confunde con "pendiente". El punto dice "no aplica". */}
                    {et.exterior && !f.esExterior
                      ? <span className={`${estilos.marca} ${estilos.noAplica}`} title="No aplica a este contrato">·</span>
                      : puedeMarcar
                        ? <button className={`${estilos.marca} ${f.hechas[i] ? estilos.hecha : estilos.pendiente}`} disabled={marcando !== ""}
                            title={f.hechas[i] ? `Quitar ${et.etiqueta}` : `Marcar ${et.etiqueta}`}
                            onClick={() => void alternarEtapa(f.numero, et, f.hechas[i])}>
                            {f.hechas[i] ? "✓" : ""}
                          </button>
                        : <span className={`${estilos.marca} ${f.hechas[i] ? estilos.hecha : estilos.pendiente}`}>{f.hechas[i] ? "✓" : ""}</span>}
                  </td>
                ))}
              </tr>
            ))}
            {!visibles.length && (
              <tr><td colSpan={3 + columnas.length} className="vacio">Sin contratos con ese filtro.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
    {editandoPrendas && (
      <div className={estilos.modalFondo} role="dialog" aria-modal="true" onMouseDown={(e) => { if (e.target === e.currentTarget) setEditandoPrendas(null) }}>
        <div className={estilos.modal}>
          <div className="header-row">
            <div>
              <h3 style={{ margin: 0 }}>Prendas de {editandoPrendas.numero}</h3>
              <p className="conteo">{editandoPrendas.cliente}</p>
            </div>
            <button className="secondary" onClick={() => setEditandoPrendas(null)}>Cerrar</button>
          </div>
          {detalladas && (
            <div className="badge bajo" style={{ display: "block", whiteSpace: "normal", lineHeight: 1.4, marginBottom: 10 }}>
              Este contrato tiene el desglose por talla y género. Guardar aquí lo reemplaza por totales planos y el taller
              pierde de qué talla es cada prenda. Para conservarlo, edítalo desde el expediente.
            </div>
          )}
          {cargandoPrendas ? <p className="conteo">Leyendo las prendas…</p> : <>
            {filasPrenda.map((x, i) => (
              <div className="form-inline" key={i} style={{ marginBottom: 6 }}>
                <input value={x.prenda} placeholder="Prenda" style={{ flex: 1, minWidth: 150 }}
                  onChange={(e) => setFilasPrenda((p) => p.map((y, k) => k === i ? { ...y, prenda: e.target.value } : y))} />
                <input value={x.calidad} placeholder="Calidad" style={{ width: 130 }}
                  onChange={(e) => setFilasPrenda((p) => p.map((y, k) => k === i ? { ...y, calidad: e.target.value } : y))} />
                <input type="number" min={0} value={x.cantidad} style={{ width: 80 }}
                  onChange={(e) => setFilasPrenda((p) => p.map((y, k) => k === i ? { ...y, cantidad: Number(e.target.value) } : y))} />
                <button className="secondary btn-mini" onClick={() => setFilasPrenda((p) => p.filter((_, k) => k !== i))}>Quitar</button>
              </div>
            ))}
            <button className="secondary btn-mini" onClick={() => setFilasPrenda((p) => [...p, { prenda: "", calidad: "", cantidad: 0 }])}>+ Agregar prenda</button>
            <div className="header-row" style={{ marginTop: 12 }}>
              <strong>Total: {filasPrenda.reduce((s, x) => s + (Number(x.cantidad) || 0), 0)} prendas</strong>
              <button disabled={guardando === "prendas"} onClick={() => void guardarPrendas(false)}>
                {guardando === "prendas" ? "Guardando…" : "Guardar prendas"}
              </button>
            </div>
          </>}
        </div>
      </div>
    )}
  </div>;
}
