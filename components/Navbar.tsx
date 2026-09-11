"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { createClient } from "@/lib/supabase/client";
import { tienePermiso, type Perfil } from "@/lib/permisos";
import BomanLogo from "@/components/BomanLogo";

type ModuloId =
  | "notificaciones"
  | "ventas"
  | "compras"
  | "finanzas"
  | "produccion"
  | "inventario"
  | "mantenimiento"
  | "franquicias"
  | "reportes"
  | "nomina"
  | "importaciones"
  | "administracion"
  | "contabilidad";

type OpcionMenu = {
  href: string;
  etiqueta: string;
  descripcion: string;
  visible: boolean;
};

type ModuloMenu = {
  id: ModuloId;
  etiqueta: string;
  opciones: OpcionMenu[];
};

const ICONOS: Record<ModuloId | "inicio" | "buscar" | "salir", ReactNode> = {
  inicio: <><path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 10.5V20h13v-9.5M9 20v-6h6v6"/></>,
  notificaciones: <><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"/><path d="M10 21h4"/></>,
  ventas: <><path d="M4 19V5h16v14H4Z"/><path d="M8 9h8M8 13h5"/><path d="M16 16h.01"/></>,
  compras: <><path d="M3 5h2l2 10h10l2-7H6"/><circle cx="9" cy="19" r="1"/><circle cx="17" cy="19" r="1"/></>,
  finanzas: <><path d="M3 7h18v12H3z"/><path d="M3 10h18M7 15h3"/><circle cx="17" cy="15" r="2"/></>,
  produccion: <><path d="m4 14 5-5 4 4 7-7"/><path d="M4 20h16M4 4v16"/></>,
  inventario: <><path d="m12 3 9 5-9 5-9-5 9-5Z"/><path d="m3 12 9 5 9-5M3 16l9 5 9-5"/></>,
  mantenimiento: <><path d="M14.7 6.3a4 4 0 0 0-5-5l2.1 2.1-3.4 3.4-2.1-2.1a4 4 0 0 0 5 5L19 17.4a2.1 2.1 0 0 1-3 3l-7.7-7.7"/></>,
  franquicias: <><path d="M4 10h16l-2-6H6l-2 6Z"/><path d="M5 10v10h14V10M9 20v-6h6v6"/><path d="M4 10c0 2 4 2 4 0 0 2 4 2 4 0 0 2 4 2 4 0 0 2 4 2 4 0"/></>,
  reportes: <><path d="M5 20V10M12 20V4M19 20v-7"/><path d="M3 20h18"/></>,
  nomina: <><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></>,
  importaciones: <><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 19h16"/></>,
  contabilidad: <><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 9v11"/></>,
  administracion: <><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/></>,
  buscar: <><circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/></>,
  salir: <><path d="M10 17l5-5-5-5M15 12H3"/><path d="M14 3h6v18h-6"/></>,
};

function Icono({ nombre, size = 19 }: { nombre: keyof typeof ICONOS; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {ICONOS[nombre]}
    </svg>
  );
}

// Agrupacion visual en modulos de negocio. modulosBase no cambia de
// contenido (cada modulo original sigue siendo su propia unidad, con su
// propio conjunto de "visible"); esto solo decide DONDE se pinta cada uno,
// para minimizar choques con ediciones concurrentes sobre modulosBase.
//
// GrupoId es un subconjunto de ModuloId (todo grupo toma el nombre de su
// modulo "principal"), asi que el icono del grupo es simplemente
// Icono nombre={grupo.id} - no hace falta un mapa de iconos aparte.
type GrupoId = ModuloId;

const GRUPO_DE_MODULO: Record<ModuloId, GrupoId> = {
  notificaciones: "notificaciones",
  ventas: "ventas",
  compras: "compras",
  finanzas: "finanzas",
  produccion: "produccion",
  inventario: "inventario",
  mantenimiento: "mantenimiento",
  franquicias: "franquicias",
  reportes: "reportes",
  nomina: "nomina",
  importaciones: "importaciones",
  administracion: "administracion",
  contabilidad: "contabilidad",
};

const ORDEN_GRUPOS: GrupoId[] = [
  "ventas", "produccion", "inventario", "reportes", "compras", "finanzas",
  "franquicias", "nomina", "mantenimiento", "notificaciones",
  "importaciones", "administracion", "contabilidad",
];

const ETIQUETA_GRUPO: Record<GrupoId, string> = {
  compras: "Compras",
  finanzas: "Tesorería",
  contabilidad: "Contabilidad",
  ventas: "Ventas",
  produccion: "Producción",
  inventario: "Inventario",
  mantenimiento: "Mantenimiento",
  franquicias: "Franquicias",
  nomina: "Talento Humano y Nómina",
  administracion: "Administración",
  notificaciones: "Notificaciones",
  reportes: "Análisis",
  importaciones: "Importaciones",
};

const PRINCIPALES_POR_ROL: Record<string, GrupoId[]> = {
  admin: ["ventas", "produccion", "inventario", "reportes"],
  gerencia: ["reportes", "finanzas", "produccion", "inventario"],
  control: ["inventario", "produccion", "ventas", "reportes"],
  produccion: ["produccion", "notificaciones"],
  bodega: ["inventario", "compras", "produccion", "notificaciones"],
  logistica: ["inventario", "produccion", "notificaciones"],
  tienda: ["ventas", "inventario", "compras", "notificaciones"],
  nomina: ["nomina", "notificaciones", "importaciones"],
  franquiciado: ["franquicias", "inventario", "notificaciones"],
  vendedor_franquicia: ["franquicias", "inventario", "notificaciones"],
};

const RAPIDOS_POR_ROL: Record<string, string[]> = {
  admin: ["/ventas/contratos", "/produccion/dashboard", "/inventario", "/reportes/comercial"],
  gerencia: ["/dashboard", "/reportes/comercial", "/cuentas-por-pagar", "/produccion/dashboard"],
  control: ["/control", "/conteos", "/produccion/calidad", "/reportes/comercial"],
  produccion: ["/tablero", "/produccion/cronograma", "/produccion/calidad", "/produccion/dashboard"],
  bodega: ["/inventario", "/operaciones", "/movimientos", "/conteos"],
  logistica: ["/operaciones", "/inventario", "/produccion/cronograma"],
  tienda: ["/tienda", "/ventas", "/inventario"],
  nomina: ["/nomina", "/notificaciones", "/importar"],
  franquiciado: ["/franquicia", "/inventario", "/notificaciones"],
  vendedor_franquicia: ["/franquicia", "/inventario", "/notificaciones"],
};

type GrupoRenderizado = {
  id: GrupoId;
  etiqueta: string;
  opciones: OpcionMenu[];
};

function nombreParaMenu(nombreCompleto: string) {
  const limpio = nombreCompleto.trim().replace(/\s+/g, " ");
  if (!limpio) return "Usuario";

  // Los perfiles importados desde Nómina usan el orden legal ecuatoriano:
  // APELLIDO APELLIDO NOMBRE NOMBRE. Esto afecta solo la presentación del
  // menú; el nombre completo se conserva intacto para documentos y auditoría.
  const partesComa = limpio.split(",").map((parte) => parte.trim()).filter(Boolean);
  const partes = limpio.split(" ");
  let nombre = partesComa.length > 1
    ? partesComa[1].split(" ")[0]
    : partes.length >= 4
      ? partes[2]
      : partes.length === 3
        ? partes[2]
        : partes[0];

  nombre = nombre.toLocaleLowerCase("es");
  return nombre.charAt(0).toLocaleUpperCase("es") + nombre.slice(1);
}

export default function Navbar({ perfil }: { perfil: Perfil }) {
  const router = useRouter();
  const pathname = usePathname();
  const buscarRef = useRef<HTMLInputElement>(null);
  const [movilAbierto, setMovilAbierto] = useState(false);
  const [contraido, setContraido] = useState(false);
  const [busqueda, setBusqueda] = useState("");
  const [moduloAbierto, setModuloAbierto] = useState<GrupoId | null>(null);
  const [favoritos, setFavoritos] = useState<string[]>([]);
  const [mostrarSecundarios, setMostrarSecundarios] = useState(false);

  useEffect(() => {
    setContraido(window.localStorage.getItem("boman-sidebar-contraido") === "1");
    try {
      const guardados = JSON.parse(window.localStorage.getItem("boman-nav-favoritos") || "[]");
      if (Array.isArray(guardados)) setFavoritos(guardados.filter((x): x is string => typeof x === "string"));
    } catch {
      setFavoritos([]);
    }
  }, []);

  useEffect(() => {
    setMovilAbierto(false);
  }, [pathname]);

  useEffect(() => {
    function cerrarConEscape(evento: KeyboardEvent) {
      if (evento.key === "Escape") {
        setMovilAbierto(false);
        setBusqueda("");
        buscarRef.current?.blur();
      }
      if ((evento.ctrlKey || evento.metaKey) && evento.key.toLocaleLowerCase() === "k") {
        evento.preventDefault();
        if (window.matchMedia("(max-width: 859px)").matches) abrirMenuMovil();
        window.setTimeout(() => buscarRef.current?.focus(), 40);
      }
    }
    document.addEventListener("keydown", cerrarConEscape);
    return () => document.removeEventListener("keydown", cerrarConEscape);
  }, []);

  async function handleLogout() {
    await createClient().auth.signOut();
    router.push("/login");
    router.refresh();
  }

  function alternarContraido() {
    setContraido((actual) => {
      const siguiente = !actual;
      window.localStorage.setItem("boman-sidebar-contraido", siguiente ? "1" : "0");
      return siguiente;
    });
  }

  function alternarModulo(id: GrupoId) {
    if (contraido) {
      setContraido(false);
      window.localStorage.setItem("boman-sidebar-contraido", "0");
      setModuloAbierto(id);
      return;
    }
    setModuloAbierto((actual) => (actual === id ? null : id));
  }

  function alternarFavorito(href: string) {
    setFavoritos((actuales) => {
      const siguientes = actuales.includes(href)
        ? actuales.filter((item) => item !== href)
        : [...actuales, href];
      window.localStorage.setItem("boman-nav-favoritos", JSON.stringify(siguientes));
      return siguientes;
    });
  }

  const puedeEditarProductos = perfil.rol === "admin";
  const puedeAdministrar = perfil.rol === "admin";
  const puedeConfigurarStock = perfil.rol === "admin" || perfil.rol === "control";
  const puedeVerControl = tienePermiso(perfil, "control.acceder");
  const puedeVerVentas = tienePermiso(perfil, "ventas.acceder");
  const puedeVerCompras = tienePermiso(perfil, "compras.acceder");
  const puedeVerTesoreria = tienePermiso(perfil, "tesoreria.acceder");
  const puedeVerProduccion = tienePermiso(perfil, "produccion.acceder");
  const puedeVerCostosProduccion = tienePermiso(perfil, "produccion.costos.ver");
  // v107: oculta lo especifico de Boman Sport (contratos/BomanSport,
  // franquicias) incluso para admin cuando el ERP corre en modo marca
  // blanca. Se consulta directo desde el perfil, sin pasar por
  // tienePermiso(): esa funcion tiene un bypass de admin que la haria
  // inutil aqui (ver lib/permisos.ts).
  const modoBoman = perfil.modo_boman_especifico;
  const puedeVerFinanzasContratos = tienePermiso(perfil, "contratos.finanzas.ver") && modoBoman;
  const puedeVerNomina = tienePermiso(perfil, "nomina.acceder");
  const puedeVerFranquicia = tienePermiso(perfil, "franquicia.acceder") && modoBoman;
  // La caja de tienda propia usa el mismo permiso que la de franquicia, pero no
  // se le muestra a los roles de franquicia: ellos entran por /franquicia. No
  // se le aplica modoBoman: es la caja generica de cualquier tienda, no algo
  // especifico de franquicias.
  const puedeVerCajaTienda = tienePermiso(perfil, "franquicia.caja")
    && ["admin", "control", "gerencia", "tienda"].includes(perfil.rol);
  const puedeVerConsolidadoFranquicias = tienePermiso(perfil, "franquicia.consolidado") && modoBoman;
  const puedeVerNotificaciones = tienePermiso(perfil, "notificaciones.acceder");
  const puedeVerMantenimiento = tienePermiso(perfil, "mantenimiento.acceder");
  const puedeVerImportaciones = tienePermiso(perfil, "importaciones.acceder");
  const nombreMenu = nombreParaMenu(perfil.nombre_completo);
  const rolVisible = ({
    admin: "Administrador",
    bodega: "Bodega",
    logistica: "Logística",
    gerencia: "Gerencia",
    tienda: "Tienda",
    control: "Control",
    produccion: "Producción",
    nomina: "Nómina",
    franquiciado: "Franquiciado",
    vendedor_franquicia: "Vendedor de franquicia",
  } as Record<string, string>)[perfil.rol] ?? perfil.rol;

  const modulosBase: ModuloMenu[] = [
    { id: "notificaciones", etiqueta: "Notificaciones", opciones: [
      { href: "/notificaciones", etiqueta: "Centro de avisos", descripcion: "Pendientes, vencimientos y comunicados", visible: puedeVerNotificaciones },
    ] },
    { id: "ventas", etiqueta: "Ventas", opciones: [
      { href: "/ventas", etiqueta: "Facturas XML", descripcion: "Conciliación SRI e inventario", visible: puedeVerVentas },
      { href: "/ventas/contratos", etiqueta: "Ingreso de contratos", descripcion: "Nuevo pedido, brief, tallas y diseños", visible: tienePermiso(perfil, "contratos.editar") && modoBoman },
      { href: "/ventas/seguimiento", etiqueta: "Panel de vendedores", descripcion: "Entregas, mockups, prendas y saldos", visible: tienePermiso(perfil, "contratos.acceder") && modoBoman },
      { href: "/ventas/entregas", etiqueta: "Despachos y entregas", descripcion: "Entregas parciales, evidencias y reversión", visible: (tienePermiso(perfil, "contratos.entregar") || tienePermiso(perfil, "contratos.revertir_entrega")) && modoBoman },
      { href: "/ventas/clientes", etiqueta: "Clientes", descripcion: "Ficha integral, contactos e historial", visible: tienePermiso(perfil, "clientes.acceder") && modoBoman },
      { href: "/ventas/cartera", etiqueta: "Cuentas por cobrar", descripcion: "Saldos, promesas, abonos y recordatorios", visible: tienePermiso(perfil, "contratos.cartera.ver") && modoBoman },
      { href: "/tienda", etiqueta: "Caja de tienda", descripcion: "Ingresos, egresos y cierre diario", visible: puedeVerCajaTienda },
    ] },
    { id: "compras", etiqueta: "Compras", opciones: [
      { href: "/compras", etiqueta: "Órdenes y recepciones", descripcion: "Proveedores, recepción y costos", visible: puedeVerCompras },
      { href: "/compras/importar-xml", etiqueta: "XML y homologación", descripcion: "Carga masiva de facturas recibidas", visible: puedeVerCompras },
    ] },
    { id: "finanzas", etiqueta: "Tesorería", opciones: [
      { href: "/cuentas-por-pagar", etiqueta: "Cartera y cheques", descripcion: "Cuentas por pagar, vencimientos y efectivo comprometido", visible: puedeVerTesoreria },
    ] },
    { id: "produccion", etiqueta: "Producción", opciones: [
      { href: "/produccion/dashboard", etiqueta: "Dashboard de producción", descripcion: "Carga, capacidad, entregas y saldos de Boman Sport", visible: puedeVerProduccion },
      { href: "/produccion/cronograma", etiqueta: "Cronograma y capacidad", descripcion: "Carga diaria por prenda vs. capacidad del taller", visible: puedeVerProduccion },
      { href: "/produccion/reportes", etiqueta: "Reportes de producción", descripcion: "Producción por día, prenda, diseñador o contrato", visible: puedeVerProduccion },
      { href: "/produccion/costos", etiqueta: "Costos y rentabilidad", descripcion: "Hoja de costo, margen y consolidado por contrato", visible: puedeVerCostosProduccion },
      { href: "/produccion/cobros", etiqueta: "Presupuestos y cobros", descripcion: "Abonos, saldos e historial financiero", visible: puedeVerFinanzasContratos },
      { href: "/produccion/contratos", etiqueta: "Expedientes de contratos", descripcion: "Brief, diseños, tallas e historial completo", visible: puedeVerProduccion },
      { href: "/produccion", etiqueta: "Órdenes de producción", descripcion: "Rutas, etapas, lotes y costos", visible: puedeVerProduccion },
      { href: "/produccion/calidad", etiqueta: "Calidad y errores", descripcion: "Novedades, reprocesos y acciones correctivas", visible: puedeVerProduccion || puedeVerNomina },
      { href: "/tablero", etiqueta: "Tablero de contratos", descripcion: "Avance por etapa de los contratos de Boman Sport", visible: puedeVerProduccion },
      // Unica entrada visible para un operario de estacion: su cuenta no tiene
      // produccion.acceder, asi que el resto del menu le queda vacio.
      { href: "/estacion", etiqueta: "Mi estación", descripcion: "La cola de trabajo de tu estación del taller", visible: tienePermiso(perfil, "produccion.estacion") },
    ] },
    { id: "inventario", etiqueta: "Inventario", opciones: [
      { href: "/inventario", etiqueta: "Existencias", descripcion: "Stock disponible por almacén", visible: tienePermiso(perfil, "inventario.acceder") },
      { href: "/operaciones", etiqueta: "Operaciones", descripcion: "Solicitudes y transferencias", visible: tienePermiso(perfil, "operaciones.acceder") },
      { href: "/conteos", etiqueta: "Conteos físicos", descripcion: "Conteo, reconteo y diferencias", visible: tienePermiso(perfil, "conteos.acceder") },
      { href: "/movimientos", etiqueta: "Movimientos", descripcion: "Entradas, salidas y trazabilidad", visible: tienePermiso(perfil, "movimientos.acceder") },
      { href: "/control", etiqueta: "Centro de control", descripcion: "Aprobaciones e incidencias", visible: puedeVerControl },
      { href: "/productos", etiqueta: "Productos", descripcion: "Catálogo, categorías y precios", visible: puedeEditarProductos },
      { href: "/configuracion/inventario", etiqueta: "Políticas de stock", descripcion: "Mínimos, máximos y reposición", visible: puedeConfigurarStock },
    ] },
    { id: "franquicias", etiqueta: "Franquicias", opciones: [
      { href: "/franquicia", etiqueta: "Operación del local", descripcion: "Ventas, caja e inventario", visible: puedeVerFranquicia },
      { href: "/franquicias/consolidado", etiqueta: "Panel consolidado", descripcion: "Comparativo de todos los locales", visible: puedeVerConsolidadoFranquicias },
    ] },
    { id: "mantenimiento", etiqueta: "Mantenimiento", opciones: [
      { href: "/mantenimiento", etiqueta: "Maquinaria y activos", descripcion: "Preventivos, órdenes y costos", visible: puedeVerMantenimiento },
    ] },
    { id: "reportes", etiqueta: "Análisis", opciones: [
      { href: "/reportes", etiqueta: "Reportes", descripcion: "Indicadores y cumplimiento", visible: tienePermiso(perfil, "reportes.acceder") },
      { href: "/reportes/comercial", etiqueta: "Consolidado comercial", descripcion: "Ventas, entregas, cobros y comisiones", visible: tienePermiso(perfil, "reportes.comercial.ver") && modoBoman },
    ] },
    { id: "nomina", etiqueta: "Talento Humano y Nómina", opciones: [
      { href: "/nomina", etiqueta: "Personal y nómina", descripcion: "Expedientes, novedades y roles", visible: puedeVerNomina },
    ] },
    { id: "importaciones", etiqueta: "Importaciones", opciones: [
      { href: "/importar", etiqueta: "Centro de importaciones", descripcion: "Excel, CSV y cargas auditadas", visible: puedeVerImportaciones },
    ] },
    { id: "administracion", etiqueta: "Administración", opciones: [
      { href: "/administracion/empresas", etiqueta: "Empresas y locales", descripcion: "Grupo, RUC, tiendas y bodegas", visible: puedeAdministrar },
      { href: "/administracion/usuarios", etiqueta: "Usuarios", descripcion: "Roles, almacenes y accesos", visible: puedeAdministrar },
      { href: "/administracion/permisos", etiqueta: "Permisos por rol", descripcion: "Matriz de acceso del ERP", visible: puedeAdministrar },
      { href: "/administracion/permisos-personas", etiqueta: "Permisos por persona", descripcion: "Excepciones individuales sobre el rol", visible: puedeAdministrar },
      { href: "/administracion/franquicias", etiqueta: "Configurar franquicias", descripcion: "Locales y empresas titulares", visible: puedeAdministrar && modoBoman },
      { href: "/administracion/contratos-bomansport", etiqueta: "Sincronización BomanSport", descripcion: "Importación de contratos desde Google Sheets", visible: puedeAdministrar && modoBoman },
      { href: "/administracion/cierre-bomansport", etiqueta: "Cierre BomanSport", descripcion: "Diagnóstico y transición definitiva a Vercel", visible: puedeAdministrar && modoBoman },
    ] },
    // Modulo vacio a proposito: el pipeline de render de abajo filtra los
    // modulos sin opciones visibles, asi que "Contabilidad" no aparece en el
    // menu hasta que una pantalla contable real (libro diario, libro mayor,
    // activos fijos...) le agregue una opcion aqui. Trabajo grande aparte,
    // fuera de esta reorganizacion.
    { id: "contabilidad", etiqueta: "Contabilidad", opciones: [] },
  ];

  const consulta = busqueda.trim().toLocaleLowerCase("es");
  const gruposMapa = new Map<GrupoId, GrupoRenderizado>();
  function grupoDe(id: GrupoId): GrupoRenderizado {
    let grupo = gruposMapa.get(id);
    if (!grupo) {
      grupo = { id, etiqueta: ETIQUETA_GRUPO[id], opciones: [] };
      gruposMapa.set(id, grupo);
    }
    return grupo;
  }
  modulosBase.forEach((modulo) => {
    const opcionesFiltradas = modulo.opciones.filter((opcion) => opcion.visible && (
      !consulta || `${modulo.etiqueta} ${opcion.etiqueta} ${opcion.descripcion}`.toLocaleLowerCase("es").includes(consulta)
    ));
    if (!opcionesFiltradas.length) return;
    grupoDe(GRUPO_DE_MODULO[modulo.id]).opciones.push(...opcionesFiltradas);
  });
  const grupos = ORDEN_GRUPOS
    .map((id) => gruposMapa.get(id))
    .filter((grupo): grupo is GrupoRenderizado => Boolean(grupo));

  function rutaActiva(href: string) {
    return pathname === href || pathname.startsWith(`${href}/`);
  }

  const opcionActiva = modulosBase
    .flatMap((modulo) => modulo.opciones)
    .filter((opcion) => opcion.visible && rutaActiva(opcion.href))
    .sort((a, b) => b.href.length - a.href.length)[0];
  const moduloActivo = opcionActiva
    ? modulosBase.find((modulo) => modulo.opciones.some((opcion) => opcion.href === opcionActiva.href))
    : undefined;
  const grupoActivoId = moduloActivo ? GRUPO_DE_MODULO[moduloActivo.id] : undefined;
  const tituloActual = pathname === "/dashboard" ? "Panel principal" : opcionActiva?.etiqueta ?? "Boman ERP";
  const idsPrincipales = PRINCIPALES_POR_ROL[perfil.rol] ?? ["ventas", "produccion", "inventario", "reportes"];
  const gruposPrincipales = grupos.filter((grupo) => idsPrincipales.includes(grupo.id));
  const gruposSecundarios = grupos.filter((grupo) => !idsPrincipales.includes(grupo.id));
  const activoEsSecundario = Boolean(grupoActivoId && gruposSecundarios.some((grupo) => grupo.id === grupoActivoId));
  const todasLasOpciones = modulosBase.flatMap((modulo) => modulo.opciones.filter((opcion) => opcion.visible));
  const rutasRapidas = [...favoritos, ...(RAPIDOS_POR_ROL[perfil.rol] ?? [])]
    .filter((href, indice, lista) => lista.indexOf(href) === indice);
  const accesosRapidos = rutasRapidas
    .map((href) => todasLasOpciones.find((opcion) => opcion.href === href))
    .filter((opcion): opcion is OpcionMenu => Boolean(opcion))
    .slice(0, 4);

  useEffect(() => {
    setModuloAbierto(pathname === "/dashboard" ? null : grupoActivoId ?? null);
    const principales = PRINCIPALES_POR_ROL[perfil.rol] ?? ["ventas", "produccion", "inventario", "reportes"];
    if (grupoActivoId && !principales.includes(grupoActivoId)) setMostrarSecundarios(true);
  }, [pathname, grupoActivoId, perfil.rol]);

  function abrirMenuMovil() {
    // En pantallas pequeñas el menú siempre debe abrirse completo, aunque el
    // usuario lo haya dejado contraído previamente en el escritorio.
    setContraido(false);
    setMovilAbierto(true);
  }

  function renderOpcion(opcion: OpcionMenu) {
    const esFavorito = favoritos.includes(opcion.href);
    return (
      <div className="nav-subenlace-fila" key={opcion.href}>
        <Link
          href={opcion.href}
          className={`nav-subenlace ${rutaActiva(opcion.href) ? "activo" : ""}`}
          title={`${opcion.etiqueta} — ${opcion.descripcion}`}
        >
          <span className="nav-subenlace-marca" aria-hidden="true" />
          <span className="nav-enlace-texto"><strong>{opcion.etiqueta}</strong><small>{opcion.descripcion}</small></span>
        </Link>
        <button type="button" className={`nav-favorito ${esFavorito ? "activo" : ""}`} onClick={() => alternarFavorito(opcion.href)} aria-label={`${esFavorito ? "Quitar" : "Agregar"} ${opcion.etiqueta} ${esFavorito ? "de" : "a"} favoritos`} title={esFavorito ? "Quitar de favoritos" : "Agregar a favoritos"}>{esFavorito ? "★" : "☆"}</button>
      </div>
    );
  }

  function renderGrupo(grupo: GrupoRenderizado) {
    const expandido = Boolean(consulta) || moduloAbierto === grupo.id;
    const activo = grupoActivoId === grupo.id;
    return (
      <section className={`nav-seccion ${expandido ? "abierta" : ""}`} key={grupo.id} aria-label={grupo.etiqueta}>
        <button type="button" className={`nav-modulo ${activo ? "activo" : ""}`} onClick={() => alternarModulo(grupo.id)} aria-expanded={expandido} aria-controls={`nav-submenu-${grupo.id}`} title={grupo.etiqueta}>
          <span className="nav-enlace-icono"><Icono nombre={grupo.id} /></span>
          <span className="nav-modulo-texto">{grupo.etiqueta}</span>
          <span className="nav-modulo-cantidad">{grupo.opciones.length}</span>
          <span className="nav-modulo-flecha" aria-hidden="true">⌄</span>
        </button>
        {!contraido && <div className={`nav-submenu-envoltorio${expandido ? " abierta" : ""}`}><div className="nav-submenu" id={`nav-submenu-${grupo.id}`}>{grupo.opciones.map(renderOpcion)}</div></div>}
      </section>
    );
  }

  return (
    <>
      <header className="nav-mobile-bar">
        <button type="button" className="nav-mobile-trigger" onClick={abrirMenuMovil} aria-label="Abrir navegación" aria-controls="menu-principal" aria-expanded={movilAbierto}>
          <span aria-hidden="true">☰</span>
        </button>
        <BomanLogo className="nav-mobile-logo" priority />
        <strong>{tituloActual}</strong>
      </header>

      <nav id="menu-principal" className={`navbar ${contraido ? "nav-contraido" : ""} ${movilAbierto ? "nav-movil-abierto" : ""}`} aria-label="Navegación principal">
        <div className="nav-encabezado">
          <Link href="/dashboard" className="brand" aria-label="Ir al panel principal">
            <BomanLogo className="brand-logo" priority />
            <span className="brand-sistema">GESTIÓN EMPRESARIAL</span>
          </Link>
          <button type="button" className="nav-cerrar-movil" onClick={() => setMovilAbierto(false)} aria-label="Cerrar navegación">×</button>
        </div>

        <div className="nav-busqueda">
          <Icono nombre="buscar" size={17} />
          <input ref={buscarRef} value={busqueda} onChange={(evento) => setBusqueda(evento.target.value)} placeholder="Buscar módulo o tarea…" aria-label="Buscar módulo o tarea" />
          {!busqueda && <kbd>Ctrl K</kbd>}
          {busqueda && <button type="button" onClick={() => { setBusqueda(""); buscarRef.current?.focus(); }} aria-label="Limpiar búsqueda">×</button>}
        </div>

        <div className="nav-scroll">
          <Link href="/dashboard" className={`nav-enlace nav-inicio ${rutaActiva("/dashboard") ? "activo" : ""}`} title="Panel principal">
            <span className="nav-enlace-icono"><Icono nombre="inicio" /></span>
            <span className="nav-enlace-texto"><strong>Panel principal</strong><small>Resumen de tu operación</small></span>
          </Link>

          {!contraido && accesosRapidos.length > 0 && <section className="nav-rapidos" aria-label="Accesos rápidos">
            <span className="nav-seccion-titulo">Accesos rápidos</span>
            <div>{accesosRapidos.map((opcion) => <Link href={opcion.href} className={rutaActiva(opcion.href) ? "activo" : ""} key={`rapido-${opcion.href}`} title={opcion.descripcion}><span>↗</span>{opcion.etiqueta}</Link>)}</div>
          </section>}

          {!contraido && <div className="nav-seccion-titulo nav-seccion-divisor">Principal</div>}
          {gruposPrincipales.map(renderGrupo)}

          {gruposSecundarios.length > 0 && !contraido && <button type="button" className={`nav-mas-opciones ${mostrarSecundarios || activoEsSecundario || consulta ? "abierto" : ""}`} onClick={() => setMostrarSecundarios((actual) => !actual)} aria-expanded={mostrarSecundarios || activoEsSecundario || Boolean(consulta)}>
            <span>•••</span><strong>Más opciones</strong><small>{gruposSecundarios.length}</small><b>⌄</b>
          </button>}
          {(contraido || mostrarSecundarios || activoEsSecundario || Boolean(consulta)) && gruposSecundarios.map(renderGrupo)}
          {!grupos.length && <p className="nav-sin-resultados">No encontramos ese módulo.</p>}
        </div>

        <div className="nav-usuario">
          <span className="nav-avatar" aria-hidden="true">{nombreMenu.charAt(0).toUpperCase()}</span>
          <span className="nav-identidad" title={perfil.nombre_completo}><strong>{nombreMenu}</strong><small>{rolVisible}</small></span>
          <button type="button" className="nav-salir" onClick={handleLogout} aria-label="Cerrar sesión" title="Cerrar sesión"><Icono nombre="salir" size={18} /></button>
        </div>

        <button type="button" className="nav-contraer" onClick={alternarContraido} aria-label={contraido ? "Expandir navegación" : "Contraer navegación"} title={contraido ? "Expandir" : "Contraer"}>
          <span aria-hidden="true">{contraido ? "›" : "‹"}</span>
        </button>
      </nav>

      {movilAbierto && <button type="button" className="nav-overlay" onClick={() => setMovilAbierto(false)} aria-label="Cerrar navegación" />}
    </>
  );
}
