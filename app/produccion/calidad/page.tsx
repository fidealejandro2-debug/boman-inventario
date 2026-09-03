export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import NovedadesCalidadCliente from "./NovedadesCalidadCliente";

export default async function CalidadProduccionPage() {
  const perfil = await getPerfilActual();
  if (
    !tienePermiso(perfil, "produccion.acceder")
    && !tienePermiso(perfil, "nomina.acceder")
  ) redirect("/dashboard");

  return <><Navbar perfil={perfil} /><main className="container"><NovedadesCalidadCliente perfil={perfil} /></main></>;
}
