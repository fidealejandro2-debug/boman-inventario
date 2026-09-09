export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import IngresoContratoCliente from "./IngresoContratoCliente";

export default async function IngresoContratoPage() {
  const perfil = await getPerfilActual();
  if (!perfil.modo_boman_especifico || !tienePermiso(perfil, "contratos.editar")) redirect("/dashboard");
  return <><Navbar perfil={perfil}/><main className="container"><IngresoContratoCliente perfil={perfil}/></main></>;
}
