export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import UsuariosCliente from "./UsuariosCliente";

export default async function UsuariosPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <UsuariosCliente usuarioActualId={perfil.id} />
      </div>
    </>
  );
}
