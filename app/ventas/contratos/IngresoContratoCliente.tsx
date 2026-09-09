"use client";

import { Fragment, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { confirmarDialogo, mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/permisos";
import estilos from "./IngresoContrato.module.css";

// Todas estas listas son copia literal de BomanSport/index.html: son la fuente
// de verdad del negocio. Si aqui difieren aunque sea en una tilde o un espacio,
// el brief y la migracion v94 dejan de cuadrar (paso con "Semi profesional" vs
// "Semiprofesional" y con "Sin calidad" vs "Estandar").
const PASOS=["Vendedor","Contrato","Prendas","Mockups","Especificaciones","Jugadores","Cierre"];
const PRENDAS=["Camiseta Jugador","Camiseta Jugador M/L","Pantaloneta Jugador","Camiseta Arquero","Camiseta Arquero M/L","Pantaloneta Arquero","Arquero Completo","Uniformes Completos","Camiseta Polo","Camiseta Polo M/L","Chompa","Pantalón","Exterior Completo","Rompevientos","Chompa de Frío","Chompa Frío 3/4","Chompas Retro","Chompa Deportiva","Hoodie","Buzo de Compresión","Chaleco","Medias","Bandera","Cinta Capitán","Bermudas","Falda Short","Licra","Bolsos","BVDS"];
// Rompevientos se muestra como "Chompa de Lluvia" pero se guarda con su nombre
// interno: el resto del sistema (brief, tallas, facturacion) usa el interno.
const PRENDA_LABEL_ESPECIAL:Record<string,string>={"Rompevientos":"Chompa de Lluvia"};
const etiquetaPrenda=(p:string)=>PRENDA_LABEL_ESPECIAL[p]||p;
// Prendas "conjunto": se expanden en sus componentes para tallas y colores.
const PRENDA_EXPANSION:Record<string,string[]>={"Uniformes Completos":["Camiseta Jugador","Pantaloneta Jugador"],"Arquero Completo":["Camiseta Arquero","Pantaloneta Arquero"],"Exterior Completo":["Chompa","Pantalón"]};
const PRENDAS_SIN_TALLA=["Medias","Bandera","Cinta Capitán"];
const PRENDAS_CANTIDAD_GENERAL=["Bolsos"];
const CALIDADES=["Semiprofesional","Competición","Profesional","Amateur","Estándar"];
// Las prendas "conjunto" se expanden en sus componentes y las que no llevan
// talla (medias, bandera, cinta) no generan seccion de tallas.
function prendasConTalla(sel:string[]){const out:string[]=[];for(const p of sel)for(const c of (PRENDA_EXPANSION[p]??[p]))if(!PRENDAS_SIN_TALLA.includes(c)&&!out.includes(c))out.push(c);return out}

const ADULTOS=["XS","S","M","L","XL","2XL","3XL","4XL"];
const NINOS=["24 (0)","26 (2)","28 (4)","30 (6)","32 (8)","34 (10)","36 (12)"];
const TECNICAS=["Sublimado","Estampado","Bordado","TPU","No aplica"];
const UBICACION_TPU=["No aplica","Frente","Mangas","Espalda","Frente y mangas"];
const VENDEDORES=["Nicole","Anabel","Roberto","Tienda Shopping","Tienda Mariano Eguez","Tienda Puyo","Tienda Riobamba","Tienda Guayaquil"];
const CANALES=["Tienda física","WhatsApp","Instagram","Facebook","Llamada telefónica","Referido"];
const FORMAS_ENTREGA=["Retiro en tienda","Envío a domicilio","Courier","Entrega en cancha"];
const TIPOS_UNIFORME=["Uniforme completo","Uniforme completo (Falda Short)","Camiseta + Bermuda","Polo + Bermuda","BVD + Bermuda","Solo bermuda","BVD + Pantaloneta","BVD con Falda Short","Polo + Pantaloneta","Camiseta + Exterior","Polo + Exterior","Solo camiseta","Solo Polo","Solo pantaloneta","Solo Falda Short","Solo pantalón","Solo BVD","Chompa","Chompa de Frío","Chompa Frío 3/4","Chompa de Lluvia","Chompa Retro","Chompa Deportiva","Hoodie","Buzo de Compresión","Chaleco","Exterior completo","Arquero completo","Personalizado"];
// Cupos del taller (Codigo.gs: CAPACIDAD_DIARIA). Se validan contra la carga
// real del dia de inicio de produccion, no son solo texto informativo.
const CAPACIDAD_DIARIA:Record<string,number>={total:900,"Normal":600,"Equipo Profesional":100,"Mercadería":150,"Emergente":50};
const BORRADOR="boman-contrato-v108-borrador";
const uuid=()=>crypto.randomUUID();

type Prenda={id:string;prenda:string;calidad:string;detalle:string;genero:"H"|"M"|"N";talla:string;cantidad:number};
type Jugador={id:string;nombre:string;numero:string;categoria:string;talla_superior:string;talla_inferior:string;manga:string;calidad:string;modelo_arquero:string;tipo_uniforme:string;detalle:string;mockup:string};
type Archivo={id:string;tipo:"mockup"|"logo";file?:File;preview?:string;url?:string;drive_id?:string;descripcion:string;color:string;prenda:string;posicion:string;tecnica:string;calidad_aplicable:string;observacion:string};
type Spec={id:string;prenda_clave:string;variante_calidad:string;mockup:string;campos:Record<string,string>;observacion:string};
type CampoTecnico={c:string;t:string;o?:string[]};

// Catálogo de campos técnicos tomado del formulario legado (index.html) recortado a
// lo que el brief realmente IMPRIME en sus tablas: el legado tiene cientos de
// variantes condicionales por calidad que nunca llegan al papel del taller.
const CAMPOS_CAMISETA:CampoTecnico[]=[{c:"corte",t:"Corte",o:["Ranglan","Recta","Corte especial"]},{c:"cuello_tipo",t:"Cuello tipo",o:["Normal","Polo","Chino","Especial"]},{c:"cuello_forma",t:"Cuello forma",o:["Normal","Redondo","En V","Cruzado","Personalizado"]},{c:"cuello_falso",t:"Cuello falso",o:["No","Sí","En V","Redondo"]},{c:"cuello_material",t:"Cuello material",o:["Rib","Tejido rib","Tejido licra","Tela"]},{c:"cuello_tecnica",t:"Cuello técnica",o:["Llano","Estampado","Sublimado","Personalizado"]},{c:"botones",t:"Botones",o:["No","Sí","Combinado"]},{c:"botones_cantidad",t:"Cantidad de botones"},{c:"punos_tipo",t:"Puños tipo",o:["Integrado","Aparte tela","Aparte tejido","Aparte rib","Combinado","No aplica"]},{c:"punos_tecnica",t:"Puños técnica",o:["Llano","Sublimado","Estampado","Sublimado y estampado","Personalizado","No aplica"]},{c:"vivos",t:"Vivos",o:["No","Sí","No aplica"]},{c:"vivos_donde",t:"Vivos dónde"},{c:"basta",t:"Basta",o:["Normal","Con casita","Falso","Cola de pato"]},{c:"empanada",t:"Empanada",o:["No aplica","Triangular","Cuadrada","Hexagonal"]},{c:"babero",t:"Babero",o:["No","Sí","Apuntado","Especial","No aplica"]},{c:"vinchas",t:"Vinchas",o:["No","Tela","Tejido","Rib"]},{c:"pie_cuello",t:"Pie de cuello",o:["No","Sí"]},{c:"pie_cuello_color",t:"Pie de cuello color"},{c:"reata",t:"Reata",o:["No","Pro","Tela","Sesgo","Pro sin Boman"]},{c:"reata_color",t:"Reata color"},{c:"talla_origen",t:"Etiqueta talla",o:["Nacional","Importada"]},{c:"talla_marca",t:"Marca de talla",o:["Con Boman","Sin Boman","Personalizada"]}];
const CAMPOS_TECNICOS:Record<string,CampoTecnico[]>={
 camiseta:CAMPOS_CAMISETA,
 polo:CAMPOS_CAMISETA,
 pantaloneta:[{c:"tipo",t:"Tipo",o:["Basquet","Futbol"]},{c:"basta",t:"Basta",o:["Basquet normal","Basquet casita","Futbol normal","Futbol casita","Especial","Cosida aparte","Cosida aparte sublimada","Cosida aparte tela"]},{c:"cordon",t:"Cordón",o:["Unitario","Metreado"]},{c:"elastico",t:"Elástico",o:["Boman","Normal"]},{c:"vivos",t:"Vivos",o:["No","Sí"]},{c:"vivos_color",t:"Vivos color / dónde"},{c:"franjas_sublimadas",t:"Franjas sublimadas",o:["No aplica","Sí"]},{c:"franjas_adidas",t:"Franjas Adidas",o:["No aplica","1 franja","2 franjas","3 franjas","4 franjas"]},{c:"bolsillos",t:"Bolsillos",o:["No","Con cierre","Sin cierre"]},{c:"talla_origen",t:"Etiqueta talla",o:["Nacional","Importada"]},{c:"talla_marca",t:"Marca de talla",o:["Con Boman","Sin Boman","Personalizada"]}],
 chompa:[{c:"estilo",t:"Estilo",o:["Normal","Retro (Escolar)"]},{c:"capucha",t:"Capucha",o:["Sin capucha","Normal","Desmontable"]},{c:"capucha_reata",t:"Reata capucha"},{c:"basta",t:"Basta",o:["Faja","Basta suelta"]},{c:"cierre",t:"Cierre",o:["Sin cierre","Medio","Bajo","Completo"]},{c:"cierre_estampado",t:"Cierre estampado",o:["No","Sí"]},{c:"punos_tipo",t:"Puños",o:["Con elástico boman","Sin elástico","Elástico normal","Sesgo","Combinado"]},{c:"punos_forma",t:"Puño forma",o:["Puño normal","Puño guante"]},{c:"bolsillos",t:"Bolsillos",o:["No","Con cierre","Sin cierre","Canguro"]},{c:"velcro",t:"Velcro",o:["No","Sí"]},{c:"velcro_detalle",t:"Velcro detalle"},{c:"tiras_adidas",t:"Tiras Adidas",o:["Sin tira","1 tira","2 tiras","3 tiras","4 tiras"]},{c:"tela",t:"Tela"}],
 pantalon:[{c:"basta",t:"Basta",o:["Recta","Tubo","Semitubo","Puño"]},{c:"puno_tipo",t:"Tipo puño",o:["Rib","Tela","Elástico normal","Especial"]},{c:"basta_cierre",t:"Basta cierre",o:["Con cierre","Sin cierre"]},{c:"bolsillos",t:"Bolsillos",o:["No tiene","Con cierre","Sin cierre"]},{c:"franja",t:"Franja de tela",o:["No aplica","Sublimada"]},{c:"tiras_adidas",t:"Tira Adidas",o:["No","1 tira","2 tiras","3 tiras"]},{c:"cordon",t:"Cordón",o:["Unitario","Metreado"]},{c:"vivos",t:"Vivos",o:["No","Sí"]},{c:"vivos_donde",t:"Vivos dónde"}],
 otro:[{c:"material",t:"Material"},{c:"color",t:"Color"},{c:"detalle",t:"Detalle"}]};
// El brief pinta cada prenda con un color de cabecera propio; agrupar por familia
// evita mantener una entrada por cada uno de los 26 nombres de PRENDAS.
function familiaPrenda(prenda:string){const n=prenda.toLowerCase();
 if(n.includes("polo"))return"polo";
 if(n.includes("pantaloneta")||n.includes("bermuda")||n.includes("falda"))return"pantaloneta";
 if(n.includes("pantal")||n.includes("licra"))return"pantalon";
 if(n.includes("chompa")||n.includes("rompevientos")||n.includes("hoodie")||n.includes("buzo"))return"chompa";
 if(n.includes("camiseta")||n.includes("bvd"))return"camiseta";
 return"otro"}
const FAMILIA_MARCA:Record<string,{color:string;icono:string}>={camiseta:{color:"#1F4E78",icono:"👕"},polo:{color:"#5B21B6",icono:"👔"},pantaloneta:{color:"#155E75",icono:"🩳"},chompa:{color:"#92400E",icono:"🧥"},pantalon:{color:"#374151",icono:"👖"},otro:{color:"#0F766E",icono:"🎽"}};
type Fact={id:string;concepto:string;calidad:string;cantidad:number;obsequio:boolean};
type Cab={vendedor:string;canal:string;cliente:string;telefono:string;whatsapp:string;email:string;tipo_contrato:string;fecha_entrega:string;fecha_inicio_produccion:string;prioridad:string;arqueros:number;total_manual:number;reposicion:boolean;contrato_origen_reposicion_id:string;nombre_tecnica:string;numero_tecnica:string;sellos_tpu:string;ubicacion_tpu:string;bordado:string;colores:string;instrucciones:string;presupuesto:number;abono:number;forma_entrega:string;direccion:string;vendedor_responsable:string;autorizado:boolean;adicionales:string};
// Accesorios del pedido. En el legado cada uno es un select + una cantidad, y
// se imprimen en el recuadro "ADICIONALES DEL PEDIDO" del brief.
const ADICIONALES:{clave:keyof Adic;titulo:string;opciones:string[];etiquetaCant:string}[]=[
 {clave:"medias",titulo:"Medias",opciones:["No incluye medias","Incluye medias","Incluye polainas","Incluye antideslizantes","Incluye personalizadas"],etiquetaCant:"Cantidad de medias (si aplica)"},
 {clave:"polainas",titulo:"Polainas",opciones:["No incluye polainas","Incluye polainas"],etiquetaCant:"Cantidad de polainas (si aplica)"},
 {clave:"antideslizantes",titulo:"Medias antideslizantes",opciones:["No incluye antideslizantes","Incluye antideslizantes"],etiquetaCant:"Cantidad de antideslizantes (si aplica)"},
 {clave:"banda_capitan",titulo:"Banda de Capitán",opciones:["Sin banda de capitán","Con banda de capitán"],etiquetaCant:"Cantidad de bandas (si aplica)"},
 {clave:"banderin",titulo:"Banderín",opciones:["Sin banderín","Con banderín"],etiquetaCant:"Cantidad de banderines (si aplica)"},
 {clave:"bandera",titulo:"Bandera",opciones:["Sin bandera","Con bandera"],etiquetaCant:"Cantidad de banderas (si aplica)"},
 {clave:"bolsos",titulo:"Bolsos",opciones:["Sin bolsos","Con bolsos"],etiquetaCant:"Cantidad de bolsos (si aplica)"},
];
type Adic={medias:string;polainas:string;antideslizantes:string;banda_capitan:string;banderin:string;bandera:string;bolsos:string};
type AdicCant=Record<keyof Adic,number>;
type Form={cab:Cab;prendasSel:string[];adic:Adic;adicCant:AdicCant;medidasBandera:string;prendas:Prenda[];jugadores:Jugador[];archivos:Archivo[];specs:Spec[];facturacion:Fact[]};
const adicInicial=():Adic=>ADICIONALES.reduce((a,x)=>({...a,[x.clave]:x.opciones[0]}),{} as Adic);
const adicCantInicial=():AdicCant=>ADICIONALES.reduce((a,x)=>({...a,[x.clave]:0}),{} as AdicCant);

const cabInicial=(nombre:string):Cab=>({vendedor:nombre,canal:"",cliente:"",telefono:"",whatsapp:"",email:"",tipo_contrato:"Normal",fecha_entrega:"",fecha_inicio_produccion:"",prioridad:"Normal",arqueros:0,total_manual:0,reposicion:false,contrato_origen_reposicion_id:"",nombre_tecnica:"",numero_tecnica:"",sellos_tpu:"No",ubicacion_tpu:"",bordado:"",colores:"",instrucciones:"",presupuesto:0,abono:0,forma_entrega:"Retiro en tienda",direccion:"",vendedor_responsable:nombre,autorizado:false,adicionales:""});
const inicial=(nombre:string):Form=>({cab:cabInicial(nombre),prendasSel:[],adic:adicInicial(),adicCant:adicCantInicial(),medidasBandera:"",prendas:[],jugadores:[],archivos:[],specs:[],facturacion:[]});
const texto=(v:unknown)=>String(v??"").trim();
// Compatibilidad al cargar una reposición: el jsonb `spec` guardado puede venir con la
// forma nueva {campos,observacion}, con la vieja {indicaciones:"…"} o con cualquier otra.
// Nunca se vuelca JSON crudo en pantalla — eso era justo lo que el vendedor veía antes.
function leerSpec(spec:unknown):{campos:Record<string,string>;observacion:string}{
 if(!spec||typeof spec!=="object")return{campos:{},observacion:texto(spec)};
 const o=spec as Record<string,unknown>;
 const crudo=o.campos&&typeof o.campos==="object"?o.campos as Record<string,unknown>:null;
 const campos=crudo?Object.fromEntries(Object.entries(crudo).map(([k,v])=>[k,texto(v)])):{};
 let observacion=texto(o.observacion)||texto(o.indicaciones);
 // Las specs migradas de BomanSport vienen anidadas ({"punos":{"tipo":"Aparte
 // Rib","tecnica":"Sublimado"}}). Se aplanan a "Aparte Rib · Sublimado" en vez
 // de descartarlas: si no, una reposicion de un contrato viejo perderia toda
 // su ficha tecnica en silencio.
 if(!Object.keys(campos).length){
  for(const [clave,valor] of Object.entries(o)){
   if(clave==="observacion"||clave==="indicaciones"||valor==null)continue;
   const plano=typeof valor==="object"
    ?Object.values(valor as Record<string,unknown>).map(texto).filter(Boolean).join(" · ")
    :texto(valor);
   if(plano)campos[clave]=plano;
  }
 }
 return{campos,observacion};
}
function Campo({titulo,children,ancho=false}:{titulo:string;children:ReactNode;ancho?:boolean}){return <label className={ancho?estilos.ancho:""}><span>{titulo}</span>{children}</label>}

export default function IngresoContratoCliente({perfil}:{perfil:Perfil}){
 const supabase=useRef(createClient()).current;
 const [form,setForm]=useState<Form>(()=>inicial(perfil.nombre_completo));
 const [paso,setPaso]=useState(0); const [guardando,setGuardando]=useState(false); const [resultado,setResultado]=useState<{numero:string;id:string;respaldo:"en_curso"|"ok"|"pendiente"}|null>(null);
 const [busqueda,setBusqueda]=useState(""); const [coincidencias,setCoincidencias]=useState<any[]>([]); const [buscando,setBuscando]=useState(false); const [preview,setPreview]=useState(false);
 const total=useMemo(()=>form.prendas.reduce((s,x)=>s+Math.max(0,Number(x.cantidad)||0),0),[form.prendas]);
 const saldo=Math.max(0,Number(form.cab.presupuesto||0)-Number(form.cab.abono||0));
 const setCab=<K extends keyof Cab>(k:K,v:Cab[K])=>setForm(f=>({...f,cab:{...f.cab,[k]:v}}));
 const cambiar=<T extends {id:string}>(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string,cambio:Partial<T>)=>setForm(f=>({...f,[lista]:(f[lista] as unknown as T[]).map(x=>x.id===id?{...x,...cambio}:x)} as Form));
 const quitar=(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string)=>setForm(f=>({...f,[lista]:(f[lista] as {id:string}[]).filter(x=>x.id!==id)} as Form));

 useEffect(()=>{const raw=localStorage.getItem(BORRADOR);if(!raw)return;try{const d=JSON.parse(raw) as Form;if(d?.cab&&Array.isArray(d.prendas))void confirmarDialogo("Hay un borrador guardado en este dispositivo. ¿Deseas recuperarlo?").then(si=>si?setForm({...d,archivos:(d.archivos||[]).filter(x=>x.url)}):localStorage.removeItem(BORRADOR))}catch{localStorage.removeItem(BORRADOR)}},[]);
 useEffect(()=>{const t=setTimeout(()=>{const seguro={...form,archivos:form.archivos.filter(x=>x.url).map(({file,preview,...x})=>x)};localStorage.setItem(BORRADOR,JSON.stringify(seguro))},900);return()=>clearTimeout(t)},[form]);

 function errorPaso(n=paso){const c=form.cab;if(n===0&&(!texto(c.vendedor)||!texto(c.cliente)||!texto(c.canal)||!texto(c.telefono)))return"Completa vendedor, canal de venta, cliente/equipo y teléfono.";if(n===1&&(!c.fecha_entrega||!c.tipo_contrato||!c.prioridad))return"Completa tipo, prioridad y fecha de entrega.";if(n===2&&!form.prendasSel.length)return"Selecciona al menos una prenda del pedido.";if(n===5&&(!form.prendas.length||total<1))return"Agrega al menos una línea de talla con cantidad.";if(n===4&&(!c.nombre_tecnica||!c.numero_tecnica||!c.sellos_tpu))return"Completa las técnicas de nombre, número y TPU.";if(n===6&&(!texto(c.vendedor_responsable)||!c.autorizado))return"Confirma el vendedor responsable y la autorización de producción.";if(n===6&&Number(c.abono)>Number(c.presupuesto))return"El abono no puede superar el presupuesto.";return""}
 async function irSiguiente(){const e=errorPaso();if(e)return mostrarAvisoDialogo(e,"Revisa este paso",true);setPaso(x=>Math.min(6,x+1))}
 async function abrirPaso(i:number){if(i>paso){const e=errorPaso();if(e)return mostrarAvisoDialogo(e,"Revisa este paso",true)}setPaso(i)}

 async function buscarAnterior(){if(texto(busqueda).length<2)return mostrarAvisoDialogo("Escribe al menos 2 caracteres.","Buscar reposición");setBuscando(true);const{data,error}=await supabase.rpc("buscar_contratos_reposicion_v108",{p_busqueda:busqueda});setBuscando(false);if(error)return mostrarAvisoDialogo(error.message,"No se pudo buscar",true);setCoincidencias((data as any[])||[])}
 async function cargarReposicion(id:string){const{data,error}=await supabase.rpc("obtener_plantilla_contrato_v108",{p_contrato_id:id});if(error)return mostrarAvisoDialogo(error.message,"No se pudo cargar",true);const d:any=data,c=d.contrato||{};setForm(f=>({...f,cab:{...f.cab,tipo_contrato:c.tipo_contrato||"Normal",prioridad:c.prioridad||"Normal",reposicion:true,contrato_origen_reposicion_id:id,nombre_tecnica:c.nombre_tecnica||"",numero_tecnica:c.numero_tecnica||"",sellos_tpu:c.sellos_tpu||"No",ubicacion_tpu:c.ubicacion_tpu||"",bordado:c.bordado||"",colores:Array.isArray(c.colores_generales)?c.colores_generales.map((x:any)=>x.nombre||x).join(", "):"",adicionales:c.adicionales?.detalle||""},prendas:(d.prendas||[]).map((x:any)=>({...x,id:uuid()})),jugadores:(d.jugadores||[]).map((x:any)=>({...x,id:uuid()})),archivos:(d.archivos||[]).map((x:any)=>({...x,id:uuid()})),specs:(d.especificaciones||[]).map((x:any)=>({id:uuid(),prenda_clave:x.prenda_clave,variante_calidad:x.variante_calidad||"",mockup:texto(x.variante_mockup),...leerSpec(x.spec)})),facturacion:(d.facturacion||[]).map((x:any)=>({...x,id:uuid()}))}));setBusqueda("");setCoincidencias([]);await mostrarAvisoDialogo("Se copiaron prendas, jugadores, diseños y especificaciones. Cliente, fechas y valores siguen siendo los del nuevo contrato.","Reposición preparada")}

 function agregarPrenda(){setForm(f=>({...f,prendas:[...f.prendas,{id:uuid(),prenda:"Camiseta Jugador",calidad:"Amateur",detalle:"",genero:"H",talla:"M",cantidad:1}]}))}
 function agregarJugador(){setForm(f=>({...f,jugadores:[...f.jugadores,{id:uuid(),nombre:"",numero:"",categoria:"Hombre",talla_superior:"M",talla_inferior:"M",manga:"Corta",calidad:"Amateur",modelo_arquero:"",tipo_uniforme:"Uniforme completo",detalle:"",mockup:""}]}))}
 function agregarSpec(){setForm(f=>({...f,specs:[...f.specs,{id:uuid(),prenda_clave:f.prendas[0]?.prenda||"Camiseta Jugador",variante_calidad:f.prendas[0]?.calidad||"Amateur",mockup:"",campos:{},observacion:""}]}))}
 function agregarFact(){setForm(f=>({...f,facturacion:[...f.facturacion,{id:uuid(),concepto:"Uniforme completo",calidad:f.prendas[0]?.calidad||"Amateur",cantidad:1,obsequio:false}]}))}
 function seleccionar(tipo:"mockup"|"logo",files:FileList|null){if(!files)return;const limite=tipo==="mockup"?10:20;const nuevos=Array.from(files).slice(0,limite).map(file=>({id:uuid(),tipo,file,preview:file.type.startsWith("image/")?URL.createObjectURL(file):undefined,descripcion:file.name.replace(/\.[^.]+$/,""),color:"",prenda:"",posicion:"",tecnica:"",calidad_aplicable:"Todas",observacion:""}));setForm(f=>({...f,archivos:[...f.archivos,...nuevos]}))}

 async function importarJugadores(file:File){try{const XLSX=await import("xlsx");const wb=XLSX.read(await file.arrayBuffer(),{type:"array"});const rows=XLSX.utils.sheet_to_json<Record<string,unknown>>(wb.Sheets[wb.SheetNames[0]],{defval:""});if(!rows.length)throw new Error("La hoja no contiene filas");const jugadores:Jugador[]=rows.map(r=>({id:uuid(),nombre:texto(r.Nombre||r.NOMBRE),numero:texto(r.Numero||r.Número||r.NUMERO),categoria:texto(r.Categoria||r.Categoría)||"Hombre",talla_superior:texto(r.Talla_superior||r["Talla camiseta"]),talla_inferior:texto(r.Talla_inferior||r["Talla pantaloneta"]),manga:texto(r.Manga)||"Corta",calidad:texto(r.Calidad)||"Amateur",modelo_arquero:texto(r.Modelo_arquero),tipo_uniforme:texto(r.Tipo_uniforme)||"Uniforme completo",detalle:texto(r.Detalle),mockup:texto(r.Mockup)}));setForm(f=>({...f,jugadores}));await mostrarAvisoDialogo(`Se cargaron ${jugadores.length} jugador(es).`,"Excel procesado")}catch(e){await mostrarAvisoDialogo(e instanceof Error?e.message:"No se pudo leer el archivo","Excel inválido",true)}}
 async function plantillaJugadores(){const XLSX=await import("xlsx");const ws=XLSX.utils.json_to_sheet([{Nombre:"",Numero:"",Categoria:"Hombre",Talla_superior:"M",Talla_inferior:"M",Manga:"Corta",Calidad:"Amateur",Modelo_arquero:"",Tipo_uniforme:"Uniforme completo",Detalle:"",Mockup:"Mockup 1"}]);ws["!cols"]=[24,10,14,16,16,12,18,18,24,28,16].map(wch=>({wch}));const wb=XLSX.utils.book_new();XLSX.utils.book_append_sheet(wb,ws,"Jugadores");XLSX.writeFile(wb,"plantilla_jugadores_boman.xlsx")}

 async function guardar(){const falla=[0,1,2,4,6].map(errorPaso).find(Boolean);if(falla)return mostrarAvisoDialogo(falla,"Contrato incompleto",true);if(!await confirmarDialogo(`Se registrará un contrato nuevo con ${total} prendas y saldo de $${saldo.toFixed(2)}. ¿Continuar?`))return;setGuardando(true);try{const archivos:any[]=[];for(let orden=0;orden<form.archivos.length;orden++){const a=form.archivos[orden];if(!a.file){archivos.push({...a,orden});continue}const key=uuid();const prep=await supabase.rpc("preparar_archivo_contrato_v108",{p_nombre_archivo:a.file.name,p_mime_type:a.file.type,p_tamano_bytes:a.file.size,p_idempotency_key:key});if(prep.error)throw prep.error;const path=(prep.data as any).path;const subida=await supabase.storage.from("contratos-archivos").upload(path,a.file,{contentType:a.file.type,upsert:false});if(subida.error)throw subida.error;archivos.push({...a,file:undefined,preview:undefined,pendiente_id:(prep.data as any).id,url:supabase.storage.from("contratos-archivos").getPublicUrl(path).data.publicUrl,orden})}
  const mapa=new Map<string,Prenda>();for(const x of form.prendas){const k=[x.prenda,x.calidad,x.detalle,x.genero,x.talla].join("¦");const anterior=mapa.get(k);mapa.set(k,{...x,cantidad:(anterior?.cantidad||0)+Number(x.cantidad)})}
  const payload={contrato:{...form.cab,prendas_txt:form.prendasSel.map(etiquetaPrenda).join(", "),colores_generales:form.cab.colores.split(",").map(x=>x.trim()).filter(Boolean).map(nombre=>({nombre})),adicionales:{detalle:form.cab.adicionales,items:ADICIONALES.filter(a=>form.adicCant[a.clave]>0||form.adic[a.clave]!==a.opciones[0]).map(a=>({tipo:a.titulo,valor:form.adic[a.clave],cantidad:form.adicCant[a.clave]})),medidas_bandera:form.medidasBandera}},prendas:Array.from(mapa.values()).map(({id,...x})=>x),jugadores:form.jugadores.map(({id,...x},orden)=>({...x,orden})),archivos:archivos.map(({id,...x})=>x),especificaciones:form.specs.map(({id,mockup,campos,observacion,...x},orden)=>({...x,orden,variante_mockup:mockup,spec:{campos,observacion}})),facturacion:form.facturacion.map(({id,...x},orden)=>({...x,orden}))};
  const alta=await supabase.rpc("crear_contrato_v108",{p_datos:payload,p_idempotency_key:uuid()});if(alta.error)throw alta.error;const r:any=alta.data;localStorage.removeItem(BORRADOR);setResultado({numero:r.numero,id:r.contrato_id,respaldo:"en_curso"});setPreview(false);void respaldar(r.contrato_id)}catch(e){await mostrarAvisoDialogo(e instanceof Error?e.message:"No se pudo registrar el contrato","Error al registrar",true)}finally{setGuardando(false)}}

 async function respaldar(id:string){try{const res=await fetch("/api/bomansport/respaldo-contrato",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({contrato_id:id})});const data=await res.json();setResultado(x=>x&&x.id===id?{...x,respaldo:data.ok?"ok":"pendiente"}:x)}catch{setResultado(x=>x&&x.id===id?{...x,respaldo:"pendiente"}:x)}}

 if(resultado)return <section className={`card ${estilos.exito}`}><div>✓</div><h1>Contrato registrado</h1><strong>{resultado.numero}</strong><p>Ya está disponible en Producción → Contratos y en el tablero.</p><p className={resultado.respaldo==="pendiente"?estilos.respaldoPendiente:estilos.respaldoOk}>{resultado.respaldo==="en_curso"?"Respaldando en Google Sheets…":resultado.respaldo==="ok"?"✓ Copia de respaldo guardada en Google Sheets":"El respaldo en Sheets quedó pendiente; el contrato está seguro en Supabase."}</p><div>{resultado.respaldo==="pendiente"&&<button className="secondary" onClick={()=>void respaldar(resultado.id)}>Reintentar respaldo</button>}<button onClick={()=>{setResultado(null);setForm(inicial(perfil.nombre_completo));setPaso(0)}}>Ingresar otro</button><a className="button secondary" href="/produccion/contratos">Abrir expedientes</a></div></section>;
 return <>
  <header className={estilos.cabecera}><div><span className="eyebrow">VENTAS · v108</span><h1>Ingreso de contratos</h1><p>Pedido, brief técnico, tallas, diseños y valores conectados directamente con producción.</p></div><button className="secondary" onClick={()=>setPreview(true)}>Vista previa</button></header>
  <nav className={estilos.pasos}>{PASOS.map((x,i)=><button key={x} className={i===paso?estilos.activo:i<paso?estilos.completo:""} onClick={()=>void abrirPaso(i)}><b>{i<paso?"✓":i+1}</b><span>{x}</span></button>)}</nav>
  <section className={`card ${estilos.formulario}`}>
   {paso===0&&<PasoCliente form={form} setCab={setCab} busqueda={busqueda} setBusqueda={setBusqueda} buscar={buscarAnterior} buscando={buscando} coincidencias={coincidencias} cargar={cargarReposicion}/>} 
   {paso===1&&<PasoContrato form={form} setCab={setCab}/>}
   {paso===2&&<PasoPrendas form={form} setForm={setForm} setCab={setCab} total={total} supabase={supabase}/>}
   {paso===3&&<PasoArchivos form={form} seleccionar={seleccionar} cambiar={cambiar} quitar={quitar}/>} 
   {paso===4&&<PasoTecnica form={form} setCab={setCab} agregar={agregarSpec} cambiar={cambiar} quitar={quitar}/>} 
   {paso===5&&<PasoJugadores form={form} importar={importarJugadores} plantilla={plantillaJugadores} agregar={agregarJugador} agregarPrenda={agregarPrenda} cambiar={cambiar} quitar={quitar}/>} 
   {paso===6&&<PasoCierre form={form} setCab={setCab} saldo={saldo} agregar={agregarFact} cambiar={cambiar} quitar={quitar}/>} 
   <footer className={estilos.acciones}><button className="secondary" disabled={paso===0||guardando} onClick={()=>setPaso(x=>x-1)}>Anterior</button><span>Paso {paso+1} de 7 · borrador automático</span>{paso<6?<button onClick={()=>void irSiguiente()}>Continuar</button>:<><button className="secondary" onClick={()=>setPreview(true)}>Revisar</button><button onClick={()=>void guardar()} disabled={guardando}>{guardando?"Subiendo y registrando…":"Registrar contrato"}</button></>}</footer>
  </section>
  {preview&&<VistaPrevia form={form} total={total} saldo={saldo} cerrar={()=>setPreview(false)}/>} 
 </>;
}

type SetCab=<K extends keyof Cab>(k:K,v:Cab[K])=>void;
type Cambiar=<T extends {id:string}>(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string,cambio:Partial<T>)=>void;
type Quitar=(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string)=>void;

function PasoCliente({form,setCab,busqueda,setBusqueda,buscar,buscando,coincidencias,cargar}:{form:Form;setCab:SetCab;busqueda:string;setBusqueda:(x:string)=>void;buscar:()=>void;buscando:boolean;coincidencias:any[];cargar:(id:string)=>void}){return <><h2>Vendedor y cliente</h2><div className={estilos.reposicion}><div><strong>¿Es una reposición?</strong><span>Copia el brief anterior y crea un contrato nuevo.</span></div><div><input value={busqueda} onChange={e=>setBusqueda(e.target.value)} onKeyDown={e=>e.key==="Enter"&&buscar()} placeholder="Cliente o BOM-2026-…"/><button className="secondary" onClick={buscar}>{buscando?"Buscando…":"Buscar"}</button></div>{coincidencias.map(x=><button className={estilos.resultado} key={x.id} onClick={()=>cargar(x.id)}><strong>{x.numero}</strong><span>{x.cliente} · {x.total_prendas} prendas</span></button>)}</div><div className={estilos.grid}><Campo titulo="Vendedor *"><><input list="lista-vendedores" value={form.cab.vendedor} onChange={e=>setCab("vendedor",e.target.value)} placeholder="Seleccionar o escribir vendedor…"/><datalist id="lista-vendedores">{VENDEDORES.map(v=><option key={v} value={v}/>)}</datalist><small className={estilos.pista}>Selecciona de la lista o escribe otro nombre.</small></></Campo><Campo titulo="Canal de venta *"><select value={form.cab.canal} onChange={e=>setCab("canal",e.target.value)}><option value="">Seleccionar…</option>{CANALES.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="Cliente / equipo *"><input value={form.cab.cliente} onChange={e=>setCab("cliente",e.target.value)} placeholder="Nombre del equipo o cliente"/></Campo><Campo titulo="Teléfono *"><input value={form.cab.telefono} onChange={e=>setCab("telefono",e.target.value)} placeholder="0999123456"/></Campo><Campo titulo="WhatsApp"><input value={form.cab.whatsapp} onChange={e=>setCab("whatsapp",e.target.value)}/></Campo><Campo titulo="Correo"><input type="email" value={form.cab.email} onChange={e=>setCab("email",e.target.value)}/></Campo></div></>}
// 5 dias laborables antes de la fecha deseada, igual que el formulario legado.
function habilesAntes(iso:string,dias:number){
 const d=new Date(iso+"T00:00:00");if(isNaN(d.getTime()))return "";
 let n=0;while(n<dias){d.setDate(d.getDate()-1);const g=d.getDay();if(g!==0&&g!==6)n++}
 return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
}
function BarraCupo({etiqueta,usado,tope}:{etiqueta:string;usado:number;tope:number}){
 const excede=usado>tope;const pct=Math.min(100,tope>0?(usado/tope)*100:0);
 return <div className={estilos.barra}><span>{etiqueta}</span><div className={estilos.barraPista}><i style={{width:`${pct}%`,background:excede?"#dc2626":"#f59e0b"}}/></div><b className={excede?estilos.cupoMal:undefined}>{usado} / {tope}</b></div>;
}
type Cupo={tope_total:number;usado_total:number;por_tipo:{tipo:string;tope:number;usado:number}[]};
function CapacidadDia({supabase,fecha,tipo,total}:{supabase:ReturnType<typeof createClient>;fecha:string;tipo:string;total:number}){
 const [cupo,setCupo]=useState<Cupo|null>(null);const [estado,setEstado]=useState<"idle"|"cargando"|"error">("idle");
 useEffect(()=>{
  if(!fecha){setCupo(null);setEstado("idle");return}
  let vivo=true;setEstado("cargando");
  supabase.rpc("capacidad_dia_produccion_v110",{p_fecha:fecha}).then(({data,error})=>{
   if(!vivo)return;
   if(error||!data){setCupo(null);setEstado("error");return}
   setCupo(data as unknown as Cupo);setEstado("idle");
  });
  return()=>{vivo=false};
 },[fecha,supabase]);
 if(!fecha)return null;
 if(estado==="cargando")return <p className={estilos.pista}>Consultando el cupo del día…</p>;
 if(estado==="error"||!cupo)return <p className={estilos.pista}>No se pudo consultar el cupo del día (¿falta instalar v110?).</p>;
 // Se suma el contrato actual: lo que importa es como quedaria el dia, no como esta.
 const delTipo=cupo.por_tipo.find(x=>x.tipo===tipo);
 const topeTipo=delTipo?.tope??CAPACIDAD_DIARIA[tipo]??600;
 const usadoTipo=(delTipo?.usado??0)+total;
 const usadoTot=cupo.usado_total+total;
 const excedeTipo=usadoTipo>topeTipo,excedeTot=usadoTot>cupo.tope_total;
 return <div className={estilos.cupo}>
  <strong>Capacidad del día seleccionado</strong>
  <BarraCupo etiqueta={`Cupo ${tipo} (máx ${topeTipo})`} usado={usadoTipo} tope={topeTipo}/>
  <BarraCupo etiqueta={`Cupo total (máx ${cupo.tope_total})`} usado={usadoTot} tope={cupo.tope_total}/>
  {(excedeTipo||excedeTot)&&<p className={estilos.cupoExcedido}>⚠️ Cupo de {excedeTipo?tipo:"total"} excedido. Requiere autorización de Don Diego.</p>}
 </div>;
}
function PasoContrato({form,setCab}:{form:Form;setCab:SetCab}){return <><h2>Tipo de contrato y fecha</h2><div className={estilos.tipos}>{[["Normal","600 prendas/día"],["Equipo Profesional","100 prendas/día"],["Mercadería","150 prendas/día"],["Emergente","50 prendas/día"]].map(x=><button className={form.cab.tipo_contrato===x[0]?estilos.seleccionado:""} onClick={()=>setCab("tipo_contrato",x[0])} key={x[0]}><strong>{x[0]}</strong><small>{x[1]}</small></button>)}</div><div className={estilos.grid}><Campo titulo="Fecha deseada por el cliente *"><><input type="date" value={form.cab.fecha_entrega} onChange={e=>{const v=e.target.value;setCab("fecha_entrega",v);if(v)setCab("fecha_inicio_produccion",habilesAntes(v,5))}}/><small className={estilos.pista}>Al elegirla se propone el inicio de producción en el paso Prendas.</small></></Campo></div></>}
function PasoPrendas({form,setForm,setCab,total,supabase}:{form:Form;setForm:React.Dispatch<React.SetStateAction<Form>>;setCab:SetCab;total:number;supabase:ReturnType<typeof createClient>}){
 const alternar=(p:string)=>setForm(f=>({...f,prendasSel:f.prendasSel.includes(p)?f.prendasSel.filter(x=>x!==p):[...f.prendasSel,p]}));
 const setAdic=(k:keyof Adic,v:string)=>setForm(f=>({...f,adic:{...f.adic,[k]:v}}));
 const setAdicCant=(k:keyof Adic,v:number)=>setForm(f=>({...f,adicCant:{...f.adicCant,[k]:v}}));
 return <>
  <h2>Prendas y cantidades</h2>
  <p className={estilos.pista}>Selecciona las prendas a producir (la calidad se define por prenda en el paso de tallas).</p>
  <div className={estilos.tituloBloque}>Prendas incluidas en el pedido *</div>
  <div className={estilos.prendasGrid}>{PRENDAS.map(p=><label key={p} className={form.prendasSel.includes(p)?estilos.prendaSel:undefined}><input type="checkbox" checked={form.prendasSel.includes(p)} onChange={()=>alternar(p)}/><span>{etiquetaPrenda(p)}</span></label>)}</div>
  <div className={estilos.grid}>
   <Campo titulo="Total de prendas *" ancho><><div className={estilos.avisoInfo}>Se calcula automáticamente desde la tabla de tallas del paso Jugadores. Puedes modificarlo si es necesario.</div><input type="number" min={0} value={form.cab.total_manual||total} onChange={e=>setCab("total_manual",Number(e.target.value))} className={estilos.totalAuto}/></></Campo>
   <Campo titulo="Cantidad de arqueros"><input type="number" min={0} value={form.cab.arqueros} onChange={e=>setCab("arqueros",Number(e.target.value))}/></Campo>
  </div>
  <div className={estilos.tituloBloque}>Prioridad del contrato *</div>
  <div className={estilos.prioridades}>{[["Urgente","🔴","3 a 7 días hábiles"],["Normal","🟢","7 a 15 días hábiles"]].map(([v,ico,plazo])=><button key={v} className={form.cab.prioridad===v?estilos.prioridadSel:undefined} onClick={()=>setCab("prioridad",v)}><span>{ico}</span><strong>{v.toUpperCase()}</strong><small>{plazo}</small></button>)}</div>
  <div className={estilos.grid}><Campo titulo="Inicio de producción" ancho><><input type="date" value={form.cab.fecha_inicio_produccion} onChange={e=>setCab("fecha_inicio_produccion",e.target.value)}/><small className={estilos.pista}>Auto: 5 días laborables antes de la fecha deseada. Puedes ajustarlo manualmente.</small></></Campo></div>
  <CapacidadDia supabase={supabase} fecha={form.cab.fecha_inicio_produccion} tipo={form.cab.tipo_contrato} total={form.cab.total_manual||total}/>
  <p className={estilos.notaLili}>⚠️ Nota: Lili asignará la fecha exacta de inicio de producción según la capacidad del taller.</p>
  <div className={estilos.tituloBloque}>🎽 ADICIONALES DEL PEDIDO</div>
  <p className={estilos.avisoFuerte}>📌 Revisa esta sección muy bien antes de continuar: aquí se registran los accesorios del pedido, como banderas, banderines, medias y bolsos.</p>
  <div className={estilos.adicionales}>{ADICIONALES.map(a=><div key={a.clave} className={estilos.filaAdic}><Campo titulo={a.titulo}><select value={form.adic[a.clave]} onChange={e=>setAdic(a.clave,e.target.value)}>{a.opciones.map(o=><option key={o}>{o}</option>)}</select></Campo><Campo titulo={a.etiquetaCant}><input type="number" min={0} value={form.adicCant[a.clave]} onChange={e=>setAdicCant(a.clave,Number(e.target.value))}/></Campo></div>)}</div>
  {form.adic.bandera!=="Sin bandera"&&<div className={estilos.grid}><Campo titulo="Medidas de la bandera" ancho><input value={form.medidasBandera} onChange={e=>setForm(f=>({...f,medidasBandera:e.target.value}))} placeholder="Ej. 1,50X90"/></Campo></div>}
 </>;
}
function PasoArchivos({form,seleccionar,cambiar,quitar}:{form:Form;seleccionar:(t:"mockup"|"logo",f:FileList|null)=>void;cambiar:Cambiar;quitar:Quitar}){return <><h2>Mockups, logos y sellos</h2><div className={estilos.cargas}><label><strong>Mockups</strong><span>Hasta 10 imágenes o PDF; el primero será principal.</span><input type="file" multiple accept="image/jpeg,image/png,image/webp,application/pdf" onChange={e=>seleccionar("mockup",e.target.files)}/></label><label><strong>Logos y sellos</strong><span>Puedes seleccionar varios archivos.</span><input type="file" multiple accept="image/jpeg,image/png,image/webp,application/pdf" onChange={e=>seleccionar("logo",e.target.files)}/></label></div><div className={estilos.archivos}>{form.archivos.map(a=><article key={a.id}>{a.preview?<img src={a.preview} alt=""/>:<div className={estilos.archivoViejo}>{a.tipo.toUpperCase()}</div>}<select value={a.tipo} onChange={e=>cambiar<Archivo>("archivos",a.id,{tipo:e.target.value as Archivo["tipo"]})}><option value="mockup">Mockup</option><option value="logo">Logo / sello</option></select><input value={a.descripcion} placeholder="Descripción" onChange={e=>cambiar<Archivo>("archivos",a.id,{descripcion:e.target.value})}/>{a.tipo==="logo"&&<><input value={a.prenda} placeholder="Prenda aplicable" onChange={e=>cambiar<Archivo>("archivos",a.id,{prenda:e.target.value})}/><input value={a.posicion} placeholder="Posición" onChange={e=>cambiar<Archivo>("archivos",a.id,{posicion:e.target.value})}/><input value={a.tecnica} placeholder="Técnica" onChange={e=>cambiar<Archivo>("archivos",a.id,{tecnica:e.target.value})}/></>}<button className="secondary" onClick={()=>quitar("archivos",a.id)}>Quitar</button></article>)}</div></>}
function PasoTecnica({form,setCab,agregar,cambiar,quitar}:{form:Form;setCab:SetCab;agregar:()=>void;cambiar:Cambiar;quitar:Quitar}){return <><h2>Especificaciones técnicas</h2><div className={estilos.grid}><Campo titulo="Nombre jugador - técnica *"><select value={form.cab.nombre_tecnica} onChange={e=>setCab("nombre_tecnica",e.target.value)}><option value="">Seleccionar…</option>{TECNICAS.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="Número jugador - técnica *"><select value={form.cab.numero_tecnica} onChange={e=>setCab("numero_tecnica",e.target.value)}><option value="">Seleccionar…</option>{TECNICAS.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="¿Lleva sellos TPU? *"><select value={form.cab.sellos_tpu} onChange={e=>setCab("sellos_tpu",e.target.value)}><option>No</option><option>Sí</option></select></Campo><Campo titulo="Ubicación TPU"><select value={form.cab.ubicacion_tpu} onChange={e=>setCab("ubicacion_tpu",e.target.value)}>{UBICACION_TPU.map(x=><option key={x} value={x==="No aplica"?"":x}>{x}</option>)}</select></Campo><Campo titulo="Bordado / observaciones" ancho><textarea rows={3} value={form.cab.bordado} onChange={e=>setCab("bordado",e.target.value)}/></Campo><Campo titulo="Colores generales, separados por coma" ancho><input value={form.cab.colores} onChange={e=>setCab("colores",e.target.value)} placeholder="Azul marino, dorado, blanco"/></Campo></div><Titulo titulo="Detalle por prenda y calidad" texto="Los campos llenos se imprimen como tabla técnica en el brief; los vacíos no aparecen." accion={agregar} etiqueta="+ Especificación"/>{form.specs.map(s=><TarjetaSpec key={s.id} spec={s} prendas={Array.from(new Set(form.prendas.map(x=>x.prenda)))} mockups={mockupsDe(form)} cambiar={cambiar} quitar={quitar}/>)}{!form.specs.length&&<Vacio texto="Sin especificaciones técnicas: el brief saldrá solo con las técnicas generales."/>}</>}
function TarjetaSpec({spec,prendas,mockups,cambiar,quitar}:{spec:Spec;prendas:string[];mockups:Archivo[];cambiar:Cambiar;quitar:Quitar}){
 const campos=CAMPOS_TECNICOS[familiaPrenda(spec.prenda_clave)];
 const marca=FAMILIA_MARCA[familiaPrenda(spec.prenda_clave)];
 const fijar=(c:string,v:string)=>cambiar<Spec>("specs",spec.id,{campos:{...spec.campos,[c]:v}});
 return <article className={estilos.tarjetaSpec}>
  <header style={{borderLeftColor:marca.color}}>
   <span aria-hidden="true">{marca.icono}</span>
   <select aria-label="Prenda" value={spec.prenda_clave} onChange={e=>cambiar<Spec>("specs",spec.id,{prenda_clave:e.target.value})}>{(prendas.length?prendas:[spec.prenda_clave]).map(x=><option key={x}>{x}</option>)}</select>
   <select aria-label="Calidad" value={spec.variante_calidad} onChange={e=>cambiar<Spec>("specs",spec.id,{variante_calidad:e.target.value})}>{CALIDADES.map(x=><option key={x}>{x}</option>)}</select>
   <select aria-label="Mockup al que aplica" value={spec.mockup} onChange={e=>cambiar<Spec>("specs",spec.id,{mockup:e.target.value})}><option value="">Todos los mockups</option>{mockups.map((m,i)=><option key={m.id}>{etiquetaMockup(m,i)}</option>)}</select>
   <button className="secondary" onClick={()=>quitar("specs",spec.id)}>Quitar</button>
  </header>
  <div className={estilos.camposSpec}>{campos.map(f=><label key={f.c}><span>{f.t}</span>{f.o?<select value={spec.campos[f.c]||""} onChange={e=>fijar(f.c,e.target.value)}><option value="">— sin definir —</option>{f.o.map(o=><option key={o}>{o}</option>)}</select>:<input value={spec.campos[f.c]||""} onChange={e=>fijar(f.c,e.target.value)} placeholder="Opcional"/>}</label>)}</div>
  <label className={estilos.obsSpec}><span>Observación libre</span><textarea rows={2} value={spec.observacion} onChange={e=>cambiar<Spec>("specs",spec.id,{observacion:e.target.value})} placeholder="Lo que se salga de lo estándar para esta prenda…"/></label>
 </article>;
}
function PasoJugadores({form,importar,plantilla,agregar,agregarPrenda,cambiar,quitar}:{form:Form;importar:(f:File)=>void;plantilla:()=>void;agregar:()=>void;agregarPrenda:()=>void;cambiar:Cambiar;quitar:Quitar}){return <><Titulo titulo="Jugadores y personalización" texto="Ingreso manual o carga desde Excel." accion={agregar} etiqueta="+ Jugador"><button className="secondary" onClick={plantilla}>Plantilla Excel</button><label className={estilos.botonArchivo}>Cargar Excel<input type="file" accept=".xlsx,.xls,.csv" onChange={e=>e.target.files?.[0]&&importar(e.target.files[0])}/></label></Titulo>{form.jugadores.map((j,i)=><div className={estilos.filaJugador} key={j.id}><b>{i+1}</b><input placeholder="Nombre" value={j.nombre} onChange={e=>cambiar<Jugador>("jugadores",j.id,{nombre:e.target.value})}/><input placeholder="Número" value={j.numero} onChange={e=>cambiar<Jugador>("jugadores",j.id,{numero:e.target.value})}/><select value={j.categoria} onChange={e=>cambiar<Jugador>("jugadores",j.id,{categoria:e.target.value})}><option>Hombre</option><option>Mujer</option><option>Niño</option><option>Niña</option></select><input placeholder="Talla sup." value={j.talla_superior} onChange={e=>cambiar<Jugador>("jugadores",j.id,{talla_superior:e.target.value})}/><input placeholder="Talla inf." value={j.talla_inferior} onChange={e=>cambiar<Jugador>("jugadores",j.id,{talla_inferior:e.target.value})}/><select value={j.calidad} onChange={e=>cambiar<Jugador>("jugadores",j.id,{calidad:e.target.value})}>{CALIDADES.map(x=><option key={x}>{x}</option>)}</select><input placeholder="Detalle" value={j.detalle} onChange={e=>cambiar<Jugador>("jugadores",j.id,{detalle:e.target.value})}/><button className="secondary" onClick={()=>quitar("jugadores",j.id)}>Quitar</button></div>)}{!form.jugadores.length&&<Vacio texto="Este contrato no tiene nómina de jugadores."/>}<div className={estilos.tituloBloque}>TALLAS POR PRENDA Y CALIDAD</div><p className={estilos.avisoInfo}>Para cada prenda seleccionada agrega una línea por calidad. Ingresa las cantidades por talla y género (H/M para adultos, N para niños).</p>{!form.prendasSel.length&&<Vacio texto="Selecciona las prendas en el paso Prendas para ver las secciones de tallas."/>}{form.prendasSel.length>0&&<><div className={estilos.tituloAccion}><div><h3 style={{margin:0}}>Líneas de talla</h3><p>Prendas elegidas: {form.prendasSel.map(etiquetaPrenda).join(" · ")}</p></div><div><button onClick={agregarPrenda}>+ Agregar línea</button></div></div>{form.prendas.map(x=><div className={estilos.filaPrenda} key={x.id}><select value={x.prenda} onChange={e=>cambiar<Prenda>("prendas",x.id,{prenda:e.target.value})}>{prendasConTalla(form.prendasSel).map(p=><option key={p} value={p}>{etiquetaPrenda(p)}</option>)}</select><select value={x.calidad} onChange={e=>cambiar<Prenda>("prendas",x.id,{calidad:e.target.value})}>{CALIDADES.map(p=><option key={p}>{p}</option>)}</select><input placeholder="Detalle / variante" value={x.detalle} onChange={e=>cambiar<Prenda>("prendas",x.id,{detalle:e.target.value})}/><select value={x.genero} onChange={e=>cambiar<Prenda>("prendas",x.id,{genero:e.target.value as Prenda["genero"],talla:e.target.value==="N"?NINOS[0]:"M"})}><option value="H">Hombre</option><option value="M">Mujer</option><option value="N">Niño/a</option></select><select value={x.talla} onChange={e=>cambiar<Prenda>("prendas",x.id,{talla:e.target.value})}>{(x.genero==="N"?NINOS:ADULTOS).map(t=><option key={t}>{t}</option>)}</select><input type="number" min={1} value={x.cantidad} onChange={e=>cambiar<Prenda>("prendas",x.id,{cantidad:Number(e.target.value)})}/><button className="secondary" onClick={()=>quitar("prendas",x.id)}>Quitar</button></div>)}{!form.prendas.length&&<Vacio texto="Aún no agregas líneas de talla."/>}</>}</>}
function PasoCierre({form,setCab,saldo,agregar,cambiar,quitar}:{form:Form;setCab:SetCab;saldo:number;agregar:()=>void;cambiar:Cambiar;quitar:Quitar}){return <><h2>Producción, valores y cierre</h2><div className={estilos.grid}><Campo titulo="Presupuesto total (USD)"><input type="number" min={0} step=".01" value={form.cab.presupuesto} onChange={e=>setCab("presupuesto",Number(e.target.value))}/></Campo><Campo titulo="Abono recibido (USD)"><input type="number" min={0} step=".01" value={form.cab.abono} onChange={e=>setCab("abono",Number(e.target.value))}/></Campo><div className={estilos.saldo}><span>Saldo pendiente</span><strong>${saldo.toFixed(2)}</strong></div><Campo titulo="Forma de entrega"><select value={form.cab.forma_entrega} onChange={e=>setCab("forma_entrega",e.target.value)}><option value="">Seleccionar…</option>{FORMAS_ENTREGA.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="Dirección"><input value={form.cab.direccion} onChange={e=>setCab("direccion",e.target.value)}/></Campo><Campo titulo="Instrucciones especiales" ancho><textarea rows={4} value={form.cab.instrucciones} onChange={e=>setCab("instrucciones",e.target.value)}/></Campo><Campo titulo="Vendedor responsable *"><input value={form.cab.vendedor_responsable} onChange={e=>setCab("vendedor_responsable",e.target.value)}/></Campo></div><Titulo titulo="Detalle de facturación" accion={agregar} etiqueta="+ Línea"/>{form.facturacion.map(x=><div className={estilos.filaFact} key={x.id}><input value={x.concepto} onChange={e=>cambiar<Fact>("facturacion",x.id,{concepto:e.target.value})}/><select value={x.calidad} onChange={e=>cambiar<Fact>("facturacion",x.id,{calidad:e.target.value})}>{CALIDADES.map(x=><option key={x}>{x}</option>)}</select><input type="number" min={1} value={x.cantidad} onChange={e=>cambiar<Fact>("facturacion",x.id,{cantidad:Number(e.target.value)})}/><label className={estilos.check}><input type="checkbox" checked={x.obsequio} onChange={e=>cambiar<Fact>("facturacion",x.id,{obsequio:e.target.checked})}/> Obsequio</label><button className="secondary" onClick={()=>quitar("facturacion",x.id)}>Quitar</button></div>)}<label className={estilos.autoriza}><input type="checkbox" checked={form.cab.autorizado} onChange={e=>setCab("autorizado",e.target.checked)}/><span><strong>Confirmo que revisé todos los datos.</strong> Autorizo el envío de este contrato a producción.</span></label></>}
function Titulo({titulo,texto,accion,etiqueta,children}:{titulo:string;texto?:string;accion:()=>void;etiqueta:string;children?:ReactNode}){return <div className={estilos.tituloAccion}><div><h2>{titulo}</h2>{texto&&<p>{texto}</p>}</div><div>{children}<button onClick={accion}>{etiqueta}</button></div></div>}
function Vacio({texto}:{texto:string}){return <div className={estilos.vacio}>{texto}</div>}

/* ─────────────────────────────────────────────────────────────────────────────
   BRIEF DE PRODUCCIÓN
   Reproduce el documento del sistema legado (Apps Script, generarBriefHtml_). El
   taller lo imprime y lo lee a diario, así que se respeta SU lenguaje visual —azul
   #1F4E78, banner de calidad amarillo, bandas de color por calidad y por género—
   y no el cromo de la aplicación: es un papel, no una pantalla. Por lo mismo va
   siempre sobre blanco, aunque la app esté en tema oscuro.
   ───────────────────────────────────────────────────────────────────────────── */
const ORDEN_TALLAS=[...NINOS,...ADULTOS];
const posTalla=(t:string)=>{const i=ORDEN_TALLAS.indexOf(t);return i<0?99:i};
const posCalidad=(c:string)=>{const i=CALIDADES.indexOf(c);return i<0?99:i};
const fechaCorta=(v:string)=>{const m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(texto(v));return m?`${m[3]}/${m[2]}/${m[1]}`:texto(v)};
const mockupsDe=(f:Form)=>f.archivos.filter(a=>a.tipo==="mockup");
const etiquetaMockup=(a:Archivo,i:number)=>texto(a.descripcion)||`Mockup ${i+1}`;
const imagenDe=(a:Archivo)=>a.preview||a.url||"";
// Resolver a QUÉ mockup apunta un jugador o una spec. Igual que el legado: manda la
// descripción exacta y solo si ninguna coincide se lee "Mockup N" como alias posicional,
// para que una imagen descrita literalmente "Mockup 2" no caiga también en la segunda.
function indiceMockup(valor:string,mockups:Archivo[]){
 const v=texto(valor).toLowerCase(); if(!v)return -1;
 const porDesc=mockups.findIndex(m=>texto(m.descripcion).toLowerCase()===v); if(porDesc>=0)return porDesc;
 const porEtiqueta=mockups.findIndex((m,i)=>etiquetaMockup(m,i).toLowerCase()===v); if(porEtiqueta>=0)return porEtiqueta;
 const pos=/^mockup\s+(\d+)$/.exec(v); if(pos){const i=Number(pos[1])-1;if(i>=0&&i<mockups.length)return i}
 return -1;
}

function VistaPrevia({form,total,saldo,cerrar}:{form:Form;total:number;saldo:number;cerrar:()=>void}){
 const [montado,setMontado]=useState(false);
 // El brief se monta en <body> por portal: así la regla @media print puede apagar el
 // resto de la página con un selector de hijo directo, sin tocar globals.css.
 useEffect(()=>{setMontado(true);document.body.classList.add("brief-imprimible");const esc=(e:KeyboardEvent)=>{if(e.key==="Escape")cerrar()};document.addEventListener("keydown",esc);return()=>{document.body.classList.remove("brief-imprimible");document.removeEventListener("keydown",esc)}},[cerrar]);
 const c=form.cab;
 const mockups=mockupsDe(form);
 const logos=form.archivos.filter(a=>a.tipo==="logo");
 const calidades=Array.from(new Set(form.prendas.map(x=>x.calidad).filter(Boolean)));
 const calidad=calidades.length?calidades.join(" / "):"Sin calidad";
 const colores=c.colores.split(",").map(x=>x.trim()).filter(Boolean);
 const adicionales=texto(c.adicionales).split("\n").map(x=>x.trim()).filter(Boolean);
 // Jugadores y specs se reparten por mockup; lo que no cae en ninguno se muestra
 // aparte para que nunca desaparezca del papel (el legado tuvo ese bug y lo blinda).
 const porMockup=mockups.map((m,i)=>({m,i,jugadores:form.jugadores.filter(j=>indiceMockup(j.mockup,mockups)===i),specs:form.specs.filter(s=>indiceMockup(s.mockup,mockups)===i)}));
 const jugadoresSueltos=form.jugadores.filter(j=>indiceMockup(j.mockup,mockups)<0);
 const specsSueltas=form.specs.filter(s=>indiceMockup(s.mockup,mockups)<0);
 const grupos=agruparTallas(form.prendas);
 const detalle=form.facturacion.length
  ?form.facturacion.map(f=>({cantidad:String(f.cantidad),texto:f.concepto,calidad:f.calidad,obsequio:f.obsequio}))
  :grupos.map(g=>({cantidad:String(g.lineas.reduce((s,l)=>s+l.totH+l.totM+l.totN,0)),texto:g.prenda,calidad:"",obsequio:false}));
 if(!montado)return null;
 return createPortal(
  <div className={estilos.vistaPrevia} role="dialog" aria-modal="true" aria-label="Brief de producción" onMouseDown={e=>e.target===e.currentTarget&&cerrar()}>
   <div className={`${estilos.barraBrief} ${estilos.noPrint}`}>
    <strong>Vista previa del brief de producción</strong>
    <button onClick={()=>window.print()}>Imprimir</button>
    <button className="secondary" onClick={cerrar}>Cerrar</button>
   </div>
   <article className={estilos.hoja}>
    <div className={estilos.bTop}>
     <div className={estilos.bCal} style={calidad.length>26?{fontSize:"13px"}:calidad.length>16?{fontSize:"17px"}:undefined}>{calidad}</div>
     <div className={estilos.bNota}>NOTA: ANTES DEL ENSAMBLE, CORROBORAR QUE EL MOCKUP SEA EL CORRECTO</div>
    </div>
    <div className={estilos.bTitulo}>DETALLE DE CONTRATO: {c.cliente||"—"}</div>
    <table className={estilos.bhTbl}><tbody>
     <tr>
      <td className={estilos.bhLbl}>CONTRATO:</td>
      <td className={estilos.bhVal}>{c.cliente||"—"}{c.prioridad==="Urgente"&&<span className={estilos.bBadgeRojo}>⚠️ URGENTE</span>}{c.reposicion&&<span className={estilos.bBadgeRojo}>🔄 REPOSICIÓN</span>}</td>
      <td className={estilos.bhRespH} rowSpan={2}><div className={estilos.bhCod}>NUEVO CONTRATO</div>RESPONSABLE<div className={estilos.bhResp}>{c.vendedor_responsable||c.vendedor||"—"}</div></td>
     </tr>
     <tr><td className={estilos.bhLbl}>FECHA DE INGRESO:</td><td className={estilos.bhVal}>{fechaCorta(new Date().toISOString().slice(0,10))}</td></tr>
     <tr><td className={estilos.bhLbl}>FECHA DE ENTREGA:</td><td className={`${estilos.bhVal} ${estilos.bhEnt}`}>{fechaCorta(c.fecha_entrega)||"—"}</td><td className={estilos.bhVal}>{c.tipo_contrato} · {total} prendas</td></tr>
     <tr><td className={estilos.bhLbl}>ENTREGA:</td><td className={estilos.bhVal} colSpan={2}>{c.forma_entrega||"—"}{c.direccion&&` · ${c.direccion}`}</td></tr>
    </tbody></table>

    <div className={estilos.bCols}>
     <table className={estilos.cdTbl}><tbody>
      <tr><td className={estilos.cdH}>CANT.</td><td className={estilos.cdH}>{form.facturacion.length?"DETALLE (FACTURACIÓN)":"DETALLE"}</td></tr>
      {detalle.length?detalle.map((d,i)=><tr key={i}><td className={estilos.cdQ}>{d.cantidad}</td><td className={estilos.cdD}>{d.texto}{d.calidad&&<span style={{color:"#1F4E78"}}> ({d.calidad})</span>}{d.obsequio&&<b style={{color:"#9333ea"}}> 🎁 OBSEQUIO</b>}</td></tr>)
       :<tr><td className={estilos.cdQ}>0</td><td className={estilos.cdD}>Sin prendas cargadas</td></tr>}
     </tbody></table>
     <div>
      <div className={estilos.bSubtitulo}>Resumen técnico</div>
      <table className={estilos.bDatos}><tbody>
       <tr><td>Técnica nombre</td><td>{c.nombre_tecnica||"—"}</td></tr>
       <tr><td>Técnica número</td><td>{c.numero_tecnica||"—"}</td></tr>
       <tr><td>Sellos TPU</td><td>{c.sellos_tpu||"—"}{c.ubicacion_tpu&&` · ${c.ubicacion_tpu}`}</td></tr>
       {!!texto(c.bordado)&&<tr><td>Bordado especial</td><td style={{color:"#7c3aed",fontWeight:700}}>{c.bordado}</td></tr>}
       {c.arqueros>0&&<tr><td>Arqueros</td><td>{c.arqueros}</td></tr>}
      </tbody></table>
     </div>
     {!!adicionales.length&&<div className={estilos.bAdic}><div className={estilos.bAdicTit}>⚠️ ADICIONALES DEL PEDIDO</div>{adicionales.map((l,i)=><div key={i} className={/^bandera/i.test(l)?estilos.bAdicBandera:estilos.bAdicLinea}>• {l}</div>)}</div>}
    </div>

    {!!colores.length&&<div className={estilos.bColores}>
     <div className={estilos.bH3}>COLORES GENERALES</div>
     <div className={estilos.bChips}>{colores.map(x=><span key={x} className={estilos.bChip}>{x}</span>)}</div>
     <div className={estilos.bAviso}>⚠️ SIEMPRE PREDOMINA EL COLOR DEL MOCKUP Y DE LA MUESTRA SOBRE EL COLOR REFERENCIAL</div>
    </div>}

    {porMockup.map(({m,i,jugadores,specs})=><section key={m.id} className={estilos.bSeccion}>
     <div className={estilos.bMk}>
      <div>
       <div className={estilos.bMkCab}><span>MOCKUP {i+1}</span>{texto(m.descripcion)&&` ${m.descripcion}`}</div>
       {imagenDe(m)?<img className={estilos.bMkFoto} src={imagenDe(m)} alt={`Mockup ${i+1}`}/>:<div className={estilos.bMkVacio}>Sin imagen</div>}
       {!!texto(m.color)&&<div className={estilos.bMkColor}>🎨 {m.color}</div>}
       {!!specs.map(s=>s.campos.corte).filter(Boolean).length&&<div className={estilos.bCorte}>✂️ CORTE: {Array.from(new Set(specs.map(s=>s.campos.corte).filter(Boolean))).join(" / ")}</div>}
       {i===0&&!!texto(c.instrucciones)&&<div className={estilos.bInstr}><div className={estilos.bInstrTit}>⚠️ INSTRUCCIONES ESPECIALES</div><div>{c.instrucciones}</div></div>}
      </div>
      <div>{specs.length?<BloqueSpecs specs={specs} titulo={`🧵 Especificaciones técnicas — Mockup ${i+1}`}/>:<div className={estilos.bMkSinSpec}>Sin especificaciones técnicas propias de este mockup.</div>}</div>
     </div>
     {!!jugadores.length&&<div className={estilos.bTablaAncha}><TablaJugadores jugadores={jugadores}/></div>}
    </section>)}

    {!mockups.length&&!!form.specs.length&&<section className={estilos.bSeccion}><BloqueSpecs specs={form.specs} titulo="🧵 Especificaciones técnicas"/></section>}
    {!!mockups.length&&!!specsSueltas.length&&<section className={estilos.bSeccion}><BloqueSpecs specs={specsSueltas} titulo="🧵 Especificaciones técnicas — todas las prendas"/></section>}
    {!!jugadoresSueltos.length&&<section className={estilos.bSeccion}>
     {!!mockups.length&&<div className={estilos.bSinMockup}>SIN MOCKUP ASIGNADO</div>}
     {!mockups.length&&<div className={estilos.bH3}>LISTA DE JUGADORES ({jugadoresSueltos.length})</div>}
     <TablaJugadores jugadores={jugadoresSueltos}/>
    </section>}

    {!!grupos.length&&<section className={estilos.bSeccion}>
     <div className={estilos.bH3}>TABLA DE TALLAS POR PRENDA</div>
     <div className={estilos.bTallas}>{grupos.map(g=><BloqueTallas key={g.prenda} grupo={g}/>)}</div>
    </section>}

    {!!logos.length&&<section className={estilos.bSeccion}>
     <div className={estilos.bH3}>LOGOS Y SELLOS ({logos.length})</div>
     <div className={estilos.bLogos}>{logos.map((l,i)=><div key={l.id} className={estilos.bLogo}>
      <div className={estilos.bLogoTit}>LOGO {i+1}{texto(l.descripcion)&&` — ${l.descripcion}`}</div>
      <div className={estilos.bLogoTags}><span className={estilos.bTagAzul}>👕 {l.prenda||"Sin especificar"}</span><span className={estilos.bTagClaro}>📍 {l.posicion||"Sin especificar"}</span>{!!texto(l.tecnica)&&<span className={estilos.bTagMorado}>🔧 {l.tecnica}</span>}{l.calidad_aplicable&&l.calidad_aplicable!=="Todas"&&<span className={estilos.bTagAmbar}>★ {l.calidad_aplicable}</span>}</div>
      {imagenDe(l)?<div className={estilos.bLogoFoto}><img src={imagenDe(l)} alt=""/></div>:<div className={estilos.bLogoSinFoto}>📁 Archivo adjunto</div>}
      {!!texto(l.observacion)&&<div className={estilos.bObs}><b>📝 Obs:</b> {l.observacion}</div>}
     </div>)}</div>
    </section>}

    <section className={estilos.bSeccion}>
     <div className={estilos.bH3}>VALORES</div>
     <table className={estilos.bDatos}><tbody>
      <tr><td>Presupuesto</td><td>${Number(c.presupuesto||0).toFixed(2)}</td></tr>
      <tr><td>Abono recibido</td><td>${Number(c.abono||0).toFixed(2)}</td></tr>
      <tr><td>Saldo pendiente</td><td style={{fontWeight:900,color:"#92400E"}}>${saldo.toFixed(2)}</td></tr>
     </tbody></table>
    </section>
    <div className={estilos.bPie}>Brief generado {fechaCorta(new Date().toISOString().slice(0,10))} · Boman Sport</div>
   </article>
  </div>,document.body);
}

// Tabla de jugadores del brief: cabecera azul, zebra, bandas de calidad y columnas
// que se ocultan si nadie las llenó (roban ancho para mostrar solo guiones).
function TablaJugadores({jugadores}:{jugadores:Jugador[]}){
 const arr=jugadores.slice().sort((a,b)=>posCalidad(a.calidad)-posCalidad(b.calidad)||a.tipo_uniforme.localeCompare(b.tipo_uniforme)||a.nombre.localeCompare(b.nombre));
 const hay={numero:arr.some(j=>texto(j.numero)),manga:arr.some(j=>j.manga==="Larga"),inferior:arr.some(j=>texto(j.talla_inferior)),arquero:arr.some(j=>texto(j.modelo_arquero)),calidad:arr.some(j=>texto(j.calidad)),tipo:arr.some(j=>texto(j.tipo_uniforme)),detalle:arr.some(j=>texto(j.detalle))};
 const columnas=1+Number(hay.numero)+1+1+Number(hay.manga)+Number(hay.inferior)+Number(hay.arquero)+Number(hay.tipo)+Number(hay.detalle);
 let calPrevia="";
 return <table className={estilos.bJug}>
  <thead><tr>
   <th>NOMBRE</th>{hay.numero&&<th>NÚM</th>}<th>CATEG.</th><th>T.CAM</th>{hay.manga&&<th>MANGA</th>}{hay.inferior&&<th>T.PANT</th>}{hay.arquero&&<th>MOD. ARQ.</th>}{hay.tipo&&<th>TIPO</th>}{hay.detalle&&<th>DETALLE</th>}
  </tr></thead>
  <tbody>{arr.map((j,i)=>{
   const banda=hay.calidad&&texto(j.calidad)&&j.calidad!==calPrevia?j.calidad:"";
   if(banda)calPrevia=j.calidad;
   return <Fragment key={j.id}>
    {!!banda&&<tr><td className={estilos.bBandaCal} colSpan={columnas}>■ {banda.toUpperCase()} ▼</td></tr>}
    <tr className={i%2===0?estilos.bPar:undefined}>
     <td className={texto(j.nombre)?estilos.bNombre:estilos.bSinNombre}>{texto(j.nombre)||"SIN NOMBRE"}</td>
     {hay.numero&&<td className={estilos.bCentroFuerte}>{j.numero}</td>}
     <td className={estilos.bCentro}>{j.categoria||"—"}</td>
     <td className={estilos.bTallaSup}>{texto(j.talla_superior)||"—"}</td>
     {hay.manga&&<td className={j.manga==="Larga"?estilos.bMangaLarga:estilos.bMangaCorta}>{j.manga==="Larga"?"LARGA":"corta"}</td>}
     {hay.inferior&&<td className={estilos.bTallaInf}>{texto(j.talla_inferior)||"—"}</td>}
     {hay.arquero&&<td className={texto(j.modelo_arquero)?estilos.bArquero:estilos.bCentroSuave}>{texto(j.modelo_arquero)||"—"}</td>}
     {hay.tipo&&<td className={estilos.bCentro}>{texto(j.tipo_uniforme)||"—"}</td>}
     {hay.detalle&&<td className={estilos.bDetalle}>{texto(j.detalle)||"—"}</td>}
    </tr>
   </Fragment>;
  })}</tbody>
  <tfoot><tr><td colSpan={columnas}>Total: {arr.length} jugadores</td></tr></tfoot>
 </table>;
}

// Fichas de especificación: una por prenda, con su cabecera de color, la caja de CORTE
// destacada y la tabla etiqueta|valor. Los campos vacíos o "No aplica" no se imprimen.
function BloqueSpecs({specs,titulo}:{specs:Spec[];titulo:string}){
 return <div><div className={estilos.bSpecTit}>{titulo}</div><div className={estilos.bSpecs}>{specs.map(s=>{
  const familia=familiaPrenda(s.prenda_clave); const marca=FAMILIA_MARCA[familia];
  const filas=CAMPOS_TECNICOS[familia].filter(f=>f.c!=="corte"&&texto(s.campos[f.c])&&!/^no aplica$/i.test(texto(s.campos[f.c])));
  return <article key={s.id} className={estilos.bSpecCard}>
   <div className={estilos.bSpecCab} style={{background:marca.color}}>{marca.icono} {s.prenda_clave.toUpperCase()}{s.variante_calidad&&` · ${s.variante_calidad}`}</div>
   {!!texto(s.campos.corte)&&<div className={estilos.bCorte}>✂️ CORTE: {s.campos.corte}</div>}
   {!!filas.length&&<table className={estilos.bDatos}><tbody>{filas.map(f=><tr key={f.c}><td>{f.t}</td><td>{s.campos[f.c]}</td></tr>)}</tbody></table>}
   {!filas.length&&!texto(s.campos.corte)&&!texto(s.observacion)&&<div className={estilos.bSpecVacio}>Sin detalle técnico cargado.</div>}
   {!!texto(s.observacion)&&<div className={estilos.bObs}><b>📝 Obs:</b> {s.observacion}</div>}
  </article>;
 })}</div></div>;
}

type LineaTallas={clave:string;calidad:string;detalle:string;tallas:string[];conteo:Record<string,{H:number;M:number;N:number}>;totH:number;totM:number;totN:number};
type GrupoTallas={prenda:string;lineas:LineaTallas[]};
// Cuadros-resumen de tallas: una caja por prenda, dentro una tabla por calidad con las
// tallas como columnas y una fila por género. Las prendas de arquero van al final.
function agruparTallas(prendas:Prenda[]):GrupoTallas[]{
 const porPrenda=new Map<string,Map<string,LineaTallas>>();
 for(const p of prendas){
  const cant=Math.max(0,Number(p.cantidad)||0); if(!cant)continue;
  if(!porPrenda.has(p.prenda))porPrenda.set(p.prenda,new Map());
  const lineas=porPrenda.get(p.prenda)!; const clave=`${p.calidad}¦${p.detalle}`;
  if(!lineas.has(clave))lineas.set(clave,{clave,calidad:p.calidad,detalle:p.detalle,tallas:[],conteo:{},totH:0,totM:0,totN:0});
  const l=lineas.get(clave)!;
  if(!l.conteo[p.talla])l.conteo[p.talla]={H:0,M:0,N:0};
  l.conteo[p.talla][p.genero]+=cant;
  if(p.genero==="H")l.totH+=cant; else if(p.genero==="M")l.totM+=cant; else l.totN+=cant;
 }
 return Array.from(porPrenda,([prenda,lineas])=>({prenda,lineas:Array.from(lineas.values()).map(l=>({...l,tallas:Object.keys(l.conteo).sort((a,b)=>posTalla(a)-posTalla(b)||a.localeCompare(b))}))}))
  .sort((a,b)=>Number(/arquer/i.test(a.prenda))-Number(/arquer/i.test(b.prenda)));
}
function BloqueTallas({grupo}:{grupo:GrupoTallas}){
 const unica=grupo.lineas.length===1;
 const totalPrenda=grupo.lineas.reduce((s,l)=>s+l.totH+l.totM+l.totN,0);
 const maxCols=Math.max(...grupo.lineas.map(l=>l.tallas.length));
 return <div className={estilos.bTallaBloque} style={{flexBasis:maxCols>=11?"100%":maxCols>=7?"480px":"300px"}}>
  <div className={estilos.bTallaCab}>👕 {grupo.prenda.toUpperCase()}{unica&&grupo.lineas[0].calidad&&` — ${grupo.lineas[0].calidad.toUpperCase()}`}<span>{totalPrenda} uds</span></div>
  {grupo.lineas.map(l=><div key={l.clave}>
   {!unica&&<div className={estilos.bTallaLinea}><span>{(l.calidad||l.detalle||"Sin calidad").toUpperCase()}</span><span>{l.totH+l.totM+l.totN} uds</span></div>}
   <table className={estilos.bTallaTbl}><tbody>
    <tr><th className={estilos.bTallaGen}>Género</th>{l.tallas.map(t=><th key={t}>{t}</th>)}<th className={estilos.bTallaTot}>Total</th></tr>
    {l.totH>0&&<tr className={estilos.bFilaH}><td>👨 Hombre</td>{l.tallas.map(t=><td key={t}>{l.conteo[t].H||"·"}</td>)}<td>{l.totH}</td></tr>}
    {l.totM>0&&<tr className={estilos.bFilaM}><td>👩 Mujer</td>{l.tallas.map(t=><td key={t}>{l.conteo[t].M||"·"}</td>)}<td>{l.totM}</td></tr>}
    {l.totN>0&&<tr className={estilos.bFilaN}><td>🧒 Niño/a</td>{l.tallas.map(t=><td key={t}>{l.conteo[t].N||"·"}</td>)}<td>{l.totN}</td></tr>}
    {[l.totH,l.totM,l.totN].filter(x=>x>0).length>1&&<tr className={estilos.bFilaTotal}><td>TOTAL</td>{l.tallas.map(t=><td key={t}>{l.conteo[t].H+l.conteo[t].M+l.conteo[t].N||"—"}</td>)}<td className={estilos.bTallaTot}>{l.totH+l.totM+l.totN}</td></tr>}
   </tbody></table>
  </div>)}
 </div>;
}
