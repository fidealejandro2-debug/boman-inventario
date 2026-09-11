"use client";

import { useMemo, useState, useTransition } from "react";
import { confirmarDialogo, mostrarAvisoDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";
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

type Filtro = "pend" | "todos" | "urg" | "tarde" | "fab2" | "muestras" | "ent";
type Columna = "numero" | "cliente" | "entrega" | "inicio" | "prendas" | "disenador";

const ORDENABLES: { clave: Columna; etiqueta: string }[] = [
  { clave: "numero", etiqueta: "Contrato" },
  { clave: "entrega", etiqueta: "Entrega" },
  { clave: "disenador", etiqueta: "Diseño" },
];

function hoyISO() { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}` }
function masDias(dias: number) { const d = new Date(); d.setDate(d.getDate() + dias); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}` }

const FILTROS: { valor: Filtro; etiqueta: string }[] = [
  { valor: "pend", etiqueta: "Pendientes" },
  { valor: "todos", etiqueta: "Todos" },
  { valor: "urg", etiqueta: "🔴 Urgentes" },
  { valor: "tarde", etiqueta: "⚠️ Atrasados" },
  { valor: "fab2", etiqueta: "🏭 Fábrica 2" },
  { valor: "muestras", etiqueta: "🧪 Faltan muestras" },
  { valor: "ent", etiqueta: "🚚 Entregados" },
];

type FilaPrenda = { prenda: string; calidad: string; cantidad: number };
type ArchivoDet = { id: string; drive: string; url: string; descripcion: string; prenda?: string; posicion?: string; tecnica?: string; observacion?: string };
type EtapaDet = { area: string; etapa: string; operario: string; noAplica: boolean; cuando: string };
type Detalle = { mockups: ArchivoDet[]; logos: ArchivoDet[]; etapas: EtapaDet[] };

// Una imagen puede venir de Drive (lo importado de la hoja) o del bucket de
// Supabase (lo ingresado en Vercel). El id de Drive manda porque de ahi sale la
// miniatura publica; si no lo hay, la url guardada sirve tal cual.
function fuenteImagen(a: ArchivoDet, ancho: number) {
  return a.drive ? `https://drive.google.com/thumbnail?id=${a.drive}&sz=w${ancho}` : a.url;
}

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
  const [lupa, setLupa] = useState<Fila | null>(null);
  const [detalle, setDetalle] = useState<Detalle | null>(null);
  const [cargandoDetalle, setCargandoDetalle] = useState(false);
  const [subiendo, setSubiendo] = useState(false);
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

  async function abrirLupa(f: Fila) {
    setLupa(f); setDetalle(null); setCargandoDetalle(true);
    const { data, error } = await supabase.rpc("archivos_contrato_v125", { p_contrato_id: f.id });
    setCargandoDetalle(false);
    if (error) { setLupa(null); return void mostrarAvisoDialogo(error.message.includes("archivos_contrato_v125") ? "Falta instalar v125 en Supabase." : error.message, "No se pudo abrir el contrato", true) }
    setDetalle(data as Detalle);
  }

  // Misma cadena que el asistente de ingreso: la base reserva la ruta, el
  // archivo sube al bucket y recien despues se apenda la fila. Si la subida
  // falla, no queda una fila apuntando a un archivo que no existe.
  async function subirFoto(f: Fila, file: File | null) {
    if (!file || subiendo) return;
    setSubiendo(true);
    try {
      const clave = crypto.randomUUID();
      const prep = await supabase.rpc("preparar_archivo_contrato_v108", {
        p_nombre_archivo: file.name, p_mime_type: file.type,
        p_tamano_bytes: file.size, p_idempotency_key: clave,
      });
      if (prep.error) throw prep.error;
      const path = (prep.data as { path: string; id: string }).path;
      const subida = await supabase.storage.from("contratos-archivos").upload(path, file, { contentType: file.type, upsert: false });
      if (subida.error) throw subida.error;
      const publica = supabase.storage.from("contratos-archivos").getPublicUrl(path).data.publicUrl;
      const alta = await supabase.rpc("agregar_archivo_contrato_v125", {
        p_contrato_id: f.id, p_pendiente_id: (prep.data as { id: string }).id,
        p_url: publica, p_descripcion: `Foto de ${f.numero}`, p_idempotency_key: crypto.randomUUID(),
      });
      if (alta.error) throw alta.error;
      if (lupa?.id === f.id) await abrirLupa(f);
      refrescar(() => router.refresh());
    } catch (e) {
      await mostrarAvisoDialogo(e instanceof Error ? e.message : "No se pudo subir la foto", "Error al subir", true);
    } finally { setSubiendo(false) }
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
  const [orden, setOrden] = useState<Columna>("entrega");
  const [asc, setAsc] = useState(true);
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  // Los entregados no vienen en el tablero normal: son otra consulta. Se piden
  // solo si se elige ese filtro y se quedan cacheados aqui mientras dure la
  // pagina, para no repetir la llamada cada vez que se alterna el filtro.
  const [entregados, setEntregados] = useState<DatosTablero | null>(null);
  const [cargandoEnt, setCargandoEnt] = useState(false);
  const restringido = !!estacionesPermitidas?.length;
  const [estacion, setEstacion] = useState(restringido ? estacionesPermitidas![0] : "");

  const hayError = "error" in datos;
  // Con el filtro "Entregados" la fuente es otra consulta, no un subconjunto:
  // el tablero normal ni siquiera trae esos contratos.
  const fuente: DatosTablero | null = hayError ? null : (filtro === "ent" ? entregados : datos);
  const etapas = fuente?.etapas ?? (hayError ? [] : datos.etapas);
  const filas = fuente?.filas ?? [];

  async function pedirEntregados() {
    if (entregados || cargandoEnt) return;
    setCargandoEnt(true);
    const { data, error } = await supabase.rpc("tablero_produccion_v102", { p_solo_entregados: true });
    setCargandoEnt(false);
    if (error) return void mostrarAvisoDialogo(
      /p_solo_entregados|not unique|does not exist/i.test(error.message)
        ? "Falta correr sql/v124_tablero_entregados.sql para poder ver los entregados."
        : error.message, "No se pudieron cargar los entregados", true);
    setEntregados(data as DatosTablero);
  }

  function elegirFiltro(f: Filtro) {
    setFiltro(f);
    if (f === "ent") void pedirEntregados();
  }

  function exportar() {
    exportarCSV(`tablero_${filtro}_${hoyISO()}`, visibles.map((f) => ({
      Contrato: f.numero, Cliente: f.cliente, Vendedor: f.vendedor,
      Disenador: f.disenador, "Autor mockup": f.autorMockup,
      Ingreso: f.ingreso, Inicio: f.inicio, Entrega: f.entrega,
      Prendas: f.prendas, Desglose: f.prendasTxt, Calidad: f.calidad.join(" · "),
      Urgente: f.urgente ? "Sí" : "No", Atrasado: f.atrasado ? "Sí" : "No",
      Maquila: f.maquila, Observacion: f.obs,
      // Una columna por etapa visible: el CSV sale con lo mismo que se ve en
      // pantalla, no con las 16 siempre.
      ...Object.fromEntries(columnas.map(({ et, i }) => [et.etiqueta, f.hechas[i] ? "Sí" : ""])),
    })));
  }

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
      // Rango por fecha de entrega. Un contrato sin fecha queda fuera cuando
      // hay rango: no se puede afirmar que caiga dentro.
      if (desde || hasta) {
        const d = f.entregaISO || "";
        if (!d) return false;
        if (desde && d < desde) return false;
        if (hasta && d > hasta) return false;
      }
      // "Pendientes" esconde lo que ya esta hecho. Con una estacion elegida es
      // lo que le falta a ESA estacion: su cola de trabajo, no la del taller.
      if (filtro === "pend" && !pendiente(f)) return false;
      if (!q) return true;
      return [f.numero, f.cliente, f.disenador, f.vendedor, f.prendasTxt]
        .some((campo) => String(campo || "").toLowerCase().includes(q));
    });
    const signo = asc ? 1 : -1;
    return lista.sort((a, b) => {
      switch (orden) {
        case "numero": return signo * a.numero.localeCompare(b.numero);
        case "cliente": return signo * a.cliente.localeCompare(b.cliente, "es");
        case "prendas": return signo * (a.prendas - b.prendas);
        // Sin diseñador va SIEMPRE al final, se ordene como se ordene: es lo
        // que hay que resolver, no un valor mas del alfabeto.
        case "disenador": {
          if (!a.disenador !== !b.disenador) return a.disenador ? -1 : 1;
          return signo * a.disenador.localeCompare(b.disenador, "es");
        }
        case "inicio": return signo * String(a.inicioISO || "9999").localeCompare(String(b.inicioISO || "9999"));
        default: {
          // Lo que no tiene fecha de entrega tampoco se mezcla: al final.
          if (!a.entregaMs && !b.entregaMs) return 0;
          if (!a.entregaMs) return 1;
          if (!b.entregaMs) return -1;
          return signo * (a.entregaMs - b.entregaMs);
        }
      }
    });
  }, [filas, busqueda, filtro, orden, asc, columnas, desde, hasta]);

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
          <label>Entrega entre</label>
          <div className="form-inline">
            <input type="date" value={desde} onChange={(e) => setDesde(e.target.value)} aria-label="Entrega desde" />
            <input type="date" value={hasta} onChange={(e) => setHasta(e.target.value)} aria-label="Entrega hasta" />
          </div>
          <div className="form-inline" style={{ marginTop: 6 }}>
            <button className="secondary btn-mini" onClick={() => { setDesde(hoyISO()); setHasta(hoyISO()) }}>Hoy</button>
            <button className="secondary btn-mini" onClick={() => { setDesde(hoyISO()); setHasta(masDias(6)) }}>7 días</button>
            <button className="secondary btn-mini" onClick={() => { setDesde(hoyISO()); setHasta(masDias(29)) }}>30 días</button>
            {(desde || hasta) && <button className="secondary btn-mini" onClick={() => { setDesde(""); setHasta("") }}>✕ Quitar</button>}
          </div>
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
          <button key={f.valor} className={filtro === f.valor ? "" : "secondary"} onClick={() => elegirFiltro(f.valor)}>{f.etiqueta}</button>
        ))}
        <button className="secondary" onClick={exportar} disabled={!visibles.length} title="Descarga lo que está a la vista">
          ⬇️ Exportar
        </button>
      </div>
      {filtro === "ent" && cargandoEnt && <p className="conteo">Cargando los entregados…</p>}
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
              <button className={estilos.botonFoto} onClick={() => void abrirLupa(f)} title="Ver mockups, logos y avance">
                {f.mks[0]?.i
                  // eslint-disable-next-line @next/next/no-img-element
                  ? <img className={estilos.tFoto} src={`https://drive.google.com/thumbnail?id=${f.mks[0].i}&sz=w160`} alt="" loading="lazy" />
                  : <span className={`${estilos.tFoto} ${estilos.sinFoto}`}>🖼️</span>}
              </button>
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
              {ORDENABLES.map((c, k) => (
                <th key={c.clave} rowSpan={2}
                  className={`${k === 0 ? estilos.colContrato : ""} ${estilos.ordenable}`}
                  style={k === 0 ? undefined : { minWidth: k === 1 ? 110 : 105 }}
                  onClick={() => { if (orden === c.clave) setAsc((x) => !x); else { setOrden(c.clave); setAsc(true) } }}
                  title={`Ordenar por ${c.etiqueta.toLowerCase()}`}>
                  {c.etiqueta}{orden === c.clave ? (asc ? " ▲" : " ▼") : ""}
                </th>
              ))}
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
                    <button className={estilos.botonFoto} onClick={() => void abrirLupa(f)} title="Ver mockups, logos y avance">
                      {f.mks[0]?.i
                        // eslint-disable-next-line @next/next/no-img-element
                        ? <img className={estilos.miniatura} src={`https://drive.google.com/thumbnail?id=${f.mks[0].i}&sz=w120`} alt="" loading="lazy" />
                        : <span className={estilos.sinFoto}>🖼️</span>}
                      {f.mks.length > 1 && <span className={estilos.contadorFotos}>{f.mks.length}</span>}
                    </button>
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
    {lupa && (
      <div className={estilos.modalFondo} role="dialog" aria-modal="true" onMouseDown={(e) => { if (e.target === e.currentTarget) setLupa(null) }}>
        <div className={`${estilos.modal} ${estilos.modalAncho}`}>
          <div className="header-row">
            <div>
              <h3 style={{ margin: 0 }}>{lupa.urgente ? "🔴 " : ""}{lupa.numero}</h3>
              <p className="conteo">{lupa.cliente} · {lupa.vendedor || "sin vendedor"}</p>
            </div>
            <button className="secondary" onClick={() => setLupa(null)}>Cerrar</button>
          </div>

          <div className={estilos.fichaChips}>
            <span className={lupa.atrasado ? "badge bajo" : "badge ok"}>🚚 Entrega {lupa.entrega || "sin fecha"}</span>
            {lupa.inicio && <span className="badge">▶️ Inicia {lupa.inicio}</span>}
            <span className="badge">{lupa.prendas} prendas</span>
            {lupa.disenador ? <span className="badge">🎨 {lupa.disenador}</span> : <span className="badge bajo">🎨 sin asignar</span>}
            {lupa.autorMockup && <span className="badge">🖌️ {lupa.autorMockup}</span>}
            {lupa.maquila && <span className="badge">🏭 {lupa.maquila}</span>}
            {lupa.fabrica === 2 && <span className="badge ajuste">Fábrica 2</span>}
          </div>
          {lupa.prendasTxt && <p className="conteo">🧵 {lupa.prendasTxt}</p>}
          {lupa.obs && <div className="badge bajo" style={{ display: "block", whiteSpace: "normal", lineHeight: 1.4, margin: "8px 0" }}>📝 {lupa.obs}</div>}

          {puedeEditarContenido && (
            <label className={estilos.subirFoto}>
              <input type="file" accept="image/jpeg,image/png,image/webp" capture="environment" disabled={subiendo}
                onChange={(e) => { void subirFoto(lupa, e.target.files?.[0] ?? null); e.target.value = "" }} />
              {subiendo ? "Subiendo…" : "📷 Agregar foto del diseño"}
            </label>
          )}

          {cargandoDetalle ? <p className="conteo">Cargando el contrato…</p> : detalle && <>
            <h4 className={estilos.tituloBloque}>Mockups ({detalle.mockups.length})</h4>
            {detalle.mockups.length ? (
              <div className={estilos.galeria}>
                {detalle.mockups.map((m) => (
                  <figure key={m.id}>
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={fuenteImagen(m, 900)} alt={m.descripcion} loading="lazy" />
                    <figcaption>{m.descripcion || "Mockup"}</figcaption>
                  </figure>
                ))}
              </div>
            ) : <p className="conteo">Este contrato no tiene mockups.</p>}

            {!!detalle.logos.length && <>
              <h4 className={estilos.tituloBloque}>Logos y sellos ({detalle.logos.length})</h4>
              <div className={estilos.galeriaChica}>
                {detalle.logos.map((l) => (
                  <figure key={l.id}>
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={fuenteImagen(l, 320)} alt={l.descripcion} loading="lazy" />
                    <figcaption>
                      {[l.prenda, l.posicion].filter(Boolean).join(" · ") || l.descripcion || "Logo"}
                      {l.tecnica && <span className="conteo"> · {l.tecnica}</span>}
                    </figcaption>
                  </figure>
                ))}
              </div>
            </>}

            <h4 className={estilos.tituloBloque}>Avance registrado ({detalle.etapas.length})</h4>
            {detalle.etapas.length ? (
              <ul className={estilos.avance}>
                {detalle.etapas.map((e, k) => (
                  <li key={k}>
                    <strong>{e.area || "—"}</strong> · {e.etapa}{e.noAplica ? " (no aplica)" : ""}
                    <span className="conteo"> — {e.operario || "sin registrar"}, {e.cuando}</span>
                  </li>
                ))}
              </ul>
            ) : <p className="conteo">Todavía nadie marcó una etapa de este contrato.</p>}
          </>}
        </div>
      </div>
    )}

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
