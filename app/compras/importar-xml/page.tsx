export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import ImportarComprasXmlCliente from "./ImportarComprasXmlCliente";

export default async function ImportarComprasXmlPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "compras.acceder")) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container"><ImportarComprasXmlCliente perfil={perfil} /></main>
    </>
  );
}
