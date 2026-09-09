"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
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
type GrupoId = Exclude<ModuloId, "inventario" | "mantenimiento">;

const GRUPO_DE_MODULO: Record<ModuloId, GrupoId> = {
  notificaciones: "notificaciones",
  ventas: "ventas",
  compras: "compras",
  finanzas: "finanzas",
  produccion: "produccion",
  inventario: "compras",      // Compras: facturas/retenciones + bodega/inventario
  mantenimiento: "produccion", // Producción: maquinaria, mantenimientos, contratos...
  franquicias: "franquicias",
  reportes: "reportes",
  nomina: "nomina",
  importaciones: "importaciones",
  administracion: "administracion",
  contabilidad: "contabilidad",
};

// Modulos que, dentro de su grupo, se muestran como su propio sub-menu
// (un segundo nivel de acordeon) en vez de mezclar sus opciones sueltas con
// las del grupo. Hoy solo Inventario: tiene 7 opciones propias y merece su
// espacio dentro de Compras. Mantenimiento tiene una sola opcion, por eso se
// deja como item suelto dentro de Producción en vez de anidarlo.
const MODULOS_ANIDADOS: Partial<Record<ModuloId, true>> = { inventario: true };

const ORDEN_GRUPOS: GrupoId[] = [
  "compras", "finanzas", "contabilidad", "ventas", "produccion",
  "franquicias", "nomina", "administracion",
  "notificaciones", "reportes", "importaciones",
];

const ETIQUETA_GRUPO: Record<GrupoId, string> = {
  compras: "Compras",
  finanzas: "Tesorería",
  contabilidad: "Contabilidad",
  ventas: "Ventas",
  produccion: "Producción",
  franquicias: "Franquicias",
  nomina: "Talento Humano y Nómina",
  administracion: "Administración",
  notificaciones: "Notificaciones",
  reportes: "Análisis",
  importaciones: "Importaciones",
};

type SubgrupoRenderizado = { id: ModuloId; etiqueta: string; opciones: OpcionMenu[] };
type GrupoRenderizado = {
  id: GrupoId;
  etiqueta: string;
  opcionesDirectas: OpcionMenu[];
  subgrupos: SubgrupoRenderizado[];
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
  const [movilAbierto, setMovilAbierto] = useState(false);
  const [contraido, setContraido] = useState(false);
  const [busqueda, setBusqueda] = useState("");
  const [moduloAbierto, setModuloAbierto] = useState<GrupoId | null>(null);
  const [subgrupoAbierto, setSubgrupoAbierto] = useState<ModuloId | null>(null);

  useEffect(() => {
    setContraido(window.localStorage.getItem("boman-sidebar-contraido") === "1");
  }, []);

  useEffect(() => {
    setMovilAbierto(false);
  }, [pathname]);

  useEffect(() => {
    function cerrarConEscape(evento: KeyboardEvent) {
      if (evento.key === "Escape") setMovilAbierto(false);
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

  function alternarSubgrupo(id: ModuloId) {
    setSubgrupoAbierto((actual) => (actual === id ? null : id));
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
      grupo = { id, etiqueta: ETIQUETA_GRUPO[id], opcionesDirectas: [], subgrupos: [] };
      gruposMapa.set(id, grupo);
    }
    return grupo;
  }
  modulosBase.forEach((modulo) => {
    const opcionesFiltradas = modulo.opciones.filter((opcion) => opcion.visible && (
      !consulta || `${modulo.etiqueta} ${opcion.etiqueta} ${opcion.descripcion}`.toLocaleLowerCase("es").includes(consulta)
    ));
    if (!opcionesFiltradas.length) return;
    const grupo = grupoDe(GRUPO_DE_MODULO[modulo.id]);
    if (MODULOS_ANIDADOS[modulo.id]) {
      grupo.subgrupos.push({ id: modulo.id, etiqueta: modulo.etiqueta, opciones: opcionesFiltradas });
    } else {
      grupo.opcionesDirectas.push(...opcionesFiltradas);
    }
  });
  const grupos = ORDEN_GRUPOS
    .map((id) => gruposMapa.get(id))
    .filter((grupo): grupo is GrupoRenderizado => Boolean(grupo));

  function rutaActiva(href: string) {
    return pathname === href || pathname.startsWith(`${href}/`);
  }

  const moduloActivo = modulosBase.find((modulo) =>
    modulo.opciones.some((opcion) => opcion.visible && rutaActiva(opcion.href))
  );
  const grupoActivoId = moduloActivo ? GRUPO_DE_MODULO[moduloActivo.id] : undefined;
  const subgrupoActivoId = moduloActivo && MODULOS_ANIDADOS[moduloActivo.id] ? moduloActivo.id : undefined;
  const opcionActiva = moduloActivo?.opciones.find((opcion) => opcion.visible && rutaActiva(opcion.href));
  const tituloActual = pathname === "/dashboard" ? "Panel principal" : opcionActiva?.etiqueta ?? "Boman ERP";

  useEffect(() => {
    setModuloAbierto(pathname === "/dashboard" ? null : grupoActivoId ?? null);
    setSubgrupoAbierto(pathname === "/dashboard" ? null : subgrupoActivoId ?? null);
  }, [pathname, grupoActivoId, subgrupoActivoId]);

  return (
    <>
      <header className="nav-mobile-bar">
        <button type="button" className="nav-mobile-trigger" onClick={() => setMovilAbierto(true)} aria-label="Abrir navegación" aria-controls="menu-principal" aria-expanded={movilAbierto}>
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
          <input value={busqueda} onChange={(evento) => setBusqueda(evento.target.value)} placeholder="Buscar módulo…" aria-label="Buscar módulo" />
        </div>

        <div className="nav-scroll">
          <Link href="/dashboard" className={`nav-enlace nav-inicio ${rutaActiva("/dashboard") ? "activo" : ""}`} title="Panel principal">
            <span className="nav-enlace-icono"><Icono nombre="inicio" /></span>
            <span className="nav-enlace-texto"><strong>Panel principal</strong><small>Resumen de tu operación</small></span>
          </Link>

          {grupos.map((grupo) => {
            const expandido = Boolean(consulta) || moduloAbierto === grupo.id;
            const activo = grupoActivoId === grupo.id;
            return (
              <section className={`nav-seccion ${expandido ? "abierta" : ""}`} key={grupo.id} aria-label={grupo.etiqueta}>
                <button
                  type="button"
                  className={`nav-modulo ${activo ? "activo" : ""}`}
                  onClick={() => alternarModulo(grupo.id)}
                  aria-expanded={expandido}
                  aria-controls={`nav-submenu-${grupo.id}`}
                  title={grupo.etiqueta}
                >
                  <span className="nav-enlace-icono"><Icono nombre={grupo.id} /></span>
                  <span className="nav-modulo-texto">{grupo.etiqueta}</span>
                  <span className="nav-modulo-flecha" aria-hidden="true">⌄</span>
                </button>
                {!contraido && (
                  <div className={`nav-submenu-envoltorio${expandido ? " abierta" : ""}`}>
                    <div className="nav-submenu" id={`nav-submenu-${grupo.id}`}>
                      {grupo.opcionesDirectas.map((opcion) => (
                        <Link
                          key={opcion.href}
                          href={opcion.href}
                          className={`nav-subenlace ${rutaActiva(opcion.href) ? "activo" : ""}`}
                          title={`${opcion.etiqueta} — ${opcion.descripcion}`}
                        >
                          <span className="nav-subenlace-marca" aria-hidden="true" />
                          <span className="nav-enlace-texto"><strong>{opcion.etiqueta}</strong><small>{opcion.descripcion}</small></span>
                          <span className="nav-enlace-flecha" aria-hidden="true">›</span>
                        </Link>
                      ))}
                      {grupo.subgrupos.map((subgrupo) => {
                        const subExpandido = Boolean(consulta) || subgrupoAbierto === subgrupo.id;
                        return (
                          <div key={subgrupo.id}>
                            <button
                              type="button"
                              className={`nav-modulo ${subgrupoActivoId === subgrupo.id ? "activo" : ""}`}
                              onClick={() => alternarSubgrupo(subgrupo.id)}
                              aria-expanded={subExpandido}
                              aria-controls={`nav-submenu-${subgrupo.id}`}
                              title={subgrupo.etiqueta}
                            >
                              <span className="nav-enlace-icono"><Icono nombre={subgrupo.id} size={17} /></span>
                              <span className="nav-modulo-texto">{subgrupo.etiqueta}</span>
                              <span className="nav-modulo-flecha" aria-hidden="true">⌄</span>
                            </button>
                            <div className={`nav-submenu-envoltorio${subExpandido ? " abierta" : ""}`}>
                              <div className="nav-submenu" id={`nav-submenu-${subgrupo.id}`}>
                                {subgrupo.opciones.map((opcion) => (
                                  <Link
                                    key={opcion.href}
                                    href={opcion.href}
                                    className={`nav-subenlace ${rutaActiva(opcion.href) ? "activo" : ""}`}
                                    title={`${opcion.etiqueta} — ${opcion.descripcion}`}
                                  >
                                    <span className="nav-subenlace-marca" aria-hidden="true" />
                                    <span className="nav-enlace-texto"><strong>{opcion.etiqueta}</strong><small>{opcion.descripcion}</small></span>
                                    <span className="nav-enlace-flecha" aria-hidden="true">›</span>
                                  </Link>
                                ))}
                              </div>
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                )}
              </section>
            );
          })}
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
