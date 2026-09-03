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
  | "produccion"
  | "inventario"
  | "mantenimiento"
  | "franquicias"
  | "reportes"
  | "nomina"
  | "importaciones"
  | "administracion";

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
  produccion: <><path d="m4 14 5-5 4 4 7-7"/><path d="M4 20h16M4 4v16"/></>,
  inventario: <><path d="m12 3 9 5-9 5-9-5 9-5Z"/><path d="m3 12 9 5 9-5M3 16l9 5 9-5"/></>,
  mantenimiento: <><path d="M14.7 6.3a4 4 0 0 0-5-5l2.1 2.1-3.4 3.4-2.1-2.1a4 4 0 0 0 5 5L19 17.4a2.1 2.1 0 0 1-3 3l-7.7-7.7"/></>,
  franquicias: <><path d="M4 10h16l-2-6H6l-2 6Z"/><path d="M5 10v10h14V10M9 20v-6h6v6"/><path d="M4 10c0 2 4 2 4 0 0 2 4 2 4 0 0 2 4 2 4 0 0 2 4 2 4 0"/></>,
  reportes: <><path d="M5 20V10M12 20V4M19 20v-7"/><path d="M3 20h18"/></>,
  nomina: <><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></>,
  importaciones: <><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 19h16"/></>,
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
  const [moduloAbierto, setModuloAbierto] = useState<ModuloId | null>(null);

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

  function alternarModulo(id: ModuloId) {
    if (contraido) {
      setContraido(false);
      window.localStorage.setItem("boman-sidebar-contraido", "0");
      setModuloAbierto(id);
      return;
    }
    setModuloAbierto((actual) => (actual === id ? null : id));
  }

  const puedeEditarProductos = perfil.rol === "admin";
  const puedeAdministrar = perfil.rol === "admin";
  const puedeConfigurarStock = perfil.rol === "admin" || perfil.rol === "control";
  const puedeVerControl = tienePermiso(perfil, "control.acceder");
  const puedeVerVentas = tienePermiso(perfil, "ventas.acceder");
  const puedeVerCompras = tienePermiso(perfil, "compras.acceder");
  const puedeVerProduccion = tienePermiso(perfil, "produccion.acceder");
  const puedeVerNomina = tienePermiso(perfil, "nomina.acceder");
  const puedeVerFranquicia = tienePermiso(perfil, "franquicia.acceder");
  const puedeVerConsolidadoFranquicias = tienePermiso(perfil, "franquicia.consolidado");
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
    ] },
    { id: "compras", etiqueta: "Compras", opciones: [
      { href: "/compras", etiqueta: "Órdenes y recepciones", descripcion: "Proveedores, recepción y costos", visible: puedeVerCompras },
      { href: "/compras/importar-xml", etiqueta: "XML y homologación", descripcion: "Carga masiva de facturas recibidas", visible: puedeVerCompras },
    ] },
    { id: "produccion", etiqueta: "Producción", opciones: [
      { href: "/produccion", etiqueta: "Órdenes de producción", descripcion: "Rutas, etapas, lotes y costos", visible: puedeVerProduccion },
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
    { id: "nomina", etiqueta: "Talento humano", opciones: [
      { href: "/nomina", etiqueta: "Personal y nómina", descripcion: "Expedientes, novedades y roles", visible: puedeVerNomina },
    ] },
    { id: "importaciones", etiqueta: "Importaciones", opciones: [
      { href: "/importar", etiqueta: "Centro de importaciones", descripcion: "Excel, CSV y cargas auditadas", visible: puedeVerImportaciones },
    ] },
    { id: "administracion", etiqueta: "Administración", opciones: [
      { href: "/administracion/empresas", etiqueta: "Empresas y locales", descripcion: "Grupo, RUC, tiendas y bodegas", visible: puedeAdministrar },
      { href: "/administracion/usuarios", etiqueta: "Usuarios", descripcion: "Roles, almacenes y accesos", visible: puedeAdministrar },
      { href: "/administracion/permisos", etiqueta: "Permisos por rol", descripcion: "Matriz de acceso del ERP", visible: puedeAdministrar },
      { href: "/administracion/franquicias", etiqueta: "Configurar franquicias", descripcion: "Locales y empresas titulares", visible: puedeAdministrar },
    ] },
  ];

  const consulta = busqueda.trim().toLocaleLowerCase("es");
  const modulos = modulosBase
    .map((modulo) => ({
      ...modulo,
      opciones: modulo.opciones.filter((opcion) => opcion.visible && (
        !consulta || `${modulo.etiqueta} ${opcion.etiqueta} ${opcion.descripcion}`.toLocaleLowerCase("es").includes(consulta)
      )),
    }))
    .filter((modulo) => modulo.opciones.length > 0);

  function rutaActiva(href: string) {
    return pathname === href || pathname.startsWith(`${href}/`);
  }

  const moduloActivo = modulosBase.find((modulo) =>
    modulo.opciones.some((opcion) => opcion.visible && rutaActiva(opcion.href))
  );
  const opcionActiva = moduloActivo?.opciones.find((opcion) => opcion.visible && rutaActiva(opcion.href));
  const tituloActual = pathname === "/dashboard" ? "Panel principal" : opcionActiva?.etiqueta ?? "Boman ERP";

  useEffect(() => {
    setModuloAbierto(pathname === "/dashboard" ? null : moduloActivo?.id ?? null);
  }, [pathname, moduloActivo?.id]);

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

          {modulos.map((modulo) => {
            const expandido = Boolean(consulta) || moduloAbierto === modulo.id;
            const activo = moduloActivo?.id === modulo.id;
            return (
              <section className={`nav-seccion ${expandido ? "abierta" : ""}`} key={modulo.id} aria-label={modulo.etiqueta}>
                <button
                  type="button"
                  className={`nav-modulo ${activo ? "activo" : ""}`}
                  onClick={() => alternarModulo(modulo.id)}
                  aria-expanded={expandido}
                  aria-controls={`nav-submenu-${modulo.id}`}
                  title={modulo.etiqueta}
                >
                  <span className="nav-enlace-icono"><Icono nombre={modulo.id} /></span>
                  <span className="nav-modulo-texto">{modulo.etiqueta}</span>
                  <span className="nav-modulo-flecha" aria-hidden="true">⌄</span>
                </button>
                {expandido && !contraido && (
                  <div className="nav-submenu" id={`nav-submenu-${modulo.id}`}>
                    {modulo.opciones.map((opcion) => (
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
                )}
              </section>
            );
          })}
          {!modulos.length && <p className="nav-sin-resultados">No encontramos ese módulo.</p>}
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
