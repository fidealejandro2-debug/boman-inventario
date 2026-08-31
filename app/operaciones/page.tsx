export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import OperacionesCliente from "./OperacionesCliente";

export default async function OperacionesPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "operaciones.acceder")) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <OperacionesCliente perfil={perfil} />
      </main>
    </>
  );
}
