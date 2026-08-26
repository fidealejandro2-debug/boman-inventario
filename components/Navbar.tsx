"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";

export default function Navbar({ perfil }: { perfil: Perfil }) {
  const router = useRouter();
  const pathname = usePathname();
  const supabase = createClient();
  const [abierto, setAbierto] = useState(false);

  async function handleLogout() {
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  const puedeEditarProductos = perfil.rol === "admin";
  const puedeVerTodo = ["admin", "control", "gerencia"].includes(perfil.rol);
  const rolVisible = ({ admin: "Administrador", bodega: "Bodega", logistica: "Logística", gerencia: "Gerencia", tienda: "Tienda", control: "Control" } as Record<string, string>)[perfil.rol] ?? perfil.rol;
  const enlaces = [
    { href: "/dashboard", etiqueta: "Inicio", visible: true },
    { href: "/inventario", etiqueta: "Stock", visible: true },
    { href: "/operaciones", etiqueta: "Solicitudes y transferencias", visible: true },
    { href: "/conteos", etiqueta: "Conteos", visible: perfil.rol !== "logistica" },
    { href: "/movimientos", etiqueta: "Movimientos", visible: true },
    { href: "/productos", etiqueta: "Productos", visible: puedeEditarProductos },
    { href: "/reportes", etiqueta: "Reportes", visible: puedeVerTodo },
    { href: "/control", etiqueta: "Control", visible: puedeVerTodo },
    { href: "/configuracion/inventario", etiqueta: "Políticas de stock", visible: perfil.rol === "admin" || perfil.rol === "control" },
    { href: "/administracion/usuarios", etiqueta: "Usuarios", visible: perfil.rol === "admin" },
  ].filter((enlace) => enlace.visible);

  return (
    <nav className="navbar">
      <div className="nav-principal">
        <div className="nav-encabezado">
          <Link href="/dashboard" className="brand" onClick={() => setAbierto(false)}>BOMAN · Inventario</Link>
          <button
            type="button"
            className="nav-toggle"
            onClick={() => setAbierto((valor) => !valor)}
            aria-expanded={abierto}
            aria-label="Abrir menú de navegación"
          >
            {abierto ? "✕" : "☰"}
          </button>
        </div>
        <div className={`nav-links ${abierto ? "abierto" : ""}`}>
          {enlaces.map((enlace) => (
            <Link
              key={enlace.href}
              href={enlace.href}
              className={pathname === enlace.href || pathname.startsWith(enlace.href + "/") ? "activo" : ""}
              onClick={() => setAbierto(false)}
            >
              {enlace.etiqueta}
            </Link>
          ))}
        </div>
      </div>
      <div className={`nav-usuario ${abierto ? "abierto" : ""}`}>
        <span>
          {perfil.nombre_completo} · {rolVisible}
        </span>
        <button className="nav-salir" onClick={handleLogout}>
          Salir
        </button>
      </div>
    </nav>
  );
}
