export const dynamic="force-dynamic";
import{redirect}from"next/navigation";import Navbar from"@/components/Navbar";import{getPerfilActual,tienePermiso}from"@/lib/getPerfil";import CarteraCliente from"./CarteraCliente";
export default async function CarteraPage(){const perfil=await getPerfilActual();if(!perfil.modo_boman_especifico||!tienePermiso(perfil,"contratos.cartera.ver"))redirect("/dashboard");return <><Navbar perfil={perfil}/><main className="container"><CarteraCliente puedeEditar={tienePermiso(perfil,"contratos.cartera.editar")}/></main></>}
