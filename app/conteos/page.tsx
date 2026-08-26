export const dynamic = "force-dynamic";

import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import ConteosCliente from "./ConteosCliente";

export default async function ConteosPage() {
  const perfil = await getPerfilActual();
  return <><Navbar perfil={perfil} /><main className="container"><ConteosCliente perfil={perfil} /></main></>;
}
