export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual } from "@/lib/getPerfil";
import EmpresasCliente from "./EmpresasCliente";

export default async function EmpresasPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <EmpresasCliente />
      </main>
    </>
  );
}
