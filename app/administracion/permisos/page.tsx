export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual } from "@/lib/getPerfil";
import PermisosCliente from "./PermisosCliente";

export default async function PermisosPage() {
  const perfil = await getPerfilActual();
  // Esta puerta no es configurable: evita que el ultimo administrador se
  // quite a si mismo la capacidad de recuperar la matriz.
  if (perfil.rol !== "admin") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <PermisosCliente />
      </main>
    </>
  );
}
