export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual } from "@/lib/getPerfil";
import PermisosPersonaCliente from "./PermisosPersonaCliente";

export default async function PermisosPersonaPage() {
  const perfil = await getPerfilActual();
  // Misma puerta no configurable que /administracion/permisos.
  if (perfil.rol !== "admin") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <PermisosPersonaCliente />
      </main>
    </>
  );
}
