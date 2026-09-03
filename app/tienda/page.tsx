export const dynamic = "force-dynamic";

import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import CajaTiendaCliente from "./CajaTiendaCliente";

export default async function CajaTiendaPage({
  searchParams,
}: {
  searchParams?: { local?: string };
}) {
  const perfil = await getPerfilActual();
  // Mismo permiso que la caja de franquicia: es el mismo diario, solo cambia
  // el tipo de local. v71 lo enciende para el rol tienda.
  if (!tienePermiso(perfil, "franquicia.caja")) redirect("/dashboard");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <CajaTiendaCliente rol={perfil.rol} tiendaInicialId={searchParams?.local} />
      </div>
    </>
  );
}
