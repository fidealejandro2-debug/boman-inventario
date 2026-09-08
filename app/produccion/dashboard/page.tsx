export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import DashboardProduccionCliente from "./DashboardProduccionCliente";

export default async function DashboardProduccionPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "produccion.acceder")) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <DashboardProduccionCliente />
      </main>
    </>
  );
}
