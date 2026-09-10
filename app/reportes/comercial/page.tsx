export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import ConsolidadoComercialCliente from "./ConsolidadoComercialCliente";

export default async function ConsolidadoComercialPage() {
  const perfil = await getPerfilActual();
  if (!perfil.modo_boman_especifico || !tienePermiso(perfil, "reportes.comercial.ver")) {
    redirect("/dashboard");
  }

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <ConsolidadoComercialCliente
          puedeConfigurarComisiones={tienePermiso(perfil, "reportes.comercial.comisiones")}
        />
      </main>
    </>
  );
}
