export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import ComprobantesVenta from "../ComprobantesVenta";

export default async function ComprobantesVentaPage() {
  const perfil = await getPerfilActual();
  // Admin/control ya ven todo por su rol (RLS de las tablas base, v150); el
  // permiso es para delegar la revisión a una persona puntual sin volverla
  // admin/control.
  const puedeVer = tienePermiso(perfil, "franquicia.comprobantes.auditar_todo")
    || ["admin", "control"].includes(perfil.rol);
  if (!puedeVer) redirect("/dashboard");
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <ComprobantesVenta />
      </main>
    </>
  );
}
