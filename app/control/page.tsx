export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import ControlCliente from "./ControlCliente";

export default async function ControlPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "control.acceder")) redirect("/dashboard");
  return <><Navbar perfil={perfil} /><main className="container"><ControlCliente perfil={perfil} /></main></>;
}
