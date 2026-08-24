export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import MovimientosCliente from "./MovimientosCliente";

export default async function MovimientosPage() {
  const perfil = await getPerfilActual();
  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <MovimientosCliente perfil={perfil} />
      </div>
    </>
  );
}
