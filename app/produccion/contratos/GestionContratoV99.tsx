"use client";

import { useEffect, useMemo, useState } from "react";
import { mostrarAvisoDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import estilos from "./Contratos.module.css";

const ESTADOS = ["Ingresado", "Por imprimir", "Impreso", "Sublimación", "Cortado", "En costura o maquila", "Estampado", "Terminado", "Estampado final", "Pendiente entrega", "Entregado"];
const TIPOS = ["Normal", "Equipo Profesional", "Mercadería", "Emergente"];
type Contrato = Record<string, unknown> & { id: string; numero: string };
type Formulario = {fecha_inicio_produccion:string;fecha_salida_produccion:string;fecha_entrega:string;prioridad:string;tipo_contrato:string;estado:string;disenador:string;autor_mockup:string;maquila:string;orden_dia:string;observacion:string;muestras_tpu_faltan:boolean;muestras_dtf_faltan:boolean};
function texto(v:unknown){return v==null?"":String(v)}
function inicial(c:Contrato):Formulario{return {fecha_inicio_produccion:texto(c.fecha_inicio_produccion),fecha_salida_produccion:texto(c.fecha_salida_produccion),fecha_entrega:texto(c.fecha_entrega),prioridad:texto(c.prioridad||"Normal"),tipo_contrato:texto(c.tipo_contrato||"Normal"),estado:texto(c.estado||"Ingresado"),disenador:texto(c.disenador),autor_mockup:texto(c.autor_mockup),maquila:texto(c.maquila),orden_dia:texto(c.orden_dia),observacion:texto(c.observacion),muestras_tpu_faltan:Boolean(c.muestras_tpu_faltan),muestras_dtf_faltan:Boolean(c.muestras_dtf_faltan)}}

export default function GestionContratoV99({contrato,onGuardado,onCerrar}:{contrato:Contrato;onGuardado:()=>Promise<void>;onCerrar:()=>void}){
 const supabase=useMemo(()=>createClient(),[]);const [form,setForm]=useState<Formulario>(()=>inicial(contrato));const [guardando,setGuardando]=useState(false);
 useEffect(()=>setForm(inicial(contrato)),[contrato]);
 function cambiar<K extends keyof Formulario>(clave:K,valor:Formulario[K]){setForm(actual=>({...actual,[clave]:valor}))}
 async function guardar(){const original=inicial(contrato);const cambios:Record<string,string|boolean|null>={};(Object.keys(form) as Array<keyof Formulario>).forEach(clave=>{if(form[clave]!==original[clave]){const valor=form[clave];cambios[clave]=typeof valor==="string"&&valor.trim()===""?null:valor}});if(!Object.keys(cambios).length){await mostrarAvisoDialogo("No modificaste ningún dato del contrato.","Sin cambios");return}const motivo=await pedirMotivoDialogo(`Explica por qué se modificará la gestión del contrato ${contrato.numero}.`,10,"Motivo del cambio");if(!motivo)return;setGuardando(true);const{error}=await supabase.rpc("guardar_gestion_contrato_v99",{p_contrato_id:contrato.id,p_cambios:cambios,p_motivo:motivo,p_idempotency_key:crypto.randomUUID()});setGuardando(false);if(error){await mostrarAvisoDialogo(error.message.includes("guardar_gestion_contrato_v99")?"Falta instalar v99 en Supabase.":error.message,"No se pudo actualizar el contrato",true);return}await mostrarAvisoDialogo("Los cambios quedaron guardados y auditados.","Contrato actualizado");await onGuardado();onCerrar()}
 return <section className={`card ${estilos.editorGestion}`}><div className={estilos.editorCabecera}><div><span className="eyebrow">GESTIÓN V99</span><h3>Actualizar planificación y responsables</h3></div><button className="secondary" onClick={onCerrar}>Cerrar edición</button></div><div className={estilos.formGestion}>
  <label className="field"><span>Estado</span><select value={form.estado} onChange={e=>cambiar("estado",e.target.value)}>{ESTADOS.map(x=><option key={x}>{x}</option>)}</select></label>
  <label className="field"><span>Prioridad</span><select value={form.prioridad} onChange={e=>cambiar("prioridad",e.target.value)}><option>Normal</option><option>Urgente</option></select></label>
  <label className="field"><span>Tipo de contrato</span><select value={form.tipo_contrato} onChange={e=>cambiar("tipo_contrato",e.target.value)}>{TIPOS.map(x=><option key={x}>{x}</option>)}</select></label>
  <label className="field"><span>Orden del día</span><input type="number" min="0" step="0.01" value={form.orden_dia} onChange={e=>cambiar("orden_dia",e.target.value)}/></label>
  <label className="field"><span>Inicio de producción</span><input type="date" value={form.fecha_inicio_produccion} onChange={e=>cambiar("fecha_inicio_produccion",e.target.value)}/></label>
  <label className="field"><span>Salida de producción</span><input type="date" value={form.fecha_salida_produccion} onChange={e=>cambiar("fecha_salida_produccion",e.target.value)}/></label>
  <label className="field"><span>Entrega comprometida</span><input type="date" value={form.fecha_entrega} onChange={e=>cambiar("fecha_entrega",e.target.value)}/></label>
  <label className="field"><span>Diseñador</span><input value={form.disenador} onChange={e=>cambiar("disenador",e.target.value)} placeholder="Nombre del diseñador"/></label>
  <label className="field"><span>Autor del mockup</span><input value={form.autor_mockup} onChange={e=>cambiar("autor_mockup",e.target.value)} placeholder="Responsable del arte"/></label>
  <label className="field"><span>Maquila</span><input value={form.maquila} onChange={e=>cambiar("maquila",e.target.value)} placeholder="Taller o responsable externo"/></label>
  <label className={`field ${estilos.campoCompleto}`}><span>Observación operativa</span><textarea rows={3} value={form.observacion} onChange={e=>cambiar("observacion",e.target.value)} placeholder="Indicaciones para producción"/></label>
 </div><div className={estilos.opcionesMuestras}><label><input type="checkbox" checked={form.muestras_tpu_faltan} onChange={e=>cambiar("muestras_tpu_faltan",e.target.checked)}/> Faltan muestras TPU</label><label><input type="checkbox" checked={form.muestras_dtf_faltan} onChange={e=>cambiar("muestras_dtf_faltan",e.target.checked)}/> Faltan muestras DTF</label></div><div className={estilos.editorAcciones}><span>Al guardar se solicitará un motivo y quedará registrado por campo.</span><button disabled={guardando} onClick={guardar}>{guardando?"Guardando…":"Guardar cambios"}</button></div></section>
}
