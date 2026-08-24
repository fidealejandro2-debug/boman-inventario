export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import ReportesCliente from "./ReportesCliente";

export default async function ReportesPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin" && perfil.rol !== "gerencia") redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <ReportesCliente />
      </div>
    </>
  );
}
