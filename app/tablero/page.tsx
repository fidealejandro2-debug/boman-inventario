export const dynamic = "force-dynamic";

import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import TableroCliente, { type DatosTablero } from "./TableroCliente";

/**
 * Trae el tablero desde Apps Script. La llamada sale del SERVIDOR, no del
 * navegador: ahi esta todo el sentido de traer esta pantalla a Vercel. Yendo
 * server-to-server no hay cuenta de Google que resolver, y desaparecen las
 * sesiones cruzadas y el authuser que impedian entrar a media empresa.
 *
 * El token nunca llega al cliente. Los contratos siguen viviendo en la hoja:
 * esto migra la pantalla, no los datos.
 */
async function traerTablero(): Promise<DatosTablero | { error: string }> {
  const base = process.env.BOMANSPORT_WEBAPP_URL;
  const token = process.env.BOMANSPORT_API_TOKEN;
  if (!base || !token) {
    return { error: "Faltan BOMANSPORT_WEBAPP_URL o BOMANSPORT_API_TOKEN en las variables de entorno." };
  }
  const url = `${base}?api=tablero&token=${encodeURIComponent(token)}`;
  try {
    // Apps Script contesta con un 302 hacia googleusercontent.com; fetch sigue
    // la redireccion solo. cache:"no-store" porque el taller marca etapas todo
    // el dia y un tablero cacheado seria peor que no tenerlo.
    const res = await fetch(url, { cache: "no-store", redirect: "follow" });
    if (!res.ok) return { error: `Apps Script respondio ${res.status}` };
    const datos = await res.json();
    if (datos && datos.error) return { error: String(datos.error) };
    return datos as DatosTablero;
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e) };
  }
}

export default async function TableroPage() {
  const perfil = await getPerfilActual();
  if (!tienePermiso(perfil, "produccion.acceder")) redirect("/dashboard");
  const datos = await traerTablero();
  return (
    <>
      <Navbar perfil={perfil} />
      <main className="container">
        <TableroCliente datos={datos} />
      </main>
    </>
  );
}
