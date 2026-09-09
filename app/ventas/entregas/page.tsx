export const dynamic = "force-dynamic";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import EntregasCliente from "./EntregasCliente";

export default async function EntregasPage(){
 const perfil=await getPerfilActual();
 const puedeEntregar=tienePermiso(perfil,"contratos.entregar"),puedeRevertir=tienePermiso(perfil,"contratos.revertir_entrega");
 if(!perfil.modo_boman_especifico||(!puedeEntregar&&!puedeRevertir))redirect("/dashboard");
 return <><Navbar perfil={perfil}/><main className="container"><EntregasCliente nombre={perfil.nombre_completo} puedeEntregar={puedeEntregar} puedeRevertir={puedeRevertir}/></main></>;
}
