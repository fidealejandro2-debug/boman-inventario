export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import MovimientosCliente from "./MovimientosCliente";

export default async function MovimientosPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "movimientos.acceder")) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <MovimientosCliente perfil={perfil} />
      </div>
    </>
  );
}
