"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { tienePermiso, type Perfil } from "@/lib/permisos";
import { pedirTextoDialogo } from "@/components/Dialogo";

type Activo = {
  id: string; empresa_id: string; almacen_id: string | null; codigo: string; nombre: string;
  categoria: string; marca: string | null; modelo: string | null; numero_serie: string | null;
  ubicacion: string | null; responsable_id: string | null; responsable: string | null;
  criticidad: string; estado: string; fecha_adquisicion: string | null; valor_adquisicion: number | null;
  garantia_hasta: string | null; tipo_medidor: string; lectura_actual: number;
  frecuencia_mantenimiento_dias: number | null; frecuencia_mantenimiento_uso: number | null;
  ultimo_mantenimiento_fecha: string | null; proximo_mantenimiento_fecha: string | null;
  proxima_lectura_mantenimiento: number | null; notas: string | null; activo: boolean;
  empresa_codigo: string; empresa: string; almacen: string | null; estado_plan: string; ordenes_abiertas: number;
};
type Orden = {
  id: string; numero: string; activo_id: string; activo_codigo: string; activo_nombre: string;
  activo_criticidad: string; empresa: string; almacen: string | null; tipo: string; prioridad: string;
  estado: string; fecha_solicitud: string; fecha_programada: string | null; inicio_at: string | null;
  fin_at: string | null; descripcion: string; diagnostico: string | null; trabajo_realizado: string | null;
  proveedor: string | null; responsable: string | null; costo_estimado: number; costo_real: number | null;
  minutos_fuera_servicio: number | null; lectura_cierre: number | null; atrasada: boolean;
};
type Empresa = { id: string; codigo: string; razon_social: string };
type Almacen = { id: string; nombre: string };
type EmpresaAlmacen = { empresa_id: string; almacen_id: string };
type Responsable = { id: string; nombre_completo: string };
type Resumen = { activos: number; detenidos: number; vencidos: number; proximos: number; ordenes_abiertas: number; ordenes_atrasadas: number };
type Tab = "resumen" | "activos" | "ordenes";

const RESUMEN_VACIO: Resumen = { activos: 0, detenidos: 0, vencidos: 0, proximos: 0, ordenes_abiertas: 0, ordenes_atrasadas: 0 };
const ACTIVO_VACIO = {
  codigo: "", nombre: "", categoria: "maquinaria", empresa_id: "", almacen_id: "",
  marca: "", modelo: "", numero_serie: "", ubicacion: "", responsable_id: "", criticidad: "media",
  estado: "operativo", fecha_adquisicion: "", valor_adquisicion: "", garantia_hasta: "",
  tipo_medidor: "ninguno", lectura_actual: "0", frecuencia_mantenimiento_dias: "",
  frecuencia_mantenimiento_uso: "", proximo_mantenimiento_fecha: "",
  proxima_lectura_mantenimiento: "", notas: "", activo: true,
};
const ORDEN_VACIA = { activo_id: "", tipo: "preventivo", prioridad: "normal", fecha_programada: "", descripcion: "", responsable_id: "", costo_estimado: "0" };
const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });

function fecha(valor: string | null) {
  if (!valor) return "—";
  const [a, m, d] = valor.slice(0, 10).split("-");
  return `${d}/${m}/${a}`;
}
async function etiqueta(valor: string) { return valor.replaceAll("_", " "); }

export default function MantenimientoCliente({ perfil }: { perfil: Perfil }) {
  const supabase = useMemo(() => createClient(), []);
  const puedeEditar = tienePermiso(perfil, "mantenimiento.editar");
  const [tab, setTab] = useState<Tab>("resumen");
  const [activos, setActivos] = useState<Activo[]>([]);
  const [ordenes, setOrdenes] = useState<Orden[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [empresaAlmacenes, setEmpresaAlmacenes] = useState<EmpresaAlmacen[]>([]);
  const [responsables, setResponsables] = useState<Responsable[]>([]);
  const [resumen, setResumen] = useState<Resumen>(RESUMEN_VACIO);
  const [busqueda, setBusqueda] = useState("");
  const [estado, setEstado] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [editando, setEditando] = useState<Activo | null | undefined>(undefined);
  const [formActivo, setFormActivo] = useState(ACTIVO_VACIO);
  const [mostrarOrden, setMostrarOrden] = useState(false);
  const [formOrden, setFormOrden] = useState(ORDEN_VACIA);

  async function cargar() {
    setCargando(true); setError(null);
    const [a, o, e, al, ea, p, r] = await Promise.all([
      supabase.from("vista_activos_mantenimiento_v54").select("*").order("codigo"),
      supabase.from("vista_ordenes_mantenimiento_v54").select("*").order("created_at", { ascending: false }).limit(500),
      supabase.from("empresas").select("id,codigo,razon_social").eq("activo", true).order("codigo"),
      supabase.from("almacenes").select("id,nombre").eq("activo", true).order("nombre"),
      supabase.from("empresa_almacenes").select("empresa_id,almacen_id"),
      supabase.from("perfiles").select("id,nombre_completo").eq("activo", true).order("nombre_completo"),
      supabase.rpc("resumen_mantenimiento_v54"),
    ]);
    setCargando(false);
    const fallo = a.error ?? o.error ?? e.error ?? al.error ?? ea.error ?? p.error ?? r.error;
    if (fallo) return setError(fallo.message);
    setActivos((a.data ?? []) as Activo[]); setOrdenes((o.data ?? []) as Orden[]);
    setEmpresas((e.data ?? []) as Empresa[]); setAlmacenes((al.data ?? []) as Almacen[]);
    setEmpresaAlmacenes((ea.data ?? []) as EmpresaAlmacen[]);
    setResponsables((p.data ?? []) as Responsable[]);
    setResumen((r.data as Resumen) ?? RESUMEN_VACIO);
  }

  useEffect(() => { cargar(); }, []);

  const activosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    return activos.filter((a) => (!estado || a.estado_plan === estado || a.estado === estado)
      && (!q || [a.codigo, a.nombre, a.marca, a.modelo, a.numero_serie, a.empresa, a.almacen]
        .some((v) => (v ?? "").toLocaleLowerCase("es").includes(q))));
  }, [activos, busqueda, estado]);
  const ordenesFiltradas = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    return ordenes.filter((o) => (!estado || o.estado === estado)
      && (!q || [o.numero, o.activo_codigo, o.activo_nombre, o.descripcion, o.empresa]
        .some((v) => (v ?? "").toLocaleLowerCase("es").includes(q))));
  }, [ordenes, busqueda, estado]);
  const ordenesAbiertas = ordenes.filter((o) => !["completada", "cancelada"].includes(o.estado));
  const costoMes = ordenes.filter((o) => o.estado === "completada" && o.fin_at
    && o.fin_at.slice(0, 7) === new Date().toLocaleDateString("sv-SE", { timeZone: "America/Guayaquil" }).slice(0, 7))
    .reduce((s, o) => s + Number(o.costo_real ?? 0), 0);

  function nuevoActivo() {
    setFormActivo({ ...ACTIVO_VACIO, empresa_id: empresas[0]?.id ?? "" });
    setEditando(null); setError(null);
  }
  function editarActivo(a: Activo) {
    setFormActivo({
      codigo: a.codigo, nombre: a.nombre, categoria: a.categoria, empresa_id: a.empresa_id,
      almacen_id: a.almacen_id ?? "", marca: a.marca ?? "", modelo: a.modelo ?? "",
      numero_serie: a.numero_serie ?? "", ubicacion: a.ubicacion ?? "", criticidad: a.criticidad,
      responsable_id: a.responsable_id ?? "",
      estado: a.estado, fecha_adquisicion: a.fecha_adquisicion ?? "",
      valor_adquisicion: a.valor_adquisicion == null ? "" : String(a.valor_adquisicion),
      garantia_hasta: a.garantia_hasta ?? "", tipo_medidor: a.tipo_medidor,
      lectura_actual: String(a.lectura_actual),
      frecuencia_mantenimiento_dias: a.frecuencia_mantenimiento_dias == null ? "" : String(a.frecuencia_mantenimiento_dias),
      frecuencia_mantenimiento_uso: a.frecuencia_mantenimiento_uso == null ? "" : String(a.frecuencia_mantenimiento_uso),
      proximo_mantenimiento_fecha: a.proximo_mantenimiento_fecha ?? "",
      proxima_lectura_mantenimiento: a.proxima_lectura_mantenimiento == null ? "" : String(a.proxima_lectura_mantenimiento),
      notas: a.notas ?? "", activo: a.activo,
    });
    setEditando(a); setError(null);
  }
  async function cambiarActivo(cambio: Partial<typeof ACTIVO_VACIO>) { setFormActivo({ ...formActivo, ...cambio }); }

  async function guardarActivo() {
    if (!formActivo.codigo.trim() || !formActivo.nombre.trim() || !formActivo.empresa_id) return setError("Código, nombre y empresa son obligatorios.");
    const motivo = await pedirTextoDialogo("Motivo del registro o cambio:", editando ? "Actualización de ficha del activo" : "Alta inicial del activo");
    if (!motivo?.trim()) return;
    setProcesando(true); setError(null); setMensaje(null);
    const { error: guardarError } = await supabase.rpc("guardar_activo_mantenimiento_v54", {
      p_id: editando?.id ?? null,
      p_datos: { ...formActivo, almacen_id: formActivo.almacen_id || null,
        responsable_id: formActivo.responsable_id || null },
      p_motivo: motivo.trim(), p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (guardarError) return setError(guardarError.message);
    setEditando(undefined); setMensaje(editando ? "Activo actualizado." : "Activo creado."); await cargar();
  }

  function nuevaOrden(activo?: Activo) {
    setFormOrden({ ...ORDEN_VACIA, activo_id: activo?.id ?? activos.find((a) => a.activo && a.estado !== "baja")?.id ?? "", responsable_id: perfil.id });
    setMostrarOrden(true); setError(null);
  }
  async function crearOrden() {
    if (!formOrden.activo_id || !formOrden.descripcion.trim()) return setError("Selecciona el activo y describe el trabajo.");
    setProcesando(true); setError(null); setMensaje(null);
    const { error: crearError } = await supabase.rpc("crear_orden_mantenimiento_v54", {
      p_activo_id: formOrden.activo_id, p_tipo: formOrden.tipo, p_prioridad: formOrden.prioridad,
      p_fecha_programada: formOrden.fecha_programada || null, p_descripcion: formOrden.descripcion.trim(),
      p_responsable_id: formOrden.responsable_id || null, p_costo_estimado: Number(formOrden.costo_estimado) || 0,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (crearError) return setError(crearError.message);
    setMostrarOrden(false); setMensaje("Orden de mantenimiento creada."); setTab("ordenes"); await cargar();
  }

  const almacenesEmpresa = almacenes.filter((a) => empresaAlmacenes.some((ea) =>
    ea.empresa_id === formActivo.empresa_id && ea.almacen_id === a.id
  ));

  async function cambiarOrden(orden: Orden, destino: string) {
    const datos: Record<string, unknown> = {};
    let motivo = "";
    if (destino === "programada") {
      const programada = await pedirTextoDialogo("Fecha programada (AAAA-MM-DD):", orden.fecha_programada ?? "");
      if (!programada) return; datos.fecha_programada = programada; motivo = "Programación de la orden";
    } else if (destino === "completada") {
      const trabajo = await pedirTextoDialogo("Trabajo realizado:", ""); if (!trabajo?.trim()) return;
      const costo = await pedirTextoDialogo("Costo real USD:", String(orden.costo_estimado ?? 0)); if (costo === null) return;
      const minutos = await pedirTextoDialogo("Minutos fuera de servicio (opcional):", "");
      const lectura = await pedirTextoDialogo("Lectura actual al cierre (opcional):", "");
      const diagnostico = await pedirTextoDialogo("Diagnóstico / causa encontrada (opcional):", "");
      Object.assign(datos, { trabajo_realizado: trabajo.trim(), costo_real: Number(costo) || 0,
        minutos_fuera_servicio: minutos || null, lectura_cierre: lectura || null, diagnostico: diagnostico || null });
      motivo = "Trabajo verificado y completado";
    } else if (destino === "cancelada") {
      const cancelacion = await pedirTextoDialogo("Justificación de la cancelación:", ""); if (!cancelacion?.trim()) return;
      datos.cancelacion_motivo = cancelacion.trim(); motivo = cancelacion.trim();
    } else {
      const texto = destino === "en_proceso" ? "Inicio del trabajo" : "Trabajo puesto en espera";
      motivo = (await pedirTextoDialogo("Observación:", texto))?.trim() ?? ""; if (!motivo) return;
    }
    setProcesando(true); setError(null); setMensaje(null);
    const { error: cambioError } = await supabase.rpc("cambiar_estado_orden_mantenimiento_v54", {
      p_orden_id: orden.id, p_estado: destino, p_datos: datos,
      p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (cambioError) return setError(cambioError.message);
    setMensaje(`Orden ${orden.numero}: ${etiqueta(destino)}.`); await cargar();
  }

  return <section className="mantenimiento-centro">
    <div className="header-row mantenimiento-cabecera">
      <div><span className="modulo-kicker">GESTIÓN DE ACTIVOS</span><h1>Mantenimiento</h1><p className="conteo">Maquinaria, equipos, prevención, órdenes de trabajo, costos y paradas.</p></div>
      <div className="mantenimiento-acciones">{puedeEditar && <><button className="secondary" onClick={nuevoActivo}>Nuevo activo</button><button onClick={() => nuevaOrden()}>Nueva orden</button></>}<button className="secondary" onClick={cargar} disabled={cargando}>Actualizar</button></div>
    </div>
    {error && <div className="error-box">{error}</div>}{mensaje && <div className="success-box">{mensaje}</div>}

    <div className="kpis compactos mantenimiento-kpis">
      <div className="kpi"><div className="label">Activos operativos</div><div className="valor">{resumen.activos}</div></div>
      <div className={`kpi ${resumen.detenidos ? "alerta" : "ok"}`}><div className="label">Detenidos</div><div className="valor">{resumen.detenidos}</div></div>
      <div className={`kpi ${resumen.vencidos ? "alerta" : "ok"}`}><div className="label">Mantenimiento vencido</div><div className="valor">{resumen.vencidos}</div></div>
      <div className="kpi"><div className="label">Próximos 30 días</div><div className="valor">{resumen.proximos}</div></div>
      <div className="kpi"><div className="label">Órdenes abiertas</div><div className="valor">{resumen.ordenes_abiertas}</div></div>
      <div className={`kpi ${resumen.ordenes_atrasadas ? "alerta" : "ok"}`}><div className="label">Órdenes atrasadas</div><div className="valor">{resumen.ordenes_atrasadas}</div></div>
    </div>

    <div className="tabs">
      {([['resumen', 'Resumen'], ['activos', `Activos (${activos.length})`], ['ordenes', `Órdenes (${ordenes.length})`]] as const).map(([v, l]) => <button className={`tab ${tab === v ? "activo" : ""}`} onClick={() => { setTab(v); setEstado(""); }} key={v}>{l}</button>)}
    </div>

    {tab !== "resumen" && <div className="card"><div className="filtros">
      <div className="field buscador"><label>Buscar</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Código, activo, orden o detalle…" /></div>
      <div className="field"><label>Estado</label><select value={estado} onChange={(e) => setEstado(e.target.value)}><option value="">Todos</option>{(tab === "activos" ? ["operativo", "detenido", "mantenimiento", "fuera_servicio", "vencido", "proximo", "sin_plan"] : ["solicitada", "programada", "en_proceso", "en_espera", "completada", "cancelada"]).map((v) => <option value={v} key={v}>{etiqueta(v)}</option>)}</select></div>
    </div></div>}

    {tab === "resumen" && <div className="mantenimiento-resumen-grid">
      <div className="card"><div className="header-row"><div><h2>Trabajo pendiente</h2><p className="conteo">Primero las urgentes, atrasadas y de activos críticos.</p></div>{puedeEditar && <button onClick={() => nuevaOrden()}>Programar</button>}</div>
        <div className="mantenimiento-lista">{ordenesAbiertas.slice(0, 8).map((o) => <button className="mantenimiento-pendiente" onClick={() => { setTab("ordenes"); setBusqueda(o.numero); }} key={o.id}><span className={`mant-prioridad ${o.prioridad}`} /><span><strong>{o.numero} · {o.activo_codigo}</strong><small>{o.descripcion}</small></span><b className={o.atrasada ? "texto-rojo" : ""}>{o.fecha_programada ? fecha(o.fecha_programada) : "Sin fecha"}</b></button>)}{!ordenesAbiertas.length && <div className="vacio">No hay órdenes abiertas.</div>}</div>
      </div>
      <div className="card"><h2>Control del mes</h2><div className="mantenimiento-metricas"><div><span>Costo ejecutado</span><strong>{DINERO.format(costoMes)}</strong></div><div><span>Minutos detenidos</span><strong>{ordenes.filter((o) => o.estado === "completada").reduce((s, o) => s + Number(o.minutos_fuera_servicio ?? 0), 0)}</strong></div><div><span>Sin plan preventivo</span><strong>{activos.filter((a) => a.estado_plan === "sin_plan").length}</strong></div><div><span>Activos críticos</span><strong>{activos.filter((a) => a.criticidad === "critica" && a.activo).length}</strong></div></div></div>
    </div>}

    {tab === "activos" && <div className="card"><div className="tabla-scroll"><table><thead><tr><th>Activo</th><th>Empresa / ubicación</th><th>Estado</th><th>Criticidad</th><th>Lectura</th><th>Próximo mantenimiento</th><th>Órdenes</th>{puedeEditar && <th>Acciones</th>}</tr></thead><tbody>
      {activosFiltrados.map((a) => <tr key={a.id} className={a.estado_plan === "vencido" ? "fila-alerta" : ""}><td><strong>{a.codigo}</strong><div>{a.nombre}</div><small>{etiqueta(a.categoria)}{a.marca ? ` · ${a.marca} ${a.modelo ?? ""}` : ""}</small></td><td><strong>{a.empresa_codigo}</strong><div>{a.almacen ?? "Sin almacén"}</div><small>{a.ubicacion ?? "Sin ubicación"}</small></td><td><span className={`badge mant-${a.estado}`}>{etiqueta(a.estado)}</span><div><small>{etiqueta(a.estado_plan)}</small></div></td><td><span className={`badge criticidad-${a.criticidad}`}>{a.criticidad}</span></td><td className="num">{a.tipo_medidor === "ninguno" ? "—" : `${a.lectura_actual} ${a.tipo_medidor}`}</td><td><strong>{fecha(a.proximo_mantenimiento_fecha)}</strong>{a.proxima_lectura_mantenimiento != null && <small style={{ display: "block" }}>Lectura: {a.proxima_lectura_mantenimiento}</small>}</td><td className="num">{a.ordenes_abiertas}</td>{puedeEditar && <td><div className="acciones-en-fila"><button className="secondary" onClick={() => editarActivo(a)}>Editar</button><button onClick={() => nuevaOrden(a)} disabled={a.ordenes_abiertas > 0}>Orden</button></div></td>}</tr>)}
      {!cargando && !activosFiltrados.length && <tr><td colSpan={8} className="vacio">No hay activos con estos filtros.</td></tr>}</tbody></table></div></div>}

    {tab === "ordenes" && <div className="card"><div className="tabla-scroll"><table><thead><tr><th>Orden / activo</th><th>Trabajo</th><th>Estado</th><th>Prioridad</th><th>Programada</th><th>Responsable / proveedor</th><th className="num">Costo</th>{puedeEditar && <th>Flujo</th>}</tr></thead><tbody>
      {ordenesFiltradas.map((o) => <tr key={o.id} className={o.atrasada ? "fila-alerta" : ""}><td><strong>{o.numero}</strong><div>{o.activo_codigo} · {o.activo_nombre}</div><small>{o.empresa}{o.almacen ? ` / ${o.almacen}` : ""}</small></td><td><strong>{etiqueta(o.tipo)}</strong><div>{o.descripcion}</div>{o.trabajo_realizado && <small>Realizado: {o.trabajo_realizado}</small>}</td><td><span className={`badge mant-${o.estado}`}>{etiqueta(o.estado)}</span></td><td><span className={`badge prioridad-${o.prioridad}`}>{o.prioridad}</span></td><td>{fecha(o.fecha_programada)}{o.atrasada && <small className="texto-rojo" style={{ display: "block" }}>Atrasada</small>}</td><td>{o.responsable ?? "Sin asignar"}<small style={{ display: "block" }}>{o.proveedor ?? ""}</small></td><td className="num">{o.estado === "completada" ? DINERO.format(Number(o.costo_real ?? 0)) : DINERO.format(Number(o.costo_estimado ?? 0))}</td>{puedeEditar && <td><div className="acciones-en-fila">{o.estado === "solicitada" && <button className="secondary" onClick={() => cambiarOrden(o, "programada")}>Programar</button>}{["solicitada", "programada", "en_espera"].includes(o.estado) && <button onClick={() => cambiarOrden(o, "en_proceso")}>Iniciar</button>}{o.estado === "en_proceso" && <><button className="secondary" onClick={() => cambiarOrden(o, "en_espera")}>Espera</button><button onClick={() => cambiarOrden(o, "completada")}>Completar</button></>}{!["completada", "cancelada"].includes(o.estado) && <button className="peligro-inline" onClick={() => cambiarOrden(o, "cancelada")}>Cancelar</button>}</div></td>}</tr>)}
      {!cargando && !ordenesFiltradas.length && <tr><td colSpan={8} className="vacio">No hay órdenes con estos filtros.</td></tr>}</tbody></table></div></div>}

    {editando !== undefined && <div className="modal-operativo" onMouseDown={(e) => { if (e.target === e.currentTarget) setEditando(undefined); }}><div className="modal-contenido ancho"><div className="header-row"><div><h2>{editando ? `Editar ${editando.codigo}` : "Nuevo activo"}</h2><p className="conteo">Identificación, ubicación y plan preventivo.</p></div><button className="secondary" onClick={() => setEditando(undefined)}>Cerrar</button></div><div className="grid-form">
      <div className="field"><label>Código *</label><input value={formActivo.codigo} onChange={(e) => cambiarActivo({ codigo: e.target.value })} /></div><div className="field"><label>Nombre *</label><input value={formActivo.nombre} onChange={(e) => cambiarActivo({ nombre: e.target.value })} /></div><div className="field"><label>Categoría *</label><select value={formActivo.categoria} onChange={(e) => cambiarActivo({ categoria: e.target.value })}>{["maquinaria", "vehiculo", "equipo", "herramienta", "infraestructura", "otro"].map((v) => <option key={v}>{v}</option>)}</select></div>
      <div className="field"><label>Empresa *</label><select value={formActivo.empresa_id} onChange={(e) => cambiarActivo({ empresa_id: e.target.value, almacen_id: "" })}><option value="">Selecciona…</option>{empresas.map((e) => <option value={e.id} key={e.id}>{e.codigo} · {e.razon_social}</option>)}</select></div><div className="field"><label>Almacén</label><select value={formActivo.almacen_id} onChange={(e) => cambiarActivo({ almacen_id: e.target.value })}><option value="">Sin almacén</option>{almacenesEmpresa.map((a) => <option value={a.id} key={a.id}>{a.nombre}</option>)}</select></div><div className="field"><label>Ubicación</label><input value={formActivo.ubicacion} onChange={(e) => cambiarActivo({ ubicacion: e.target.value })} /></div>
      <div className="field"><label>Marca</label><input value={formActivo.marca} onChange={(e) => cambiarActivo({ marca: e.target.value })} /></div><div className="field"><label>Modelo</label><input value={formActivo.modelo} onChange={(e) => cambiarActivo({ modelo: e.target.value })} /></div><div className="field"><label>Número de serie</label><input value={formActivo.numero_serie} onChange={(e) => cambiarActivo({ numero_serie: e.target.value })} /></div>
      <div className="field"><label>Responsable</label><select value={formActivo.responsable_id} onChange={(e) => cambiarActivo({ responsable_id: e.target.value })}><option value="">Sin asignar</option>{responsables.map((p) => <option value={p.id} key={p.id}>{p.nombre_completo}</option>)}</select></div><div className="field"><label>Criticidad</label><select value={formActivo.criticidad} onChange={(e) => cambiarActivo({ criticidad: e.target.value })}>{["baja", "media", "alta", "critica"].map((v) => <option key={v}>{v}</option>)}</select></div><div className="field"><label>Estado</label><select value={formActivo.estado} onChange={(e) => cambiarActivo({ estado: e.target.value })}>{["operativo", "detenido", "mantenimiento", "fuera_servicio", "baja"].map((v) => <option key={v}>{etiqueta(v)}</option>)}</select></div>
      <div className="field"><label>Fecha adquisición</label><input type="date" value={formActivo.fecha_adquisicion} onChange={(e) => cambiarActivo({ fecha_adquisicion: e.target.value })} /></div><div className="field"><label>Valor adquisición</label><input type="number" min={0} step="0.01" value={formActivo.valor_adquisicion} onChange={(e) => cambiarActivo({ valor_adquisicion: e.target.value })} /></div><div className="field"><label>Garantía hasta</label><input type="date" value={formActivo.garantia_hasta} onChange={(e) => cambiarActivo({ garantia_hasta: e.target.value })} /></div>
      <div className="field"><label>Tipo de medidor</label><select value={formActivo.tipo_medidor} onChange={(e) => cambiarActivo({ tipo_medidor: e.target.value })}>{["ninguno", "horas", "kilometros", "ciclos"].map((v) => <option key={v}>{v}</option>)}</select></div><div className="field"><label>Lectura actual</label><input type="number" min={0} step="0.01" value={formActivo.lectura_actual} onChange={(e) => cambiarActivo({ lectura_actual: e.target.value })} /></div><div className="field"><label>Próxima lectura</label><input type="number" min={0} step="0.01" value={formActivo.proxima_lectura_mantenimiento} onChange={(e) => cambiarActivo({ proxima_lectura_mantenimiento: e.target.value })} /></div>
      <div className="field"><label>Frecuencia en días</label><input type="number" min={1} value={formActivo.frecuencia_mantenimiento_dias} onChange={(e) => cambiarActivo({ frecuencia_mantenimiento_dias: e.target.value })} /></div><div className="field"><label>Frecuencia por uso</label><input type="number" min={0} step="0.01" value={formActivo.frecuencia_mantenimiento_uso} onChange={(e) => cambiarActivo({ frecuencia_mantenimiento_uso: e.target.value })} /></div><div className="field"><label>Próxima fecha</label><input type="date" value={formActivo.proximo_mantenimiento_fecha} onChange={(e) => cambiarActivo({ proximo_mantenimiento_fecha: e.target.value })} /></div>
      <div className="field ancho-total"><label>Notas</label><textarea rows={3} value={formActivo.notas} onChange={(e) => cambiarActivo({ notas: e.target.value })} /></div>
    </div><div className="modal-acciones"><button className="secondary" onClick={() => setEditando(undefined)}>Cancelar</button><button onClick={guardarActivo} disabled={procesando}>{procesando ? "Guardando…" : "Guardar activo"}</button></div></div></div>}

    {mostrarOrden && <div className="modal-operativo" onMouseDown={(e) => { if (e.target === e.currentTarget) setMostrarOrden(false); }}><div className="modal-contenido"><div className="header-row"><div><h2>Nueva orden de mantenimiento</h2><p className="conteo">Un activo solo puede tener una orden abierta.</p></div><button className="secondary" onClick={() => setMostrarOrden(false)}>Cerrar</button></div><div className="grid-form">
      <div className="field ancho-total"><label>Activo *</label><select value={formOrden.activo_id} onChange={(e) => setFormOrden({ ...formOrden, activo_id: e.target.value })}><option value="">Selecciona…</option>{activos.filter((a) => a.activo && a.estado !== "baja").map((a) => <option value={a.id} key={a.id}>{a.codigo} · {a.nombre} · {a.empresa_codigo}</option>)}</select></div><div className="field"><label>Tipo</label><select value={formOrden.tipo} onChange={(e) => setFormOrden({ ...formOrden, tipo: e.target.value })}>{["preventivo", "correctivo", "inspeccion", "calibracion"].map((v) => <option key={v}>{v}</option>)}</select></div><div className="field"><label>Prioridad</label><select value={formOrden.prioridad} onChange={(e) => setFormOrden({ ...formOrden, prioridad: e.target.value })}>{["baja", "normal", "alta", "urgente"].map((v) => <option key={v}>{v}</option>)}</select></div><div className="field"><label>Fecha programada</label><input type="date" value={formOrden.fecha_programada} onChange={(e) => setFormOrden({ ...formOrden, fecha_programada: e.target.value })} /></div><div className="field"><label>Responsable</label><select value={formOrden.responsable_id} onChange={(e) => setFormOrden({ ...formOrden, responsable_id: e.target.value })}><option value="">Sin asignar</option>{responsables.map((p) => <option value={p.id} key={p.id}>{p.nombre_completo}</option>)}</select></div><div className="field"><label>Costo estimado USD</label><input type="number" min={0} step="0.01" value={formOrden.costo_estimado} onChange={(e) => setFormOrden({ ...formOrden, costo_estimado: e.target.value })} /></div><div className="field ancho-total"><label>Trabajo solicitado *</label><textarea rows={4} value={formOrden.descripcion} onChange={(e) => setFormOrden({ ...formOrden, descripcion: e.target.value })} /></div>
    </div><div className="modal-acciones"><button className="secondary" onClick={() => setMostrarOrden(false)}>Cancelar</button><button onClick={crearOrden} disabled={procesando}>{procesando ? "Creando…" : "Crear orden"}</button></div></div></div>}
  </section>;
}
