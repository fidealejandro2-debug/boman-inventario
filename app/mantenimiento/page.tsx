export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import MantenimientoCliente from "./MantenimientoCliente";

export default async function MantenimientoPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "mantenimiento.acceder")) redirect("/dashboard");
  return <><Navbar perfil={perfil} /><main className="container"><MantenimientoCliente perfil={perfil} /></main></>;
}
