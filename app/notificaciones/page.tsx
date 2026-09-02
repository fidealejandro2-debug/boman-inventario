export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import NotificacionesCliente from "./NotificacionesCliente";

export default async function NotificacionesPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "notificaciones.acceder")) redirect("/dashboard");
  return <><Navbar perfil={perfil} /><main className="container"><NotificacionesCliente perfil={perfil} /></main></>;
}
