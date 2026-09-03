export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import CuentasPorPagarCliente from "./CuentasPorPagarCliente";

export default async function CuentasPorPagarPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "tesoreria.acceder")) redirect("/dashboard");
  return <><Navbar perfil={perfil} /><main className="container"><CuentasPorPagarCliente perfil={perfil} /></main></>;
}
