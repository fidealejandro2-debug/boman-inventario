export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import CronogramaProduccionCliente from "./CronogramaProduccionCliente";

export default async function CronogramaProduccionPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "produccion.acceder")) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <CronogramaProduccionCliente esAdmin={perfil.rol === "admin"} puedeEditar={tienePermiso(perfil, "contratos.editar")} />
      </main>
    </>
  );
}
