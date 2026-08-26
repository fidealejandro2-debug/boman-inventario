"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";
import { fecha } from "@/lib/utils";
import { ETIQUETAS_ESTADO } from "@/lib/erp";

type Linea = {
  id: string; producto_id: string; stock_sistema: number | null;
  cantidad_contada: number | null; cantidad_reconteo: number | null;
  cantidad_despachada: number | null; cantidad_recibida: number | null; cantidad_rechazada: number | null;
  producto: { sku: string; nombre: string; talla: string | null; precio: number | null } | null;
};
type Documento = {
  id: string; numero: string; tipo: string; estado: string; nota: string | null;
  origen_id: string | null; destino_id: string | null; created_at: string;
  despachado_at: string | null; recibido_at: string | null;
  origen: { nombre: string } | null; destino: { nombre: string } | null;
  creador: { nombre_completo: string } | null; lineas: Linea[];
};

export default function ControlCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [documentos, setDocumentos] = useState<Documento[]>([]);
  const [eventos, setEventos] = useState<any[]>([]);
  const [cambiosProductos, setCambiosProductos] = useState<any[]>([]);
  const [revisando, setRevisando] = useState<Documento | null>(null);
  const [reconteos, setReconteos] = useState<Record<string, string>>({});
  const [nota, setNota] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const puedeResolver = perfil.rol === "admin" || perfil.rol === "control";

  async function cargar() {
    setCargando(true);
    const [d, e, p] = await Promise.all([
      supabase.from("documentos_inventario").select(`
        id, numero, tipo, estado, nota, origen_id, destino_id, created_at, despachado_at, recibido_at,
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
    ]);
    if (d.error || e.error || p.error) setMsg({ tipo: "error", texto: d.error?.message ?? e.error?.message ?? p.error!.message });
    setDocumentos((d.data ?? []) as any as Documento[]);
    setEventos(e.data ?? []);
    setCambiosProductos(p.data ?? []);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const solicitudes = documentos.filter((d) => d.tipo === "solicitud_reposicion" && d.estado === "solicitado");
  const conteos = documentos.filter((d) => d.tipo === "conteo" && d.estado === "pendiente_revision");
  const diferencias = documentos.filter((d) => d.tipo === "transferencia" && d.estado === "recibido_con_diferencia");
  const enTransito = documentos.filter((d) => d.tipo === "transferencia" && ["despachado", "en_transito"].includes(d.estado));

  const unidadesDiferencia = useMemo(() => diferencias.reduce((total, d) => total + d.lineas.reduce((s, l) => s + Math.max((l.cantidad_despachada ?? 0) - (l.cantidad_recibida ?? 0), 0), 0), 0), [diferencias]);

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

  async function cerrarDiferencia(documento: Documento) {
    const detalle = window.prompt(`Resolución de la diferencia de ${documento.numero}:`)?.trim();
    if (!detalle) return;
    setProcesando(true);
    const { error } = await supabase.rpc("cerrar_incidencia_transferencia", { p_documento_id: documento.id, p_nota: detalle });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: "Incidencia cerrada y auditada." }); await cargar();
  }

  return (
    <>
      <div className="header-row"><div><h2 style={{ color: "#1f3864", margin: 0 }}>Centro de Control</h2><p className="conteo">Pendientes, diferencias, aprobaciones y trazabilidad operativa.</p></div><Link href="/reportes" className="boton-link">Reportes operativos</Link></div>
      {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}
      <div className="kpis">
        <div className={`kpi ${solicitudes.length ? "alerta" : "ok"}`}><div className="label">Solicitudes pendientes</div><div className="valor">{solicitudes.length}</div></div>
        <div className={`kpi ${conteos.length ? "alerta" : "ok"}`}><div className="label">Conteos por revisar</div><div className="valor">{conteos.length}</div></div>
        <div className={`kpi ${diferencias.length ? "alerta" : "ok"}`}><div className="label">Recepciones con diferencia</div><div className="valor">{diferencias.length}</div><small>{unidadesDiferencia} unidad(es)</small></div>
        <div className="kpi"><div className="label">Transferencias en tránsito</div><div className="valor">{enTransito.length}</div></div>
      </div>

      {cargando ? <div className="card"><div className="vacio">Consolidando operaciones...</div></div> : <>
        <div className="grid-control">
          <section className="card"><div className="header-row"><h3>Solicitudes pendientes</h3><Link href="/operaciones">Gestionar →</Link></div>{solicitudes.map((d) => <div className="pendiente-control" key={d.id}><div><strong>{d.numero}</strong><span>{d.destino?.nombre} · {fecha(d.created_at)}</span></div><b>{d.lineas.length} SKU</b></div>)}{!solicitudes.length && <div className="vacio">Sin solicitudes pendientes.</div>}</section>
          <section className="card"><h3 style={{ marginTop: 0 }}>Conteos pendientes</h3>{conteos.map((d) => { const dif = d.lineas.filter((l) => l.cantidad_contada !== l.stock_sistema); return <div className="pendiente-control" key={d.id}><div><strong>{d.numero}</strong><span>{d.origen?.nombre} · {d.creador?.nombre_completo}</span></div><div><span className={`badge ${dif.length ? "bajo" : "ok"}`}>{dif.length} diferencias</span>{puedeResolver && <button className="secondary" onClick={() => abrirRevision(d)}>Revisar</button>}</div></div>; })}{!conteos.length && <div className="vacio">Sin conteos pendientes.</div>}</section>
        </div>

        <section className="card"><h3 style={{ marginTop: 0 }}>Recepciones con diferencia</h3><div className="tabla-scroll"><table><thead><tr><th>Documento</th><th>Ruta</th><th>Fecha recepción</th><th>Detalle</th><th>Nota</th><th></th></tr></thead><tbody>{diferencias.map((d) => <tr key={d.id}><td><strong>{d.numero}</strong></td><td>{d.origen?.nombre} → {d.destino?.nombre}</td><td>{d.recibido_at ? fecha(d.recibido_at) : "-"}</td><td>{d.lineas.filter((l) => (l.cantidad_despachada ?? 0) !== (l.cantidad_recibida ?? 0) || (l.cantidad_rechazada ?? 0) > 0).map((l) => <div key={l.id} className="conteo"><b>{l.producto?.sku}</b>: env. {l.cantidad_despachada}, rec. {l.cantidad_recibida}, rech. {l.cantidad_rechazada ?? 0}</div>)}</td><td>{d.nota}</td><td>{puedeResolver && <button disabled={procesando} onClick={() => cerrarDiferencia(d)}>Cerrar incidencia</button>}</td></tr>)}{!diferencias.length && <tr><td colSpan={6} className="vacio">No existen diferencias abiertas.</td></tr>}</tbody></table></div></section>

        <section className="card"><h3 style={{ marginTop: 0 }}>Auditoría reciente</h3><div className="tabla-scroll"><table><thead><tr><th>Fecha</th><th>Documento</th><th>Cambio</th><th>Usuario</th><th>Detalle</th></tr></thead><tbody>{eventos.map((e) => <tr key={e.id}><td>{fecha(e.created_at)}</td><td><strong>{e.documento?.numero}</strong></td><td>{ETIQUETAS_ESTADO[e.estado_anterior] ?? e.estado_anterior ?? "Creado"} → {ETIQUETAS_ESTADO[e.estado_nuevo] ?? e.estado_nuevo}</td><td>{e.usuario?.nombre_completo}</td><td>{e.detalle ?? "-"}</td></tr>)}</tbody></table></div></section>

        <section className="card"><h3 style={{ marginTop: 0 }}>Cambios recientes del catálogo</h3><div className="tabla-scroll"><table><thead><tr><th>Fecha</th><th>SKU / producto</th><th>Campos modificados</th><th>Usuario</th></tr></thead><tbody>{cambiosProductos.map((c) => { const campos = Object.keys(c.valores_nuevos ?? {}).filter((k) => JSON.stringify(c.valores_anteriores?.[k]) !== JSON.stringify(c.valores_nuevos?.[k])); return <tr key={c.id}><td>{fecha(c.created_at)}</td><td><strong>{c.producto?.sku}</strong><div className="conteo">{c.producto?.nombre}</div></td><td>{campos.join(", ") || "-"}</td><td>{c.usuario?.nombre_completo ?? "Proceso del sistema"}</td></tr>; })}{!cambiosProductos.length && <tr><td colSpan={4} className="vacio">Sin cambios recientes del catálogo.</td></tr>}</tbody></table></div></section>
      </>}

      {revisando && <div className="modal-operativo" role="dialog" aria-modal="true"><div className="modal-contenido ancho"><div className="header-row"><div><h3 style={{ margin: 0 }}>Revisión {revisando.numero}</h3><span className="conteo">{revisando.origen?.nombre} · primer conteo por {revisando.creador?.nombre_completo}</span></div><button className="chip-limpiar" onClick={() => setRevisando(null)}>Cerrar</button></div><div className="tabla-scroll"><table><thead><tr><th>SKU</th><th>Producto</th><th className="num">Sistema</th><th className="num">1er conteo</th><th className="num">Diferencia</th><th className="num">2do conteo Control</th></tr></thead><tbody>{revisando.lineas.map((l) => { const diferencia = (l.cantidad_contada ?? 0) - (l.stock_sistema ?? 0); return <tr key={l.id} className={diferencia ? "fila-alerta" : ""}><td><strong>{l.producto?.sku}</strong></td><td>{l.producto?.nombre} {l.producto?.talla ?? ""}</td><td className="num">{l.stock_sistema}</td><td className="num">{l.cantidad_contada}</td><td className="num">{diferencia > 0 ? `+${diferencia}` : diferencia}</td><td className="num">{diferencia ? <input type="number" min={0} value={reconteos[l.producto_id] ?? ""} onChange={(e) => setReconteos({ ...reconteos, [l.producto_id]: e.target.value })} style={{ width: 90 }} /> : "No requiere"}</td></tr>; })}</tbody></table></div><div className="field"><label>Resolución / número de acta</label><textarea rows={3} value={nota} onChange={(e) => setNota(e.target.value)} style={{ width: "100%" }} /></div><div className="acciones-documento"><button disabled={procesando} onClick={() => resolverConteo(true)}>Aprobar y aplicar</button><button className="peligro" disabled={procesando} onClick={() => resolverConteo(false)}>Devolver para corrección</button></div></div></div>}
    </>
  );
}
