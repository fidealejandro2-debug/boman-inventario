export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import ContratosBomansportCliente from "./ContratosBomansportCliente";

export default async function ContratosBomansportPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <ContratosBomansportCliente />
      </div>
    </>
  );
}
