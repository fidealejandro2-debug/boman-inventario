export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import ConfiguracionInventarioCliente from "./ConfiguracionInventarioCliente";

export default async function ConfiguracionInventarioPage() {
  const perfil = await getPerfilActual();
  if (!["admin", "control"].includes(perfil.rol)) redirect("/dashboard");
  return <><Navbar perfil={perfil} /><main className="container"><ConfiguracionInventarioCliente /></main></>;
}
