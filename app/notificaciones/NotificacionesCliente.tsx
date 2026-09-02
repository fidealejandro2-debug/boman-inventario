"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { tienePermiso, type Perfil } from "@/lib/permisos";

type Nivel = "informativa" | "accion" | "alerta" | "critica";
type Notificacion = {
  clave: string; modulo: string; nivel: Nivel; titulo: string; mensaje: string;
  href: string; fecha: string; origen: string; leida: boolean; archivada: boolean;
};
type Respuesta = { no_leidas: number; criticas: number; total: number; items: Notificacion[] };

const VACIO: Respuesta = { no_leidas: 0, criticas: 0, total: 0, items: [] };
const ETIQUETA_NIVEL: Record<Nivel, string> = {
  informativa: "Información", accion: "Acción", alerta: "Alerta", critica: "Crítica",
};
const ROLES = [
  ["", "Todos los roles"], ["bodega", "Bodega"], ["logistica", "Logística"],
  ["gerencia", "Gerencia"], ["tienda", "Tienda"], ["control", "Control"],
  ["nomina", "Nómina"], ["franquiciado", "Franquiciado"],
  ["vendedor_franquicia", "Vendedor de franquicia"],
];

function fechaHora(valor: string) {
  return new Intl.DateTimeFormat("es-EC", {
    dateStyle: "medium", timeStyle: "short", timeZone: "America/Guayaquil",
  }).format(new Date(valor));
}

export default function NotificacionesCliente({ perfil }: { perfil: Perfil }) {
  const supabase = useMemo(() => createClient(), []);
  const [respuesta, setRespuesta] = useState<Respuesta>(VACIO);
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [filtro, setFiltro] = useState<"todas" | "no_leidas" | "criticas">("todas");
  const [busqueda, setBusqueda] = useState("");
  const [mostrarPublicacion, setMostrarPublicacion] = useState(false);
  const [publicacion, setPublicacion] = useState({
    titulo: "", mensaje: "", modulo: "General", nivel: "informativa" as Nivel,
    rol_destino: "", href: "/dashboard", vigente_hasta: "",
  });
  const puedePublicar = tienePermiso(perfil, "notificaciones.publicar");

  const cargar = useCallback(async () => {
    setCargando(true); setError(null);
    // Si v54 ya está instalada, esta llamada materializa vencimientos preventivos.
    await supabase.rpc("sincronizar_alertas_mantenimiento_v54");
    const { data, error: consultaError } = await supabase.rpc("listar_notificaciones_v53", {
      p_incluir_leidas: true, p_incluir_archivadas: false,
    });
    setCargando(false);
    if (consultaError) return setError(consultaError.message);
    setRespuesta((data as Respuesta) ?? VACIO);
  }, [supabase]);

  useEffect(() => {
    cargar();
    const intervalo = window.setInterval(cargar, 120000);
    return () => window.clearInterval(intervalo);
  }, [cargar]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    return respuesta.items.filter((item) =>
      (filtro !== "no_leidas" || !item.leida)
      && (filtro !== "criticas" || item.nivel === "critica")
      && (!q || [item.titulo, item.mensaje, item.modulo]
        .some((texto) => texto.toLocaleLowerCase("es").includes(q)))
    );
  }, [respuesta.items, filtro, busqueda]);

  async function marcar(claves: string[], accion: "leer" | "no_leida" | "archivar") {
    if (!claves.length) return;
    setProcesando(true); setError(null);
    const { error: marcarError } = await supabase.rpc("marcar_notificaciones_v53", {
      p_claves: claves, p_accion: accion,
    });
    setProcesando(false);
    if (marcarError) return setError(marcarError.message);
    await cargar();
  }

  async function publicar() {
    if (!publicacion.titulo.trim() || !publicacion.mensaje.trim()) {
      return setError("Escribe el título y el mensaje del comunicado.");
    }
    setProcesando(true); setError(null); setMensaje(null);
    const { error: publicarError } = await supabase.rpc("publicar_notificacion_v53", {
      p_datos: {
        ...publicacion,
        rol_destino: publicacion.rol_destino || null,
        vigente_hasta: publicacion.vigente_hasta
          ? `${publicacion.vigente_hasta}T23:59:59-05:00` : null,
      },
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (publicarError) return setError(publicarError.message);
    setPublicacion({ titulo: "", mensaje: "", modulo: "General", nivel: "informativa", rol_destino: "", href: "/dashboard", vigente_hasta: "" });
    setMostrarPublicacion(false); setMensaje("Comunicado publicado correctamente.");
    await cargar();
  }

  return <section className="notificaciones-centro">
    <div className="header-row">
      <div>
        <span className="modulo-kicker">CENTRO GENERAL</span>
        <h1>Notificaciones</h1>
        <p className="conteo">Pendientes, alertas, vencimientos y comunicados de todos tus módulos.</p>
      </div>
      <div className="notificaciones-acciones">
        {puedePublicar && <button className="secondary" onClick={() => setMostrarPublicacion((v) => !v)}>
          {mostrarPublicacion ? "Cerrar publicación" : "Publicar comunicado"}
        </button>}
        <button onClick={cargar} disabled={cargando}>{cargando ? "Actualizando…" : "Actualizar"}</button>
      </div>
    </div>

    {error && <div className="error-box">{error}</div>}
    {mensaje && <div className="success-box">{mensaje}</div>}

    <div className="kpis compactos">
      <div className="kpi"><div className="label">Sin leer</div><div className="valor">{respuesta.no_leidas}</div></div>
      <div className={`kpi ${respuesta.criticas ? "alerta" : "ok"}`}><div className="label">Críticas</div><div className="valor">{respuesta.criticas}</div></div>
      <div className="kpi"><div className="label">Visibles</div><div className="valor">{respuesta.total}</div></div>
      <div className="kpi"><div className="label">Módulos</div><div className="valor">{new Set(respuesta.items.map((i) => i.modulo)).size}</div></div>
    </div>

    {mostrarPublicacion && <div className="card notificacion-publicar">
      <div className="header-row"><div><h2>Nuevo comunicado</h2><p className="conteo">Puede dirigirse a todos o solamente a un rol.</p></div></div>
      <div className="grid-form">
        <div className="field"><label>Título</label><input value={publicacion.titulo} onChange={(e) => setPublicacion({ ...publicacion, titulo: e.target.value })} maxLength={120} /></div>
        <div className="field"><label>Módulo</label><input value={publicacion.modulo} onChange={(e) => setPublicacion({ ...publicacion, modulo: e.target.value })} maxLength={50} /></div>
        <div className="field"><label>Nivel</label><select value={publicacion.nivel} onChange={(e) => setPublicacion({ ...publicacion, nivel: e.target.value as Nivel })}>{Object.entries(ETIQUETA_NIVEL).map(([v, l]) => <option value={v} key={v}>{l}</option>)}</select></div>
        <div className="field"><label>Destinatarios</label><select value={publicacion.rol_destino} onChange={(e) => setPublicacion({ ...publicacion, rol_destino: e.target.value })}>{ROLES.map(([v, l]) => <option value={v} key={v}>{l}</option>)}</select></div>
        <div className="field"><label>Ruta al abrir</label><input value={publicacion.href} onChange={(e) => setPublicacion({ ...publicacion, href: e.target.value })} placeholder="/dashboard" /></div>
        <div className="field"><label>Visible hasta (opcional)</label><input type="date" value={publicacion.vigente_hasta} onChange={(e) => setPublicacion({ ...publicacion, vigente_hasta: e.target.value })} /></div>
        <div className="field ancho-total"><label>Mensaje</label><textarea rows={3} value={publicacion.mensaje} onChange={(e) => setPublicacion({ ...publicacion, mensaje: e.target.value })} maxLength={600} /></div>
      </div>
      <div className="modal-acciones"><button className="secondary" onClick={() => setMostrarPublicacion(false)}>Cancelar</button><button onClick={publicar} disabled={procesando}>{procesando ? "Publicando…" : "Publicar"}</button></div>
    </div>}

    <div className="card">
      <div className="notificaciones-filtros">
        <div className="tabs">
          {([['todas', 'Todas'], ['no_leidas', 'Sin leer'], ['criticas', 'Críticas']] as const).map(([valor, etiqueta]) =>
            <button className={`tab ${filtro === valor ? "activo" : ""}`} onClick={() => setFiltro(valor)} key={valor}>{etiqueta}</button>)}
        </div>
        <div className="field buscador"><label>Buscar</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Módulo, título o detalle…" /></div>
        <button className="secondary" disabled={procesando || !respuesta.items.some((i) => !i.leida)} onClick={() => marcar(respuesta.items.filter((i) => !i.leida).map((i) => i.clave), "leer")}>Marcar todo leído</button>
      </div>

      <div className="notificaciones-lista">
        {visibles.map((item) => <article className={`notificacion-item ${item.nivel} ${item.leida ? "leida" : ""}`} key={item.clave}>
          <span className="notificacion-indicador" aria-hidden="true" />
          <div className="notificacion-cuerpo">
            <div className="notificacion-meta"><span>{item.modulo}</span><b>{ETIQUETA_NIVEL[item.nivel]}</b><time>{fechaHora(item.fecha)}</time></div>
            <h3>{item.titulo}</h3><p>{item.mensaje}</p>
          </div>
          <div className="notificacion-botones">
            <Link href={item.href} onClick={() => { if (!item.leida) void marcar([item.clave], "leer"); }}>Abrir</Link>
            <button className="secondary" onClick={() => marcar([item.clave], item.leida ? "no_leida" : "leer")} disabled={procesando}>{item.leida ? "Marcar pendiente" : "Marcar leída"}</button>
            <button className="notificacion-archivar" onClick={() => marcar([item.clave], "archivar")} disabled={procesando}>Archivar</button>
          </div>
        </article>)}
        {!cargando && !visibles.length && <div className="notificaciones-vacio"><span>✓</span><strong>No hay avisos en esta vista</strong><p>Tu centro está al día con los filtros seleccionados.</p></div>}
      </div>
    </div>
  </section>;
}
