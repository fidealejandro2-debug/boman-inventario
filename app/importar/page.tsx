export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import ImportarCliente from "./ImportarCliente";

export default async function ImportarPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin" && perfil.rol !== "bodega") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <ImportarCliente />
      </div>
    </>
  );
}
