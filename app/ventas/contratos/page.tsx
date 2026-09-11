export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import IngresoContratoCliente from "./IngresoContratoCliente";

export default async function IngresoContratoPage({ searchParams }: { searchParams: { editar?: string } }) {
  const perfil = await getPerfilActual();
  if (!perfil.modo_boman_especifico || !tienePermiso(perfil, "contratos.editar")) redirect("/dashboard");
  // ?editar=<id> reusa el mismo asistente para reeditar un contrato guardado.
  // El permiso es aparte y mas estrecho: reeditar reemplaza prendas, jugadores
  // y archivos, no solo corrige un dato.
  const editarId = tienePermiso(perfil, "contratos.editar_contenido") ? searchParams?.editar : undefined;
  return <><Navbar perfil={perfil}/><main className="container"><IngresoContratoCliente perfil={perfil} editarId={editarId}/></main></>;
}
