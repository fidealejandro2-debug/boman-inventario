export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import ComprasCliente from "./ComprasCliente";

export default async function ComprasPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "compras.acceder")) {
    redirect("/dashboard");
  }
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container"><ComprasCliente perfil={perfil} /></main>
    </>
  );
}
