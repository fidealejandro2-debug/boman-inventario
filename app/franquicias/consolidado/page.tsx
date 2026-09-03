export const dynamic = "force-dynamic";

import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import ConsolidadoFranquiciasCliente from "./ConsolidadoFranquiciasCliente";

export default async function ConsolidadoFranquiciasPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "franquicia.consolidado")) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <ConsolidadoFranquiciasCliente />
      </main>
    </>
  );
}
