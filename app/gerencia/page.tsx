export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import PanelGerenciaCliente from "./PanelGerenciaCliente";

export default async function GerenciaPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "gerencia.acceder")) redirect("/dashboard");

  return <>
    <Navbar perfil={perfil} />
    <main className="container">
      <PanelGerenciaCliente accesos={{
        modoBoman: perfil.modo_boman_especifico,
        comercial: tienePermiso(perfil, "reportes.comercial.ver"),
        produccion: tienePermiso(perfil, "produccion.acceder"),
        costos: tienePermiso(perfil, "produccion.costos.ver"),
        contratos: tienePermiso(perfil, "contratos.acceder"),
        cartera: tienePermiso(perfil, "contratos.cartera.ver"),
        finanzasContratos: tienePermiso(perfil, "contratos.finanzas.ver"),
        franquicias: tienePermiso(perfil, "franquicia.consolidado"),
        inventario: tienePermiso(perfil, "inventario.acceder"),
        reportes: tienePermiso(perfil, "reportes.acceder"),
        tesoreria: tienePermiso(perfil, "tesoreria.acceder"),
        nomina: tienePermiso(perfil, "nomina.acceder"),
        mantenimiento: tienePermiso(perfil, "mantenimiento.acceder"),
      }} />
    </main>
  </>;
}
