"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";

export default function Navbar({ perfil }: { perfil: Perfil }) {
  const router = useRouter();
  const supabase = createClient();

  async function handleLogout() {
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  const puedeEditarProductos = perfil.rol === "admin";
  const puedeVerTodo = perfil.rol === "admin" || perfil.rol === "gerencia";
  const puedeImportar = perfil.rol === "admin" || perfil.rol === "bodega";

  return (
    <div className="navbar">
      <div style={{ display: "flex", alignItems: "center" }}>
        <span className="brand" style={{ marginRight: 30 }}>BOMAN · Inventario</span>
        <Link href="/dashboard">Inicio</Link>
        <Link href="/inventario">Stock</Link>
        <Link href="/movimientos">Movimientos</Link>
        {puedeEditarProductos && <Link href="/productos">Productos</Link>}
        {puedeVerTodo && <Link href="/reportes">Reportes</Link>}
        {puedeImportar && <Link href="/importar">Importar</Link>}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <span style={{ fontSize: 13, opacity: 0.85 }}>
          {perfil.nombre_completo} · {perfil.rol}
        </span>
        <button className="secondary" style={{ background: "transparent", color: "white", borderColor: "white" }} onClick={handleLogout}>
          Salir
        </button>
      </div>
    </div>
  );
}
