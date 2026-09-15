export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import StockCliente from "./StockCliente";

export default async function InventarioPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "inventario.acceder")) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <StockCliente
          perfil={perfil}
          puedeEditarFotos={["admin", "franquiciado", "tienda"].includes(perfil.rol)}
        />
      </div>
    </>
  );
}
