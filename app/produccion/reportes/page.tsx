export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import ReportesProduccionCliente from "./ReportesProduccionCliente";

export default async function ReportesProduccionPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "produccion.acceder")) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <ReportesProduccionCliente />
      </main>
    </>
  );
}
