export const dynamic="force-dynamic";
import {redirect} from "next/navigation";
import Navbar from "@/components/Navbar";
import {getPerfilActual} from "@/lib/getPerfil";
import CierreBomansportCliente from "./CierreBomansportCliente";
export default async function CierreBomansportPage(){const perfil=await getPerfilActual();if(perfil.rol!=="admin")redirect("/dashboard");return <><Navbar perfil={perfil}/><main className="container"><CierreBomansportCliente/></main></>}
