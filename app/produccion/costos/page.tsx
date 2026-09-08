export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import CostosRentabilidadCliente from "./CostosRentabilidadCliente";

export default async function CostosRentabilidadPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "produccion.costos.ver")) redirect("/dashboard");
  return <><Navbar perfil={perfil}/><main className="container"><CostosRentabilidadCliente puedeEditar={tienePermiso(perfil,"produccion.costos.editar")}/></main></>;
}
