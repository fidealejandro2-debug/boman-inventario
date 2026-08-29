"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";
import BomanLogo from "@/components/BomanLogo";

type OpcionMenu = {
  href: string;
  etiqueta: string;
  descripcion: string;
  visible: boolean;
};

type ModuloMenu = {
  id: "ventas" | "compras" | "produccion" | "inventario" | "reportes" | "administracion";
  etiqueta: string;
  icono: string;
  opciones: OpcionMenu[];
};

export default function Navbar({ perfil }: { perfil: Perfil }) {
  const router = useRouter();
  const pathname = usePathname();
  const supabase = createClient();
  const navRef = useRef<HTMLElement>(null);
  const [abierto, setAbierto] = useState(false);
  const [moduloAbierto, setModuloAbierto] = useState<string | null>(null);

  async function handleLogout() {
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  function cerrarMenu() {
    setAbierto(false);
    setModuloAbierto(null);
  }

  useEffect(() => {
    cerrarMenu();
  }, [pathname]);

  useEffect(() => {
    function cerrarDesdeFuera(evento: MouseEvent) {
      if (navRef.current && !navRef.current.contains(evento.target as Node)) setModuloAbierto(null);
    }
    function cerrarConEscape(evento: KeyboardEvent) {
      if (evento.key === "Escape") cerrarMenu();
    }
    document.addEventListener("mousedown", cerrarDesdeFuera);
    document.addEventListener("keydown", cerrarConEscape);
    return () => {
      document.removeEventListener("mousedown", cerrarDesdeFuera);
      document.removeEventListener("keydown", cerrarConEscape);
    };
  }, []);

  const puedeEditarProductos = perfil.rol === "admin";
  const puedeVerReportes = ["admin", "control", "gerencia"].includes(perfil.rol);
  const puedeAdministrar = perfil.rol === "admin";
  const puedeConfigurarStock = perfil.rol === "admin" || perfil.rol === "control";
  const puedeVerControl = ["admin", "control", "gerencia"].includes(perfil.rol);
  const puedeVerVentas = ["admin", "control", "tienda", "bodega", "gerencia"].includes(perfil.rol);
  const puedeVerCompras = ["admin", "control", "bodega", "gerencia"].includes(perfil.rol);
  const puedeVerProduccion = ["admin", "control", "bodega", "gerencia"].includes(perfil.rol);
  const rolVisible = ({
    admin: "Administrador",
    bodega: "Bodega",
    logistica: "Logística",
    gerencia: "Gerencia",
    tienda: "Tienda",
    control: "Control",
  } as Record<string, string>)[perfil.rol] ?? perfil.rol;

  const modulosBase: ModuloMenu[] = [
    {
      id: "ventas",
      etiqueta: "Ventas",
      icono: "$",
      opciones: [
        { href: "/ventas", etiqueta: "Facturas XML", descripcion: "Conciliación SRI y descuento de inventario", visible: puedeVerVentas },
      ],
    },
    {
      id: "compras",
      etiqueta: "Compras",
      icono: "OC",
      opciones: [
        { href: "/compras", etiqueta: "Órdenes y recepciones", descripcion: "Proveedores, aprobación, recepción parcial y costos", visible: puedeVerCompras },
      ],
    },
    {
      id: "produccion",
      etiqueta: "Producción",
      icono: "OP",
      opciones: [
        { href: "/produccion", etiqueta: "Órdenes, fórmulas y costos", descripcion: "Materiales en proceso, mermas, resultado y costo real por RUC", visible: puedeVerProduccion },
      ],
    },
    {
      id: "inventario",
      etiqueta: "Inventario",
      icono: "▦",
      opciones: [
        { href: "/inventario", etiqueta: "Stock por almacén", descripcion: "Físico, reservado, disponible y en tránsito", visible: true },
        { href: "/operaciones", etiqueta: "Solicitudes y transferencias", descripcion: "Reposición, preparación, despacho y recepción", visible: true },
        { href: "/conteos", etiqueta: "Conteos físicos", descripcion: "Conteo, reconteo y diferencias", visible: perfil.rol !== "logistica" },
        { href: "/movimientos", etiqueta: "Movimientos", descripcion: "Entradas, salidas y trazabilidad", visible: true },
        { href: "/control", etiqueta: "Centro de Control", descripcion: "Aprobaciones, incidencias y auditoría", visible: puedeVerControl },
        { href: "/productos", etiqueta: "Catálogo de productos", descripcion: "Productos, categorías, precios e importación", visible: puedeEditarProductos },
        { href: "/configuracion/inventario", etiqueta: "Políticas de stock", descripcion: "Mínimos, máximos y puntos de reposición", visible: puedeConfigurarStock },
      ],
    },
    {
      id: "reportes",
      etiqueta: "Reportes",
      icono: "▥",
      opciones: [
        { href: "/reportes", etiqueta: "Reportes y análisis", descripcion: "Stock, valoración, reposición y cumplimiento", visible: puedeVerReportes },
      ],
    },
    {
      id: "administracion",
      etiqueta: "Administración",
      icono: "⚙",
      opciones: [
        { href: "/administracion/empresas", etiqueta: "Grupo y empresas", descripcion: "RUC, tiendas, bodegas y operadoras del grupo económico", visible: puedeAdministrar },
        { href: "/administracion/usuarios", etiqueta: "Usuarios y permisos", descripcion: "Roles, almacenes, contraseñas y eliminación de accesos", visible: puedeAdministrar },
      ],
    },
  ];
  const modulos = modulosBase
    .map((modulo) => ({ ...modulo, opciones: modulo.opciones.filter((opcion) => opcion.visible) }))
    .filter((modulo) => modulo.opciones.length > 0);

  function rutaActiva(href: string) {
    return pathname === href || pathname.startsWith(href + "/");
  }

  return (
    <nav className="navbar" ref={navRef} aria-label="Navegación principal">
      <div className="nav-principal">
        <div className="nav-encabezado">
          <Link href="/dashboard" className="brand" onClick={cerrarMenu}>
            <BomanLogo className="brand-logo" priority />
            <span className="brand-sistema">ERP DE INVENTARIO</span>
          </Link>
          <button
            type="button"
            className="nav-toggle"
            onClick={() => {
              setAbierto((valor) => !valor);
              setModuloAbierto(null);
            }}
            aria-expanded={abierto}
            aria-controls="menu-principal"
            aria-label={abierto ? "Cerrar menú de navegación" : "Abrir menú de navegación"}
          >
            {abierto ? "×" : "☰"}
          </button>
        </div>

        <div id="menu-principal" className={`nav-modulos ${abierto ? "abierto" : ""}`}>
          <Link href="/dashboard" className={`nav-inicio ${rutaActiva("/dashboard") ? "activo" : ""}`} onClick={cerrarMenu}>
            Inicio
          </Link>
          {modulos.map((modulo) => {
            const activo = modulo.opciones.some((opcion) => rutaActiva(opcion.href));
            const expandido = moduloAbierto === modulo.id;
            return (
              <div className={`nav-modulo ${activo ? "activo" : ""}`} key={modulo.id}>
                <button
                  type="button"
                  className="nav-modulo-trigger"
                  onClick={() => setModuloAbierto(expandido ? null : modulo.id)}
                  aria-expanded={expandido}
                  aria-haspopup="true"
                >
                  <span className="nav-modulo-icono" aria-hidden="true">{modulo.icono}</span>
                  {modulo.etiqueta}
                  <span className="nav-chevron" aria-hidden="true">⌄</span>
                </button>
                <div className={`nav-submenu ${expandido ? "abierto" : ""}`}>
                  <div className="nav-submenu-titulo">Módulo de {modulo.etiqueta}</div>
                  {modulo.opciones.map((opcion) => (
                    <Link
                      key={opcion.href}
                      href={opcion.href}
                      className={rutaActiva(opcion.href) ? "activo" : ""}
                      onClick={cerrarMenu}
                    >
                      <span>{opcion.etiqueta}</span>
                      <small>{opcion.descripcion}</small>
                    </Link>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <div className={`nav-usuario ${abierto ? "abierto" : ""}`}>
        <span className="nav-identidad">
          <strong>{perfil.nombre_completo}</strong>
          <small>{rolVisible}</small>
        </span>
        <button type="button" className="nav-salir" onClick={handleLogout}>Salir</button>
      </div>
    </nav>
  );
}
