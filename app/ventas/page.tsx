export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import VentasXmlCliente from "./VentasXmlCliente";

export default async function VentasPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "ventas.acceder")) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <VentasXmlCliente perfil={perfil} />
      </main>
    </>
  );
}
