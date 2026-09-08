"use client";

import {useEffect,useRef,useState} from "react";
import BomanLogo from "@/components/BomanLogo";
import {createClient} from "@/lib/supabase/client";
import ExpedienteContrato,{type Expediente} from "@/app/produccion/contratos/ExpedienteContrato";
import estilos from "@/app/produccion/contratos/Contratos.module.css";

export default function BriefPublicoCliente({token}:{token:string}){
 const supabase=useRef(createClient()).current;const[datos,setDatos]=useState<Expediente|null>(null);const[error,setError]=useState<string|null>(null);const[cargando,setCargando]=useState(true);
 useEffect(()=>{let activo=true;(async()=>{const{data,error}=await supabase.rpc("obtener_brief_publico_v97",{p_token:token});if(!activo)return;if(error)setError(error.message);else setDatos(data as Expediente);setCargando(false)})();return()=>{activo=false}},[supabase,token]);
 return <main style={{maxWidth:1180,margin:"0 auto",padding:"24px 16px 60px"}}>
   <header className={`${estilos.cabecera} ${estilos.noImprimir}`}><div><BomanLogo className={estilos.logo}/><h1>Brief de producción</h1><p>Documento compartido de Boman Sport.</p></div>{datos&&<button onClick={()=>window.print()}>Imprimir / guardar PDF</button>}</header>
   {cargando&&<section className="card"><div className={estilos.vacio}>Abriendo el brief seguro…</div></section>}
   {error&&<section className="card"><div className="error-box"><strong>No se puede abrir este brief.</strong><div style={{marginTop:6}}>El enlace venció, fue revocado o no existe.</div></div></section>}
   {datos&&<ExpedienteContrato datos={datos} publico/>}
 </main>;
}
