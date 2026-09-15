export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import RankingLocalesCliente from "./RankingLocalesCliente";

export default async function RankingLocalesPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "franquicia.consolidado")) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <RankingLocalesCliente />
      </main>
    </>
  );
}
