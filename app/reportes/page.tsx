export const dynamic = "force-dynamic";

import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import ReportesCliente from "./ReportesCliente";
import ReportesOperativos from "./ReportesOperativos";
import ReportesAvanzados from "./ReportesAvanzados";

export default async function ReportesPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "reportes.acceder")) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <ReportesCliente />
        <ReportesOperativos />
        <ReportesAvanzados />
      </div>
    </>
  );
}
