export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import { createClient } from "@/lib/supabase/server";
import TableroCliente, { type DatosTablero } from "@/app/tablero/TableroCliente";

/**
 * Pantalla del operario de taller (v117). Es el mismo tablero, recortado a la
 * estacion de la cuenta: mismos datos, misma tabla, mismos botones de marcar.
 *
 * No se duplica TableroCliente a proposito. Dos tableros que tienen que
 * comportarse igual terminan divergiendo, y lo que de verdad separa a un
 * operario de un jefe no es la pantalla sino lo que la BASE le deja hacer:
 * marcar_etapa_contrato_v116 rechaza un area que no sea la suya, y sus
 * permisos quedan recortados por el encierro de v117. Aqui solo se elige que
 * columnas ve.
 */
async function traerTablero(): Promise<DatosTablero | { error: string }> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("tablero_produccion_v102");
  if (error) {
    return {
      error: /produccion\.estacion|permiso/i.test(error.message)
        ? "Tu cuenta todavía no puede leer el tablero. Falta correr sql/v117_estaciones_produccion.sql."
        : error.message,
    };
  }
  if (!data || typeof data !== "object") return { error: "Supabase no devolvió datos para el tablero." };
  return data as DatosTablero;
}

export default async function EstacionPage() {
  const perfil = await getPerfilActual();
  const puedeVer = tienePermiso(perfil, "produccion.estacion") || tienePermiso(perfil, "produccion.acceder");
  if (!puedeVer) redirect("/dashboard");

  // Un jefe o admin que entre aqui ve el selector completo: la pantalla no
  // esconde nada que su cuenta no esconda ya.
  const estaciones = perfil.estaciones.length ? perfil.estaciones : undefined;

  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        {!estaciones && (
          <div className="card">
            <div className="badge bajo" style={{ display: "inline-block", whiteSpace: "normal", lineHeight: 1.4 }}>
              Tu cuenta no tiene una estación asignada, así que ves el taller completo. Las estaciones se asignan en Administración → Permisos por persona.
            </div>
          </div>
        )}
        <TableroCliente
          datos={await traerTablero()}
          puedeMarcar={tienePermiso(perfil, "contratos.marcar_etapa")}
          estacionesPermitidas={estaciones}
        />
      </main>
    </>
  );
}
