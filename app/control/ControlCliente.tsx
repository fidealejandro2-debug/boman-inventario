"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";
import { fecha } from "@/lib/utils";
import { ETIQUETAS_ESTADO } from "@/lib/erp";
import { confirmarDialogo } from "@/components/Dialogo";

type Linea = {
  id: string; producto_id: string; stock_sistema: number | null;
  cantidad_contada: number | null; cantidad_reconteo: number | null;
  cantidad_despachada: number | null; cantidad_recibida: number | null; cantidad_rechazada: number | null;
  producto: { sku: string; nombre: string; talla: string | null; precio: number | null } | null;
};
type Documento = {
  id: string; numero: string; tipo: string; estado: string; nota: string | null;
  creado_por: string;
  origen_id: string | null; destino_id: string | null; created_at: string;
  despachado_at: string | null; recibido_at: string | null;
  origen: { nombre: string } | null; destino: { nombre: string } | null;
  creador: { nombre_completo: string } | null; lineas: Linea[];
};
type AccionIncidencia = {
  id: string; origen_estado: "no_recibida" | "cuarentena";
  accion: string; cantidad: number; detalle: string; created_at: string;
  usuario: { nombre_completo: string } | null;
};
type LineaIncidencia = {
  id: string; producto_id: string; cantidad_no_conforme_inicial: number;
  cantidad_no_recibida_inicial: number; observacion: string | null;
  producto: { sku: string; nombre: string; talla: string | null } | null;
  acciones: AccionIncidencia[];
};
type Incidencia = {
  id: string; estado: string; descripcion_inicial: string; causa_raiz: string | null;
  accion_correctiva: string | null; fecha_limite: string; created_at: string;
  documento: {
    id: string; numero: string; origen: { nombre: string } | null;
    destino: { nombre: string } | null;
  } | null;
  creador: { nombre_completo: string } | null;
  lineas: LineaIncidencia[];
};
type DisposicionLinea = {
  accionNoRecibida: "recibir_destino" | "retornar_origen" | "perdida";
  cantidadNoRecibida: string;
  accionCuarentena: "liberar_destino" | "retornar_origen" | "perdida";
  cantidadCuarentena: string;
};

const ETIQUETAS_DISPOSICION: Record<string, string> = {
  recibir_destino: "Ingreso tardío al destino",
  liberar_destino: "Liberación de cuarentena al destino",
  retornar_origen: "Retorno confirmado al origen",
  perdida: "Baja definitiva / pérdida",
};

function mostrarFechaLimite(valor: string) {
  const [anio, mes, dia] = valor.slice(0, 10).split("-");
  return `${dia}/${mes}/${anio}`;
}

function incidenciaEstaVencida(valor: string) {
  return new Date(`${valor.slice(0, 10)}T23:59:59`).getTime() < Date.now();
}

export default function ControlCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [documentos, setDocumentos] = useState<Documento[]>([]);
  const [eventos, setEventos] = useState<any[]>([]);
  const [cambiosProductos, setCambiosProductos] = useState<any[]>([]);
  const [incidencias, setIncidencias] = useState<Incidencia[]>([]);
  const [resolviendoIncidencia, setResolviendoIncidencia] = useState<Incidencia | null>(null);
  const [disposiciones, setDisposiciones] = useState<Record<string, DisposicionLinea>>({});
  const [notaIncidencia, setNotaIncidencia] = useState("");
  const [causaRaiz, setCausaRaiz] = useState("");
  const [accionCorrectiva, setAccionCorrectiva] = useState("");
  const [confirmacionBaja, setConfirmacionBaja] = useState(false);
  const [justificacionBaja, setJustificacionBaja] = useState("");
  const [revisando, setRevisando] = useState<Documento | null>(null);
  const [reconteos, setReconteos] = useState<Record<string, string>>({});
  const [nota, setNota] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const puedeResolver = perfil.rol === "admin" || perfil.rol === "control";

  async function cargar() {
    setCargando(true);
    const [d, e, p, inc] = await Promise.all([
      supabase.from("documentos_inventario").select(`
        id, numero, tipo, estado, nota, creado_por, origen_id, destino_id, created_at, despachado_at, recibido_at,
        origen:almacenes!documentos_inventario_origen_id_fkey(nombre),
        destino:almacenes!documentos_inventario_destino_id_fkey(nombre),
        creador:perfiles!documentos_inventario_creado_por_fkey(nombre_completo),
        lineas:documento_inventario_lineas(
          id, producto_id, stock_sistema, cantidad_contada, cantidad_reconteo,
          cantidad_despachada, cantidad_recibida, cantidad_rechazada,
          producto:productos(sku, nombre, talla, precio)
        )
      `).order("created_at", { ascending: false }).limit(500),
      supabase.from("documento_inventario_eventos").select(`
        id, estado_anterior, estado_nuevo, detalle, created_at,
        documento:documentos_inventario(numero, tipo),
        usuario:perfiles!documento_inventario_eventos_usuario_id_fkey(nombre_completo)
      `).order("created_at", { ascending: false }).limit(30),
      supabase.from("productos_maestro_cambios").select(`
        id, valores_anteriores, valores_nuevos, created_at,
        producto:productos(sku, nombre),
        usuario:perfiles!productos_maestro_cambios_realizado_por_fkey(nombre_completo)
      `).order("created_at", { ascending: false }).limit(20),
      supabase.from("incidencias_transferencia").select(`
        id, estado, descripcion_inicial, causa_raiz, accion_correctiva,
        fecha_limite, created_at,
        documento:documentos_inventario!incidencias_transferencia_documento_id_fkey(
          id, numero,
          origen:almacenes!documentos_inventario_origen_id_fkey(nombre),
          destino:almacenes!documentos_inventario_destino_id_fkey(nombre)
        ),
        creador:perfiles!incidencias_transferencia_creado_por_fkey(nombre_completo),
        lineas:incidencia_transferencia_lineas(
          id, producto_id, cantidad_no_conforme_inicial,
          cantidad_no_recibida_inicial, observacion,
          producto:productos(sku, nombre, talla),
          acciones:incidencia_transferencia_acciones(
            id, origen_estado, accion, cantidad, detalle, created_at,
            usuario:perfiles!incidencia_transferencia_acciones_realizado_por_fkey(nombre_completo)
          )
        )
      `).order("created_at", { ascending: false }).limit(150),
    ]);
    if (d.error || e.error || p.error || inc.error) setMsg({ tipo: "error", texto: d.error?.message ?? e.error?.message ?? p.error?.message ?? inc.error!.message });
    setDocumentos((d.data ?? []) as any as Documento[]);
    setEventos(e.data ?? []);
    setCambiosProductos(p.data ?? []);
    setIncidencias((inc.data ?? []) as any as Incidencia[]);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const solicitudes = documentos.filter((d) => d.tipo === "solicitud_reposicion" && d.estado === "solicitado");
  const conteos = documentos.filter((d) => d.tipo === "conteo" && d.estado === "pendiente_revision");
  const lineasRevision = revisando?.lineas.filter((linea) =>
    (linea.stock_sistema ?? 0) !== 0 || (linea.cantidad_contada ?? 0) !== 0
  ) ?? [];
  const lineasRevisionOcultas = (revisando?.lineas.length ?? 0) - lineasRevision.length;
  const enTransito = documentos.filter((d) => d.tipo === "transferencia" && ["despachado", "en_transito"].includes(d.estado));
  const incidenciasAbiertas = incidencias
    .filter((inc) => inc.estado !== "resuelta")
    .sort((a, b) => a.fecha_limite.localeCompare(b.fecha_limite));

  function pendienteLinea(linea: LineaIncidencia, origen: "no_recibida" | "cuarentena") {
    const inicial = origen === "no_recibida" ? linea.cantidad_no_recibida_inicial : linea.cantidad_no_conforme_inicial;
    const resuelto = linea.acciones.filter((a) => a.origen_estado === origen).reduce((s, a) => s + a.cantidad, 0);
    return Math.max(inicial - resuelto, 0);
  }

  const unidadesDiferencia = useMemo(() => incidencias
    .filter((inc) => inc.estado !== "resuelta")
    .reduce((total, inc) => total + inc.lineas.reduce(
      (s, l) => s + pendienteLinea(l, "no_recibida") + pendienteLinea(l, "cuarentena"), 0
    ), 0), [incidencias]);
  const disposicionesRecientes = useMemo(() => incidencias.flatMap((inc) =>
    inc.lineas.flatMap((linea) => linea.acciones.map((accion) => ({ inc, linea, accion })))
  ).sort((a, b) => b.accion.created_at.localeCompare(a.accion.created_at)).slice(0, 40), [incidencias]);
  const hayBajaSeleccionada = Object.values(disposiciones).some((valor) =>
    (valor.accionNoRecibida === "perdida" && Number(valor.cantidadNoRecibida) > 0)
    || (valor.accionCuarentena === "perdida" && Number(valor.cantidadCuarentena) > 0)
  );

  function abrirRevision(conteo: Documento) {
    const valores: Record<string, string> = {};
    conteo.lineas.forEach((l) => {
      if (l.cantidad_contada !== l.stock_sistema) valores[l.producto_id] = l.cantidad_reconteo == null ? "" : String(l.cantidad_reconteo);
    });
    setRevisando(conteo); setReconteos(valores); setNota(""); setMsg(null);
  }

  async function guardarReconteo() {
    if (!revisando) return false;
    const distintas = revisando.lineas.filter((l) => l.cantidad_contada !== l.stock_sistema);
    const items = distintas.filter((l) => reconteos[l.producto_id] !== "").map((l) => ({ producto_id: l.producto_id, cantidad: Number(reconteos[l.producto_id]) }));
    if (items.length !== distintas.length || items.some((i) => !Number.isInteger(i.cantidad) || i.cantidad < 0)) {
      setMsg({ tipo: "error", texto: "Registra un segundo conteo válido para cada diferencia." }); return false;
    }
    const { error } = await supabase.rpc("guardar_reconteo_inventario", {
      p_documento_id: revisando.id, p_items: items, p_nota: nota || "Segundo conteo de Control",
    });
    if (error) { setMsg({ tipo: "error", texto: error.message }); return false; }
    return true;
  }

  async function resolverConteo(aprobar: boolean) {
    if (!revisando) return;
    if (!nota.trim()) { setMsg({ tipo: "error", texto: "Escribe la resolución o número de acta." }); return; }
    setProcesando(true); setMsg(null);
    if (aprobar && revisando.lineas.some((l) => l.cantidad_contada !== l.stock_sistema)) {
      const ok = await guardarReconteo();
      if (!ok) { setProcesando(false); return; }
    }
    const { error } = await supabase.rpc("resolver_conteo_inventario", {
      p_documento_id: revisando.id, p_aprobar: aprobar, p_nota: nota.trim(),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setRevisando(null);
    setMsg({ tipo: "ok", texto: aprobar ? "Conteo aprobado y diferencias aplicadas al kardex." : "Conteo devuelto para corrección." });
    await cargar();
  }

  function abrirGestionIncidencia(incidencia: Incidencia) {
    const valores: Record<string, DisposicionLinea> = {};
    incidencia.lineas.forEach((linea) => {
      valores[linea.id] = {
        accionNoRecibida: "recibir_destino",
        cantidadNoRecibida: String(pendienteLinea(linea, "no_recibida")),
        accionCuarentena: "liberar_destino",
        cantidadCuarentena: String(pendienteLinea(linea, "cuarentena")),
      };
    });
    setResolviendoIncidencia(incidencia);
    setDisposiciones(valores);
    setNotaIncidencia("");
    setCausaRaiz(incidencia.causa_raiz ?? "");
    setAccionCorrectiva(incidencia.accion_correctiva ?? "");
    setConfirmacionBaja(false);
    setJustificacionBaja("");
    setMsg(null);
  }

  function actualizarDisposicion(lineaId: string, cambio: Partial<DisposicionLinea>) {
    setConfirmacionBaja(false);
    setDisposiciones((actual) => ({
      ...actual,
      [lineaId]: { ...actual[lineaId], ...cambio },
    }));
  }

  async function resolverIncidencia() {
    if (!resolviendoIncidencia) return;
    if (!notaIncidencia.trim()) {
      setMsg({ tipo: "error", texto: "Describe la verificación o disposición realizada." });
      return;
    }

    const acciones: Array<{
      linea_incidencia_id: string; origen_estado: "no_recibida" | "cuarentena";
      accion: string; cantidad: number;
    }> = [];
    let quedaraPendiente = false;

    for (const linea of resolviendoIncidencia.lineas) {
      const valores = disposiciones[linea.id];
      const pendienteNoRecibida = pendienteLinea(linea, "no_recibida");
      const pendienteCuarentena = pendienteLinea(linea, "cuarentena");
      const cantidadNoRecibida = Number(valores?.cantidadNoRecibida ?? 0);
      const cantidadCuarentena = Number(valores?.cantidadCuarentena ?? 0);

      if (!Number.isInteger(cantidadNoRecibida) || cantidadNoRecibida < 0 || cantidadNoRecibida > pendienteNoRecibida
        || !Number.isInteger(cantidadCuarentena) || cantidadCuarentena < 0 || cantidadCuarentena > pendienteCuarentena) {
        setMsg({ tipo: "error", texto: `Las cantidades de ${linea.producto?.sku ?? "una línea"} no son válidas.` });
        return;
      }
      if ((valores?.accionNoRecibida === "perdida" || valores?.accionCuarentena === "perdida") && perfil.rol !== "admin") {
        setMsg({ tipo: "error", texto: "Solo Administración puede reconocer una pérdida de inventario." });
        return;
      }
      if (cantidadNoRecibida > 0) acciones.push({
        linea_incidencia_id: linea.id, origen_estado: "no_recibida",
        accion: valores.accionNoRecibida, cantidad: cantidadNoRecibida,
      });
      if (cantidadCuarentena > 0) acciones.push({
        linea_incidencia_id: linea.id, origen_estado: "cuarentena",
        accion: valores.accionCuarentena, cantidad: cantidadCuarentena,
      });
      if (cantidadNoRecibida < pendienteNoRecibida || cantidadCuarentena < pendienteCuarentena) quedaraPendiente = true;
    }

    if (!acciones.length) {
      setMsg({ tipo: "error", texto: "Registra al menos una disposición con cantidad mayor a cero." });
      return;
    }
    const totalBaja = acciones.filter((a) => a.accion === "perdida").reduce((s, a) => s + a.cantidad, 0);
    if (totalBaja > 0) {
      if (acciones.some((a) => a.accion !== "perdida")) {
        setMsg({ tipo: "error", texto: "La baja definitiva debe registrarse sola. Deja las demás cantidades en cero y procésalas por separado." });
        return;
      }
      if (justificacionBaja.trim().length < 10) {
        setMsg({ tipo: "error", texto: "Describe por qué la unidad se considera perdida o no recuperable." });
        return;
      }
      if (!confirmacionBaja) {
        setMsg({ tipo: "error", texto: "Confirma que se realizó la búsqueda física antes de autorizar la baja." });
        return;
      }
      if (!await confirmarDialogo(`DOCUMENTO ${resolviendoIncidencia.documento?.numero ?? "SIN NÚMERO"}\n\nVas a dar de BAJA DEFINITIVA ${totalBaja} unidad(es). No ingresarán al stock de ningún almacén. Esta acción quedará identificada con tu usuario.\n\n¿Confirmas la baja?`)) return;
    }
    if (!quedaraPendiente && (!causaRaiz.trim() || !accionCorrectiva.trim())) {
      setMsg({ tipo: "error", texto: "Para cerrar la no conformidad registra la causa raíz y la acción correctiva." });
      return;
    }

    setProcesando(true);
    const { data, error } = await supabase.rpc("resolver_incidencia_transferencia", {
      p_incidencia_id: resolviendoIncidencia.id,
      p_acciones: acciones,
      p_nota: totalBaja > 0
        ? `${notaIncidencia.trim()} | BAJA DEFINITIVA: ${justificacionBaja.trim()}`
        : notaIncidencia.trim(),
      p_causa_raiz: causaRaiz.trim() || null,
      p_accion_correctiva: accionCorrectiva.trim() || null,
      p_idempotency_key: crypto.randomUUID(),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setResolviendoIncidencia(null);
    setMsg({
      tipo: "ok",
      texto: data === "resuelta" ? "No conformidad resuelta y trazabilidad cerrada." : "Disposición registrada; la investigación continúa abierta.",
    });
    await cargar();
  }

  return (
    <>
      <div className="header-row"><div><h2 style={{ color: "#1f3864", margin: 0 }}>Centro de Control</h2><p className="conteo">Pendientes, diferencias, aprobaciones y trazabilidad operativa.</p></div><Link href="/reportes" className="boton-link">Reportes operativos</Link></div>
      {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}
      <div className="kpis">
        <div className={`kpi ${solicitudes.length ? "alerta" : "ok"}`}><div className="label">Solicitudes pendientes</div><div className="valor">{solicitudes.length}</div></div>
        <div className={`kpi ${conteos.length ? "alerta" : "ok"}`}><div className="label">Conteos por revisar</div><div className="valor">{conteos.length}</div></div>
        <div className={`kpi ${incidenciasAbiertas.length ? "alerta" : "ok"}`}><div className="label">No conformidades abiertas</div><div className="valor">{incidenciasAbiertas.length}</div><small>{unidadesDiferencia} unidad(es) bajo seguimiento</small></div>
        <div className="kpi"><div className="label">Transferencias en tránsito</div><div className="valor">{enTransito.length}</div></div>
      </div>

      {cargando ? <div className="card"><div className="vacio">Consolidando operaciones...</div></div> : <>
        <div className="grid-control">
          <section className="card"><div className="header-row"><h3>Solicitudes pendientes</h3><Link href="/operaciones">Gestionar →</Link></div>{solicitudes.map((d) => <div className="pendiente-control" key={d.id}><div><strong>{d.numero}</strong><span>{d.destino?.nombre} · {fecha(d.created_at)}</span></div><b>{d.lineas.length} SKU</b></div>)}{!solicitudes.length && <div className="vacio">Sin solicitudes pendientes.</div>}</section>
          <section className="card"><h3 style={{ marginTop: 0 }}>Conteos pendientes</h3>{conteos.map((d) => { const dif = d.lineas.filter((l) => l.cantidad_contada !== l.stock_sistema); const propio = d.creado_por === perfil.id; const puedeRevisarlo = puedeResolver && (!propio || perfil.rol === "admin"); return <div className="pendiente-control" key={d.id}><div><strong>{d.numero}</strong><span>{d.origen?.nombre} · {d.creador?.nombre_completo}</span></div><div><span className={`badge ${dif.length ? "bajo" : "ok"}`}>{dif.length} diferencias</span>{propio && perfil.rol === "admin" && <span className="badge estado-pendiente_revision">Excepción Admin</span>}{propio && perfil.rol === "control" && <small>Requiere otro revisor</small>}{puedeRevisarlo && <button className="secondary" onClick={() => abrirRevision(d)}>Revisar</button>}</div></div>; })}{!conteos.length && <div className="vacio">Sin conteos pendientes.</div>}</section>
        </div>

        <section className="card"><div className="header-row"><div><h3 style={{ margin: 0 }}>No conformidades de transferencias</h3><p className="conteo">Cada unidad queda en tránsito de incidencia, cuarentena o con una disposición final documentada.</p></div></div><div className="tabla-scroll"><table><thead><tr><th>Documento</th><th>Ruta</th><th>Vencimiento</th><th>Saldo bajo seguimiento</th><th>Descripción inicial</th><th></th></tr></thead><tbody>{incidenciasAbiertas.map((inc) => { const vencida = incidenciaEstaVencida(inc.fecha_limite); return <tr key={inc.id} className={vencida ? "fila-alerta" : ""}><td><strong>{inc.documento?.numero}</strong><div className="conteo">Abierta por {inc.creador?.nombre_completo ?? "sistema"}</div></td><td>{inc.documento?.origen?.nombre} → {inc.documento?.destino?.nombre}</td><td><span className={`badge ${vencida ? "bajo" : "estado-pendiente_revision"}`}>{mostrarFechaLimite(inc.fecha_limite)}{vencida ? " · vencida" : ""}</span></td><td>{inc.lineas.map((l) => { const nr = pendienteLinea(l, "no_recibida"); const nc = pendienteLinea(l, "cuarentena"); if (!nr && !nc) return null; return <div key={l.id} className="conteo"><b>{l.producto?.sku}</b>: {nr ? `${nr} no recibida(s)` : ""}{nr && nc ? " · " : ""}{nc ? `${nc} en cuarentena` : ""}</div>; })}</td><td>{inc.descripcion_inicial}</td><td>{puedeResolver && <button disabled={procesando} onClick={() => abrirGestionIncidencia(inc)}>Gestionar</button>}</td></tr>; })}{!incidenciasAbiertas.length && <tr><td colSpan={6} className="vacio">No existen no conformidades abiertas.</td></tr>}</tbody></table></div></section>

        <section className="card"><div className="header-row"><div><h3 style={{ margin: 0 }}>Disposiciones y bajas de cuarentena</h3><p className="conteo">Trazabilidad permanente de lo que salió de tránsito de incidencia o cuarentena.</p></div></div><div className="tabla-scroll"><table><thead><tr><th>Fecha</th><th>Documento</th><th>Producto</th><th>Origen del saldo</th><th>Disposición final</th><th className="num">Cantidad</th><th>Responsable</th><th>Evidencia</th></tr></thead><tbody>{disposicionesRecientes.map(({ inc, linea, accion }) => <tr key={accion.id} className={accion.accion === "perdida" ? "fila-alerta" : ""}><td>{fecha(accion.created_at)}</td><td><strong>{inc.documento?.numero}</strong><div className="conteo">{inc.documento?.origen?.nombre} → {inc.documento?.destino?.nombre}</div></td><td><strong>{linea.producto?.sku}</strong><div className="conteo">{linea.producto?.nombre}</div></td><td>{accion.origen_estado === "cuarentena" ? "Cuarentena" : "No recibida"}</td><td><span className={`badge ${accion.accion === "perdida" ? "bajo" : "ok"}`}>{ETIQUETAS_DISPOSICION[accion.accion] ?? accion.accion}</span></td><td className="num"><strong>{accion.cantidad}</strong></td><td>{accion.usuario?.nombre_completo ?? "Sistema"}</td><td>{accion.detalle}</td></tr>)}{!disposicionesRecientes.length && <tr><td colSpan={8} className="vacio">Todavía no existen disposiciones registradas.</td></tr>}</tbody></table></div></section>

        <section className="card"><h3 style={{ marginTop: 0 }}>Auditoría reciente</h3><div className="tabla-scroll"><table><thead><tr><th>Fecha</th><th>Documento</th><th>Cambio</th><th>Usuario</th><th>Detalle</th></tr></thead><tbody>{eventos.map((e) => <tr key={e.id}><td>{fecha(e.created_at)}</td><td><strong>{e.documento?.numero}</strong></td><td>{ETIQUETAS_ESTADO[e.estado_anterior] ?? e.estado_anterior ?? "Creado"} → {ETIQUETAS_ESTADO[e.estado_nuevo] ?? e.estado_nuevo}</td><td>{e.usuario?.nombre_completo}</td><td>{e.detalle ?? "-"}</td></tr>)}</tbody></table></div></section>

        <section className="card"><h3 style={{ marginTop: 0 }}>Cambios recientes del catálogo</h3><div className="tabla-scroll"><table><thead><tr><th>Fecha</th><th>SKU / producto</th><th>Campos modificados</th><th>Usuario</th></tr></thead><tbody>{cambiosProductos.map((c) => { const campos = Object.keys(c.valores_nuevos ?? {}).filter((k) => JSON.stringify(c.valores_anteriores?.[k]) !== JSON.stringify(c.valores_nuevos?.[k])); return <tr key={c.id}><td>{fecha(c.created_at)}</td><td><strong>{c.producto?.sku}</strong><div className="conteo">{c.producto?.nombre}</div></td><td>{campos.join(", ") || "-"}</td><td>{c.usuario?.nombre_completo ?? "Proceso del sistema"}</td></tr>; })}{!cambiosProductos.length && <tr><td colSpan={4} className="vacio">Sin cambios recientes del catálogo.</td></tr>}</tbody></table></div></section>
      </>}

      {resolviendoIncidencia && <div className="modal-operativo" role="dialog" aria-modal="true"><div className="modal-contenido ancho"><div className="header-row"><div><h3 style={{ margin: 0 }}>Gestión de no conformidad · {resolviendoIncidencia.documento?.numero}</h3><span className="conteo">{resolviendoIncidencia.documento?.origen?.nombre} → {resolviendoIncidencia.documento?.destino?.nombre}</span></div><button className="chip-limpiar" onClick={() => setResolviendoIncidencia(null)}>Cerrar</button></div><div className="info-box"><strong>Control de producto no conforme:</strong> “no recibida” sigue bajo investigación; “cuarentena” existe físicamente pero no está disponible para venta. Puedes resolver parcialmente y conservar el saldo abierto. Registra un retorno solo después de que el origen confirme la recepción física. Una baja definitiva no suma stock y queda registrada permanentemente como pérdida.</div><div className="tabla-scroll"><table><thead><tr><th>Producto</th><th>Origen del saldo</th><th className="num">Pendiente</th><th className="num">Resolver ahora</th><th>Disposición</th></tr></thead><tbody>{resolviendoIncidencia.lineas.flatMap((linea) => { const pendienteNoRecibida = pendienteLinea(linea, "no_recibida"); const pendienteCuarentena = pendienteLinea(linea, "cuarentena"); const valores = disposiciones[linea.id]; const filas = []; if (pendienteNoRecibida) filas.push(<tr key={`${linea.id}-nr`}><td><strong>{linea.producto?.sku}</strong><div className="conteo">{linea.producto?.nombre} {linea.producto?.talla ?? ""}</div></td><td><span className="badge bajo">No recibida</span></td><td className="num">{pendienteNoRecibida}</td><td className="num"><input type="number" min={0} max={pendienteNoRecibida} value={valores?.cantidadNoRecibida ?? ""} onChange={(e) => actualizarDisposicion(linea.id, { cantidadNoRecibida: e.target.value })} style={{ width: 85 }} /></td><td><select value={valores?.accionNoRecibida ?? "recibir_destino"} onChange={(e) => actualizarDisposicion(linea.id, { accionNoRecibida: e.target.value as DisposicionLinea["accionNoRecibida"] })}><option value="recibir_destino">Llegó después: ingresar a destino</option><option value="retornar_origen">Recepción confirmada en origen</option>{perfil.rol === "admin" && <option value="perdida">BAJA DEFINITIVA — no sumará al stock</option>}</select></td></tr>); if (pendienteCuarentena) filas.push(<tr key={`${linea.id}-nc`}><td><strong>{linea.producto?.sku}</strong><div className="conteo">{linea.producto?.nombre} {linea.producto?.talla ?? ""}</div></td><td><span className="badge estado-pendiente_revision">Cuarentena</span></td><td className="num">{pendienteCuarentena}</td><td className="num"><input type="number" min={0} max={pendienteCuarentena} value={valores?.cantidadCuarentena ?? ""} onChange={(e) => actualizarDisposicion(linea.id, { cantidadCuarentena: e.target.value })} style={{ width: 85 }} /></td><td><select value={valores?.accionCuarentena ?? "liberar_destino"} onChange={(e) => actualizarDisposicion(linea.id, { accionCuarentena: e.target.value as DisposicionLinea["accionCuarentena"] })}><option value="liberar_destino">Conforme tras revisión: liberar</option><option value="retornar_origen">Retorno recibido y verificado en origen</option>{perfil.rol === "admin" && <option value="perdida">BAJA DEFINITIVA — no sumará al stock</option>}</select></td></tr>); return filas; })}</tbody></table></div>{hayBajaSeleccionada && <div className="error"><strong>Acción excepcional: baja definitiva</strong><p>Procesa la baja por separado. Antes de continuar verifica físicamente origen, destino, transporte y cuarentena.</p><div className="field"><label>Justificación específica de la baja *</label><textarea rows={2} value={justificacionBaja} onChange={(e) => { setJustificacionBaja(e.target.value); setConfirmacionBaja(false); }} placeholder="Resultado de la búsqueda, daño irreversible o evidencia de la pérdida" /></div><label style={{ display: "flex", gap: 8, alignItems: "flex-start" }}><input type="checkbox" checked={confirmacionBaja} onChange={(e) => setConfirmacionBaja(e.target.checked)} /> Confirmo que la unidad fue buscada y verificada físicamente, y entiendo que no ingresará al stock de ningún almacén.</label></div>}{resolviendoIncidencia.lineas.some((l) => l.acciones.length > 0) && <details className="info-box"><summary><strong>Historial de disposiciones</strong></summary>{resolviendoIncidencia.lineas.flatMap((l) => l.acciones.map((a) => <div key={a.id} className="conteo">{fecha(a.created_at)} · {l.producto?.sku} · {a.cantidad} · {a.accion.replaceAll("_", " ")} · {a.usuario?.nombre_completo ?? "sistema"}</div>))}</details>}<div className="grid-form"><div className="field"><label>Verificación / evidencia de esta acción *</label><textarea rows={3} value={notaIncidencia} onChange={(e) => setNotaIncidencia(e.target.value)} /></div><div className="field"><label>Causa raíz (obligatoria al cerrar)</label><textarea rows={3} value={causaRaiz} onChange={(e) => setCausaRaiz(e.target.value)} /></div><div className="field"><label>Acción correctiva o preventiva (obligatoria al cerrar)</label><textarea rows={3} value={accionCorrectiva} onChange={(e) => setAccionCorrectiva(e.target.value)} /></div></div><div className="acciones-documento"><button className={hayBajaSeleccionada ? "peligro" : undefined} disabled={procesando} onClick={resolverIncidencia}>{procesando ? "Registrando..." : hayBajaSeleccionada ? "Revisar y confirmar baja definitiva" : "Registrar disposición"}</button></div></div></div>}

      {revisando && <div className="modal-operativo" role="dialog" aria-modal="true"><div className="modal-contenido ancho"><div className="header-row"><div><h3 style={{ margin: 0 }}>Revisión {revisando.numero}</h3><span className="conteo">{revisando.origen?.nombre} · primer conteo por {revisando.creador?.nombre_completo}</span></div><button className="chip-limpiar" onClick={() => setRevisando(null)}>Cerrar</button></div>{revisando.creado_por === perfil.id && perfil.rol === "admin" && <div className="info-box"><strong>Excepción de Administrador:</strong> estás revisando tu propio conteo. El segundo conteo y la aprobación quedarán identificados expresamente en la auditoría.</div>}<div className="info-box"><strong>{lineasRevision.length} líneas relevantes.</strong> Se ocultaron {lineasRevisionOcultas} productos con stock anterior 0 y conteo actual 0. Los registros permanecen en la auditoría.</div><div className="tabla-scroll"><table><thead><tr><th>SKU</th><th>Producto</th><th className="num">Stock anterior</th><th className="num">Conteo actual</th><th className="num">Diferencia</th><th className="num">Reconteo Control</th></tr></thead><tbody>{lineasRevision.map((l) => { const diferencia = (l.cantidad_contada ?? 0) - (l.stock_sistema ?? 0); return <tr key={l.id} className={diferencia ? "fila-alerta" : ""}><td><strong>{l.producto?.sku}</strong></td><td>{l.producto?.nombre} {l.producto?.talla ?? ""}</td><td className="num">{l.stock_sistema ?? 0}</td><td className="num">{l.cantidad_contada ?? 0}</td><td className="num">{diferencia > 0 ? `+${diferencia}` : diferencia}</td><td className="num">{diferencia ? <input type="number" min={0} value={reconteos[l.producto_id] ?? ""} onChange={(e) => setReconteos({ ...reconteos, [l.producto_id]: e.target.value })} style={{ width: 90 }} /> : "No requiere"}</td></tr>; })}{!lineasRevision.length && <tr><td colSpan={6} className="vacio">Todos los productos quedaron 0 → 0; no existen líneas relevantes para mostrar.</td></tr>}</tbody></table></div><div className="field"><label>Resolución / número de acta</label><textarea rows={3} value={nota} onChange={(e) => setNota(e.target.value)} style={{ width: "100%" }} /></div><div className="acciones-documento"><button disabled={procesando} onClick={() => resolverConteo(true)}>Aprobar y aplicar</button><button className="peligro" disabled={procesando} onClick={() => resolverConteo(false)}>Devolver para corrección</button></div></div></div>}
    </>
  );
}
