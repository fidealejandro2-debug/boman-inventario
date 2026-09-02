"use client";

import { useEffect, useMemo, useState } from "react";
import type { Perfil } from "@/lib/getPerfil";
import { createClient } from "@/lib/supabase/client";
import { pedirMotivoDialogo, confirmarDialogo } from "@/components/Dialogo";

type Formula = {
  id: string; grupo_id: string; codigo: string; version: number;
  rendimiento_base: number; costo_mano_obra_lote: number;
  costo_indirecto_lote: number;
  producto: { id: string; sku: string; nombre: string; unidad_medida: string } | null;
};
type Empresa = { id: string; grupo_id: string; codigo: string; razon_social: string };
type Almacen = { id: string; codigo: string; nombre: string };
type EmpresaAlmacen = { empresa_id: string; almacen_id: string; custodia_inventario: boolean };
type PerfilResumen = { id: string; nombre_completo: string; rol: string };
type Proveedor = { id: string; razon_social: string; nombre_comercial: string | null };
type ProveedorEmpresa = { proveedor_id: string; empresa_id: string; activo: boolean };
type Material = {
  id: string; producto_id: string; unidad_medida: string;
  cantidad_teorica: number; merma_teorica_porcentaje: number;
  cantidad_planificada: number; cantidad_entregada: number;
  cantidad_consumida: number; cantidad_merma: number; cantidad_devuelta: number;
  costo_unitario_referencia: number; costo_real_linea: number | null;
  producto: { sku: string; nombre: string } | null;
};
type EtapaOrden = {
  id: string; secuencia: number; codigo: string; nombre: string;
  modalidad: "interna" | "maquila" | "control_calidad";
  requiere_evidencia: boolean; instrucciones: string | null;
  estado: "pendiente" | "en_proceso" | "completada" | "omitida";
  responsable_perfil_id: string | null; proveedor_id: string | null;
  cantidad_procesada: number | null; cantidad_no_conforme: number;
  costo_estimado: number; costo_real: number | null;
  iniciado_at: string | null; completado_at: string | null;
  evidencia_cierre: string | null;
  responsable: { nombre_completo: string } | null;
  proveedor: { razon_social: string; nombre_comercial: string | null } | null;
};
type LoteProduccion = {
  codigo: string; estado_calidad: "liberado" | "cuarentena" | "mixto";
  cantidad_conforme: number; cantidad_no_conforme: number; fecha_produccion: string;
};
type Orden = {
  id: string; numero: string; grupo_id: string; empresa_id: string;
  formula_id: string; formula_codigo: string; formula_version: number;
  almacen_materiales_id: string; almacen_terminado_id: string;
  estado: "pendiente_aprobacion" | "aprobada" | "en_proceso" | "completada" | "rechazada" | "cancelada";
  cantidad_planificada: number; cantidad_conforme: number; cantidad_no_conforme: number;
  fecha_planificada: string | null; prioridad: "normal" | "urgente";
  nota: string | null; costo_total_estimado: number;
  costo_mano_obra_estimado: number; costo_indirecto_estimado: number;
  costo_total_real: number | null; costo_unitario_real: number | null;
  ruta_codigo: string | null; ruta_version: number | null;
  costo_etapas_estimado: number; costo_etapas_real: number | null;
  created_at: string;
  empresa: { codigo: string; razon_social: string } | null;
  resultado: { sku: string; nombre: string; unidad_medida: string } | null;
  almacen_materiales: { nombre: string } | null;
  almacen_terminado: { nombre: string } | null;
  materiales: Material[];
  etapas: EtapaOrden[];
  lote: LoteProduccion | null;
};
type FormularioOrden = {
  formula_id: string; empresa_id: string; almacen_materiales_id: string;
  almacen_terminado_id: string; cantidad_planificada: number;
  fecha_planificada: string; prioridad: "normal" | "urgente"; nota: string;
  idempotencyKey: string;
};
type EditorEntrega = {
  ordenId: string; cantidades: Record<string, number>; nota: string; permitirExceso: boolean;
  idempotencyKey: string;
};
type EditorCierre = {
  ordenId: string; consumos: Record<string, number>; mermas: Record<string, number>;
  conforme: number; noConforme: number; manoObra: number; indirectos: number; nota: string;
  idempotencyKey: string;
};
type EditorEtapa = {
  etapaId: string; accion: "iniciar" | "completar";
  responsablePerfilId: string; proveedorId: string; nota: string;
  cantidadProcesada: number; cantidadNoConforme: number; costoReal: number;
  evidencia: string; idempotencyKey: string;
};

const ESTADO: Record<Orden["estado"], string> = {
  pendiente_aprobacion: "Pendiente de aprobación", aprobada: "Aprobada",
  en_proceso: "En proceso", completada: "Completada", rechazada: "Rechazada",
  cancelada: "Cancelada",
};
const ESTADO_ETAPA: Record<EtapaOrden["estado"], string> = {
  pendiente: "Pendiente", en_proceso: "En proceso",
  completada: "Completada", omitida: "Omitida",
};
const dinero = new Intl.NumberFormat("es-EC", {
  style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 4,
});

function normalizar(valor: string) {
  return valor.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

export default function OrdenesProduccionCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [formulas, setFormulas] = useState<Formula[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [empresaAlmacenes, setEmpresaAlmacenes] = useState<EmpresaAlmacen[]>([]);
  const [perfiles, setPerfiles] = useState<PerfilResumen[]>([]);
  const [proveedores, setProveedores] = useState<Proveedor[]>([]);
  const [proveedorEmpresas, setProveedorEmpresas] = useState<ProveedorEmpresa[]>([]);
  const [ordenes, setOrdenes] = useState<Orden[]>([]);
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const [busqueda, setBusqueda] = useState("");
  const [estado, setEstado] = useState("");
  const [mostrarNueva, setMostrarNueva] = useState(false);
  const [formulario, setFormulario] = useState<FormularioOrden>({
    formula_id: "", empresa_id: "", almacen_materiales_id: "",
    almacen_terminado_id: "", cantidad_planificada: 1,
    fecha_planificada: "", prioridad: "normal", nota: "", idempotencyKey: "",
  });
  const [entrega, setEntrega] = useState<EditorEntrega | null>(null);
  const [cierre, setCierre] = useState<EditorCierre | null>(null);
  const [etapaEditor, setEtapaEditor] = useState<EditorEtapa | null>(null);

  const puedeResolver = ["admin", "control"].includes(perfil.rol);
  const puedeOperar = ["admin", "control", "bodega"].includes(perfil.rol);
  const puedeOperarEtapa = ["admin", "control", "bodega", "logistica"].includes(perfil.rol);

  async function cargar() {
    setCargando(true);
    const [f, e, a, ea, p, pr, pe, o] = await Promise.all([
      supabase.from("formulas_produccion").select(`
        id,grupo_id,codigo,version,rendimiento_base,costo_mano_obra_lote,costo_indirecto_lote,
        producto:productos!formulas_produccion_producto_resultado_id_fkey(id,sku,nombre,unidad_medida)
      `).eq("estado", "activa").order("codigo"),
      supabase.from("empresas").select("id,grupo_id,codigo,razon_social").eq("activo", true).order("razon_social"),
      supabase.from("almacenes").select("id,codigo,nombre").eq("activo", true).order("nombre"),
      supabase.from("empresa_almacenes").select("empresa_id,almacen_id,custodia_inventario").eq("custodia_inventario", true),
      supabase.from("perfiles").select("id,nombre_completo,rol").eq("activo", true).order("nombre_completo"),
      supabase.from("proveedores").select("id,razon_social,nombre_comercial").eq("activo", true).order("razon_social"),
      supabase.from("proveedor_empresas").select("proveedor_id,empresa_id,activo").eq("activo", true),
      supabase.from("ordenes_produccion").select(`
        id,numero,grupo_id,empresa_id,formula_id,formula_codigo,formula_version,
        almacen_materiales_id,almacen_terminado_id,estado,cantidad_planificada,
        cantidad_conforme,cantidad_no_conforme,fecha_planificada,prioridad,nota,
        costo_total_estimado,costo_mano_obra_estimado,costo_indirecto_estimado,
        costo_total_real,costo_unitario_real,ruta_codigo,ruta_version,
        costo_etapas_estimado,costo_etapas_real,created_at,
        empresa:empresas!ordenes_produccion_empresa_id_fkey(codigo,razon_social),
        resultado:productos!ordenes_produccion_producto_resultado_id_fkey(sku,nombre,unidad_medida),
        almacen_materiales:almacenes!ordenes_produccion_almacen_materiales_id_fkey(nombre),
        almacen_terminado:almacenes!ordenes_produccion_almacen_terminado_id_fkey(nombre),
        materiales:orden_produccion_materiales(
          id,producto_id,unidad_medida,cantidad_teorica,merma_teorica_porcentaje,
          cantidad_planificada,cantidad_entregada,cantidad_consumida,cantidad_merma,
          cantidad_devuelta,costo_unitario_referencia,costo_real_linea,
          producto:productos!orden_produccion_materiales_producto_id_fkey(sku,nombre)
        ),
        etapas:orden_produccion_etapas(
          id,secuencia,codigo,nombre,modalidad,requiere_evidencia,instrucciones,
          estado,responsable_perfil_id,proveedor_id,cantidad_procesada,
          cantidad_no_conforme,costo_estimado,costo_real,iniciado_at,
          completado_at,evidencia_cierre,
          responsable:perfiles!orden_produccion_etapas_responsable_perfil_id_fkey(nombre_completo),
          proveedor:proveedores!orden_produccion_etapas_proveedor_id_fkey(razon_social,nombre_comercial)
        ),
        lote:lotes_produccion(codigo,estado_calidad,cantidad_conforme,cantidad_no_conforme,fecha_produccion)
      `).order("created_at", { ascending: false }).limit(200),
    ]);
    const error = f.error ?? e.error ?? a.error ?? ea.error ?? p.error ?? pr.error ?? pe.error ?? o.error;
    if (error) setMsg({ tipo: "error", texto: `No se pudo cargar Producción V25: ${error.message}` });
    setFormulas((f.data ?? []) as any as Formula[]);
    setEmpresas((e.data ?? []) as Empresa[]);
    setAlmacenes((a.data ?? []) as Almacen[]);
    setEmpresaAlmacenes((ea.data ?? []) as EmpresaAlmacen[]);
    setPerfiles((p.data ?? []) as PerfilResumen[]);
    setProveedores((pr.data ?? []) as Proveedor[]);
    setProveedorEmpresas((pe.data ?? []) as ProveedorEmpresa[]);
    setOrdenes(((o.data ?? []) as any as Orden[]).map((orden) => ({
      ...orden,
      etapas: [...(orden.etapas ?? [])].sort((x, y) => x.secuencia - y.secuencia),
      lote: Array.isArray(orden.lote) ? orden.lote[0] ?? null : orden.lote,
    })));
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const formulaSeleccionada = formulas.find((formula) => formula.id === formulario.formula_id);
  const empresasDisponibles = empresas.filter((empresa) =>
    !formulaSeleccionada || empresa.grupo_id === formulaSeleccionada.grupo_id
  );
  const almacenesDisponibles = almacenes.filter((almacen) => empresaAlmacenes.some((asignacion) =>
    asignacion.empresa_id === formulario.empresa_id && asignacion.almacen_id === almacen.id
  ));
  const ordenesFiltradas = useMemo(() => {
    const q = normalizar(busqueda.trim());
    return ordenes.filter((orden) => (!estado || orden.estado === estado) && (!q || normalizar([
      orden.numero, orden.formula_codigo, orden.resultado?.sku ?? "",
      orden.resultado?.nombre ?? "", orden.empresa?.razon_social ?? "",
    ].join(" ")).includes(q)));
  }, [busqueda, estado, ordenes]);

  function seleccionarFormula(formulaId: string) {
    const formula = formulas.find((item) => item.id === formulaId);
    const empresaActual = empresas.find((empresa) => empresa.id === formulario.empresa_id);
    setFormulario({
      ...formulario, formula_id: formulaId,
      empresa_id: empresaActual?.grupo_id === formula?.grupo_id ? formulario.empresa_id : "",
      almacen_materiales_id: "", almacen_terminado_id: "",
    });
  }

  function seleccionarEmpresa(empresaId: string) {
    setFormulario({ ...formulario, empresa_id: empresaId,
      almacen_materiales_id: "", almacen_terminado_id: "" });
  }

  async function crearOrden(evento: React.FormEvent) {
    evento.preventDefault();
    if (!formulario.formula_id || !formulario.empresa_id
      || !formulario.almacen_materiales_id || !formulario.almacen_terminado_id) {
      setMsg({ tipo: "error", texto: "Completa fórmula, empresa y almacenes." }); return;
    }
    const idempotencyKey = formulario.idempotencyKey || crypto.randomUUID();
    if (!formulario.idempotencyKey) setFormulario({ ...formulario, idempotencyKey });
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("crear_orden_produccion_v24", {
      p_formula_id: formulario.formula_id, p_empresa_id: formulario.empresa_id,
      p_almacen_materiales_id: formulario.almacen_materiales_id,
      p_almacen_terminado_id: formulario.almacen_terminado_id,
      p_cantidad_planificada: formulario.cantidad_planificada,
      p_fecha_planificada: formulario.fecha_planificada || null,
      p_prioridad: formulario.prioridad, p_nota: formulario.nota || null,
      p_idempotency_key: idempotencyKey,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMostrarNueva(false);
    setFormulario({ formula_id: "", empresa_id: "", almacen_materiales_id: "",
      almacen_terminado_id: "", cantidad_planificada: 1, fecha_planificada: "",
      prioridad: "normal", nota: "", idempotencyKey: "" });
    setMsg({ tipo: "ok", texto: `Orden ${data?.numero ?? ""} creada para aprobación.` });
    await cargar();
  }

  async function resolver(orden: Orden, aprobar: boolean) {
    const nota = (await pedirMotivoDialogo(aprobar
      ? "Evidencia de revisión y aprobación:" : "Motivo del rechazo:"))?.trim();
    if (!nota) return;
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("resolver_orden_produccion_v24", {
      p_orden_id: orden.id, p_aprobar: aprobar, p_nota: nota,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: aprobar ? "Orden aprobada y materiales reservados." : "Orden rechazada." });
    await cargar();
  }

  function abrirEntrega(orden: Orden) {
    setEntrega({
      ordenId: orden.id,
      cantidades: Object.fromEntries(orden.materiales.map((material) => [
        material.id, Math.max(material.cantidad_planificada - material.cantidad_entregada, 0),
      ])),
      nota: "", permitirExceso: false, idempotencyKey: crypto.randomUUID(),
    });
    setCierre(null); setEtapaEditor(null); setMsg(null);
  }

  async function guardarEntrega(orden: Orden) {
    if (!entrega) return;
    const items = orden.materiales.map((material) => ({
      orden_material_id: material.id, cantidad: Math.floor(entrega.cantidades[material.id] ?? 0),
    })).filter((item) => item.cantidad > 0);
    if (!items.length) { setMsg({ tipo: "error", texto: "Indica al menos una cantidad para entregar." }); return; }
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("entregar_materiales_produccion_v24", {
      p_orden_id: orden.id, p_items: items, p_nota: entrega.nota || null,
      p_permitir_exceso: entrega.permitirExceso, p_idempotency_key: entrega.idempotencyKey,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setEntrega(null); setMsg({ tipo: "ok", texto: `Entrega ${data?.numero ?? ""} aplicada. El material está en proceso.` });
    await cargar();
  }

  function abrirEtapa(orden: Orden, etapa: EtapaOrden, accion: EditorEtapa["accion"]) {
    setEtapaEditor({
      etapaId: etapa.id, accion,
      responsablePerfilId: etapa.responsable_perfil_id ?? perfil.id,
      proveedorId: etapa.proveedor_id ?? "", nota: "",
      cantidadProcesada: orden.cantidad_planificada,
      cantidadNoConforme: 0, costoReal: Number(etapa.costo_estimado) || 0,
      evidencia: "", idempotencyKey: crypto.randomUUID(),
    });
    setEntrega(null); setCierre(null); setMsg(null);
  }

  async function guardarEtapa(orden: Orden, etapa: EtapaOrden) {
    if (!etapaEditor || etapaEditor.etapaId !== etapa.id) return;
    setProcesando(true); setMsg(null);
    const resultado = etapaEditor.accion === "iniciar"
      ? await supabase.rpc("iniciar_etapa_produccion_v25", {
          p_etapa_id: etapa.id,
          p_responsable_perfil_id: etapa.modalidad === "maquila"
            ? null : etapaEditor.responsablePerfilId || null,
          p_proveedor_id: etapa.modalidad === "maquila"
            ? etapaEditor.proveedorId || null : null,
          p_nota: etapaEditor.nota || null,
          p_idempotency_key: etapaEditor.idempotencyKey,
        })
      : await supabase.rpc("completar_etapa_produccion_v25", {
          p_etapa_id: etapa.id,
          p_cantidad_procesada: Math.floor(etapaEditor.cantidadProcesada),
          p_cantidad_no_conforme: Math.floor(etapaEditor.cantidadNoConforme),
          p_costo_real: etapaEditor.costoReal,
          p_evidencia: etapaEditor.evidencia || null,
          p_idempotency_key: etapaEditor.idempotencyKey,
        });
    setProcesando(false);
    if (resultado.error) { setMsg({ tipo: "error", texto: resultado.error.message }); return; }
    setEtapaEditor(null);
    setMsg({ tipo: "ok", texto: etapaEditor.accion === "iniciar"
      ? `Etapa ${etapa.nombre} iniciada.` : `Etapa ${etapa.nombre} completada.` });
    await cargar();
  }

  async function omitirEtapa(etapa: EtapaOrden) {
    const motivo = (await pedirMotivoDialogo("Justificación administrativa para omitir esta etapa (mínimo 10 caracteres):"))?.trim();
    if (!motivo) return;
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("omitir_etapa_produccion_v25", {
      p_etapa_id: etapa.id, p_motivo: motivo,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setEtapaEditor(null); setMsg({ tipo: "ok", texto: "Etapa omitida con excepción auditada." });
    await cargar();
  }

  function abrirCierre(orden: Orden) {
    setCierre({
      ordenId: orden.id,
      consumos: Object.fromEntries(orden.materiales.map((material) => [material.id, material.cantidad_entregada])),
      mermas: Object.fromEntries(orden.materiales.map((material) => [material.id, 0])),
      conforme: orden.cantidad_planificada, noConforme: 0,
      manoObra: Number(orden.costo_mano_obra_estimado),
      indirectos: Number(orden.costo_indirecto_estimado), nota: "",
      idempotencyKey: crypto.randomUUID(),
    });
    setEntrega(null); setEtapaEditor(null); setMsg(null);
  }

  async function finalizar(orden: Orden) {
    if (!cierre) return;
    const materiales = orden.materiales.map((material) => ({
      orden_material_id: material.id,
      cantidad_consumida: Math.floor(cierre.consumos[material.id] ?? 0),
      cantidad_merma: Math.floor(cierre.mermas[material.id] ?? 0),
    }));
    if (materiales.some((item) => item.cantidad_consumida < 0 || item.cantidad_merma < 0)) {
      setMsg({ tipo: "error", texto: "Revisa el consumo y la merma." }); return;
    }
    if (materiales.some((item) => {
      const material = orden.materiales.find((linea) => linea.id === item.orden_material_id);
      return item.cantidad_consumida + item.cantidad_merma > (material?.cantidad_entregada ?? 0);
    })) {
      setMsg({ tipo: "error", texto: "El consumo más la merma no puede superar lo entregado." }); return;
    }
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("finalizar_orden_produccion_v24", {
      p_orden_id: orden.id, p_materiales: materiales,
      p_cantidad_conforme: Math.floor(cierre.conforme),
      p_cantidad_no_conforme: Math.floor(cierre.noConforme),
      p_costo_mano_obra_real: cierre.manoObra,
      p_costo_indirecto_real: cierre.indirectos,
      p_nota: cierre.nota, p_idempotency_key: cierre.idempotencyKey,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setCierre(null);
    setMsg({ tipo: "ok", texto: `Orden completada. Costo real unitario: ${dinero.format(data?.costo_unitario_real ?? 0)}.` });
    await cargar();
  }

  async function cancelar(orden: Orden) {
    const motivo = (await pedirMotivoDialogo("Motivo auditado de la cancelación:"))?.trim();
    if (!motivo) return;
    const confirmar = orden.estado === "en_proceso"
      ? await confirmarDialogo("Confirma que TODO el material entregado regresó físicamente al almacén. Esta acción reintegrará ese stock.")
      : false;
    if (orden.estado === "en_proceso" && !confirmar) return;
    setProcesando(true); setMsg(null);
    const { error } = await supabase.rpc("cancelar_orden_produccion_v24", {
      p_orden_id: orden.id, p_motivo: motivo,
      p_confirmar_retorno_fisico: confirmar, p_idempotency_key: crypto.randomUUID(),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: "Orden cancelada con trazabilidad." });
    await cargar();
  }

  if (cargando) return <div className="card"><div className="vacio">Cargando órdenes de producción...</div></div>;

  return <>
    <div className="header-row">
      <div><h3 style={{ margin: 0 }}>Órdenes de producción</h3><p className="conteo">Reserva, trabajo en proceso, resultado, merma y costo real.</p></div>
      {puedeOperar && <button onClick={() => { setMostrarNueva(!mostrarNueva); setEntrega(null); setCierre(null); }}>+ Nueva orden</button>}
    </div>
    {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

    {mostrarNueva && <form className="card" onSubmit={crearOrden} style={{ marginBottom: 14 }}>
      <h3>Planificar producción</h3>
      <div className="grid-form">
        <div className="field"><label>Fórmula activa *</label><select required value={formulario.formula_id} onChange={(e) => seleccionarFormula(e.target.value)}><option value="">Seleccionar...</option>{formulas.map((formula) => <option key={formula.id} value={formula.id}>{formula.codigo} · v{formula.version} · {formula.producto?.sku} {formula.producto?.nombre}</option>)}</select></div>
        <div className="field"><label>Empresa / RUC responsable *</label><select required value={formulario.empresa_id} onChange={(e) => seleccionarEmpresa(e.target.value)}><option value="">Seleccionar...</option>{empresasDisponibles.map((empresa) => <option key={empresa.id} value={empresa.id}>{empresa.codigo} · {empresa.razon_social}</option>)}</select></div>
        <div className="field"><label>Almacén de materiales *</label><select required value={formulario.almacen_materiales_id} onChange={(e) => setFormulario({ ...formulario, almacen_materiales_id: e.target.value })}><option value="">Seleccionar...</option>{almacenesDisponibles.map((almacen) => <option key={almacen.id} value={almacen.id}>{almacen.codigo} · {almacen.nombre}</option>)}</select></div>
        <div className="field"><label>Almacén de producto terminado *</label><select required value={formulario.almacen_terminado_id} onChange={(e) => setFormulario({ ...formulario, almacen_terminado_id: e.target.value })}><option value="">Seleccionar...</option>{almacenesDisponibles.map((almacen) => <option key={almacen.id} value={almacen.id}>{almacen.codigo} · {almacen.nombre}</option>)}</select></div>
        <div className="field"><label>Cantidad a producir *</label><input required type="number" min={1} step={1} value={formulario.cantidad_planificada} onChange={(e) => setFormulario({ ...formulario, cantidad_planificada: Math.max(1, Number(e.target.value) || 1) })} /></div>
        <div className="field"><label>Fecha planificada</label><input type="date" value={formulario.fecha_planificada} onChange={(e) => setFormulario({ ...formulario, fecha_planificada: e.target.value })} /></div>
        <div className="field"><label>Prioridad</label><select value={formulario.prioridad} onChange={(e) => setFormulario({ ...formulario, prioridad: e.target.value as "normal" | "urgente" })}><option value="normal">Normal</option><option value="urgente">Urgente</option></select></div>
      </div>
      <div className="field"><label>Nota de planificación</label><textarea rows={2} value={formulario.nota} onChange={(e) => setFormulario({ ...formulario, nota: e.target.value })} /></div>
      <div className="acciones-documento"><button disabled={procesando}>Crear para aprobación</button><button type="button" className="secondary" onClick={() => setMostrarNueva(false)}>Cancelar</button></div>
    </form>}

    <div className="card"><div className="grid-2"><div className="field"><label>Buscar</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Número, fórmula, producto o empresa" /></div><div className="field"><label>Estado</label><select value={estado} onChange={(e) => setEstado(e.target.value)}><option value="">Todos</option>{Object.entries(ESTADO).map(([valor, etiqueta]) => <option key={valor} value={valor}>{etiqueta}</option>)}</select></div></div></div>

    <div className="documentos-grid">{ordenesFiltradas.map((orden) => {
      const editandoEntrega = entrega?.ordenId === orden.id;
      const editandoCierre = cierre?.ordenId === orden.id;
      const etapaActual = orden.etapas.find((etapa) => ["pendiente", "en_proceso"].includes(etapa.estado));
      const etapasCerradas = orden.etapas.length > 0
        && orden.etapas.every((etapa) => ["completada", "omitida"].includes(etapa.estado))
        && orden.etapas.some((etapa) => etapa.estado === "completada");
      const proveedoresOrden = proveedores.filter((proveedor) => proveedorEmpresas.some((asignacion) =>
        asignacion.proveedor_id === proveedor.id && asignacion.empresa_id === orden.empresa_id
      ));
      return <article className="card documento-card" key={orden.id}>
        <div className="header-row"><div><strong>{orden.numero}</strong><div>{orden.resultado?.sku} · {orden.resultado?.nombre}</div></div><span className={`badge ${orden.estado === "completada" ? "ok" : orden.estado === "en_proceso" ? "estado-en_transito" : orden.estado === "pendiente_aprobacion" ? "estado-pendiente_revision" : orden.estado === "aprobada" ? "estado-aprobado" : "cero"}`}>{ESTADO[orden.estado]}</span></div>
        <div className="documento-meta"><span>Empresa: <b>{orden.empresa?.codigo}</b></span><span>Plan: <b>{orden.cantidad_planificada} {orden.resultado?.unidad_medida}</b></span><span>Fórmula: <b>{orden.formula_codigo} v{orden.formula_version}</b></span><span>Materiales: <b>{orden.almacen_materiales?.nombre}</b></span><span>Resultado: <b>{orden.almacen_terminado?.nombre}</b></span><span>Costo estimado: <b>{dinero.format(orden.costo_total_estimado)}</b></span></div>
        <details open={editandoEntrega || editandoCierre}><summary>Materiales y trabajo en proceso</summary><div className="tabla-scroll"><table><thead><tr><th>Material</th><th className="num">Teórico</th><th className="num">Plan base</th><th className="num">Entregado</th><th className="num">WIP</th></tr></thead><tbody>{orden.materiales.map((material) => <tr key={material.id}><td><strong>{material.producto?.sku}</strong><div>{material.producto?.nombre} · {material.unidad_medida}</div></td><td className="num">{material.cantidad_teorica}</td><td className="num">{material.cantidad_planificada}</td><td className="num">{material.cantidad_entregada}</td><td className="num"><strong>{material.cantidad_entregada - material.cantidad_consumida - material.cantidad_merma - material.cantidad_devuelta}</strong></td></tr>)}</tbody></table></div></details>

        <details open={Boolean(etapaEditor && orden.etapas.some((etapa) => etapa.id === etapaEditor.etapaId))}><summary>Ruta y etapas · {orden.ruta_codigo ? `${orden.ruta_codigo} v${orden.ruta_version}` : "Etapa general"} · {orden.etapas.filter((etapa) => etapa.estado === "completada").length}/{orden.etapas.length}</summary>
          {orden.etapas.map((etapa) => { const editando = etapaEditor?.etapaId === etapa.id; return <div key={etapa.id}>
            <div className="pendiente-control"><span><strong>{etapa.secuencia}. {etapa.nombre}</strong><small>{etapa.codigo} · {etapa.modalidad === "maquila" ? "Maquila externa" : etapa.modalidad === "control_calidad" ? "Control de calidad" : "Proceso interno"}{etapa.responsable?.nombre_completo ? ` · ${etapa.responsable.nombre_completo}` : ""}{etapa.proveedor ? ` · ${etapa.proveedor.nombre_comercial ?? etapa.proveedor.razon_social}` : ""}</small></span><div><span className={`badge ${etapa.estado === "completada" ? "ok" : etapa.estado === "en_proceso" ? "estado-en_transito" : etapa.estado === "omitida" ? "cero" : "estado-pendiente_revision"}`}>{ESTADO_ETAPA[etapa.estado]}</span>{puedeOperarEtapa && orden.estado === "en_proceso" && etapaActual?.id === etapa.id && etapa.estado === "pendiente" && <button className="secondary" onClick={() => abrirEtapa(orden, etapa, "iniciar")}>Iniciar</button>}{puedeOperarEtapa && etapa.estado === "en_proceso" && <button onClick={() => abrirEtapa(orden, etapa, "completar")}>Completar</button>}{perfil.rol === "admin" && orden.estado === "en_proceso" && etapaActual?.id === etapa.id && etapa.estado === "pendiente" && <button className="peligro" onClick={() => omitirEtapa(etapa)}>Omitir</button>}</div></div>
            {etapa.instrucciones && <p className="conteo"><strong>Instrucción:</strong> {etapa.instrucciones}</p>}
            {etapa.estado === "completada" && <p className="conteo">Procesado: {etapa.cantidad_procesada} · No conforme detectado: {etapa.cantidad_no_conforme} · Costo real: {dinero.format(etapa.costo_real ?? 0)}{etapa.evidencia_cierre ? ` · ${etapa.evidencia_cierre}` : ""}</p>}
            {editando && etapaEditor && <div className="info-box"><h4>{etapaEditor.accion === "iniciar" ? `Iniciar ${etapa.nombre}` : `Completar ${etapa.nombre}`}</h4>{etapaEditor.accion === "iniciar" ? <div className="grid-form">{etapa.modalidad === "maquila" ? <div className="field"><label>Proveedor de maquila *</label><select value={etapaEditor.proveedorId} onChange={(e) => setEtapaEditor({ ...etapaEditor, proveedorId: e.target.value })}><option value="">Seleccionar...</option>{proveedoresOrden.map((proveedor) => <option key={proveedor.id} value={proveedor.id}>{proveedor.nombre_comercial ?? proveedor.razon_social}</option>)}</select></div> : <div className="field"><label>Responsable interno *</label><select value={etapaEditor.responsablePerfilId} onChange={(e) => setEtapaEditor({ ...etapaEditor, responsablePerfilId: e.target.value })}>{perfiles.map((persona) => <option key={persona.id} value={persona.id}>{persona.nombre_completo} · {persona.rol}</option>)}</select></div>}<div className="field"><label>Nota de inicio</label><input value={etapaEditor.nota} onChange={(e) => setEtapaEditor({ ...etapaEditor, nota: e.target.value })} /></div></div> : <div className="grid-form"><div className="field"><label>Cantidad procesada *</label><input type="number" min={1} max={orden.cantidad_planificada} step={1} value={etapaEditor.cantidadProcesada} onChange={(e) => setEtapaEditor({ ...etapaEditor, cantidadProcesada: Math.max(0, Number(e.target.value) || 0) })} /></div><div className="field"><label>No conforme detectado</label><input type="number" min={0} max={etapaEditor.cantidadProcesada} step={1} value={etapaEditor.cantidadNoConforme} onChange={(e) => setEtapaEditor({ ...etapaEditor, cantidadNoConforme: Math.max(0, Number(e.target.value) || 0) })} /></div><div className="field"><label>Costo real de la etapa</label><input type="number" min={0} step="0.0001" value={etapaEditor.costoReal} onChange={(e) => setEtapaEditor({ ...etapaEditor, costoReal: Math.max(0, Number(e.target.value) || 0) })} /></div><div className="field"><label>Evidencia {etapa.requiere_evidencia ? "*" : ""}</label><input value={etapaEditor.evidencia} onChange={(e) => setEtapaEditor({ ...etapaEditor, evidencia: e.target.value })} placeholder="Acta, lote externo, revisión o novedad" /></div></div>}<div className="acciones-documento"><button disabled={procesando} onClick={() => guardarEtapa(orden, etapa)}>{etapaEditor.accion === "iniciar" ? "Confirmar inicio" : "Cerrar etapa"}</button><button className="secondary" onClick={() => setEtapaEditor(null)}>Cancelar</button></div></div>}
          </div>; })}
        </details>

        {editandoEntrega && entrega && <div className="info-box"><h4>Entregar materiales a proceso</h4>{orden.materiales.map((material) => <div className="pendiente-control" key={material.id}><span><strong>{material.producto?.sku}</strong><small>Plan {material.cantidad_planificada} · ya entregado {material.cantidad_entregada} · {material.unidad_medida}</small></span><input type="number" min={0} step={1} value={entrega.cantidades[material.id] ?? 0} onChange={(e) => setEntrega({ ...entrega, cantidades: { ...entrega.cantidades, [material.id]: Math.max(0, Number(e.target.value) || 0) } })} style={{ width: 100 }} /></div>)}<div className="field"><label>Nota de entrega</label><input value={entrega.nota} onChange={(e) => setEntrega({ ...entrega, nota: e.target.value })} /></div>{puedeResolver && <label className="checkbox-line"><input type="checkbox" checked={entrega.permitirExceso} onChange={(e) => setEntrega({ ...entrega, permitirExceso: e.target.checked })} /> Autorizar entrega superior al plan con justificación</label>}<div className="acciones-documento"><button disabled={procesando} onClick={() => guardarEntrega(orden)}>Confirmar salida a proceso</button><button className="secondary" onClick={() => setEntrega(null)}>Cerrar</button></div></div>}

        {editandoCierre && cierre && <div className="info-box"><h4>Clasificar materiales y resultado</h4><p className="conteo">El sobrante vuelve al almacén. Los costos capturados en cada etapa se suman automáticamente al cierre.</p>{orden.materiales.map((material) => <div className="pendiente-control" key={material.id}><span><strong>{material.producto?.sku}</strong><small>Entregado: {material.cantidad_entregada} {material.unidad_medida}</small></span><label>Consumido <input type="number" min={0} step={1} value={cierre.consumos[material.id] ?? 0} onChange={(e) => setCierre({ ...cierre, consumos: { ...cierre.consumos, [material.id]: Math.max(0, Number(e.target.value) || 0) } })} style={{ width: 85 }} /></label><label>Merma <input type="number" min={0} step={1} value={cierre.mermas[material.id] ?? 0} onChange={(e) => setCierre({ ...cierre, mermas: { ...cierre.mermas, [material.id]: Math.max(0, Number(e.target.value) || 0) } })} style={{ width: 85 }} /></label></div>)}<div className="grid-form"><div className="field"><label>Producto conforme</label><input type="number" min={0} step={1} value={cierre.conforme} onChange={(e) => setCierre({ ...cierre, conforme: Math.max(0, Number(e.target.value) || 0) })} /></div><div className="field"><label>Producto no conforme (cuarentena)</label><input type="number" min={0} step={1} value={cierre.noConforme} onChange={(e) => setCierre({ ...cierre, noConforme: Math.max(0, Number(e.target.value) || 0) })} /></div><div className="field"><label>Mano de obra adicional al costo de etapas</label><input type="number" min={0} step="0.0001" value={cierre.manoObra} onChange={(e) => setCierre({ ...cierre, manoObra: Math.max(0, Number(e.target.value) || 0) })} /></div><div className="field"><label>Indirectos adicionales</label><input type="number" min={0} step="0.0001" value={cierre.indirectos} onChange={(e) => setCierre({ ...cierre, indirectos: Math.max(0, Number(e.target.value) || 0) })} /></div></div><div className="field"><label>Evidencia del cierre *</label><textarea rows={2} value={cierre.nota} onChange={(e) => setCierre({ ...cierre, nota: e.target.value })} /></div><div className="acciones-documento"><button disabled={procesando} onClick={() => finalizar(orden)}>Finalizar e ingresar producción</button><button className="secondary" onClick={() => setCierre(null)}>Cerrar</button></div></div>}

        {orden.estado === "completada" && <div className="success">Resultado: {orden.cantidad_conforme} conforme · {orden.cantidad_no_conforme} en cuarentena · costo unitario real <strong>{dinero.format(orden.costo_unitario_real ?? 0)}</strong>{orden.lote && <> · lote <strong>{orden.lote.codigo}</strong> ({orden.lote.estado_calidad})</>}</div>}
        <div className="acciones-documento">
          {puedeResolver && orden.estado === "pendiente_aprobacion" && <><button onClick={() => resolver(orden, true)}>Aprobar</button><button className="peligro" onClick={() => resolver(orden, false)}>Rechazar</button></>}
          {puedeOperar && ["aprobada", "en_proceso"].includes(orden.estado) && <button className="secondary" onClick={() => abrirEntrega(orden)}>Entregar materiales</button>}
          {puedeOperar && orden.estado === "en_proceso" && etapasCerradas && <button onClick={() => abrirCierre(orden)}>Finalizar producción</button>}
          {puedeOperar && orden.estado === "en_proceso" && !etapasCerradas && <small>Completa las etapas antes del cierre final</small>}
          {puedeResolver && ["pendiente_aprobacion", "aprobada"].includes(orden.estado) && <button className="peligro" onClick={() => cancelar(orden)}>Cancelar</button>}
          {perfil.rol === "admin" && orden.estado === "en_proceso" && <button className="peligro" onClick={() => cancelar(orden)}>Cancelar y retornar todo</button>}
        </div>
      </article>;
    })}{!ordenesFiltradas.length && <div className="card"><div className="vacio">No hay órdenes con estos filtros.</div></div>}</div>
  </>;
}
