export const dynamic="force-dynamic";
import {redirect} from "next/navigation";import Navbar from "@/components/Navbar";import {getPerfilActual,tienePermiso} from "@/lib/getPerfil";import CobrosContratosCliente from "./CobrosContratosCliente";
export default async function CobrosPage(){const perfil=await getPerfilActual();if(!tienePermiso(perfil,"contratos.finanzas.ver"))redirect("/dashboard");return <><Navbar perfil={perfil}/><main className="container"><CobrosContratosCliente puedeEditar={tienePermiso(perfil,"contratos.finanzas.editar")}/></main></>}
