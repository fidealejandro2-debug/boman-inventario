export const dynamic = "force-dynamic";

import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import FranquiciaCliente from "./FranquiciaCliente";

export default async function FranquiciaPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "franquicia.acceder")) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <FranquiciaCliente rol={perfil.rol} permisos={perfil.permisos} />
      </div>
    </>
  );
}
