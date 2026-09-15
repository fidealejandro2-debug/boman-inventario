export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import NovedadesCliente from "./NovedadesCliente";

export default async function NovedadesOperativasPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "operativas.novedades.gestionar")) redirect("/dashboard");
  const puedeConfigurar = tienePermiso(perfil, "operativas.cierres.configurar");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <NovedadesCliente puedeConfigurar={puedeConfigurar} />
      </main>
    </>
  );
}
