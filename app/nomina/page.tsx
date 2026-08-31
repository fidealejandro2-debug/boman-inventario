export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import NominaCliente from "./NominaCliente";

export default async function NominaPage() {
  const perfil = await getPerfilActual();
  // Más estricto que el resto del ERP: aquí viven cédulas y sueldos reales.
  if (!["admin", "gerencia", "nomina"].includes(perfil.rol)) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <NominaCliente rol={perfil.rol} />
      </div>
    </>
  );
}
