"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { confirmarDialogo, mostrarAvisoDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { tienePermiso, type Perfil } from "@/lib/permisos";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Empresa = { id: string; grupo_id: string; codigo: string; razon_social: string };
type Orden = {
  orden_id: string; numero: string; empresa_id: string; producto_resultado_id: string;
  resultado_sku: string; resultado_producto: string; estado: string; lote_codigo: string | null;
};
type Etapa = { id: string; orden_id: string; secuencia: number; nombre: string; estado: string };
type Producto = { id: string; sku: string; nombre: string };
type PerfilOperativo = { id: string; grupo_id: string | null; nombre_completo: string };
type Proveedor = { id: string; grupo_id: string; razon_social: string; nombre_comercial: string | null };
type ProveedorEmpresa = { proveedor_id: string; empresa_id: string };
type Empleado = { id: string; identificacion: string; nombre_completo: string };
type ResponsableDescuento = {
  novedad_id: string; empleado_id: string; orden: number;
  monto_solicitado: number; novedad_empleado_id: string | null;
};
type Evidencia = {
  id: string; novedad_id: string; nombre: string; referencia: string;
  descripcion: string | null; created_at: string;
};
type Novedad = {
  id: string; grupo_id: string; empresa_id: string; codigo: string;
  orden_id: string | null; orden_numero: string | null;
  etapa_id: string | null; etapa_secuencia: number | null; etapa_nombre: string | null;
  lote_id: string | null; lote_codigo: string | null;
  producto_id: string | null; sku: string | null; producto: string | null;
  pedido_referencia: string | null; formato: string; origen: string; prioridad: string;
  tipo: string; fecha_hora: string; descripcion: string; cantidad_afectada: number;
  accion_inmediata: string | null; responsable_perfil_id: string | null;
  responsable_interno: string | null; responsable_proveedor_id: string | null;
  responsable_externo: string | null; empleado_responsable_id: string | null;
  estado: string; causa_raiz: string | null; accion_correctiva: string | null;
  disposicion: string | null; costo_estimado: number; costo_real: number | null;
  solicita_descuento: boolean; monto_descuento_solicitado: number | null;
  motivo_descuento: string | null; novedad_empleado_id: string | null;
  novedad_laboral_estado: string | null; descuento_id: string | null;
  descuento_estado: string | null; descuento_saldo: number | null;
  evidencias: number; empresa_codigo: string; empresa: string;
  registrado_por_nombre: string; cerrado_at: string | null; motivo_anulacion: string | null;
  created_at: string; updated_at: string;
};
type FormRegistro = {
  empresaId: string; fechaHora: string; prioridad: string; origen: string; tipo: string;
  ordenId: string; etapaId: string; productoId: string; pedido: string; formato: string;
  cantidad: string; descripcion: string; accionInmediata: string;
  responsableTipo: "ninguno" | "interno" | "proveedor";
  responsablePerfilId: string; responsableProveedorId: string; costoEstimado: string;
  solicitaDescuento: boolean; empleadoIds: string[]; montoDescuento: string; motivoDescuento: string;
};
type FormResolucion = {
  estado: string; causaRaiz: string; accionCorrectiva: string; disposicion: string;
  costoReal: string; detalle: string; solicitaDescuento: boolean;
  empleadoIds: string[]; montoDescuento: string; motivoDescuento: string;
};

const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const ESTADOS: Record<string, string> = {
  abierta: "Abierta", en_analisis: "En análisis", accion_correctiva: "Acción correctiva",
  cerrada: "Cerrada", anulada: "Anulada",
};
const ORIGENES: [string, string][] = [
  ["produccion_interna", "Producción interna"], ["maquila_externa", "Maquila externa"],
  ["devolucion_cliente", "Devolución de cliente"], ["bodega", "Bodega"],
  ["control_calidad", "Control de calidad"], ["otro", "Otro"],
];
const TIPOS: [string, string][] = [
  ["error_corte", "Error de corte"], ["error_costura", "Error de costura"],
  ["error_estampado_sublimacion", "Estampado / sublimación"], ["error_diseno", "Error de diseño"],
  ["error_sello_tpu_dtf", "Sello / TPU / DTF"], ["reclamo_cliente", "Reclamo de cliente"],
  ["falla_maquila_externa", "Falla de maquila externa"], ["error_ingreso_contrato", "Error al ingresar contrato"],
  ["material_defectuoso", "Material defectuoso"], ["falla_maquinaria", "Falla de maquinaria"],
  ["otro", "Otro"],
];
const DISPOSICIONES: [string, string][] = [
  ["reproceso", "Reproceso"], ["reemplazo", "Reemplazo"], ["desecho", "Desecho"],
  ["devolucion_proveedor", "Devolución al proveedor"], ["aceptado_concesion", "Aceptado con concesión"],
  ["sin_afectacion", "Sin afectación"],
];

function etiqueta(opciones: [string, string][], valor: string) {
  return opciones.find(([id]) => id === valor)?.[1] ?? valor.replaceAll("_", " ");
}
function fechaHoraEcuadorInput() {
  const partes = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Guayaquil", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date());
  const valor = Object.fromEntries(partes.map((parte) => [parte.type, parte.value]));
  return `${valor.year}-${valor.month}-${valor.day}T${valor.hour}:${valor.minute}`;
}
function fechaHoraVisible(valor: string) {
  return new Intl.DateTimeFormat("es-EC", {
    timeZone: "America/Guayaquil", dateStyle: "medium", timeStyle: "short",
  }).format(new Date(valor));
}
function nuevoRegistro(empresaId = ""): FormRegistro {
  return {
    empresaId, fechaHora: fechaHoraEcuadorInput(), prioridad: "normal",
    origen: "produccion_interna", tipo: "error_costura", ordenId: "", etapaId: "",
    productoId: "", pedido: "", formato: "no_aplica", cantidad: "1", descripcion: "",
    accionInmediata: "", responsableTipo: "ninguno", responsablePerfilId: "",
    responsableProveedorId: "", costoEstimado: "0", solicitaDescuento: false,
    empleadoIds: [], montoDescuento: "", motivoDescuento: "",
  };
}

function repartirMonto(monto: string, ids: string[]) {
  const centavos = Math.round(Number(monto) * 100);
  if (!Number.isFinite(centavos) || centavos <= 0 || ids.length === 0) return [];
  const base = Math.floor(centavos / ids.length);
  const sobrantes = centavos % ids.length;
  return ids.map((id, indice) => ({ id, monto: (base + (indice < sobrantes ? 1 : 0)) / 100 }));
}

function SelectorEmpleados({ empleados, seleccionados, onChange }: {
  empleados: Empleado[]; seleccionados: string[]; onChange: (ids: string[]) => void;
}) {
  const [busqueda, setBusqueda] = useState("");
  const q = busqueda.trim().toLocaleLowerCase("es");
  const visibles = empleados.filter((item) => !q || `${item.identificacion} ${item.nombre_completo}`.toLocaleLowerCase("es").includes(q));
  function alternar(id: string) {
    onChange(seleccionados.includes(id)
      ? seleccionados.filter((actual) => actual !== id)
      : [...seleccionados, id]);
  }
  return <div className="calidad-selector-empleados">
    <div className="calidad-selector-cabecera"><strong>Personas relacionadas *</strong><span>{seleccionados.length} seleccionada{seleccionados.length === 1 ? "" : "s"}</span></div>
    <input type="search" value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Buscar por nombre o identificación" />
    <div className="calidad-empleados-lista">
      {visibles.map((item) => <label key={item.id} className={seleccionados.includes(item.id) ? "seleccionado" : ""}>
        <input type="checkbox" checked={seleccionados.includes(item.id)} onChange={() => alternar(item.id)} />
        <span><strong>{item.nombre_completo}</strong><small>{item.identificacion}</small></span>
      </label>)}
      {visibles.length === 0 && <p className="conteo">No hay coincidencias.</p>}
    </div>
  </div>;
}

function ResumenReparto({ monto, ids, empleados }: { monto: string; ids: string[]; empleados: Empleado[] }) {
  const reparto = repartirMonto(monto, ids);
  if (!reparto.length) return null;
  return <div className="calidad-reparto ancho-total">
    <strong>Distribución del total</strong>
    {reparto.map((item) => <span key={item.id}><b>{empleados.find((empleado) => empleado.id === item.id)?.nombre_completo ?? "Empleado"}</b><em>{DINERO.format(item.monto)}</em></span>)}
  </div>;
}

export default function NovedadesCalidadCliente({ perfil }: { perfil: Perfil }) {
  const supabase = useMemo(() => createClient(), []);
  const puedeRegistrar = tienePermiso(perfil, "produccion.calidad.registrar");
  const puedeResolver = tienePermiso(perfil, "produccion.calidad.resolver");
  const puedeDerivar = tienePermiso(perfil, "produccion.calidad.descuento");
  const [novedades, setNovedades] = useState<Novedad[]>([]);
  const [evidencias, setEvidencias] = useState<Evidencia[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [ordenes, setOrdenes] = useState<Orden[]>([]);
  const [etapas, setEtapas] = useState<Etapa[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [perfiles, setPerfiles] = useState<PerfilOperativo[]>([]);
  const [proveedores, setProveedores] = useState<Proveedor[]>([]);
  const [proveedorEmpresas, setProveedorEmpresas] = useState<ProveedorEmpresa[]>([]);
  const [empleados, setEmpleados] = useState<Empleado[]>([]);
  const [responsablesDescuento, setResponsablesDescuento] = useState<ResponsableDescuento[]>([]);
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [busqueda, setBusqueda] = useState("");
  const [estado, setEstado] = useState("");
  const [empresaFiltro, setEmpresaFiltro] = useState("");
  const [abiertaId, setAbiertaId] = useState<string | null>(null);
  const [registrando, setRegistrando] = useState(false);
  const [formRegistro, setFormRegistro] = useState<FormRegistro>(nuevoRegistro());
  const [resolviendo, setResolviendo] = useState<Novedad | null>(null);
  const [formResolucion, setFormResolucion] = useState<FormResolucion | null>(null);
  const [evidenciando, setEvidenciando] = useState<Novedad | null>(null);
  const [formEvidencia, setFormEvidencia] = useState({ nombre: "", referencia: "", descripcion: "" });
  const [derivando, setDerivando] = useState<Novedad | null>(null);
  const [formDerivacion, setFormDerivacion] = useState({ empresaId: "", reglamento: "", baseLegal: "" });

  function avisarError(texto: string, titulo = "Revisa la información") {
    setError(null);
    void mostrarAvisoDialogo(texto, titulo, true);
  }

  async function cargar() {
    setCargando(true); setError(null);
    const consultas = await Promise.all([
      supabase.from("vista_novedades_calidad_v74").select("*").order("fecha_hora", { ascending: false }).limit(1000),
      supabase.from("novedad_calidad_evidencias").select("id,novedad_id,nombre,referencia,descripcion,created_at").order("created_at", { ascending: false }).limit(3000),
      supabase.from("empresas").select("id,grupo_id,codigo,razon_social").eq("activo", true).order("codigo"),
      supabase.from("vista_seguimiento_produccion_v25").select("orden_id,numero,empresa_id,producto_resultado_id,resultado_sku,resultado_producto,estado,lote_codigo").order("created_at", { ascending: false }).limit(1000),
      supabase.from("orden_produccion_etapas").select("id,orden_id,secuencia,nombre,estado").order("secuencia").limit(5000),
      supabase.from("productos").select("id,sku,nombre").eq("activo", true).order("sku").limit(3000),
      supabase.from("perfiles").select("id,grupo_id,nombre_completo").eq("activo", true).order("nombre_completo"),
      supabase.from("proveedores").select("id,grupo_id,razon_social,nombre_comercial").eq("activo", true).order("razon_social"),
      supabase.from("proveedor_empresas").select("proveedor_id,empresa_id").eq("activo", true),
      supabase.rpc("listar_empleados_calidad_v74"),
      supabase.from("novedad_calidad_responsables_v144").select("novedad_id,empleado_id,orden,monto_solicitado,novedad_empleado_id").order("orden"),
    ]);
    setCargando(false);
    const fallo = consultas.find((consulta) => consulta.error)?.error;
    if (fallo) return setError(`No se pudo cargar Calidad. Instala las migraciones v74 y v144 y revisa sus permisos: ${fallo.message}`);
    setNovedades((consultas[0].data ?? []) as Novedad[]);
    setEvidencias((consultas[1].data ?? []) as Evidencia[]);
    const empresasData = (consultas[2].data ?? []) as Empresa[];
    setEmpresas(empresasData); setOrdenes((consultas[3].data ?? []) as Orden[]);
    setEtapas((consultas[4].data ?? []) as Etapa[]); setProductos((consultas[5].data ?? []) as Producto[]);
    setPerfiles((consultas[6].data ?? []) as PerfilOperativo[]); setProveedores((consultas[7].data ?? []) as Proveedor[]);
    setProveedorEmpresas((consultas[8].data ?? []) as ProveedorEmpresa[]); setEmpleados((consultas[9].data ?? []) as Empleado[]);
    setResponsablesDescuento((consultas[10].data ?? []) as ResponsableDescuento[]);
    setFormRegistro((actual) => ({ ...actual, empresaId: actual.empresaId || empresasData[0]?.id || "" }));
  }

  useEffect(() => { cargar(); }, []);

  const novedadesFiltradas = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    return novedades.filter((novedad) => (!estado || novedad.estado === estado)
      && (!empresaFiltro || novedad.empresa_id === empresaFiltro)
      && (!q || [novedad.codigo, novedad.orden_numero, novedad.pedido_referencia,
        novedad.sku, novedad.producto, novedad.descripcion, novedad.responsable_interno,
        novedad.responsable_externo].some((valor) => valor?.toLocaleLowerCase("es").includes(q))));
  }, [busqueda, empresaFiltro, estado, novedades]);

  const kpis = useMemo(() => novedadesFiltradas.reduce((total, novedad) => {
    if (!["cerrada", "anulada"].includes(novedad.estado)) total.abiertas += 1;
    if (novedad.prioridad === "urgente" && !["cerrada", "anulada"].includes(novedad.estado)) total.urgentes += 1;
    if (novedad.solicita_descuento && !responsablesDescuento.some((item) => item.novedad_id === novedad.id && item.novedad_empleado_id) && novedad.estado === "cerrada") total.descuentos += 1;
    if (novedad.estado !== "anulada") total.unidades += Number(novedad.cantidad_afectada);
    total.costo += Number(novedad.costo_real ?? novedad.costo_estimado ?? 0);
    return total;
  }, { abiertas: 0, urgentes: 0, descuentos: 0, unidades: 0, costo: 0 }), [novedadesFiltradas, responsablesDescuento]);

  const ordenesEmpresa = ordenes.filter((orden) => orden.empresa_id === formRegistro.empresaId);
  const etapasOrden = etapas.filter((etapa) => etapa.orden_id === formRegistro.ordenId);
  const empresaRegistro = empresas.find((empresa) => empresa.id === formRegistro.empresaId);
  const responsablesInternos = perfiles.filter((item) => !empresaRegistro || item.grupo_id === empresaRegistro.grupo_id);
  const idsProveedoresEmpresa = new Set(proveedorEmpresas.filter((item) => item.empresa_id === formRegistro.empresaId).map((item) => item.proveedor_id));
  const proveedoresEmpresa = proveedores.filter((item) => idsProveedoresEmpresa.has(item.id));

  function cambiarRegistro(cambio: Partial<FormRegistro>) {
    setFormRegistro((actual) => ({ ...actual, ...cambio }));
  }
  function seleccionarOrden(ordenId: string) {
    const orden = ordenes.find((item) => item.orden_id === ordenId);
    cambiarRegistro({ ordenId, etapaId: "", productoId: orden?.producto_resultado_id ?? formRegistro.productoId });
  }
  function abrirRegistro() {
    setFormRegistro(nuevoRegistro(empresas[0]?.id ?? "")); setRegistrando(true); setError(null); setMensaje(null);
  }

  async function guardarRegistro(evento: React.FormEvent) {
    evento.preventDefault();
    const cantidad = Number(formRegistro.cantidad); const costo = Number(formRegistro.costoEstimado || 0);
    if (!formRegistro.empresaId) return avisarError("Selecciona la compañía responsable.");
    if (!formRegistro.ordenId && !formRegistro.productoId && !formRegistro.pedido.trim()) return avisarError("Relaciona la novedad con una orden, producto o pedido.");
    if (!Number.isInteger(cantidad) || cantidad <= 0) return avisarError("La cantidad afectada debe ser un entero mayor que cero.");
    if (!Number.isFinite(costo) || costo < 0) return avisarError("Revisa el costo estimado.");
    if (formRegistro.descripcion.trim().length < 10) return avisarError("Describe claramente el error con al menos 10 caracteres.");
    if (formRegistro.solicitaDescuento && (formRegistro.empleadoIds.length === 0 || !Number.isFinite(Number(formRegistro.montoDescuento)) || Number(formRegistro.montoDescuento) < formRegistro.empleadoIds.length / 100 || formRegistro.motivoDescuento.trim().length < 10)) return avisarError("Selecciona al menos una persona, registra un total que permita asignar $0,01 a cada una y escribe una justificación de al menos 10 caracteres.");
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("registrar_novedad_calidad_v144", {
      p_datos: {
        empresa_id: formRegistro.empresaId, fecha_hora: `${formRegistro.fechaHora}:00-05:00`,
        prioridad: formRegistro.prioridad, origen: formRegistro.origen, tipo: formRegistro.tipo,
        orden_id: formRegistro.ordenId || null, etapa_id: formRegistro.etapaId || null,
        producto_id: formRegistro.productoId || null, pedido_referencia: formRegistro.pedido.trim() || null,
        formato: formRegistro.formato, cantidad_afectada: cantidad, descripcion: formRegistro.descripcion.trim(),
        accion_inmediata: formRegistro.accionInmediata.trim() || null,
        responsable_perfil_id: formRegistro.responsableTipo === "interno" ? formRegistro.responsablePerfilId || null : null,
        responsable_proveedor_id: formRegistro.responsableTipo === "proveedor" ? formRegistro.responsableProveedorId || null : null,
        costo_estimado: costo, solicita_descuento: formRegistro.solicitaDescuento,
        empleados_responsables_ids: formRegistro.solicitaDescuento ? formRegistro.empleadoIds : [],
        monto_descuento_solicitado: formRegistro.solicitaDescuento ? Number(formRegistro.montoDescuento) : null,
        motivo_descuento: formRegistro.solicitaDescuento ? formRegistro.motivoDescuento.trim() : null,
      },
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return avisarError(rpcError.message, "No se pudo registrar la falla");
    setRegistrando(false); setMensaje("Novedad registrada y numerada con trazabilidad."); await cargar();
  }

  function abrirResolucion(novedad: Novedad) {
    setResolviendo(novedad); setError(null);
    setFormResolucion({
      estado: novedad.estado === "abierta" ? "en_analisis" : novedad.estado,
      causaRaiz: novedad.causa_raiz ?? "", accionCorrectiva: novedad.accion_correctiva ?? "",
      disposicion: novedad.disposicion ?? "", costoReal: novedad.costo_real == null ? "" : String(novedad.costo_real),
      detalle: "", solicitaDescuento: novedad.solicita_descuento,
      empleadoIds: (() => {
        const ids = responsablesDescuento.filter((item) => item.novedad_id === novedad.id).sort((a, b) => a.orden - b.orden).map((item) => item.empleado_id);
        return ids.length ? ids : novedad.empleado_responsable_id ? [novedad.empleado_responsable_id] : [];
      })(),
      montoDescuento: novedad.monto_descuento_solicitado == null ? "" : String(novedad.monto_descuento_solicitado),
      motivoDescuento: novedad.motivo_descuento ?? "",
    });
  }

  async function guardarResolucion(evento: React.FormEvent) {
    evento.preventDefault(); if (!resolviendo || !formResolucion) return;
    if (formResolucion.estado === "cerrada" && (formResolucion.causaRaiz.trim().length < 10 || formResolucion.accionCorrectiva.trim().length < 10 || !formResolucion.disposicion || formResolucion.costoReal === "")) return avisarError("Para cerrar registra causa raíz, acción correctiva, disposición y costo real.");
    if (formResolucion.costoReal !== "" && Number(formResolucion.costoReal) < 0) return avisarError("El costo real no puede ser negativo.");
    if (formResolucion.solicitaDescuento && (formResolucion.empleadoIds.length === 0 || !Number.isFinite(Number(formResolucion.montoDescuento)) || Number(formResolucion.montoDescuento) < formResolucion.empleadoIds.length / 100 || formResolucion.motivoDescuento.trim().length < 10)) return avisarError("Selecciona al menos una persona, registra un total que permita asignar $0,01 a cada una y escribe una justificación de al menos 10 caracteres.");
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("resolver_novedad_calidad_v144", {
      p_novedad_id: resolviendo.id,
      p_datos: {
        estado: formResolucion.estado, causa_raiz: formResolucion.causaRaiz.trim() || null,
        accion_correctiva: formResolucion.accionCorrectiva.trim() || null,
        disposicion: formResolucion.disposicion || null,
        costo_real: formResolucion.costoReal === "" ? null : Number(formResolucion.costoReal),
        detalle: formResolucion.detalle.trim() || "Análisis de calidad actualizado",
        solicita_descuento: formResolucion.solicitaDescuento,
        empleados_responsables_ids: formResolucion.solicitaDescuento ? formResolucion.empleadoIds : [],
        monto_descuento_solicitado: formResolucion.solicitaDescuento ? Number(formResolucion.montoDescuento) : null,
        motivo_descuento: formResolucion.solicitaDescuento ? formResolucion.motivoDescuento.trim() : null,
      },
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return avisarError(rpcError.message, "No se pudo actualizar la falla");
    setResolviendo(null); setFormResolucion(null); setMensaje("Análisis de calidad actualizado."); await cargar();
  }

  async function guardarEvidencia(evento: React.FormEvent) {
    evento.preventDefault(); if (!evidenciando) return;
    if (formEvidencia.nombre.trim().length < 3 || formEvidencia.referencia.trim().length < 5) return avisarError("Indica un nombre y una referencia verificable.");
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("agregar_evidencia_calidad_v74", {
      p_novedad_id: evidenciando.id, p_nombre: formEvidencia.nombre.trim(),
      p_referencia: formEvidencia.referencia.trim(), p_descripcion: formEvidencia.descripcion.trim() || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return avisarError(rpcError.message, "No se pudo agregar la evidencia");
    setEvidenciando(null); setFormEvidencia({ nombre: "", referencia: "", descripcion: "" });
    setMensaje("Evidencia vinculada a la novedad."); await cargar();
  }

  async function anular(novedad: Novedad) {
    if (!await confirmarDialogo(`¿Anular ${novedad.codigo}? El registro quedará visible en la auditoría.`)) return;
    const motivo = (await pedirMotivoDialogo(
      "Explica por qué este registro no corresponde.", 10, "Motivo de anulación"
    ))?.trim();
    if (!motivo) return;
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("anular_novedad_calidad_v74", {
      p_novedad_id: novedad.id, p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return avisarError(rpcError.message, "No se pudo anular la falla");
    setMensaje(`${novedad.codigo} fue anulada sin eliminar su trazabilidad.`); await cargar();
  }

  function abrirDerivacion(novedad: Novedad) {
    setDerivando(novedad); setError(null);
    setFormDerivacion({ empresaId: novedad.empresa_id, reglamento: "", baseLegal: "" });
  }
  async function derivarNomina(evento: React.FormEvent) {
    evento.preventDefault(); if (!derivando) return;
    if (!formDerivacion.empresaId || formDerivacion.reglamento.trim().length < 5) return avisarError("Selecciona la empresa emisora e indica la disposición del reglamento interno.");
    setProcesando(true); setError(null); setMensaje(null);
    const { error: rpcError } = await supabase.rpc("generar_novedades_laborales_calidad_v144", {
      p_novedad_id: derivando.id, p_empresa_emisora_id: formDerivacion.empresaId,
      p_base_reglamento: formDerivacion.reglamento.trim(), p_base_legal: formDerivacion.baseLegal.trim() || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (rpcError) return avisarError(rpcError.message, "No se pudieron crear los expedientes");
    setDerivando(null); setMensaje("Se creó un borrador disciplinario por cada persona; aún no se ha descontado ningún valor."); await cargar();
  }

  function exportar() {
    exportarCSV("novedades_calidad", novedadesFiltradas.map((novedad) => ({
      Codigo: novedad.codigo, Fecha: fechaHoraVisible(novedad.fecha_hora), Empresa: novedad.empresa_codigo,
      Orden: novedad.orden_numero ?? "", Pedido: novedad.pedido_referencia ?? "",
      Producto: novedad.sku ?? "", Tipo: etiqueta(TIPOS, novedad.tipo), Origen: etiqueta(ORIGENES, novedad.origen),
      Prioridad: novedad.prioridad, Estado: ESTADOS[novedad.estado], Unidades: novedad.cantidad_afectada,
      Descripcion: novedad.descripcion, Costo: novedad.costo_real ?? novedad.costo_estimado,
      Solicita_descuento: novedad.solicita_descuento ? "Si" : "No",
      Monto_solicitado: novedad.monto_descuento_solicitado ?? "",
      Personas_relacionadas: responsablesDescuento.filter((item) => item.novedad_id === novedad.id).map((item) => empleados.find((empleado) => empleado.id === item.empleado_id)?.nombre_completo ?? item.empleado_id).join(" | "),
      Estado_laboral: novedad.novedad_laboral_estado ?? "",
    })));
  }

  return <section className="calidad-page">
    <div className="header-row calidad-header">
      <div><span className="modulo-kicker">PRODUCCIÓN · CONTROL DE CALIDAD</span><h1>Novedades de calidad</h1><p className="conteo">Errores, reclamos, reprocesos, evidencia, causa raíz y seguimiento.</p></div>
      <div className="acciones"><button type="button" className="secondary" onClick={exportar}>Exportar</button>{puedeRegistrar && <button type="button" onClick={abrirRegistro}>Nueva novedad</button>}</div>
    </div>

    <div className="info-box calidad-aviso"><strong>Un error no genera un descuento automático.</strong><span>Calidad documenta y cierra el caso; Administración o Nómina abre el expediente formal, respeta el descargo y recién después aplica los topes del rol.</span></div>
    {error && <div className="error-box">{error}</div>}{mensaje && <div className="success-box">{mensaje}</div>}

    <div className="kpis calidad-kpis">
      <div className="kpi"><span className="label">Casos abiertos</span><strong className="valor">{kpis.abiertas}</strong></div>
      <div className={`kpi ${kpis.urgentes ? "alerta" : "ok"}`}><span className="label">Urgentes abiertos</span><strong className="valor">{kpis.urgentes}</strong></div>
      <div className="kpi"><span className="label">Unidades afectadas</span><strong className="valor">{kpis.unidades}</strong></div>
      <div className="kpi"><span className="label">Costo registrado</span><strong className="valor">{DINERO.format(kpis.costo)}</strong></div>
      <div className={`kpi ${kpis.descuentos ? "alerta" : "ok"}`}><span className="label">Por derivar a Nómina</span><strong className="valor">{kpis.descuentos}</strong></div>
    </div>

    <div className="filtros calidad-filtros">
      <div className="field buscador"><label>Buscar</label><input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Código, orden, pedido, producto o detalle" /></div>
      <div className="field"><label>Estado</label><select value={estado} onChange={(e) => setEstado(e.target.value)}><option value="">Todos</option>{Object.entries(ESTADOS).map(([id, nombre]) => <option value={id} key={id}>{nombre}</option>)}</select></div>
      <div className="field"><label>Compañía</label><select value={empresaFiltro} onChange={(e) => setEmpresaFiltro(e.target.value)}><option value="">Todas</option>{empresas.map((empresa) => <option value={empresa.id} key={empresa.id}>{empresa.codigo}</option>)}</select></div>
      {(busqueda || estado || empresaFiltro) && <button type="button" className="chip-limpiar" onClick={() => { setBusqueda(""); setEstado(""); setEmpresaFiltro(""); }}>Limpiar</button>}
    </div>

    {cargando ? <div className="vacio">Cargando novedades…</div> : !novedadesFiltradas.length ? <div className="vacio card">No hay novedades con estos filtros.</div> : <div className="calidad-lista">{novedadesFiltradas.map((novedad) => {
      const abierta = abiertaId === novedad.id;
      const evidenciaCaso = evidencias.filter((item) => item.novedad_id === novedad.id);
      const responsablesCaso = responsablesDescuento.filter((item) => item.novedad_id === novedad.id).sort((a, b) => a.orden - b.orden);
      const expedientesCreados = responsablesCaso.filter((item) => item.novedad_empleado_id).length;
      return <article className={`calidad-caso estado-${novedad.estado} prioridad-${novedad.prioridad}`} key={novedad.id}>
        <button type="button" className="calidad-resumen" onClick={() => setAbiertaId(abierta ? null : novedad.id)}>
          <span><strong>{novedad.codigo}</strong><small>{fechaHoraVisible(novedad.fecha_hora)} · {novedad.empresa_codigo}</small></span>
          <span><small>Tipo</small><strong>{etiqueta(TIPOS, novedad.tipo)}</strong></span>
          <span><small>Referencia</small><strong>{novedad.orden_numero ?? novedad.pedido_referencia ?? novedad.sku ?? "—"}</strong></span>
          <span><small>Afectación</small><strong>{novedad.cantidad_afectada} u. · {DINERO.format(Number(novedad.costo_real ?? novedad.costo_estimado))}</strong></span>
          <span className={`badge calidad-estado-${novedad.estado}`}>{ESTADOS[novedad.estado]}</span>
          {novedad.prioridad === "urgente" && <span className="badge calidad-urgente">Urgente</span>}
          <b aria-hidden="true">{abierta ? "⌃" : "⌄"}</b>
        </button>
        {abierta && <div className="calidad-detalle">
          <div className="calidad-datos">
            <div><span>Origen</span><strong>{etiqueta(ORIGENES, novedad.origen)}</strong></div>
            <div><span>Producto</span><strong>{novedad.sku ? `${novedad.sku} · ${novedad.producto}` : "—"}</strong></div>
            <div><span>Etapa / lote</span><strong>{novedad.etapa_nombre ?? "—"}{novedad.lote_codigo ? ` · ${novedad.lote_codigo}` : ""}</strong></div>
            <div><span>Formato</span><strong>{novedad.formato === "no_aplica" ? "No aplica" : novedad.formato}</strong></div>
            <div><span>Responsable operativo</span><strong>{novedad.responsable_interno ?? novedad.responsable_externo ?? "Sin asignar"}</strong></div>
            <div><span>Evidencias</span><strong>{novedad.evidencias}</strong></div>
          </div>
          <div className="calidad-relato"><span>Descripción del error</span><p>{novedad.descripcion}</p>{novedad.accion_inmediata && <><span>Acción inmediata</span><p>{novedad.accion_inmediata}</p></>}{novedad.causa_raiz && <><span>Causa raíz</span><p>{novedad.causa_raiz}</p></>}{novedad.accion_correctiva && <><span>Acción correctiva</span><p>{novedad.accion_correctiva}</p></>}</div>
          {evidenciaCaso.length > 0 && <div className="calidad-evidencias"><strong>Evidencia</strong>{evidenciaCaso.map((item) => <a href={item.referencia} target="_blank" rel="noreferrer" key={item.id}><span>{item.nombre}</span><small>{item.descripcion ?? item.referencia}</small></a>)}</div>}
          {novedad.solicita_descuento && <div className="calidad-descuento"><strong>Solicitud total: {DINERO.format(Number(novedad.monto_descuento_solicitado ?? 0))}</strong><span>{novedad.motivo_descuento}</span><div className="calidad-responsables-resumen">{responsablesCaso.map((item) => <span key={item.empleado_id}><b>{empleados.find((empleado) => empleado.id === item.empleado_id)?.nombre_completo ?? "Empleado"}</b><em>{DINERO.format(Number(item.monto_solicitado))}</em></span>)}</div><b>{expedientesCreados > 0 ? `${expedientesCreados} expediente${expedientesCreados === 1 ? "" : "s"} creado${expedientesCreados === 1 ? "" : "s"} en Nómina` : novedad.estado === "cerrada" ? "Lista para revisión de Nómina" : "Pendiente de cerrar el análisis"}</b></div>}
          {novedad.motivo_anulacion && <div className="error-box">Anulada: {novedad.motivo_anulacion}</div>}
          <div className="acciones calidad-acciones">
            {novedad.estado !== "anulada" && (puedeRegistrar || puedeResolver) && <button type="button" className="secondary" onClick={() => { setEvidenciando(novedad); setFormEvidencia({ nombre: "", referencia: "", descripcion: "" }); }}>Agregar evidencia</button>}
            {puedeResolver && !["cerrada", "anulada"].includes(novedad.estado) && <button type="button" onClick={() => abrirResolucion(novedad)}>Analizar / resolver</button>}
            {puedeDerivar && novedad.estado === "cerrada" && novedad.solicita_descuento && expedientesCreados === 0 && <button type="button" className="advertencia" onClick={() => abrirDerivacion(novedad)}>Enviar {responsablesCaso.length || 1} a Nómina</button>}
            {expedientesCreados > 0 && <Link className="btn-enlace" href="/nomina">Abrir expedientes laborales</Link>}
            {puedeResolver && !["cerrada", "anulada"].includes(novedad.estado) && <button type="button" className="peligro-inline" disabled={procesando} onClick={() => anular(novedad)}>Anular</button>}
          </div>
        </div>}
      </article>;
    })}</div>}

    {registrando && <div className="modal-operativo" onMouseDown={(e) => { if (e.target === e.currentTarget) setRegistrando(false); }}><form className="modal-contenido ancho calidad-modal" onSubmit={guardarRegistro}><div className="header-row"><div><h2>Nueva novedad de calidad</h2><p className="conteo">Registro digital de error, reclamo o reparación.</p></div><button type="button" className="secondary" onClick={() => setRegistrando(false)}>Cerrar</button></div>{error && <div className="error-box">{error}</div>}
      <div className="grid-form">
        <div className="field"><label>Compañía *</label><select value={formRegistro.empresaId} onChange={(e) => cambiarRegistro({ empresaId: e.target.value, ordenId: "", etapaId: "" })}><option value="">Selecciona…</option>{empresas.map((item) => <option value={item.id} key={item.id}>{item.codigo} · {item.razon_social}</option>)}</select></div>
        <div className="field"><label>Fecha y hora del hecho *</label><input type="datetime-local" max={fechaHoraEcuadorInput()} value={formRegistro.fechaHora} onChange={(e) => cambiarRegistro({ fechaHora: e.target.value })} /></div>
        <div className="field"><label>Prioridad</label><select value={formRegistro.prioridad} onChange={(e) => cambiarRegistro({ prioridad: e.target.value })}><option value="normal">Normal</option><option value="urgente">Urgente</option></select></div>
        <div className="field"><label>Origen *</label><select value={formRegistro.origen} onChange={(e) => cambiarRegistro({ origen: e.target.value })}>{ORIGENES.map(([id, nombre]) => <option value={id} key={id}>{nombre}</option>)}</select></div>
        <div className="field"><label>Tipo de error *</label><select value={formRegistro.tipo} onChange={(e) => cambiarRegistro({ tipo: e.target.value })}>{TIPOS.map(([id, nombre]) => <option value={id} key={id}>{nombre}</option>)}</select></div>
        <div className="field"><label>Formato de prenda</label><select value={formRegistro.formato} onChange={(e) => cambiarRegistro({ formato: e.target.value })}><option value="no_aplica">No aplica</option><option value="anterior">Formato anterior</option><option value="nuevo">Formato nuevo</option></select></div>
        <div className="field"><label>Orden de producción</label><select value={formRegistro.ordenId} onChange={(e) => seleccionarOrden(e.target.value)}><option value="">Sin orden</option>{ordenesEmpresa.map((item) => <option value={item.orden_id} key={item.orden_id}>{item.numero} · {item.resultado_sku} · {item.resultado_producto}</option>)}</select></div>
        <div className="field"><label>Etapa</label><select value={formRegistro.etapaId} disabled={!formRegistro.ordenId} onChange={(e) => cambiarRegistro({ etapaId: e.target.value })}><option value="">Sin etapa</option>{etapasOrden.map((item) => <option value={item.id} key={item.id}>{item.secuencia}. {item.nombre} · {item.estado.replaceAll("_", " ")}</option>)}</select></div>
        <div className="field"><label>N.º pedido / contrato</label><input value={formRegistro.pedido} onChange={(e) => cambiarRegistro({ pedido: e.target.value })} placeholder="Referencia si no existe orden" /></div>
        <div className="field ancho-doble"><label>Producto {formRegistro.ordenId && "(se toma de la orden)"}</label><select value={formRegistro.productoId} disabled={Boolean(formRegistro.ordenId)} onChange={(e) => cambiarRegistro({ productoId: e.target.value })}><option value="">Sin producto</option>{productos.map((item) => <option value={item.id} key={item.id}>{item.sku} · {item.nombre}</option>)}</select></div>
        <div className="field"><label>Cantidad afectada *</label><input type="number" min={1} step={1} value={formRegistro.cantidad} onChange={(e) => cambiarRegistro({ cantidad: e.target.value })} /></div>
        <div className="field ancho-total"><label>Descripción detallada *</label><textarea rows={4} value={formRegistro.descripcion} onChange={(e) => cambiarRegistro({ descripcion: e.target.value })} placeholder="Qué ocurrió, cómo se detectó y qué defecto presenta" /></div>
        <div className="field ancho-total"><label>Acción inmediata</label><textarea rows={2} value={formRegistro.accionInmediata} onChange={(e) => cambiarRegistro({ accionInmediata: e.target.value })} placeholder="Separación del lote, reproceso preventivo, aviso al cliente…" /></div>
        <div className="field"><label>Tipo de responsable</label><select value={formRegistro.responsableTipo} onChange={(e) => cambiarRegistro({ responsableTipo: e.target.value as FormRegistro["responsableTipo"], responsablePerfilId: "", responsableProveedorId: "" })}><option value="ninguno">Por determinar</option><option value="interno">Usuario interno</option><option value="proveedor">Proveedor / maquila</option></select></div>
        {formRegistro.responsableTipo === "interno" && <div className="field ancho-doble"><label>Responsable interno</label><select value={formRegistro.responsablePerfilId} onChange={(e) => cambiarRegistro({ responsablePerfilId: e.target.value })}><option value="">Sin asignar</option>{responsablesInternos.map((item) => <option value={item.id} key={item.id}>{item.nombre_completo}</option>)}</select></div>}
        {formRegistro.responsableTipo === "proveedor" && <div className="field ancho-doble"><label>Proveedor / maquila</label><select value={formRegistro.responsableProveedorId} onChange={(e) => cambiarRegistro({ responsableProveedorId: e.target.value })}><option value="">Selecciona…</option>{proveedoresEmpresa.map((item) => <option value={item.id} key={item.id}>{item.nombre_comercial ?? item.razon_social}</option>)}</select></div>}
        <div className="field"><label>Costo estimado</label><input type="number" min={0} step="0.01" value={formRegistro.costoEstimado} onChange={(e) => cambiarRegistro({ costoEstimado: e.target.value })} /></div>
        <label className="check-line ancho-total"><input type="checkbox" checked={formRegistro.solicitaDescuento} onChange={(e) => cambiarRegistro({ solicitaDescuento: e.target.checked })} /><span><strong>Solicitar evaluación de descuento</strong><small>No descuenta todavía: crea una solicitud para revisión formal de Nómina.</small></span></label>
        {formRegistro.solicitaDescuento && <><div className="ancho-doble"><SelectorEmpleados empleados={empleados} seleccionados={formRegistro.empleadoIds} onChange={(empleadoIds) => cambiarRegistro({ empleadoIds })} /></div><div className="field"><label>Monto total solicitado *</label><input type="number" min="0.01" step="0.01" value={formRegistro.montoDescuento} onChange={(e) => cambiarRegistro({ montoDescuento: e.target.value })} /><small>Se reparte por igual sin perder centavos.</small></div><ResumenReparto monto={formRegistro.montoDescuento} ids={formRegistro.empleadoIds} empleados={empleados} /><div className="field ancho-total"><label>Justificación *</label><textarea rows={2} value={formRegistro.motivoDescuento} onChange={(e) => cambiarRegistro({ motivoDescuento: e.target.value })} /></div></>}
      </div><div className="modal-acciones"><button type="button" className="secondary" onClick={() => setRegistrando(false)}>Cancelar</button><button disabled={procesando}>{procesando ? "Guardando…" : "Registrar novedad"}</button></div>
    </form></div>}

    {resolviendo && formResolucion && <div className="modal-operativo" onMouseDown={(e) => { if (e.target === e.currentTarget) setResolviendo(null); }}><form className="modal-contenido ancho calidad-modal" onSubmit={guardarResolucion}><div className="header-row"><div><h2>Analizar {resolviendo.codigo}</h2><p className="conteo">Causa raíz, acción correctiva, costo y decisión.</p></div><button type="button" className="secondary" onClick={() => setResolviendo(null)}>Cerrar</button></div>{error && <div className="error-box">{error}</div>}<div className="grid-form">
      <div className="field"><label>Nuevo estado *</label><select value={formResolucion.estado} onChange={(e) => setFormResolucion({ ...formResolucion, estado: e.target.value })}>{["abierta", "en_analisis"].includes(resolviendo.estado) && <option value="en_analisis">En análisis</option>}<option value="accion_correctiva">Acción correctiva</option><option value="cerrada">Cerrar caso</option></select></div>
      <div className="field"><label>Disposición final</label><select value={formResolucion.disposicion} onChange={(e) => setFormResolucion({ ...formResolucion, disposicion: e.target.value })}><option value="">Pendiente</option>{DISPOSICIONES.map(([id, nombre]) => <option value={id} key={id}>{nombre}</option>)}</select></div>
      <div className="field"><label>Costo real {formResolucion.estado === "cerrada" && "*"}</label><input type="number" min={0} step="0.01" value={formResolucion.costoReal} onChange={(e) => setFormResolucion({ ...formResolucion, costoReal: e.target.value })} /></div>
      <div className="field ancho-total"><label>Causa raíz {formResolucion.estado === "cerrada" && "*"}</label><textarea rows={3} value={formResolucion.causaRaiz} onChange={(e) => setFormResolucion({ ...formResolucion, causaRaiz: e.target.value })} /></div>
      <div className="field ancho-total"><label>Acción correctiva {formResolucion.estado === "cerrada" && "*"}</label><textarea rows={3} value={formResolucion.accionCorrectiva} onChange={(e) => setFormResolucion({ ...formResolucion, accionCorrectiva: e.target.value })} /></div>
      <div className="field ancho-total"><label>Nota del cambio</label><input value={formResolucion.detalle} onChange={(e) => setFormResolucion({ ...formResolucion, detalle: e.target.value })} placeholder="Qué se verificó o cambió" /></div>
      <label className="check-line ancho-total"><input type="checkbox" checked={formResolucion.solicitaDescuento} onChange={(e) => setFormResolucion({ ...formResolucion, solicitaDescuento: e.target.checked })} /><span><strong>Solicitar evaluación de descuento</strong><small>La solicitud podrá enviarse a Nómina únicamente al cerrar el caso.</small></span></label>
      {formResolucion.solicitaDescuento && <><div className="ancho-doble"><SelectorEmpleados empleados={empleados} seleccionados={formResolucion.empleadoIds} onChange={(empleadoIds) => setFormResolucion({ ...formResolucion, empleadoIds })} /></div><div className="field"><label>Monto total solicitado *</label><input type="number" min="0.01" step="0.01" value={formResolucion.montoDescuento} onChange={(e) => setFormResolucion({ ...formResolucion, montoDescuento: e.target.value })} /><small>Se reparte por igual sin perder centavos.</small></div><ResumenReparto monto={formResolucion.montoDescuento} ids={formResolucion.empleadoIds} empleados={empleados} /><div className="field ancho-total"><label>Justificación *</label><textarea rows={2} value={formResolucion.motivoDescuento} onChange={(e) => setFormResolucion({ ...formResolucion, motivoDescuento: e.target.value })} /></div></>}
    </div><div className="modal-acciones"><button type="button" className="secondary" onClick={() => setResolviendo(null)}>Cancelar</button><button disabled={procesando}>{procesando ? "Guardando…" : formResolucion.estado === "cerrada" ? "Cerrar caso" : "Guardar análisis"}</button></div></form></div>}

    {evidenciando && <div className="modal-operativo" onMouseDown={(e) => { if (e.target === e.currentTarget) setEvidenciando(null); }}><form className="modal-contenido calidad-modal" onSubmit={guardarEvidencia}><div className="header-row"><div><h2>Evidencia de {evidenciando.codigo}</h2><p className="conteo">Fotografía, archivo, acta o enlace verificable.</p></div><button type="button" className="secondary" onClick={() => setEvidenciando(null)}>Cerrar</button></div>{error && <div className="error-box">{error}</div>}<div className="grid-form una-columna"><div className="field"><label>Nombre *</label><input value={formEvidencia.nombre} onChange={(e) => setFormEvidencia({ ...formEvidencia, nombre: e.target.value })} placeholder="Ej. Foto frontal de la prenda" /></div><div className="field"><label>Enlace o referencia *</label><input value={formEvidencia.referencia} onChange={(e) => setFormEvidencia({ ...formEvidencia, referencia: e.target.value })} placeholder="https://… o código de archivo" /></div><div className="field"><label>Descripción</label><textarea rows={3} value={formEvidencia.descripcion} onChange={(e) => setFormEvidencia({ ...formEvidencia, descripcion: e.target.value })} /></div></div><div className="modal-acciones"><button type="button" className="secondary" onClick={() => setEvidenciando(null)}>Cancelar</button><button disabled={procesando}>{procesando ? "Guardando…" : "Agregar evidencia"}</button></div></form></div>}

    {derivando && <div className="modal-operativo" onMouseDown={(e) => { if (e.target === e.currentTarget) setDerivando(null); }}><form className="modal-contenido calidad-modal" onSubmit={derivarNomina}><div className="header-row"><div><h2>Enviar {derivando.codigo} a Nómina</h2><p className="conteo">Se crearán {responsablesDescuento.filter((item) => item.novedad_id === derivando.id).length || 1} borradores disciplinarios por un total de {DINERO.format(Number(derivando.monto_descuento_solicitado ?? 0))}.</p></div><button type="button" className="secondary" onClick={() => setDerivando(null)}>Cerrar</button></div>{error && <div className="error-box">{error}</div>}<div className="info-box"><strong>No aplica los descuentos todavía.</strong> Nómina deberá emitir, notificar, registrar el descargo y resolver cada expediente por separado.</div><div className="grid-form una-columna"><div className="field"><label>Compañía emisora *</label><select value={formDerivacion.empresaId} onChange={(e) => setFormDerivacion({ ...formDerivacion, empresaId: e.target.value })}>{empresas.map((item) => <option value={item.id} key={item.id}>{item.codigo} · {item.razon_social}</option>)}</select></div><div className="field"><label>Disposición del reglamento interno *</label><textarea rows={3} value={formDerivacion.reglamento} onChange={(e) => setFormDerivacion({ ...formDerivacion, reglamento: e.target.value })} /></div><div className="field"><label>Base legal adicional</label><textarea rows={2} value={formDerivacion.baseLegal} onChange={(e) => setFormDerivacion({ ...formDerivacion, baseLegal: e.target.value })} /></div></div><div className="modal-acciones"><button type="button" className="secondary" onClick={() => setDerivando(null)}>Cancelar</button><button disabled={procesando}>{procesando ? "Creando expedientes…" : "Crear borradores en Nómina"}</button></div></form></div>}
  </section>;
}
