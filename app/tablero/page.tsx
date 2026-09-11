export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import { createClient } from "@/lib/supabase/server";
import TableroCliente, { type DatosTablero } from "./TableroCliente";

/**
 * Desde v102 el tablero operativo se arma en Supabase. BomanSport queda como
 * fuente de importacion, pero una caida de Apps Script ya no tumba la pantalla.
 */
async function traerTablero(): Promise<DatosTablero | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("tablero_produccion_v102");
  if (error) {
    const faltaV102 = /tablero_produccion_v102|schema cache|could not find/i.test(error.message);
    return {
      error: faltaV102
        ? "Instala v102 para activar el tablero normalizado de Supabase."
        : error.message,
    };
  }
  if (!data || typeof data !== "object") {
    return { error: "Supabase no devolvio datos para el tablero." };
  }
  return data as DatosTablero;
}

export default async function TableroPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "produccion.acceder")) redirect("/dashboard");
  const datos = await traerTablero();
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <TableroCliente datos={datos} puedeMarcar={tienePermiso(perfil, "contratos.marcar_etapa")} puedeEditar={tienePermiso(perfil, "contratos.editar")} puedeEditarContenido={tienePermiso(perfil, "contratos.editar_contenido")} />
      </main>
    </>
  );
}
