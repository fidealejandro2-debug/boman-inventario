"use client";

import { useEffect, useMemo, useState } from "react";
import type { Perfil } from "@/lib/getPerfil";
import { createClient } from "@/lib/supabase/client";

type Grupo = { id: string; codigo: string; nombre: string };
type Formula = {
  id: string; grupo_id: string; codigo: string; version: number;
  producto: { sku: string; nombre: string } | null;
};
type EtapaRuta = {
  id?: string; secuencia: number; codigo: string; nombre: string;
  modalidad: "interna" | "maquila" | "control_calidad";
  requiere_evidencia: boolean; costo_estimado: number; instrucciones: string;
};
type Ruta = {
  id: string; grupo_id: string; codigo: string; nombre: string; version: number;
  estado: "borrador" | "activa" | "inactiva"; descripcion: string | null;
  created_at: string; etapas: EtapaRuta[];
};
type FormulaRuta = { formula_id: string; ruta_id: string };
type FormularioRuta = {
  id: string | null; grupo_id: string; codigo: string; nombre: string;
  descripcion: string; etapas: EtapaRuta[];
};

const MODALIDADES: { valor: EtapaRuta["modalidad"]; etiqueta: string }[] = [
  { valor: "interna", etiqueta: "Proceso interno" },
  { valor: "maquila", etiqueta: "Maquila externa" },
  { valor: "control_calidad", etiqueta: "Control de calidad" },
];
const ESTADOS: Record<Ruta["estado"], string> = {
  borrador: "Borrador", activa: "Activa", inactiva: "Inactiva",
};

function etapasIniciales(): EtapaRuta[] {
  return [
    { secuencia: 1, codigo: "CORTE", nombre: "Corte", modalidad: "interna", requiere_evidencia: true, costo_estimado: 0, instrucciones: "" },
    { secuencia: 2, codigo: "CONFECCION", nombre: "Confección", modalidad: "interna", requiere_evidencia: true, costo_estimado: 0, instrucciones: "" },
    { secuencia: 3, codigo: "CALIDAD", nombre: "Control de calidad", modalidad: "control_calidad", requiere_evidencia: true, costo_estimado: 0, instrucciones: "" },
    { secuencia: 4, codigo: "EMPAQUE", nombre: "Empaque", modalidad: "interna", requiere_evidencia: true, costo_estimado: 0, instrucciones: "" },
  ];
}

export default function RutasProduccionCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [grupos, setGrupos] = useState<Grupo[]>([]);
  const [formulas, setFormulas] = useState<Formula[]>([]);
  const [rutas, setRutas] = useState<Ruta[]>([]);
  const [asignaciones, setAsignaciones] = useState<FormulaRuta[]>([]);
  const [formulario, setFormulario] = useState<FormularioRuta | null>(null);
  const [formulaId, setFormulaId] = useState("");
  const [rutaId, setRutaId] = useState("");
  const [motivoAsignacion, setMotivoAsignacion] = useState("");
  const [procesando, setProcesando] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const puedeEditar = ["admin", "control"].includes(perfil.rol);

  async function cargar() {
    setCargando(true);
    const [g, f, r, fr] = await Promise.all([
      supabase.from("grupos_economicos").select("id,codigo,nombre").eq("activo", true).order("nombre"),
      supabase.from("formulas_produccion").select(`
        id,grupo_id,codigo,version,
        producto:productos!formulas_produccion_producto_resultado_id_fkey(sku,nombre)
      `).eq("estado", "activa").order("codigo"),
      supabase.from("rutas_produccion").select(`
        id,grupo_id,codigo,nombre,version,estado,descripcion,created_at,
        etapas:ruta_produccion_etapas(
          id,secuencia,codigo,nombre,modalidad,requiere_evidencia,
          costo_estimado,instrucciones
        )
      `).order("created_at", { ascending: false }),
      supabase.from("formula_rutas_produccion").select("formula_id,ruta_id"),
    ]);
    const error = g.error ?? f.error ?? r.error ?? fr.error;
    if (error) setMsg({ tipo: "error", texto: `No se pudo cargar Rutas V25: ${error.message}` });
    setGrupos((g.data ?? []) as Grupo[]);
    setFormulas((f.data ?? []) as any as Formula[]);
    setRutas(((r.data ?? []) as any as Ruta[]).map((ruta) => ({
      ...ruta, etapas: [...(ruta.etapas ?? [])].sort((a, b) => a.secuencia - b.secuencia),
    })));
    setAsignaciones((fr.data ?? []) as FormulaRuta[]);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const formulaSeleccionada = formulas.find((formula) => formula.id === formulaId);
  const rutasAsignables = useMemo(() => rutas.filter((ruta) =>
    ruta.estado === "activa" && (!formulaSeleccionada || ruta.grupo_id === formulaSeleccionada.grupo_id)
  ), [formulaSeleccionada, rutas]);

  function nuevaRuta() {
    setFormulario({
      id: null, grupo_id: grupos[0]?.id ?? "", codigo: "", nombre: "",
      descripcion: "", etapas: etapasIniciales(),
    });
    setMsg(null);
  }

  function editarRuta(ruta: Ruta, nuevaVersion = false) {
    setFormulario({
      id: nuevaVersion ? null : ruta.id,
      grupo_id: ruta.grupo_id, codigo: ruta.codigo, nombre: ruta.nombre,
      descripcion: ruta.descripcion ?? "",
      etapas: ruta.etapas.map((etapa, indice) => ({
        ...etapa, id: undefined, secuencia: indice + 1,
        instrucciones: etapa.instrucciones ?? "",
      })),
    });
    setMsg(null);
  }

  function cambiarEtapa(indice: number, cambio: Partial<EtapaRuta>) {
    if (!formulario) return;
    const etapas = formulario.etapas.map((etapa, posicion) =>
      posicion === indice ? { ...etapa, ...cambio } : etapa
    );
    setFormulario({ ...formulario, etapas });
  }

  function agregarEtapa() {
    if (!formulario) return;
    setFormulario({
      ...formulario,
      etapas: [...formulario.etapas, {
        secuencia: formulario.etapas.length + 1,
        codigo: `ETAPA${formulario.etapas.length + 1}`,
        nombre: "", modalidad: "interna", requiere_evidencia: true,
        costo_estimado: 0, instrucciones: "",
      }],
    });
  }

  function eliminarEtapa(indice: number) {
    if (!formulario || formulario.etapas.length === 1) return;
    setFormulario({
      ...formulario,
      etapas: formulario.etapas.filter((_, posicion) => posicion !== indice)
        .map((etapa, posicion) => ({ ...etapa, secuencia: posicion + 1 })),
    });
  }

  function moverEtapa(indice: number, direccion: -1 | 1) {
    if (!formulario) return;
    const destino = indice + direccion;
    if (destino < 0 || destino >= formulario.etapas.length) return;
    const etapas = [...formulario.etapas];
    [etapas[indice], etapas[destino]] = [etapas[destino], etapas[indice]];
    setFormulario({
      ...formulario,
      etapas: etapas.map((etapa, posicion) => ({ ...etapa, secuencia: posicion + 1 })),
    });
  }

  async function guardar(evento: React.FormEvent) {
    evento.preventDefault();
    if (!formulario) return;
    if (!formulario.etapas.length || formulario.etapas.some((etapa) =>
      !etapa.codigo.trim() || !etapa.nombre.trim() || etapa.costo_estimado < 0
    )) {
      setMsg({ tipo: "error", texto: "Completa los datos de todas las etapas." }); return;
    }
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("guardar_ruta_produccion_v25", {
      p_ruta_id: formulario.id, p_grupo_id: formulario.grupo_id,
      p_codigo: formulario.codigo, p_nombre: formulario.nombre,
      p_descripcion: formulario.descripcion || null,
      p_etapas: formulario.etapas.map((etapa, indice) => ({
        secuencia: indice + 1, codigo: etapa.codigo.toUpperCase(),
        nombre: etapa.nombre, modalidad: etapa.modalidad,
        requiere_evidencia: etapa.requiere_evidencia,
        costo_estimado: Number(etapa.costo_estimado) || 0,
        instrucciones: etapa.instrucciones || null,
      })),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setFormulario(null); setMsg({ tipo: "ok", texto: "Ruta guardada como borrador." });
    await cargar();
  }

  async function resolver(ruta: Ruta, activar: boolean) {
    const nota = window.prompt(activar
      ? "Evidencia de revisión para activar la ruta:"
      : "Motivo para inactivar la ruta:")?.trim();
    if (!nota) return;
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("resolver_ruta_produccion_v25", {
      p_ruta_id: ruta.id, p_activar: activar, p_nota: nota,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: activar ? "Ruta activada." : "Ruta inactivada." });
    await cargar();
  }

  async function asignarRuta() {
    if (!formulaId || !rutaId || motivoAsignacion.trim().length < 5) {
      setMsg({ tipo: "error", texto: "Selecciona fórmula, ruta y escribe un motivo de al menos 5 caracteres." }); return;
    }
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("asignar_ruta_formula_v25", {
      p_formula_id: formulaId, p_ruta_id: rutaId, p_motivo: motivoAsignacion,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setFormulaId(""); setRutaId(""); setMotivoAsignacion("");
    setMsg({ tipo: "ok", texto: "Ruta asignada a la fórmula. Las próximas órdenes copiarán sus etapas." });
    await cargar();
  }

  if (cargando) return <div className="card"><div className="vacio">Cargando rutas productivas...</div></div>;

  return <>
    <div className="header-row"><div><h3 style={{ margin: 0 }}>Rutas de producción</h3><p className="conteo">Procesos versionados para corte, confección, maquila, calidad y empaque.</p></div>{puedeEditar && <button onClick={nuevaRuta}>+ Nueva ruta</button>}</div>
    {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

    {formulario && <form className="card" onSubmit={guardar} style={{ marginBottom: 14 }}>
      <div className="header-row"><div><h3 style={{ margin: 0 }}>{formulario.id ? "Editar borrador" : "Nueva versión de ruta"}</h3><p className="conteo">La secuencia se ejecutará de arriba hacia abajo.</p></div><button type="button" className="chip-limpiar" onClick={() => setFormulario(null)}>Cerrar</button></div>
      <div className="grid-form">
        <div className="field"><label>Grupo económico *</label><select required disabled={Boolean(formulario.id)} value={formulario.grupo_id} onChange={(e) => setFormulario({ ...formulario, grupo_id: e.target.value })}><option value="">Seleccionar...</option>{grupos.map((grupo) => <option key={grupo.id} value={grupo.id}>{grupo.codigo} · {grupo.nombre}</option>)}</select></div>
        <div className="field"><label>Código *</label><input required value={formulario.codigo} onChange={(e) => setFormulario({ ...formulario, codigo: e.target.value.toUpperCase() })} placeholder="Ej.: RUTA-CAMISETA" /></div>
        <div className="field"><label>Nombre *</label><input required value={formulario.nombre} onChange={(e) => setFormulario({ ...formulario, nombre: e.target.value })} placeholder="Camiseta sublimada" /></div>
      </div>
      <div className="field"><label>Descripción</label><textarea rows={2} value={formulario.descripcion} onChange={(e) => setFormulario({ ...formulario, descripcion: e.target.value })} /></div>
      <h4>Etapas</h4>
      {formulario.etapas.map((etapa, indice) => <div className="card" key={`${etapa.codigo}-${indice}`} style={{ marginBottom: 8, padding: 10 }}><div className="pendiente-control" style={{ alignItems: "flex-end" }}>
          <span><strong>{indice + 1}</strong><small>Secuencia</small></span>
          <label>Código <input required value={etapa.codigo} onChange={(e) => cambiarEtapa(indice, { codigo: e.target.value.toUpperCase() })} style={{ width: 120 }} /></label>
          <label>Nombre <input required value={etapa.nombre} onChange={(e) => cambiarEtapa(indice, { nombre: e.target.value })} /></label>
          <label>Modalidad <select value={etapa.modalidad} onChange={(e) => cambiarEtapa(indice, { modalidad: e.target.value as EtapaRuta["modalidad"] })}>{MODALIDADES.map((modalidad) => <option key={modalidad.valor} value={modalidad.valor}>{modalidad.etiqueta}</option>)}</select></label>
          <label>Costo estimado por orden <input type="number" min={0} step="0.0001" value={etapa.costo_estimado} onChange={(e) => cambiarEtapa(indice, { costo_estimado: Math.max(0, Number(e.target.value) || 0) })} style={{ width: 100 }} /></label>
          <label className="checkbox-line"><input type="checkbox" checked={etapa.requiere_evidencia} onChange={(e) => cambiarEtapa(indice, { requiere_evidencia: e.target.checked })} /> Evidencia</label>
          <div className="acciones-documento"><button type="button" className="secondary" disabled={indice === 0} onClick={() => moverEtapa(indice, -1)}>↑</button><button type="button" className="secondary" disabled={indice === formulario.etapas.length - 1} onClick={() => moverEtapa(indice, 1)}>↓</button><button type="button" className="peligro" disabled={formulario.etapas.length === 1} onClick={() => eliminarEtapa(indice)}>Quitar</button></div>
        </div><div className="field"><label>Instrucciones de la etapa</label><input value={etapa.instrucciones} onChange={(e) => cambiarEtapa(indice, { instrucciones: e.target.value })} placeholder="Criterio de aceptación, ficha técnica o cuidado especial" /></div></div>)}
      <div className="acciones-documento"><button type="button" className="secondary" onClick={agregarEtapa}>+ Agregar etapa</button><button disabled={procesando}>{procesando ? "Guardando..." : "Guardar borrador"}</button></div>
    </form>}

    {puedeEditar && <div className="card" style={{ marginBottom: 14 }}>
      <h3 style={{ marginTop: 0 }}>Asignar ruta a fórmula activa</h3>
      <div className="grid-form">
        <div className="field"><label>Fórmula</label><select value={formulaId} onChange={(e) => { setFormulaId(e.target.value); setRutaId(""); }}><option value="">Seleccionar...</option>{formulas.map((formula) => { const actual = asignaciones.find((asignacion) => asignacion.formula_id === formula.id); const ruta = rutas.find((item) => item.id === actual?.ruta_id); return <option key={formula.id} value={formula.id}>{formula.codigo} v{formula.version} · {formula.producto?.sku} {ruta ? `— ${ruta.codigo} v${ruta.version}` : "— sin ruta"}</option>; })}</select></div>
        <div className="field"><label>Ruta activa</label><select value={rutaId} onChange={(e) => setRutaId(e.target.value)}><option value="">Seleccionar...</option>{rutasAsignables.map((ruta) => <option key={ruta.id} value={ruta.id}>{ruta.codigo} v{ruta.version} · {ruta.nombre}</option>)}</select></div>
        <div className="field"><label>Motivo *</label><input value={motivoAsignacion} onChange={(e) => setMotivoAsignacion(e.target.value)} placeholder="Configuración inicial de flujo" /></div>
        <div className="acciones-documento"><button type="button" disabled={procesando} onClick={asignarRuta}>Asignar</button></div>
      </div>
    </div>}

    <div className="documentos-grid">{rutas.map((ruta) => <article className="card documento-card" key={ruta.id}>
      <div className="header-row"><div><strong>{ruta.codigo} · v{ruta.version}</strong><div>{ruta.nombre}</div></div><span className={`badge ${ruta.estado === "activa" ? "ok" : ruta.estado === "borrador" ? "estado-pendiente_revision" : "cero"}`}>{ESTADOS[ruta.estado]}</span></div>
      <div className="documento-meta"><span>Etapas: <b>{ruta.etapas.length}</b></span><span>Costo estimado: <b>${ruta.etapas.reduce((total, etapa) => total + Number(etapa.costo_estimado), 0).toFixed(2)}</b></span><span>Fórmulas: <b>{asignaciones.filter((asignacion) => asignacion.ruta_id === ruta.id).length}</b></span></div>
      {ruta.descripcion && <p className="conteo">{ruta.descripcion}</p>}
      <details><summary>Ver secuencia</summary>{ruta.etapas.map((etapa) => <div className="pendiente-control" key={etapa.id}><span><strong>{etapa.secuencia}. {etapa.nombre}</strong><small>{etapa.codigo} · {MODALIDADES.find((item) => item.valor === etapa.modalidad)?.etiqueta}</small></span><span>{etapa.requiere_evidencia ? "Con evidencia" : "Sin evidencia"}</span></div>)}</details>
      <div className="acciones-documento">{puedeEditar && ruta.estado === "borrador" && <><button className="secondary" onClick={() => editarRuta(ruta)}>Editar</button><button onClick={() => resolver(ruta, true)}>Revisar y activar</button></>}{puedeEditar && ruta.estado === "activa" && <><button className="secondary" onClick={() => editarRuta(ruta, true)}>Nueva versión</button><button className="peligro" onClick={() => resolver(ruta, false)}>Inactivar</button></>}</div>
    </article>)}{!rutas.length && <div className="card"><div className="vacio">Aún no existen rutas. Las órdenes usarán una etapa general hasta configurarlas.</div></div>}</div>
  </>;
}
