export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import ProduccionCliente from "./ProduccionCliente";

export default async function ProduccionPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "produccion.acceder")) {
    redirect("/dashboard");
  }
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container"><ProduccionCliente perfil={perfil} /></main>
    </>
  );
}
