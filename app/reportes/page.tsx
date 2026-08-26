export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import ReportesCliente from "./ReportesCliente";
import ReportesOperativos from "./ReportesOperativos";

export default async function ReportesPage() {
  const perfil = await getPerfilActual();
  if (!["admin", "control", "gerencia"].includes(perfil.rol)) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <ReportesCliente />
        <ReportesOperativos />
      </div>
    </>
  );
}
