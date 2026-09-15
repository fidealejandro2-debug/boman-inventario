export const dynamic = "force-dynamic";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import { getPerfilActual, tienePermiso } from "@/lib/getPerfil";
import EntregasCliente from "./EntregasCliente";

export default async function EntregasPage(){
 const perfil=await getPerfilActual();
 const puedeAcceder=tienePermiso(perfil,"contratos.acceder"),puedeEntregar=tienePermiso(perfil,"contratos.entregar"),puedeRevertir=tienePermiso(perfil,"contratos.revertir_entrega"),puedeAsignar=tienePermiso(perfil,"contratos.asignar_vendedor");
 if(!perfil.modo_boman_especifico||(!puedeAcceder&&!puedeEntregar&&!puedeRevertir))redirect("/dashboard");
 return <><Navbar perfil={perfil}/><main className="container"><EntregasCliente nombre={perfil.nombre_completo} esVendedor={perfil.rol==="vendedor"} puedeEntregar={puedeEntregar} puedeRevertir={puedeRevertir} puedeAsignar={puedeAsignar}/></main></>;
}
