export const dynamic = "force-dynamic";

import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import NominaCliente from "./NominaCliente";

export default async function NominaPage() {
  const perfil = await getPerfilActual();
  // Más estricto que el resto del ERP: la misma matriz protege también el RLS.
  if (!tienePermiso(perfil, "nomina.acceder")) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <NominaCliente rol={perfil.rol} permisos={perfil.permisos} />
      </div>
    </>
  );
}
