"use client";

import { useEffect, useMemo, useState } from "react";
import { mostrarAvisoDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import estilos from "./Contratos.module.css";

const ESTADOS = ["Ingresado", "Por imprimir", "Impreso", "Sublimación", "Cortado", "En costura o maquila", "Estampado", "Terminado", "Estampado final", "Pendiente entrega", "Entregado"];
const TIPOS = ["Normal", "Equipo Profesional", "Mercadería", "Emergente"];
type Contrato = Record<string, unknown> & { id: string; numero: string };
type Formulario = {fecha_inicio_produccion:string;fecha_salida_produccion:string;fecha_entrega:string;prioridad:string;tipo_contrato:string;estado:string;disenador:string;autor_mockup:string;maquila:string;orden_dia:string;observacion:string;muestras_tpu_faltan:boolean;muestras_dtf_faltan:boolean;nombre_contrato_v115:string;cliente:string;vendedor:string;canal:string};
type PersonaDiseno = {id:string;nombre:string;cargo:string;departamento:string;disenador:boolean;mockup:boolean};
function texto(v:unknown){return v==null?"":String(v)}
function inicial(c:Contrato):Formulario{return {fecha_inicio_produccion:texto(c.fecha_inicio_produccion),fecha_salida_produccion:texto(c.fecha_salida_produccion),fecha_entrega:texto(c.fecha_entrega),prioridad:texto(c.prioridad||"Normal"),tipo_contrato:texto(c.tipo_contrato||"Normal"),estado:texto(c.estado||"Ingresado"),disenador:texto(c.disenador),autor_mockup:texto(c.autor_mockup),maquila:texto(c.maquila),orden_dia:texto(c.orden_dia),observacion:texto(c.observacion),muestras_tpu_faltan:Boolean(c.muestras_tpu_faltan),muestras_dtf_faltan:Boolean(c.muestras_dtf_faltan),nombre_contrato_v115:texto(c.nombre_contrato_v115||c.cliente),cliente:texto(c.cliente),vendedor:texto(c.vendedor),canal:texto(c.canal)}}
const DINERO=new Intl.NumberFormat("es-EC",{style:"currency",currency:"USD"});

export default function GestionContratoV99({contrato,onGuardado,onCerrar,puedeFinanzas=false}:{contrato:Contrato;onGuardado:()=>Promise<void>;onCerrar:()=>void;puedeFinanzas?:boolean}){
 const supabase=useMemo(()=>createClient(),[]);const [form,setForm]=useState<Formulario>(()=>inicial(contrato));const [guardando,setGuardando]=useState(false);
 const [personalDiseno,setPersonalDiseno]=useState<PersonaDiseno[]|null>(null);
 const [guardandoResponsable,setGuardandoResponsable]=useState<"disenador"|"mockup"|null>(null);
 // Presupuesto y abono inicial van por su propia via (v100) y con su propio
 // boton: `abono` es un total DERIVADO del libro de abonos y las dos columnas
 // estan protegidas por trigger. Mezclarlas con el resto del formulario
 // significaria que el usuario "guarda" y no pasa nada.
 const [presupuesto,setPresupuesto]=useState(()=>texto(contrato.presupuesto));
 const [abonoInicial,setAbonoInicial]=useState(()=>texto(contrato.abono_inicial_v100));
 const [guardandoFin,setGuardandoFin]=useState(false);
 useEffect(()=>{setForm(inicial(contrato));setPresupuesto(texto(contrato.presupuesto));setAbonoInicial(texto(contrato.abono_inicial_v100))},[contrato]);
 useEffect(()=>{let vigente=true;void supabase.rpc("listar_personal_diseno_v127").then(({data,error})=>{if(vigente)setPersonalDiseno(!error&&Array.isArray(data)?data as PersonaDiseno[]:null)});return()=>{vigente=false}},[supabase]);
 function cambiar<K extends keyof Formulario>(clave:K,valor:Formulario[K]){setForm(actual=>({...actual,[clave]:valor}))}
 function candidatos(tipo:"disenador"|"mockup"){
  if(!personalDiseno)return[];
  const sugeridos=personalDiseno.filter(p=>tipo==="disenador"?p.disenador:p.mockup);
  return sugeridos.length?sugeridos:personalDiseno;
 }
 function responsableActual(tipo:"disenador"|"mockup"){
  const campoId=tipo==="disenador"?contrato.disenador_empleado_id:contrato.autor_mockup_empleado_id;
  if(campoId)return String(campoId);
  const nombre=texto(tipo==="disenador"?contrato.disenador:contrato.autor_mockup).trim();
  if(!nombre||!personalDiseno)return"";
  const encontrado=personalDiseno.find(p=>p.nombre.localeCompare(nombre,"es",{sensitivity:"base"})===0);
  return encontrado?.id??`historico:${nombre}`;
 }
 async function asignarResponsable(tipo:"disenador"|"mockup",empleadoId:string){
  const etiqueta=tipo==="disenador"?"diseñador":"autor del mockup";
  const motivo=await pedirMotivoDialogo(`Explica por qué cambiará el ${etiqueta} del contrato ${contrato.numero}.`,10,"Motivo del cambio");
  if(!motivo)return;
  setGuardandoResponsable(tipo);
  const{error}=await supabase.rpc("asignar_personal_diseno_v127",{p_contrato_id:contrato.id,p_tipo:tipo,p_empleado_id:empleadoId||null,p_motivo:motivo,p_idempotency_key:crypto.randomUUID()});
  setGuardandoResponsable(null);
  if(error){await mostrarAvisoDialogo(error.message.includes("asignar_personal_diseno_v127")?"Falta instalar v127 en Supabase.":error.message,"No se pudo cambiar el responsable",true);return}
  await mostrarAvisoDialogo(`El ${etiqueta} quedó vinculado al personal de Nómina.`,"Responsable actualizado");
  await onGuardado();
 }
 async function guardarFinanzas(){
  const pre=Number(presupuesto),ini=Number(abonoInicial);
  if(!Number.isFinite(pre)||pre<0||!Number.isFinite(ini)||ini<0){await mostrarAvisoDialogo("El presupuesto y el abono inicial deben ser números mayores o iguales a cero.","Valores inválidos",true);return}
  const motivo=await pedirMotivoDialogo(`Explica por qué cambian las cifras del contrato ${contrato.numero}.`,10,"Motivo del ajuste");
  if(!motivo)return;
  setGuardandoFin(true);
  const{error}=await supabase.rpc("ajustar_finanzas_contrato_v100",{p_contrato_id:contrato.id,p_presupuesto:pre,p_abono_inicial:ini,p_motivo:motivo,p_idempotency_key:crypto.randomUUID()});
  setGuardandoFin(false);
  if(error){await mostrarAvisoDialogo(error.message.includes("ajustar_finanzas_contrato_v100")?"Falta instalar v100 en Supabase.":error.message,"No se pudo ajustar",true);return}
  await mostrarAvisoDialogo("El presupuesto quedó ajustado y auditado.","Cifras actualizadas");
  await onGuardado();
 }
 async function guardar(){const original=inicial(contrato);const cambios:Record<string,string|boolean|null>={};(Object.keys(form) as Array<keyof Formulario>).forEach(clave=>{if(form[clave]!==original[clave]){const valor=form[clave];cambios[clave]=typeof valor==="string"&&valor.trim()===""?null:valor}});if(!Object.keys(cambios).length){await mostrarAvisoDialogo("No modificaste ningún dato del contrato.","Sin cambios");return}const motivo=await pedirMotivoDialogo(`Explica por qué se modificará la gestión del contrato ${contrato.numero}.`,10,"Motivo del cambio");if(!motivo)return;setGuardando(true);const{error}=await supabase.rpc("guardar_gestion_contrato_v99",{p_contrato_id:contrato.id,p_cambios:cambios,p_motivo:motivo,p_idempotency_key:crypto.randomUUID()});setGuardando(false);if(error){await mostrarAvisoDialogo(error.message.includes("guardar_gestion_contrato_v99")?"Falta instalar v99 en Supabase.":error.message,"No se pudo actualizar el contrato",true);return}await mostrarAvisoDialogo("Los cambios quedaron guardados y auditados.","Contrato actualizado");await onGuardado();onCerrar()}
 return <section className={`card ${estilos.editorGestion}`}><div className={estilos.editorCabecera}><div><span className="eyebrow">GESTIÓN V99</span><h3>Actualizar planificación y responsables</h3></div><button className="secondary" onClick={onCerrar}>Cerrar edición</button></div><div className={estilos.formGestion}>
  <label className={`field ${estilos.campoCompleto}`}><span>Nombre del contrato</span><input value={form.nombre_contrato_v115} onChange={e=>cambiar("nombre_contrato_v115",e.target.value)} placeholder="Como se llama el pedido (equipo, colegio, evento…)"/></label>
  <label className="field"><span>Cliente real</span><input value={form.cliente} onChange={e=>cambiar("cliente",e.target.value)} placeholder="Persona o institución que paga"/></label>
  <label className="field"><span>Vendedor</span><input value={form.vendedor} onChange={e=>cambiar("vendedor",e.target.value)} placeholder="Responsable de la venta"/></label>
  <label className="field"><span>Canal</span><input value={form.canal} onChange={e=>cambiar("canal",e.target.value)} placeholder="Tienda, WhatsApp, referido…"/></label>
  <label className="field"><span>Estado</span><select value={form.estado} onChange={e=>cambiar("estado",e.target.value)}>{ESTADOS.map(x=><option key={x}>{x}</option>)}</select></label>
  <label className="field"><span>Prioridad</span><select value={form.prioridad} onChange={e=>cambiar("prioridad",e.target.value)}><option>Normal</option><option>Urgente</option></select></label>
  <label className="field"><span>Tipo de contrato</span><select value={form.tipo_contrato} onChange={e=>cambiar("tipo_contrato",e.target.value)}>{TIPOS.map(x=><option key={x}>{x}</option>)}</select></label>
  <label className="field"><span>Orden del día</span><input type="number" min="0" step="0.01" value={form.orden_dia} onChange={e=>cambiar("orden_dia",e.target.value)}/></label>
  <label className="field"><span>Inicio de producción</span><input type="date" value={form.fecha_inicio_produccion} onChange={e=>cambiar("fecha_inicio_produccion",e.target.value)}/></label>
  <label className="field"><span>Salida de producción</span><input type="date" value={form.fecha_salida_produccion} onChange={e=>cambiar("fecha_salida_produccion",e.target.value)}/></label>
  <label className="field"><span>Entrega comprometida</span><input type="date" value={form.fecha_entrega} onChange={e=>cambiar("fecha_entrega",e.target.value)}/></label>
  {personalDiseno?<label className="field"><span>Diseñador · Nómina</span><select value={responsableActual("disenador")} disabled={guardandoResponsable!==null} onChange={e=>void asignarResponsable("disenador",e.target.value)}><option value="">Sin asignar</option>{responsableActual("disenador").startsWith("historico:")&&<option value={responsableActual("disenador")} disabled>{form.disenador} · sin vínculo</option>}{candidatos("disenador").map(p=><option key={p.id} value={p.id}>{p.nombre} · {p.cargo||p.departamento}</option>)}</select></label>:<label className="field"><span>Diseñador</span><input value={form.disenador} onChange={e=>cambiar("disenador",e.target.value)} placeholder="Nombre del diseñador"/></label>}
  {personalDiseno?<label className="field"><span>Autor del mockup · Nómina</span><select value={responsableActual("mockup")} disabled={guardandoResponsable!==null} onChange={e=>void asignarResponsable("mockup",e.target.value)}><option value="">Sin asignar</option>{responsableActual("mockup").startsWith("historico:")&&<option value={responsableActual("mockup")} disabled>{form.autor_mockup} · sin vínculo</option>}{candidatos("mockup").map(p=><option key={p.id} value={p.id}>{p.nombre} · {p.cargo||p.departamento}</option>)}</select></label>:<label className="field"><span>Autor del mockup</span><input value={form.autor_mockup} onChange={e=>cambiar("autor_mockup",e.target.value)} placeholder="Responsable del arte"/></label>}
  <label className="field"><span>Maquila</span><input value={form.maquila} onChange={e=>cambiar("maquila",e.target.value)} placeholder="Taller o responsable externo"/></label>
  <label className={`field ${estilos.campoCompleto}`}><span>Observación operativa</span><textarea rows={3} value={form.observacion} onChange={e=>cambiar("observacion",e.target.value)} placeholder="Indicaciones para producción"/></label>
 </div><div className={estilos.opcionesMuestras}><label><input type="checkbox" checked={form.muestras_tpu_faltan} onChange={e=>cambiar("muestras_tpu_faltan",e.target.checked)}/> Faltan muestras TPU</label><label><input type="checkbox" checked={form.muestras_dtf_faltan} onChange={e=>cambiar("muestras_dtf_faltan",e.target.checked)}/> Faltan muestras DTF</label></div><div className={estilos.editorAcciones}><span>Al guardar se solicitará un motivo y quedará registrado por campo.</span><button disabled={guardando} onClick={guardar}>{guardando?"Guardando…":"Guardar cambios"}</button></div>
 {puedeFinanzas&&<div className={estilos.bloqueFinanzas}>
  <h4>Presupuesto y abonos</h4>
  <p className="conteo">
   El <strong>abono total</strong> ({DINERO.format(Number(contrato.abono)||0)}) no se escribe a mano: es el abono inicial más los pagos
   registrados en Presupuestos y cobros. Aquí se corrige el presupuesto y el abono inicial; cada pago posterior se registra como cobro.
  </p>
  <div className={estilos.formFinanzas}>
   <label className="field"><span>Presupuesto</span><input type="number" min="0" step="0.01" value={presupuesto} onChange={e=>setPresupuesto(e.target.value)}/></label>
   <label className="field"><span>Abono inicial</span><input type="number" min="0" step="0.01" value={abonoInicial} onChange={e=>setAbonoInicial(e.target.value)}/></label>
   <button className="secondary" disabled={guardandoFin} onClick={guardarFinanzas}>{guardandoFin?"Ajustando…":"Ajustar cifras"}</button>
  </div>
 </div>}
 </section>
}
