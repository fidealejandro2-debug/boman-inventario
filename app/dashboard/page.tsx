export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import DashboardCliente from "./DashboardCliente";

export default async function DashboardPage() {
  const perfil = await getPerfilActual();
  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <DashboardCliente perfil={perfil} />
      </div>
    </>
  );
}
