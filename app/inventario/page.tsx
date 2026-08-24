export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import StockCliente from "./StockCliente";

export default async function InventarioPage() {
  const perfil = await getPerfilActual();
  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <StockCliente />
      </div>
    </>
  );
}
