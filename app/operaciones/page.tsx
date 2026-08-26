export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import OperacionesCliente from "./OperacionesCliente";

export default async function OperacionesPage() {
  const perfil = await getPerfilActual();
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <OperacionesCliente perfil={perfil} />
      </main>
    </>
  );
}
