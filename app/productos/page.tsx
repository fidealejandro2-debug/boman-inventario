export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import ProductosCliente from "./ProductosCliente";

export default async function ProductosPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <ProductosCliente />
      </div>
    </>
  );
}
