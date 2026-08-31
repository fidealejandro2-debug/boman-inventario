export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import ConteosCliente from "./ConteosCliente";

export default async function ConteosPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "conteos.acceder")) redirect("/dashboard");
  return <><Navbar perfil={perfil} /><main className="container"><ConteosCliente perfil={perfil} /></main></>;
}
