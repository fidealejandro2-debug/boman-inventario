export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual } from "@/lib/getPerfil";
import VentasXmlCliente from "./VentasXmlCliente";

export default async function VentasPage() {
  const perfil = await getPerfilActual();
  if (!["admin", "control", "tienda", "gerencia"].includes(perfil.rol)) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <VentasXmlCliente perfil={perfil} />
      </main>
    </>
  );
}
