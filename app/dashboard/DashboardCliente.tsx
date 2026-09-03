"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { tienePermiso, type Perfil } from "@/lib/permisos";

type ResumenPanel = {
  generado_at: string;
  hoy: string;
  rol: string;
  ambito: { almacenes_total: number; almacenes: string[]; empresas_total: number; empresas: string[] };
  inventario: {
    stock_fisico: number; stock_disponible: number; transito_entrada: number;
    productos_bajo_minimo: number; unidades_sugeridas: number; movimientos_hoy: number;
  };
  operaciones: {
    solicitudes_pendientes: number; transferencias_preparar: number;
    transferencias_recibir: number; conteos_revision: number;
  };
  ventas: { documentos_hoy: number; importe_hoy: number };
  compras: { pendientes_aprobacion: number; pendientes_recepcion: number };
  produccion: { pendientes_aprobacion: number; ordenes_activas: number; ordenes_atrasadas: number };
  nomina: {
    empleados_activos: number; ausencias_solicitadas: number; documentos_por_vencer: number;
    documentos_vencidos: number; periodos_pendientes: number;
  };
  franquicia: {
    locales: number; ventas_hoy: number; total_ventas_hoy: number;
    alertas: number; cierres_pendientes_hoy: number;
  };
  administracion: { usuarios_activos: number; usuarios_inactivos: number };
  actividad: Array<{ fecha: string; tipo: string; titulo: string; detalle: string; href: string }>;
};

type EnlaceModulo = { href: string; etiqueta: string };
type ModuloPanel = {
  id: string; titulo: string; subtitulo: string; descripcion: string; href: string;
  icono: string; tono: string; visible: boolean; pendiente: number;
  pendienteTexto: string; enlaces: EnlaceModulo[];
};
type Pendiente = {
  id: string; titulo: string; detalle: string; cantidad: number; href: string;
  nivel: "critico" | "atencion" | "normal";
};
type ResumenNotificaciones = { no_leidas: number; criticas: number; total: number };
type ResumenMantenimiento = {
  activos: number; detenidos: number; vencidos: number; proximos: number;
  ordenes_abiertas: number; ordenes_atrasadas: number;
};
type ResumenTesoreria = { cuentas_vencidas: number; saldo_vencido: number; efectivo_comprometido: number };

const NOTIFICACIONES_VACIO: ResumenNotificaciones = { no_leidas: 0, criticas: 0, total: 0 };
const MANTENIMIENTO_VACIO: ResumenMantenimiento = {
  activos: 0, detenidos: 0, vencidos: 0, proximos: 0,
  ordenes_abiertas: 0, ordenes_atrasadas: 0,
};
const TESORERIA_VACIO: ResumenTesoreria = { cuentas_vencidas: 0, saldo_vencido: 0, efectivo_comprometido: 0 };

const RESUMEN_VACIO: ResumenPanel = {
  generado_at: "", hoy: "", rol: "",
  ambito: { almacenes_total: 0, almacenes: [], empresas_total: 0, empresas: [] },
  inventario: {
    stock_fisico: 0, stock_disponible: 0, transito_entrada: 0,
    productos_bajo_minimo: 0, unidades_sugeridas: 0, movimientos_hoy: 0,
  },
  operaciones: {
    solicitudes_pendientes: 0, transferencias_preparar: 0,
    transferencias_recibir: 0, conteos_revision: 0,
  },
  ventas: { documentos_hoy: 0, importe_hoy: 0 },
  compras: { pendientes_aprobacion: 0, pendientes_recepcion: 0 },
  produccion: { pendientes_aprobacion: 0, ordenes_activas: 0, ordenes_atrasadas: 0 },
  nomina: {
    empleados_activos: 0, ausencias_solicitadas: 0, documentos_por_vencer: 0,
    documentos_vencidos: 0, periodos_pendientes: 0,
  },
  franquicia: {
    locales: 0, ventas_hoy: 0, total_ventas_hoy: 0, alertas: 0, cierres_pendientes_hoy: 0,
  },
  administracion: { usuarios_activos: 0, usuarios_inactivos: 0 }, actividad: [],
};

const ETIQUETAS_ROL: Record<string, string> = {
  admin: "Administración", bodega: "Bodega", logistica: "Logística", gerencia: "Gerencia",
  tienda: "Tienda", control: "Control", nomina: "Nómina", franquiciado: "Franquiciado",
  vendedor_franquicia: "Vendedor de franquicia",
};
const ENTERO = new Intl.NumberFormat("es-EC", { maximumFractionDigits: 0 });
const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });

function numero(valor: unknown) {
  const convertido = Number(valor);
  return Number.isFinite(convertido) ? convertido : 0;
}

function fechaLarga() {
  return new Intl.DateTimeFormat("es-EC", {
    weekday: "long", day: "numeric", month: "long", year: "numeric",
    timeZone: "America/Guayaquil",
  }).format(new Date());
}

function horaEcuador(valor: string) {
  if (!valor) return "";
  return new Intl.DateTimeFormat("es-EC", {
    day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit",
    timeZone: "America/Guayaquil",
  }).format(new Date(valor));
}

function enlacesValidos(...items: Array<EnlaceModulo | false>): EnlaceModulo[] {
  return items.filter((item): item is EnlaceModulo => Boolean(item));
}

// El nombre se guarda como lo pide el IESS: APELLIDOS y luego NOMBRES. Tomar
// la primera palabra saludaba por el apellido ("Hola, BONILLA"). Con la
// convencion ecuatoriana de cuatro palabras -dos apellidos y dos nombres- el
// nombre de pila es la tercera y el primer apellido la primera.
//
// Con otra cantidad de palabras no se adivina cual es el nombre de pila: se
// prefiere devolver el nombre tal cual antes que inventar un orden y llamar mal
// a alguien.
function nombreParaSaludo(completo: string) {
  const p = (completo || "").trim().split(/s+/).filter(Boolean);
  if (p.length !== 4) return completo;
  return p[2].charAt(0).toUpperCase() + p[2].slice(1).toLowerCase();
}

export default function DashboardCliente({ perfil }: { perfil: Perfil }) {
  const supabase = useMemo(() => createClient(), []);
  const buscadorRef = useRef<HTMLInputElement>(null);
  const [resumen, setResumen] = useState<ResumenPanel>(RESUMEN_VACIO);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busqueda, setBusqueda] = useState("");
  const [notificaciones, setNotificaciones] = useState<ResumenNotificaciones>(NOTIFICACIONES_VACIO);
  const [mantenimiento, setMantenimiento] = useState<ResumenMantenimiento>(MANTENIMIENTO_VACIO);
  const [tesoreria, setTesoreria] = useState<ResumenTesoreria>(TESORERIA_VACIO);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const [panel, avisos, activos, cuentasPagar] = await Promise.all([
      supabase.rpc("resumen_panel_principal_v51"),
      supabase.rpc("resumen_notificaciones_v53"),
      supabase.rpc("resumen_mantenimiento_v54"),
      supabase.from("vista_cuentas_por_pagar_v73").select("estado,saldo_pendiente,total_comprometido"),
    ]);
    const { data, error: errorCarga } = panel;
    if (errorCarga) {
      setError(errorCarga.message.includes("resumen_panel_principal_v51")
        ? "Falta instalar la migración v51 para mostrar indicadores. Los accesos siguen disponibles."
        : errorCarga.message);
    } else if (data) {
      setResumen(data as ResumenPanel);
    }
    if (!avisos.error && avisos.data) setNotificaciones(avisos.data as ResumenNotificaciones);
    if (!activos.error && activos.data) setMantenimiento(activos.data as ResumenMantenimiento);
    if (!cuentasPagar.error && cuentasPagar.data) setTesoreria(cuentasPagar.data.reduce((acc, cuenta) => ({
      cuentas_vencidas: acc.cuentas_vencidas + (cuenta.estado === "vencida" ? 1 : 0),
      saldo_vencido: acc.saldo_vencido + (cuenta.estado === "vencida" ? Number(cuenta.saldo_pendiente) : 0),
      efectivo_comprometido: acc.efectivo_comprometido + Number(cuenta.total_comprometido ?? 0),
    }), { ...TESORERIA_VACIO }));
    setCargando(false);
  }, [supabase]);

  useEffect(() => { cargar(); }, [cargar]);
  useEffect(() => {
    function enfocarBuscador(evento: KeyboardEvent) {
      const objetivo = evento.target as HTMLElement | null;
      if (evento.key === "/" && objetivo?.tagName !== "INPUT" && objetivo?.tagName !== "TEXTAREA") {
        evento.preventDefault();
        buscadorRef.current?.focus();
      }
    }
    document.addEventListener("keydown", enfocarBuscador);
    return () => document.removeEventListener("keydown", enfocarBuscador);
  }, []);

  const puede = useCallback((permiso: Parameters<typeof tienePermiso>[1]) =>
    tienePermiso(perfil, permiso), [perfil]);
  const esFranquicia = perfil.rol === "franquiciado" || perfil.rol === "vendedor_franquicia";

  const modulos = useMemo<ModuloPanel[]>(() => {
    const op = resumen.operaciones;
    const totalOperaciones = numero(op.solicitudes_pendientes) + numero(op.transferencias_preparar)
      + numero(op.transferencias_recibir) + numero(op.conteos_revision);
    const totalCompras = numero(resumen.compras.pendientes_aprobacion) + numero(resumen.compras.pendientes_recepcion);
    const totalProduccion = numero(resumen.produccion.pendientes_aprobacion) + numero(resumen.produccion.ordenes_atrasadas);
    const totalNomina = numero(resumen.nomina.ausencias_solicitadas) + numero(resumen.nomina.documentos_por_vencer)
      + numero(resumen.nomina.documentos_vencidos) + numero(resumen.nomina.periodos_pendientes);
    const totalFranquicia = numero(resumen.franquicia.alertas) + numero(resumen.franquicia.cierres_pendientes_hoy);

    return [
      {
        id: "notificaciones", titulo: "Notificaciones", subtitulo: "Centro general de avisos",
        descripcion: "Reúne pendientes, vencimientos y comunicados de todos tus módulos.",
        href: "/notificaciones", icono: "AVI", tono: "rojo", visible: puede("notificaciones.acceder"),
        pendiente: numero(notificaciones.no_leidas), pendienteTexto: "sin leer",
        enlaces: [{ href: "/notificaciones", etiqueta: "Revisar notificaciones" }],
      },
      {
        id: "inventario", titulo: "Inventario", subtitulo: "Existencias y catálogo",
        descripcion: "Consulta stock físico, disponible, reservado y en tránsito por almacén.",
        href: "/inventario", icono: "INV", tono: "azul", visible: puede("inventario.acceder"),
        pendiente: numero(resumen.inventario.productos_bajo_minimo), pendienteTexto: "bajo mínimo",
        enlaces: enlacesValidos(
          { href: "/inventario", etiqueta: "Ver existencias" },
          puede("movimientos.acceder") && { href: "/movimientos", etiqueta: "Movimientos" },
          perfil.rol === "admin" && { href: "/productos", etiqueta: "Productos" },
          ["admin", "control"].includes(perfil.rol) && { href: "/configuracion/inventario", etiqueta: "Políticas de stock" }
        ),
      },
      {
        id: "operaciones", titulo: "Operaciones", subtitulo: "Reposición y control",
        descripcion: "Solicitudes, transferencias, despachos, recepciones y conteos físicos.",
        href: puede("operaciones.acceder") ? "/operaciones" : "/conteos", icono: "OPS", tono: "celeste",
        visible: puede("operaciones.acceder") || puede("conteos.acceder"), pendiente: totalOperaciones,
        pendienteTexto: "por atender",
        enlaces: enlacesValidos(
          puede("operaciones.acceder") && { href: "/operaciones", etiqueta: "Solicitudes y transferencias" },
          puede("conteos.acceder") && { href: "/conteos", etiqueta: "Conteos físicos" },
          puede("control.acceder") && { href: "/control", etiqueta: "Centro de Control" }
        ),
      },
      {
        id: "ventas", titulo: "Ventas", subtitulo: "Facturación e inventario",
        descripcion: "Importa facturas autorizadas, concilia códigos y descuenta las existencias.",
        href: "/ventas", icono: "VTA", tono: "verde", visible: puede("ventas.acceder") && !esFranquicia,
        pendiente: numero(resumen.ventas.documentos_hoy), pendienteTexto: "facturas hoy",
        enlaces: [{ href: "/ventas", etiqueta: "Facturas XML" }],
      },
      {
        id: "compras", titulo: "Compras", subtitulo: "Abastecimiento",
        descripcion: "Gestiona proveedores, aprobaciones, recepciones parciales y no conformidades.",
        href: "/compras", icono: "OC", tono: "naranja", visible: puede("compras.acceder"),
        pendiente: totalCompras, pendienteTexto: "órdenes pendientes",
        enlaces: [{ href: "/compras", etiqueta: "Órdenes y recepciones" }],
      },
      {
        id: "tesoreria", titulo: "Finanzas", subtitulo: "Cuentas por pagar",
        descripcion: `Controla vencimientos, pagos y cheques posfechados. Comprometido: ${DINERO.format(tesoreria.efectivo_comprometido)}.`,
        href: "/cuentas-por-pagar", icono: "CXP", tono: "morado", visible: puede("tesoreria.acceder"),
        pendiente: tesoreria.cuentas_vencidas, pendienteTexto: "facturas vencidas",
        enlaces: [{ href: "/cuentas-por-pagar", etiqueta: "Ver cartera y flujo" }],
      },
      {
        id: "produccion", titulo: "Producción", subtitulo: "Planificación y planta",
        descripcion: "Fórmulas, materiales, órdenes, rutas, etapas, lotes, calidad y costos.",
        href: "/produccion", icono: "OP", tono: "morado", visible: puede("produccion.acceder"),
        pendiente: totalProduccion, pendienteTexto: "requieren atención",
        enlaces: [{ href: "/produccion", etiqueta: "Abrir producción" }],
      },
      {
        id: "franquicia", titulo: "Franquicia", subtitulo: "Operación del local",
        descripcion: "Ventas, caja diaria, inventario, reposición y alertas del establecimiento.",
        href: "/franquicia", icono: "FQ", tono: "turquesa", visible: puede("franquicia.acceder"),
        pendiente: totalFranquicia, pendienteTexto: "alertas del local",
        enlaces: [{ href: "/franquicia", etiqueta: esFranquicia ? "Ir a mi local" : "Ver franquicias" }],
      },
      {
        id: "mantenimiento", titulo: "Mantenimiento", subtitulo: "Maquinaria y activos",
        descripcion: "Control preventivo, órdenes de trabajo, paradas, responsables y costos.",
        href: "/mantenimiento", icono: "MT", tono: "naranja", visible: puede("mantenimiento.acceder"),
        pendiente: numero(mantenimiento.vencidos) + numero(mantenimiento.ordenes_atrasadas),
        pendienteTexto: "vencidos o atrasados",
        enlaces: [{ href: "/mantenimiento", etiqueta: puede("mantenimiento.editar") ? "Gestionar mantenimiento" : "Consultar activos" }],
      },
      {
        id: "nomina", titulo: "Nómina", subtitulo: "Personas y roles",
        descripcion: "Personal, expedientes, asistencia, vacaciones, novedades y roles de pago.",
        href: "/nomina", icono: "NOM", tono: "rosa", visible: puede("nomina.acceder"),
        pendiente: totalNomina, pendienteTexto: "pendientes",
        enlaces: [{ href: "/nomina", etiqueta: puede("nomina.editar") ? "Gestionar nómina" : "Consultar nómina" }],
      },
      {
        id: "reportes", titulo: "Reportes", subtitulo: "Información para decidir",
        descripcion: "Analiza stock, valoración, reposición, cumplimiento y trazabilidad.",
        href: "/reportes", icono: "REP", tono: "gris", visible: puede("reportes.acceder"),
        pendiente: 0, pendienteTexto: "", enlaces: [{ href: "/reportes", etiqueta: "Abrir reportes" }],
      },
      {
        id: "administracion", titulo: "Administración", subtitulo: "Configuración del ERP",
        descripcion: "Empresas, almacenes, usuarios, permisos por rol y locales franquiciados.",
        href: "/administracion/usuarios", icono: "ADM", tono: "oscuro", visible: perfil.rol === "admin",
        pendiente: numero(resumen.administracion.usuarios_inactivos), pendienteTexto: "usuarios inactivos",
        enlaces: enlacesValidos(
          { href: "/administracion/empresas", etiqueta: "Empresas" },
          { href: "/administracion/usuarios", etiqueta: "Usuarios" },
          { href: "/administracion/permisos", etiqueta: "Permisos" },
          { href: "/administracion/franquicias", etiqueta: "Franquicias" }
        ),
      },
    ];
  }, [esFranquicia, perfil.rol, puede, resumen, notificaciones, mantenimiento, tesoreria]);

  const modulosVisibles = useMemo(() => {
    const consulta = busqueda.trim().toLocaleLowerCase("es");
    return modulos.filter((modulo) => modulo.visible && (!consulta
      || [modulo.titulo, modulo.subtitulo, modulo.descripcion, ...modulo.enlaces.map((e) => e.etiqueta)]
        .some((texto) => texto.toLocaleLowerCase("es").includes(consulta))));
  }, [busqueda, modulos]);

  const pendientes = useMemo<Pendiente[]>(() => {
    const items: Array<Pendiente | false> = [
      puede("notificaciones.acceder") && numero(notificaciones.criticas) > 0 && {
        id: "avisos-criticos", titulo: "Notificaciones críticas",
        detalle: "Avisos sin leer que requieren atención inmediata",
        cantidad: numero(notificaciones.criticas), href: "/notificaciones", nivel: "critico",
      },
      puede("inventario.acceder") && numero(resumen.inventario.productos_bajo_minimo) > 0 && {
        id: "stock", titulo: "Productos bajo mínimo",
        detalle: `${ENTERO.format(numero(resumen.inventario.unidades_sugeridas))} unidades sugeridas para reponer`,
        cantidad: numero(resumen.inventario.productos_bajo_minimo), href: "/inventario", nivel: "critico",
      },
      puede("operaciones.acceder") && numero(resumen.operaciones.transferencias_recibir) > 0 && {
        id: "recibir", titulo: "Transferencias por recibir", detalle: "Mercadería despachada o en tránsito",
        cantidad: numero(resumen.operaciones.transferencias_recibir), href: esFranquicia ? "/franquicia" : "/operaciones", nivel: "atencion",
      },
      puede("operaciones.acceder") && numero(resumen.operaciones.transferencias_preparar) > 0 && {
        id: "preparar", titulo: "Transferencias por preparar", detalle: "Aprobadas y listas para despacho",
        cantidad: numero(resumen.operaciones.transferencias_preparar), href: "/operaciones", nivel: "normal",
      },
      puede("control.acceder") && numero(resumen.operaciones.solicitudes_pendientes) > 0 && {
        id: "solicitudes", titulo: "Solicitudes esperando aprobación", detalle: "Reposiciones enviadas por los almacenes",
        cantidad: numero(resumen.operaciones.solicitudes_pendientes), href: "/control", nivel: "atencion",
      },
      puede("control.acceder") && numero(resumen.operaciones.conteos_revision) > 0 && {
        id: "conteos", titulo: "Conteos esperando revisión", detalle: "Segundo conteo o resolución de diferencias",
        cantidad: numero(resumen.operaciones.conteos_revision), href: "/control", nivel: "atencion",
      },
      puede("compras.acceder") && numero(resumen.compras.pendientes_aprobacion) > 0 && {
        id: "compras-aprobar", titulo: "Compras por aprobar", detalle: "Órdenes pendientes de resolución",
        cantidad: numero(resumen.compras.pendientes_aprobacion), href: "/compras", nivel: "atencion",
      },
      puede("compras.acceder") && numero(resumen.compras.pendientes_recepcion) > 0 && {
        id: "compras-recibir", titulo: "Compras por recibir", detalle: "Órdenes aprobadas o parcialmente recibidas",
        cantidad: numero(resumen.compras.pendientes_recepcion), href: "/compras", nivel: "normal",
      },
      puede("tesoreria.acceder") && tesoreria.cuentas_vencidas > 0 && {
        id: "cuentas-vencidas", titulo: "Facturas de proveedores vencidas",
        detalle: `${DINERO.format(tesoreria.saldo_vencido)} pendientes de pago`,
        cantidad: tesoreria.cuentas_vencidas, href: "/cuentas-por-pagar", nivel: "critico",
      },
      puede("produccion.acceder") && numero(resumen.produccion.ordenes_atrasadas) > 0 && {
        id: "produccion-atrasada", titulo: "Producción atrasada", detalle: "Órdenes abiertas después de su fecha planificada",
        cantidad: numero(resumen.produccion.ordenes_atrasadas), href: "/produccion", nivel: "critico",
      },
      puede("produccion.acceder") && numero(resumen.produccion.pendientes_aprobacion) > 0 && {
        id: "produccion-aprobar", titulo: "Producción por aprobar", detalle: "Órdenes esperando autorización",
        cantidad: numero(resumen.produccion.pendientes_aprobacion), href: "/produccion", nivel: "atencion",
      },
      puede("nomina.acceder") && numero(resumen.nomina.documentos_vencidos) > 0 && {
        id: "documentos-vencidos", titulo: "Documentos vencidos", detalle: "Expedientes de personal que requieren actualización",
        cantidad: numero(resumen.nomina.documentos_vencidos), href: "/nomina", nivel: "critico",
      },
      puede("nomina.acceder") && numero(resumen.nomina.ausencias_solicitadas) > 0 && {
        id: "ausencias", titulo: "Ausencias por resolver", detalle: "Solicitudes pendientes de aprobación",
        cantidad: numero(resumen.nomina.ausencias_solicitadas), href: "/nomina", nivel: "atencion",
      },
      puede("franquicia.caja") && numero(resumen.franquicia.cierres_pendientes_hoy) > 0 && {
        id: "cierre-caja", titulo: "Cierre de caja pendiente",
        detalle: "Días con movimiento de caja que quedaron sin conciliar",
        cantidad: numero(resumen.franquicia.cierres_pendientes_hoy), href: "/franquicia", nivel: "atencion",
      },
      puede("franquicia.acceder") && numero(resumen.franquicia.alertas) > 0 && {
        id: "franquicia-alertas", titulo: "Alertas de reposición", detalle: "Solicitudes aprobadas, despachadas o por recibir",
        cantidad: numero(resumen.franquicia.alertas), href: "/franquicia", nivel: "normal",
      },
      puede("mantenimiento.acceder") && numero(mantenimiento.vencidos) > 0 && {
        id: "mantenimiento-vencido", titulo: "Mantenimientos vencidos",
        detalle: "Maquinaria o activos superaron su fecha o lectura objetivo",
        cantidad: numero(mantenimiento.vencidos), href: "/mantenimiento", nivel: "critico",
      },
      puede("mantenimiento.acceder") && numero(mantenimiento.ordenes_atrasadas) > 0 && {
        id: "mantenimiento-atrasado", titulo: "Órdenes de mantenimiento atrasadas",
        detalle: "Trabajos programados que todavía no han iniciado",
        cantidad: numero(mantenimiento.ordenes_atrasadas), href: "/mantenimiento", nivel: "atencion",
      },
    ];
    const orden = { critico: 0, atencion: 1, normal: 2 };
    return items.filter((item): item is Pendiente => Boolean(item))
      .sort((a, b) => orden[a.nivel] - orden[b.nivel] || b.cantidad - a.cantidad);
  }, [esFranquicia, puede, resumen, notificaciones, mantenimiento, tesoreria]);

  const kpis = useMemo(() => {
    if (esFranquicia) return [
      { etiqueta: "Ventas de hoy", valor: ENTERO.format(numero(resumen.franquicia.ventas_hoy)), nota: DINERO.format(numero(resumen.franquicia.total_ventas_hoy)), tono: "verde" },
      { etiqueta: "Stock disponible", valor: ENTERO.format(numero(resumen.inventario.stock_disponible)), nota: "unidades del local", tono: "azul" },
      { etiqueta: "Bajo mínimo", valor: ENTERO.format(numero(resumen.inventario.productos_bajo_minimo)), nota: "productos", tono: resumen.inventario.productos_bajo_minimo ? "rojo" : "verde" },
      { etiqueta: "Por recibir", valor: ENTERO.format(numero(resumen.operaciones.transferencias_recibir)), nota: "transferencias", tono: "naranja" },
    ];
    if (perfil.rol === "nomina") return [
      { etiqueta: "Personal activo", valor: ENTERO.format(numero(resumen.nomina.empleados_activos)), nota: "empleados", tono: "azul" },
      { etiqueta: "Ausencias", valor: ENTERO.format(numero(resumen.nomina.ausencias_solicitadas)), nota: "por resolver", tono: "naranja" },
      { etiqueta: "Documentos", valor: ENTERO.format(numero(resumen.nomina.documentos_por_vencer) + numero(resumen.nomina.documentos_vencidos)), nota: "vencidos o por vencer", tono: "rojo" },
      { etiqueta: "Roles", valor: ENTERO.format(numero(resumen.nomina.periodos_pendientes)), nota: "períodos abiertos", tono: "morado" },
    ];
    return [
      { etiqueta: "Stock físico", valor: ENTERO.format(numero(resumen.inventario.stock_fisico)), nota: "unidades", tono: "azul" },
      { etiqueta: "Disponible", valor: ENTERO.format(numero(resumen.inventario.stock_disponible)), nota: "después de reservas", tono: "verde" },
      { etiqueta: "Bajo mínimo", valor: ENTERO.format(numero(resumen.inventario.productos_bajo_minimo)), nota: "productos", tono: resumen.inventario.productos_bajo_minimo ? "rojo" : "verde" },
      { etiqueta: "Actividad de hoy", valor: ENTERO.format(numero(resumen.inventario.movimientos_hoy)), nota: `${ENTERO.format(numero(resumen.inventario.transito_entrada))} un. en tránsito`, tono: "morado" },
    ];
  }, [esFranquicia, perfil.rol, resumen]);

  const alcanceAlmacenes = resumen.ambito.almacenes.length ? resumen.ambito.almacenes.join(", ") : "Sin almacenes asignados";
  const alcanceEmpresas = resumen.ambito.empresas.length ? resumen.ambito.empresas.join(", ") : "Sin empresas visibles";

  return (
    <main className="panel-principal">
      <section className="panel-portada">
        <div>
          <span className="panel-saludo">
            {resumen.ambito.almacenes.length === 1
              ? resumen.ambito.almacenes[0]
              : "CENTRO DE TRABAJO"}{" "}
            · {ETIQUETAS_ROL[perfil.rol] ?? perfil.rol}
          </span>
          <h1>Hola, {nombreParaSaludo(perfil.nombre_completo)}</h1>
          <p>{fechaLarga()}. Aquí tienes tus accesos y pendientes en un solo lugar.</p>
        </div>
        <div className="panel-portada-acciones">
          <div className="panel-actualizado">
            <span className={cargando ? "panel-pulso cargando" : "panel-pulso"} />
            {resumen.generado_at ? `Actualizado ${horaEcuador(resumen.generado_at)}` : "Preparando resumen"}
          </div>
          <button type="button" className="panel-refrescar" onClick={cargar} disabled={cargando}>
            {cargando ? "Actualizando…" : "Actualizar"}
          </button>
        </div>
      </section>

      <section className="panel-ambito" aria-label="Ámbito de información">
        <div title={alcanceAlmacenes}>
          <span>ALMACENES</span><strong>{resumen.ambito.almacenes_total || "—"}</strong><small>{alcanceAlmacenes}</small>
        </div>
        <div title={alcanceEmpresas}>
          <span>EMPRESAS</span><strong>{resumen.ambito.empresas_total || "—"}</strong><small>{alcanceEmpresas}</small>
        </div>
        <label className="panel-buscador">
          <span>Buscar un módulo o acción</span>
          <div>
            <input ref={buscadorRef} value={busqueda} onChange={(evento) => setBusqueda(evento.target.value)}
              placeholder="Ej.: conteo, compras, empleados…" />
            {busqueda
              ? <button type="button" onClick={() => setBusqueda("")} aria-label="Limpiar búsqueda">×</button>
              : <kbd>/</kbd>}
          </div>
        </label>
      </section>

      {error && <div className="error-box panel-error">{error}</div>}

      <section className="panel-kpis" aria-label="Resumen de hoy">
        {kpis.map((kpi) => (
          <article className={`panel-kpi ${kpi.tono}`} key={kpi.etiqueta}>
            <span>{kpi.etiqueta}</span><strong>{cargando ? "···" : kpi.valor}</strong><small>{kpi.nota}</small>
          </article>
        ))}
      </section>

      <div className="panel-contenido">
        <section className="panel-modulos-seccion">
          <div className="panel-seccion-titulo">
            <div><span>ACCESOS</span><h2>Mis módulos</h2></div>
            <small>{modulosVisibles.length} disponibles según tu rol</small>
          </div>
          <div className="panel-modulos-grid">
            {modulosVisibles.map((modulo) => (
              <article className={`panel-modulo ${modulo.tono}`} key={modulo.id}>
                <div className="panel-modulo-cabecera">
                  <span className="panel-modulo-icono">{modulo.icono}</span>
                  {modulo.pendiente > 0 && <span className="panel-modulo-contador">
                    {ENTERO.format(modulo.pendiente)} {modulo.pendienteTexto}
                  </span>}
                </div>
                <span className="panel-modulo-subtitulo">{modulo.subtitulo}</span>
                <h3>{modulo.titulo}</h3><p>{modulo.descripcion}</p>
                <div className="panel-modulo-enlaces">
                  {modulo.enlaces.map((enlace) => <Link href={enlace.href} key={`${modulo.id}-${enlace.href}`}>{enlace.etiqueta}</Link>)}
                </div>
                <Link href={modulo.href} className="panel-modulo-abrir" aria-label={`Abrir ${modulo.titulo}`}>
                  Abrir <span aria-hidden="true">→</span>
                </Link>
              </article>
            ))}
            {!modulosVisibles.length && <div className="panel-sin-resultados">
              <strong>No encontramos ese acceso</strong><span>Prueba con otro nombre o limpia la búsqueda.</span>
              <button type="button" onClick={() => setBusqueda("")}>Ver todos mis módulos</button>
            </div>}
          </div>
        </section>

        <aside className="panel-lateral">
          <section className="panel-pendientes">
            <div className="panel-seccion-titulo compacto">
              <div><span>PRIORIDAD</span><h2>Por atender</h2></div>
              <strong>{pendientes.reduce((total, item) => total + item.cantidad, 0)}</strong>
            </div>
            <div className="panel-pendientes-lista">
              {pendientes.slice(0, 8).map((item) => <Link href={item.href} className={`panel-pendiente ${item.nivel}`} key={item.id}>
                <span className="panel-pendiente-marca" />
                <span className="panel-pendiente-texto"><strong>{item.titulo}</strong><small>{item.detalle}</small></span>
                <b>{ENTERO.format(item.cantidad)}</b>
              </Link>)}
              {!cargando && pendientes.length === 0 && <div className="panel-al-dia">
                <span>✓</span><strong>Todo al día</strong><small>No tienes pendientes críticos en este momento.</small>
              </div>}
              {cargando && <div className="panel-cargando-lineas"><i /><i /><i /></div>}
            </div>
          </section>

          <section className="panel-actividad">
            <div className="panel-seccion-titulo compacto"><div><span>TRAZABILIDAD</span><h2>Actividad reciente</h2></div></div>
            <div className="panel-actividad-lista">
              {resumen.actividad.slice(0, 6).map((item, indice) => <Link href={item.href} className="panel-actividad-item" key={`${item.fecha}-${indice}`}>
                <span className="panel-actividad-icono">{item.tipo === "venta" ? "$" : "↕"}</span>
                <span><strong>{item.titulo}</strong><small>{item.detalle}</small><time>{horaEcuador(item.fecha)}</time></span>
              </Link>)}
              {!cargando && !resumen.actividad.length && <div className="panel-actividad-vacia">
                Todavía no existe actividad visible para tu ámbito.
              </div>}
            </div>
          </section>
        </aside>
      </div>
    </main>
  );
}
