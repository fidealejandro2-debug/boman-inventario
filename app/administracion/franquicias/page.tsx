export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import FranquiciasCliente from "./FranquiciasCliente";

export default async function FranquiciasAdminPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <FranquiciasCliente />
      </div>
    </>
  );
}
