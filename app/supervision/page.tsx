export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import PanelSupervisionCliente from "./PanelSupervisionCliente";

export default async function SupervisionPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "supervision.acceder")) redirect("/dashboard");

  return <>
    <Navbar perfil={perfil} />
    <main className="container">
      <PanelSupervisionCliente />
    </main>
  </>;
}
