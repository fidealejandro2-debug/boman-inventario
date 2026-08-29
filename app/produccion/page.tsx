export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual } from "@/lib/getPerfil";
import ProduccionCliente from "./ProduccionCliente";

export default async function ProduccionPage() {
  const perfil = await getPerfilActual();
  if (!["admin", "control", "bodega", "gerencia"].includes(perfil.rol)) {
    redirect("/dashboard");
  }
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container"><ProduccionCliente perfil={perfil} /></main>
    </>
  );
}
