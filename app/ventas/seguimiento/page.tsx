export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import PanelVendedoresCliente from "./PanelVendedoresCliente";

export default async function SeguimientoVentasPage() {
  const perfil = await getPerfilActual();
  if (!perfil.modo_boman_especifico || !tienePermiso(perfil, "contratos.acceder")) {
    redirect("/dashboard");
  }

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <PanelVendedoresCliente />
      </main>
    </>
  );
}
