"use client";

import { Fragment, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { confirmarDialogo, mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/permisos";
import estilos from "./IngresoContrato.module.css";
import {TODOS_LOS_COLORES} from "./colores";
import {FICHAS_PRENDA,fichasDePrendas,opcionesCampo,esCalidadAlta,type FichaPrenda} from "./specsPrendas";

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
// Logos: posiciones validas segun la prenda, tal cual index.html
// (POSICIONES_POR_PRENDA + getPosicionesPrenda). Sin esto los tres campos del
// logo eran texto libre y cada vendedor escribia la zona a su manera, que es
// justo lo que el taller no puede interpretar.
const POS_CAMISETA=["Pecho izquierdo","Pecho derecho","Centro pecho","Espalda superior","Espalda centro","Espalda inferior","Manga derecha","Manga izquierda","Cuello"];
const POS_PANTALON=["Pierna izquierda","Pierna derecha","Cintura frontal","Cintura posterior","Lateral izquierdo","Lateral derecho"];
const POS_CHOMPA=["Pecho izquierdo","Pecho derecho","Centro pecho","Espalda superior","Espalda centro","Manga derecha","Manga izquierda","Cuello posterior","Bolsillo"];
const POS_CHALECO=["Pecho izquierdo","Pecho derecho","Centro pecho","Espalda superior","Espalda centro"];
const POS_MEDIAS=["Caña","Tobillo"];
const POS_ESPECIAL=["Diseño completo","Frente","Reverso"];
const unicos=(a:string[])=>a.filter((v,i)=>a.indexOf(v)===i);
function posicionesDePrenda(prenda:string){
 const p=prenda.trim().toLowerCase();
 if(["camiseta jugador","camiseta jugador m/l","camiseta arquero","camiseta polo","chompas retro","bvds"].includes(p))return POS_CAMISETA;
 if(["pantaloneta jugador","pantaloneta arquero","bermudas","falda short","licra","pantalón","pantalon"].includes(p))return POS_PANTALON;
 if(["chompa","chompa de frío","chompa frío 3/4","rompevientos","chompa deportiva","hoodie","exterior completo","uniformes completos","arquero completo"].includes(p))return unicos([...POS_CAMISETA,...POS_CHOMPA]);
 if(p==="chaleco")return POS_CHALECO;
 if(p==="medias")return POS_MEDIAS;
 if(["bolsos","bandera","cinta capitán","banderín"].includes(p))return POS_ESPECIAL;
 if(p==="todas")return unicos([...POS_CAMISETA,...POS_PANTALON,...POS_CHOMPA]);
 return POS_CAMISETA;
}
const TECNICAS_LOGO=["DTF","Sublimado","Bordado","TPU"];
// Prendas ofrecidas al asignar un logo. A diferencia de prendasConTalla, aqui
// SI entran medias, bandera y demas accesorios: llevan logo aunque no lleven
// talla. "Todas" al final, igual que getPrendasParaLogos del legado.
function prendasParaLogos(sel:string[]){
 const out:string[]=[];
 for(const p of sel)for(const c of (PRENDA_EXPANSION[p]??[p]))if(!out.includes(c))out.push(c);
 return [...out,"Todas"];
}
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
// El catalogo de campos tecnicos vive solo en specsPrendas.ts (FICHAS_PRENDA):
// tener uno aqui para el brief y otro alla para el formulario hacia que lo
// capturado no se imprimiera, porque los ids no coincidian.
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
type Cab={vendedor:string;canal:string;nombre_contrato_v115:string;cliente:string;almacen_venta_id_v115:string;telefono:string;whatsapp:string;email:string;tipo_contrato:string;fecha_entrega:string;fecha_inicio_produccion:string;prioridad:string;arqueros:number;total_manual:number;reposicion:boolean;contrato_origen_reposicion_id:string;nombre_tecnica:string;numero_tecnica:string;sellos_tpu:string;ubicacion_tpu:string;bordado:string;colores:string;instrucciones:string;presupuesto:number;abono:number;forma_entrega:string;direccion:string;vendedor_responsable:string;autorizado:boolean;adicionales:string};
type AlmacenVenta={id:string;nombre:string;codigo:string};
// Accesorios del pedido. En el legado cada uno es un select + una cantidad, y
// se imprimen en el recuadro "ADICIONALES DEL PEDIDO" del brief.
const ADICIONALES:{clave:keyof Adic;titulo:string;opciones:string[];etiquetaCant:string}[]=[
 // OJO: "Incluye polainas" e "Incluye antideslizantes" NO van aqui aunque el
 // legado los ofrezca. Las dos tienen su PROPIO selector con su propia cantidad
 // (abajo), y elegirlas desde Medias las hacia compartir el casillero de
 // cantidad de las medias: el brief terminaba imprimiendo la misma prenda dos
 // veces. Codigo.gs ya trae una fusion para reparar ese caso; aqui se corta de
 // raiz. "Incluye personalizadas" si se queda: son medias, sin selector propio.
 {clave:"medias",titulo:"Medias",opciones:["No incluye medias","Incluye medias","Incluye personalizadas"],etiquetaCant:"Cantidad de medias (si aplica)"},
 {clave:"polainas",titulo:"Polainas",opciones:["No incluye polainas","Incluye polainas"],etiquetaCant:"Cantidad de polainas (si aplica)"},
 {clave:"antideslizantes",titulo:"Medias antideslizantes",opciones:["No incluye antideslizantes","Incluye antideslizantes"],etiquetaCant:"Cantidad de antideslizantes (si aplica)"},
 {clave:"banda_capitan",titulo:"Banda de Capitán",opciones:["Sin banda de capitán","Con banda de capitán"],etiquetaCant:"Cantidad de bandas (si aplica)"},
 {clave:"banderin",titulo:"Banderín",opciones:["Sin banderín","Con banderín"],etiquetaCant:"Cantidad de banderines (si aplica)"},
 {clave:"bandera",titulo:"Bandera",opciones:["Sin bandera","Con bandera"],etiquetaCant:"Cantidad de banderas (si aplica)"},
 {clave:"bolsos",titulo:"Bolsos",opciones:["Sin bolsos","Con bolsos"],etiquetaCant:"Cantidad de bolsos (si aplica)"},
];
type Adic={medias:string;polainas:string;antideslizantes:string;banda_capitan:string;banderin:string;bandera:string;bolsos:string};
type AdicCant=Record<keyof Adic,number>;
// ── JUGADORES: catalogos y automatismos del legado ────────────────────────
const MODELOS_ARQUERO:{grupo:string;modelos:string[]}[]=[
 {grupo:"ONC",modelos:["ONC25001","ONC25002","ONC25003","ONC25004","ONC25005","ONC25006","ONC25007"]},
 {grupo:"BM",modelos:Array.from({length:55},(_,i)=>"BM25"+String(i+1).padStart(3,"0"))},
 {grupo:"MAC",modelos:["MAC25001","MAC25002","MAC25003"]},
 {grupo:"TAC",modelos:["TAC25001","TAC25002","TAC25003"]},
 {grupo:"HLA",modelos:["HLA25001","HLA25002","HLA25003"]},
 {grupo:"QU",modelos:["QU25001","QU25002","QU25003","QU25004"]},
 {grupo:"Otro",modelos:["Modelo personalizado"]},
];
// Que prendas implica cada tipo de uniforme (claves en minusculas, igual que
// el legado). "Exterior" se reparte en Chompa (talla superior) + Pantalon.
const TIPO_A_PRENDAS:Record<string,string[]>={
 "uniforme completo":["Camiseta Jugador","Pantaloneta Jugador"],
 "uniforme completo (falda short)":["Camiseta Jugador","Falda Short"],
 "bvd + pantaloneta":["BVDS","Pantaloneta Jugador"],
 "bvd con falda short":["BVDS","Falda Short"],
 "polo + pantaloneta":["Camiseta Polo","Pantaloneta Jugador"],
 "camiseta + bermuda":["Camiseta Jugador","Bermudas"],
 "polo + bermuda":["Camiseta Polo","Bermudas"],
 "bvd + bermuda":["BVDS","Bermudas"],
 "solo bermuda":["Bermudas"],
 "camiseta + exterior":["Camiseta Jugador","Chompa","Pantalón"],
 "polo + exterior":["Camiseta Polo","Chompa","Pantalón"],
 "solo camiseta":["Camiseta Jugador"],"solo polo":["Camiseta Polo"],
 "solo pantaloneta":["Pantaloneta Jugador"],"solo falda short":["Falda Short"],
 "solo pantalón":["Pantalón"],"solo bvd":["BVDS"],
 "chompa":["Chompa"],"chompa de frío":["Chompa de Frío"],"chompa retro":["Chompas Retro"],
 "buzo de compresión":["Buzo de Compresión"],"chaleco":["Chaleco"],
 "exterior completo":["Chompa","Pantalón"],
 "arquero completo":["Camiseta Arquero","Pantaloneta Arquero"],
 "personalizado":["Camiseta Jugador"],
 "":["Camiseta Jugador","Pantaloneta Jugador"],
};
// Estas toman la talla INFERIOR del jugador; el resto, la superior.
const PRENDAS_TALLA_INFERIOR=new Set(["Pantaloneta Jugador","Pantaloneta Arquero","Falda Short","Pantalón","Bermudas","Licra"]);
const ORDEN_TIPO_UNIFORME=["Uniforme completo","Uniforme completo (Falda Short)","Arquero completo","Camiseta + Bermuda","Camiseta + Exterior","Solo camiseta","Polo + Bermuda","Polo + Pantaloneta","Polo + Exterior","Solo Polo","BVD + Bermuda","BVD + Pantaloneta","BVD con Falda Short","Solo BVD","Solo pantaloneta","Solo Falda Short","Solo bermuda","Solo pantalón","Chompa","Chompa de Frío","Chaleco","Exterior completo","Personalizado"];
const ORDEN_GENERO:Record<string,number>={"Hombre":0,"Mujer":1,"Niño":2,"Niña":2};
// Competicion primero: va en otra maquina.
const ORDEN_CALIDAD=["Competición","Profesional","Semiprofesional","Estándar","Amateur"];
const ORDEN_MANGA:Record<string,number>={"Corta":0,"":0,"Larga":1};
function ordenTalla(t:string){const i=ADULTOS.indexOf(t);if(i>=0)return i;const j=NINOS.indexOf(t);return j>=0?100+j:200}
function ordenarJugadores(js:Jugador[]):Jugador[]{
 const idx=(arr:string[],v:string)=>{const i=arr.indexOf(v);return i<0?arr.length:i};
 return [...js].sort((a,b)=>
  idx(ORDEN_TIPO_UNIFORME,a.tipo_uniforme)-idx(ORDEN_TIPO_UNIFORME,b.tipo_uniforme)
  ||idx(ORDEN_CALIDAD,a.calidad)-idx(ORDEN_CALIDAD,b.calidad)
  ||(ORDEN_GENERO[a.categoria]??9)-(ORDEN_GENERO[b.categoria]??9)
  ||(ORDEN_MANGA[a.manga]??0)-(ORDEN_MANGA[b.manga]??0)
  ||ordenTalla(a.talla_superior)-ordenTalla(b.talla_superior)
  ||a.nombre.localeCompare(b.nombre,"es"));
}
// Recalcula la matriz de tallas desde la nomina, con las mismas reglas del
// legado: modelo de arquero remapea a prendas de arquero, manga larga cuenta
// como prenda "M/L" aparte, y "Personalizado" suma segun que tallas se
// llenaron. Reemplaza lo que hubiera: es un recalculo, no una suma encima.
function tallasDesdeJugadores(jugadores:Jugador[]):Linea[]{
 const mapa=new Map<string,Linea>();
 for(const j of jugadores){
  const cal=texto(j.calidad);
  const tallaSup=texto(j.talla_superior),tallaInfRaw=texto(j.talla_inferior);
  const tallaInf=tallaInfRaw||tallaSup;
  const tipo=texto(j.tipo_uniforme).toLowerCase();
  const arq=texto(j.modelo_arquero),mangaLarga=texto(j.manga)==="Larga";
  let prendas=tipo==="personalizado"
   ?[...(tallaSup?["Camiseta Jugador"]:[]),...(tallaInfRaw?["Pantaloneta Jugador"]:[])]
   :(TIPO_A_PRENDAS[tipo]||TIPO_A_PRENDAS["uniforme completo"]);
  if(arq&&arq!=="N/A")prendas=prendas.map(p=>p==="Camiseta Jugador"?"Camiseta Arquero":p==="Pantaloneta Jugador"?"Pantaloneta Arquero":p);
  if(mangaLarga)prendas=prendas.map(p=>p==="Camiseta Jugador"?"Camiseta Jugador M/L":p==="Camiseta Arquero"?"Camiseta Arquero M/L":p==="Camiseta Polo"?"Camiseta Polo M/L":p);
  for(const prenda of prendas){
   const talla=PRENDAS_TALLA_INFERIOR.has(prenda)?tallaInf:tallaSup;
   if(!talla)continue;
   const clave=`${prenda}|${cal}`;
   let l=mapa.get(clave);
   if(!l){l=lineaNueva(prenda,cal);mapa.set(clave,l)}
   const esNino=NINOS.includes(talla)||j.categoria==="Niño"||j.categoria==="Niña";
   if(esNino){
    if(NINOS.includes(talla))l.ninos[talla]=(l.ninos[talla]||0)+1;
    else{const slot=l.espN.find(e=>e.nombre===talla)||l.espN.find(e=>!e.nombre);if(slot){slot.nombre=talla;slot.N+=1}}
   }else{
    const g:"H"|"M"=j.categoria==="Mujer"?"M":"H";
    if(ADULTOS.includes(talla)){const c=l.adultos[talla]||{H:0,M:0};c[g]+=1;l.adultos[talla]=c}
    else{const slot=l.espA.find(e=>e.nombre===talla)||l.espA.find(e=>!e.nombre);if(slot){slot.nombre=talla;slot[g]+=1}}
   }
  }
 }
 return Array.from(mapa.values());
}
// Alcance de prenda de cada tipo de uniforme, para las bandas de color del
// brief: el de corte busca "donde estan las camisetas sueltas" de un vistazo.
const TIPO_SOLO_SUPERIOR=new Set(["Solo camiseta","Solo Polo","Solo BVD","Chompa","Chompa de Frío","Chaleco"]);
const TIPO_SOLO_INFERIOR=new Set(["Solo pantaloneta","Solo Falda Short","Solo pantalón","Solo bermuda"]);
const grupoPrendaJugador=(tu:string)=>TIPO_SOLO_SUPERIOR.has(tu)?1:TIPO_SOLO_INFERIOR.has(tu)?2:0;
// Si en el tramo hay un solo tipo, se usa su nombre literal; si hay varios, el
// nombre del alcance. Mismo criterio que _etqGrupo del legado.
function etiquetaGrupo(arr:Jugador[],desde:number){
 const g=grupoPrendaJugador(arr[desde].tipo_uniforme),cal=arr[desde].calidad;const tipos=new Set<string>();
 for(let k=desde;k<arr.length;k++){if(grupoPrendaJugador(arr[k].tipo_uniforme)!==g||arr[k].calidad!==cal)break;if(texto(arr[k].tipo_uniforme))tipos.add(texto(arr[k].tipo_uniforme))}
 if(tipos.size===1)return Array.from(tipos)[0];
 return g===1?"Solo parte superior":g===2?"Solo parte inferior":"Uniforme completo";
}
function cuentaGrupo(arr:Jugador[],desde:number){
 const g=grupoPrendaJugador(arr[desde].tipo_uniforme),cal=arr[desde].calidad;let n=0;
 for(let k=desde;k<arr.length;k++){if(grupoPrendaJugador(arr[k].tipo_uniforme)!==g||arr[k].calidad!==cal)break;n++}
 return n;
}
// Importacion desde Excel: el legado tolera encabezados escritos de varias
// formas y normaliza tallas mal escritas antes de validar, avisando fila por
// fila. Sin esto, un Excel con "XXL" o "Talla Sup" entra vacio y en silencio.
const normTexto=(v:unknown)=>String(v??"").trim().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g,"");
function matchCI(val:string,lista:string[]){const nv=normTexto(val);if(!nv)return undefined;return lista.find(x=>normTexto(x)===nv)||lista.find(x=>normTexto(x).startsWith(nv))}
const CATEGORIAS_EXCEL:Record<string,string>={hombre:"Hombre",h:"Hombre",mujer:"Mujer",m:"Mujer",nino:"Niño",n:"Niño",nina:"Niña"};
const ALIAS_TALLA:Record<string,string>={XXL:"2XL",XXXL:"3XL",XXXXL:"4XL","2XLL":"2XL",EG:"XL",EEG:"2XL"};
// Se conservan los espacios internos para que "28 (4)" (tallas de niño) coincida.
function normTalla(t:unknown){const tr=String(t??"").trim().toUpperCase();return ALIAS_TALLA[tr.replace(/\s+/g,"")]||tr}
function colExcel(fila:Record<string,unknown>,...nombres:string[]){for(const k of Object.keys(fila))if(nombres.includes(normTexto(k)))return String(fila[k]??"").trim();return ""}
// ── FACTURACION ───────────────────────────────────────────────────────────
// El legado no deja guardar si el detalle de facturacion no CUADRA con las
// prendas del contrato: cada concepto equivale a n unidades de una categoria
// (un "Uniforme completo" = 1 Camiseta + 1 Pantaloneta), y se compara categoria
// por categoria y calidad por calidad. Los conceptos con c:null (bandera,
// medias, cinta...) se listan pero no se validan: no tienen talla contra la
// cual cuadrar.
const CAT_PRENDA_FACT:Record<string,string>={"Camiseta Jugador":"Camiseta","Camiseta Jugador M/L":"Camiseta","Camiseta Polo":"Polo","Camiseta Polo M/L":"Polo","Camiseta Arquero":"Camiseta Arquero","Camiseta Arquero M/L":"Camiseta Arquero","Pantaloneta Jugador":"Pantaloneta","Pantaloneta Arquero":"Pantaloneta Arquero","Falda Short":"Falda","Pantalón":"Pantalón","Pantalon":"Pantalón","Bermudas":"Bermuda","BVDS":"BVD","Chompa":"Chompa","Exterior Completo":"Chompa","Chompa de Frío":"Chompa de Frío","Chompa Frío 3/4":"Chompa Frío 3/4","Rompevientos":"Chompa de Lluvia","Chompas Retro":"Retro","Chompa Deportiva":"Chompa","Hoodie":"Hoodie","Chaleco":"Chaleco","Buzo de Compresión":"Buzo de Compresión","Bolsos":"Bolso"};
const catFact=(p:string)=>CAT_PRENDA_FACT[p]||String(p||"");
const CONCEPTOS_FACT:{l:string;c:Record<string,number>|null}[]=[
 {l:"Uniforme completo",c:{"Camiseta":1,"Pantaloneta":1}},{l:"Uniforme completo futbol",c:{"Camiseta":1,"Pantaloneta":1}},
 {l:"Uniforme completo basquet",c:{"Camiseta":1,"Pantaloneta":1}},{l:"Uniforme completo con bermuda",c:{"Camiseta":1,"Bermuda":1}},
 {l:"Uniforme completo con bermuda (polo)",c:{"Polo":1,"Bermuda":1}},{l:"Uniforme completo (Falda Short)",c:{"Camiseta":1,"Falda":1}},
 {l:"Uniforme completo (BVD)",c:{"BVD":1,"Pantaloneta":1}},{l:"Arquero completo",c:{"Camiseta Arquero":1,"Pantaloneta Arquero":1}},
 {l:"Camiseta Arquero",c:{"Camiseta Arquero":1}},{l:"Pantaloneta Arquero",c:{"Pantaloneta Arquero":1}},
 {l:"Camiseta",c:{"Camiseta":1}},{l:"Camiseta Polo",c:{"Polo":1}},{l:"Pantaloneta",c:{"Pantaloneta":1}},
 {l:"Falda Short",c:{"Falda":1}},{l:"Pantalón",c:{"Pantalón":1}},{l:"Bermuda",c:{"Bermuda":1}},{l:"BVD",c:{"BVD":1}},
 {l:"Chompa (exterior)",c:{"Chompa":1}},{l:"Buzo",c:{"Chompa":1}},{l:"Chompa de Frío",c:{"Chompa de Frío":1}},
 {l:"Chompa Frío 3/4",c:{"Chompa Frío 3/4":1}},{l:"Chompa de lluvia",c:{"Chompa de Lluvia":1}},{l:"Buzo Retro",c:{"Retro":1}},
 {l:"Hoodie",c:{"Hoodie":1}},{l:"Buzo de Compresión",c:{"Buzo de Compresión":1}},{l:"Chaleco",c:{"Chaleco":1}},
 {l:"Exterior completo",c:{"Chompa":1,"Pantalón":1}},{l:"Solo pantalón",c:{"Pantalón":1}},{l:"Solo chompa",c:{"Chompa":1}},
 {l:"Bolso",c:{"Bolso":1}},{l:"Bandera",c:null},{l:"Banderín",c:null},{l:"Cinta Capitán",c:null},
 {l:"Medias",c:null},{l:"Polainas",c:null},{l:"Antideslizantes",c:null},
];
const SEP_FACT="␟";
function comprobarFacturacion(prendas:Prenda[],facturacion:Fact[]){
 const real:Record<string,number>={};
 for(const l of prendas){if(l.cantidad<=0)continue;const k=`${catFact(l.prenda)}${SEP_FACT}${l.calidad}`;real[k]=(real[k]||0)+l.cantidad}
 const fact:Record<string,number>={};
 for(const f of facturacion){
  const def=CONCEPTOS_FACT.find(x=>x.l===f.concepto);
  if(!def||!def.c||f.cantidad<=0)continue;
  for(const cat of Object.keys(def.c)){const k=`${cat}${SEP_FACT}${f.calidad}`;fact[k]=(fact[k]||0)+def.c[cat]*f.cantidad}
 }
 const faltan:string[]=[],sobran:string[]=[];
 for(const k of new Set([...Object.keys(real),...Object.keys(fact)])){
  const d=(real[k]||0)-(fact[k]||0);if(!d)continue;
  const [cat,cal]=k.split(SEP_FACT);const etq=`${cat} (${cal||"sin calidad"})`;
  if(d>0)faltan.push(`${d} ${etq}`);else sobran.push(`${-d} ${etq}`);
 }
 return {ok:!faltan.length&&!sobran.length,faltan,sobran,hayPrendas:Object.keys(real).length>0};
}
// ── TALLAS ────────────────────────────────────────────────────────────────
// El legado captura las tallas como una MATRIZ por prenda+calidad (filas de
// talla x columnas H/M para adultos, N para niños) con 3 tallas especiales de
// adulto y 2 de niño que el usuario nombra a mano. "prendas" (una fila por
// combinacion con cantidad > 0) es solo el formato de guardado: se deriva de
// aqui, nunca se edita a mano.
const ESP_ADULTO=3, ESP_NINO=2;
type Linea={id:string;prenda:string;calidad:string;detalle:string;adultos:Record<string,{H:number;M:number}>;ninos:Record<string,number>;espA:{nombre:string;H:number;M:number}[];espN:{nombre:string;N:number}[]};
const lineaNueva=(prenda:string,calidad=""):Linea=>({id:uuid(),prenda,calidad,detalle:"",adultos:{},ninos:{},espA:Array.from({length:ESP_ADULTO},()=>({nombre:"",H:0,M:0})),espN:Array.from({length:ESP_NINO},()=>({nombre:"",N:0}))});
function totalLinea(l:Linea){
 let h=0,m=0,n=0;
 for(const t of ADULTOS){h+=l.adultos[t]?.H||0;m+=l.adultos[t]?.M||0}
 for(const e of l.espA){if(e.nombre.trim()){h+=e.H||0;m+=e.M||0}}
 for(const t of NINOS)n+=l.ninos[t]||0;
 for(const e of l.espN)if(e.nombre.trim())n+=e.N||0;
 return {h,m,n,total:h+m+n};
}
function expandirLineas(lineas:Linea[]):Prenda[]{
 const out:Prenda[]=[];
 for(const l of lineas){
  if(!l.prenda)continue;
  const add=(genero:Prenda["genero"],talla:string,cantidad:number)=>{if(cantidad>0)out.push({id:`${l.id}|${genero}|${talla}`,prenda:l.prenda,calidad:l.calidad,detalle:l.detalle,genero,talla,cantidad})};
  for(const t of ADULTOS){add("H",t,l.adultos[t]?.H||0);add("M",t,l.adultos[t]?.M||0)}
  for(const e of l.espA){const nom=e.nombre.trim();if(nom){add("H",nom,e.H||0);add("M",nom,e.M||0)}}
  for(const t of NINOS)add("N",t,l.ninos[t]||0);
  for(const e of l.espN){const nom=e.nombre.trim();if(nom)add("N",nom,e.N||0)}
 }
 return out;
}
// Reposicion: reconstruye la matriz desde las filas planas del contrato origen.
function lineasDesdePrendas(filas:{prenda?:unknown;calidad?:unknown;detalle?:unknown;genero?:unknown;talla?:unknown;cantidad?:unknown}[]):Linea[]{
 const mapa=new Map<string,Linea>();
 for(const f of filas){
  const prenda=texto(f.prenda);if(!prenda)continue;
  const calidad=texto(f.calidad),detalle=texto(f.detalle),talla=texto(f.talla);
  const genero=texto(f.genero)as Prenda["genero"],cant=Number(f.cantidad)||0;
  const clave=`${prenda}|${calidad}|${detalle}`;
  let l=mapa.get(clave);
  if(!l){l=lineaNueva(prenda,calidad);l.detalle=detalle;mapa.set(clave,l)}
  if(genero==="N"){
   if(NINOS.includes(talla))l.ninos[talla]=(l.ninos[talla]||0)+cant;
   else{const slot=l.espN.find(e=>e.nombre===talla)||l.espN.find(e=>!e.nombre);if(slot){slot.nombre=talla;slot.N+=cant}}
  }else{
   const g=genero==="M"?"M":"H";
   if(ADULTOS.includes(talla)){const c=l.adultos[talla]||{H:0,M:0};c[g]+=cant;l.adultos[talla]=c}
   else{const slot=l.espA.find(e=>e.nombre===talla)||l.espA.find(e=>!e.nombre);if(slot){slot.nombre=talla;slot[g]+=cant}}
  }
 }
 return Array.from(mapa.values());
}
type Form={cab:Cab;prendasSel:string[];lineas:Linea[];adic:Adic;adicCant:AdicCant;medidasBandera:string;prendas:Prenda[];jugadores:Jugador[];archivos:Archivo[];specs:Spec[];facturacion:Fact[]};
const adicInicial=():Adic=>ADICIONALES.reduce((a,x)=>({...a,[x.clave]:x.opciones[0]}),{} as Adic);
const adicCantInicial=():AdicCant=>ADICIONALES.reduce((a,x)=>({...a,[x.clave]:0}),{} as AdicCant);

const cabInicial=(nombre:string):Cab=>({vendedor:nombre,canal:"",nombre_contrato_v115:"",cliente:"",almacen_venta_id_v115:"",telefono:"",whatsapp:"",email:"",tipo_contrato:"Normal",fecha_entrega:"",fecha_inicio_produccion:"",prioridad:"Normal",arqueros:0,total_manual:0,reposicion:false,contrato_origen_reposicion_id:"",nombre_tecnica:"",numero_tecnica:"",sellos_tpu:"No",ubicacion_tpu:"",bordado:"",colores:"",instrucciones:"",presupuesto:0,abono:0,forma_entrega:"Retiro en tienda",direccion:"",vendedor_responsable:nombre,autorizado:false,adicionales:""});
const inicial=(nombre:string):Form=>({cab:cabInicial(nombre),prendasSel:[],lineas:[],adic:adicInicial(),adicCant:adicCantInicial(),medidasBandera:"",prendas:[],jugadores:[],archivos:[],specs:[],facturacion:[]});
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
 const [almacenesVenta,setAlmacenesVenta]=useState<AlmacenVenta[]>([]);
 const total=useMemo(()=>form.prendas.reduce((s,x)=>s+Math.max(0,Number(x.cantidad)||0),0),[form.prendas]);
 const saldo=Math.max(0,Number(form.cab.presupuesto||0)-Number(form.cab.abono||0));
 const setCab=<K extends keyof Cab>(k:K,v:Cab[K])=>setForm(f=>({...f,cab:{...f.cab,[k]:v}}));
 const cambiar=<T extends {id:string}>(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string,cambio:Partial<T>)=>setForm(f=>({...f,[lista]:(f[lista] as unknown as T[]).map(x=>x.id===id?{...x,...cambio}:x)} as Form));
 const quitar=(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string)=>setForm(f=>({...f,[lista]:(f[lista] as {id:string}[]).filter(x=>x.id!==id)} as Form));

 useEffect(()=>{const raw=localStorage.getItem(BORRADOR);if(!raw)return;try{const d=JSON.parse(raw) as Form;if(d?.cab&&Array.isArray(d.prendas))void confirmarDialogo("Hay un borrador guardado en este dispositivo. ¿Deseas recuperarlo?").then(si=>si?setForm({...d,cab:{...cabInicial(perfil.nombre_completo),...d.cab},archivos:(d.archivos||[]).filter(x=>x.url)}):localStorage.removeItem(BORRADOR))}catch{localStorage.removeItem(BORRADOR)}},[perfil.nombre_completo]);
 useEffect(()=>{void supabase.rpc("catalogo_ingreso_contrato_v115").then(({data,error})=>{if(error)void mostrarAvisoDialogo(error.message,"No se pudieron cargar los locales",true);else setAlmacenesVenta(((data as{almacenes?:AlmacenVenta[]})?.almacenes)||[])})},[supabase]);
 useEffect(()=>{const t=setTimeout(()=>{const seguro={...form,archivos:form.archivos.filter(x=>x.url).map(({file,preview,...x})=>x)};localStorage.setItem(BORRADOR,JSON.stringify(seguro))},900);return()=>clearTimeout(t)},[form]);

 // "prendas" es el formato de guardado (una fila por combinacion con cantidad
 // > 0) y se deriva SIEMPRE de la matriz: asi la tabla de tallas es la unica
 // fuente y no hay dos sitios donde editar lo mismo.
 useEffect(()=>{
  setForm(f=>{
   const derivadas=expandirLineas(f.lineas);
   const igual=derivadas.length===f.prendas.length&&derivadas.every((d,i)=>{const a=f.prendas[i];return a&&a.prenda===d.prenda&&a.calidad===d.calidad&&a.detalle===d.detalle&&a.genero===d.genero&&a.talla===d.talla&&a.cantidad===d.cantidad});
   return igual?f:{...f,prendas:derivadas};
  });
 },[form.lineas]);

 function errorPaso(n=paso){const c=form.cab;if(n===0&&(!texto(c.vendedor)||!texto(c.nombre_contrato_v115)||!texto(c.cliente)||!texto(c.canal)||!texto(c.telefono)))return"Completa vendedor, canal, nombre del contrato, cliente real y teléfono.";if(n===0&&almacenesVenta.length>1&&!c.almacen_venta_id_v115)return"Selecciona la tienda o local donde se realizó la venta.";if(n===1&&(!c.fecha_entrega||!c.tipo_contrato||!c.prioridad))return"Completa tipo, prioridad y fecha de entrega.";if(n===2&&!form.prendasSel.length)return"Selecciona al menos una prenda del pedido.";if(n===5&&(!form.prendas.length||total<1))return"Agrega al menos una línea de talla con cantidad.";if(n===4&&(!c.nombre_tecnica||!c.numero_tecnica||!c.sellos_tpu))return"Completa las técnicas de nombre, número y TPU.";if(n===6&&(!texto(c.vendedor_responsable)||!c.autorizado))return"Confirma el vendedor responsable y la autorización de producción.";if(n===6&&Number(c.abono)>Number(c.presupuesto))return"El abono no puede superar el presupuesto.";if(n===6){const r=comprobarFacturacion(form.prendas,form.facturacion);if(r.hayPrendas&&!r.ok)return`La facturación no cuadra con las prendas. ${r.faltan.length?"Faltan: "+r.faltan.join(", ")+". ":""}${r.sobran.length?"Sobran: "+r.sobran.join(", ")+".":""}`;}return""}
 async function irSiguiente(){const e=errorPaso();if(e)return mostrarAvisoDialogo(e,"Revisa este paso",true);setPaso(x=>Math.min(6,x+1))}
 async function abrirPaso(i:number){if(i>paso){const e=errorPaso();if(e)return mostrarAvisoDialogo(e,"Revisa este paso",true)}setPaso(i)}

 async function buscarAnterior(){if(texto(busqueda).length<2)return mostrarAvisoDialogo("Escribe al menos 2 caracteres.","Buscar reposición");setBuscando(true);const{data,error}=await supabase.rpc("buscar_contratos_reposicion_v108",{p_busqueda:busqueda});setBuscando(false);if(error)return mostrarAvisoDialogo(error.message,"No se pudo buscar",true);setCoincidencias((data as any[])||[])}
 async function cargarReposicion(id:string){const{data,error}=await supabase.rpc("obtener_plantilla_contrato_v108",{p_contrato_id:id});if(error)return mostrarAvisoDialogo(error.message,"No se pudo cargar",true);const d:any=data,c=d.contrato||{};setForm(f=>({...f,cab:{...f.cab,tipo_contrato:c.tipo_contrato||"Normal",prioridad:c.prioridad||"Normal",reposicion:true,contrato_origen_reposicion_id:id,nombre_tecnica:c.nombre_tecnica||"",numero_tecnica:c.numero_tecnica||"",sellos_tpu:c.sellos_tpu||"No",ubicacion_tpu:c.ubicacion_tpu||"",bordado:c.bordado||"",colores:Array.isArray(c.colores_generales)?c.colores_generales.map((x:any)=>x.nombre||x).join(", "):"",adicionales:c.adicionales?.detalle||""},prendasSel:Array.from(new Set(((d.prendas||[]) as {prenda?:unknown}[]).map(x=>texto(x.prenda)).filter(Boolean))),lineas:lineasDesdePrendas((d.prendas||[]) as never[]),prendas:[],jugadores:(d.jugadores||[]).map((x:any)=>({...x,id:uuid()})),archivos:(d.archivos||[]).map((x:any)=>({...x,id:uuid()})),specs:(d.especificaciones||[]).map((x:any)=>({id:uuid(),prenda_clave:x.prenda_clave,variante_calidad:x.variante_calidad||"",mockup:texto(x.variante_mockup),...leerSpec(x.spec)})),facturacion:(d.facturacion||[]).map((x:any)=>({...x,id:uuid()}))}));setBusqueda("");setCoincidencias([]);await mostrarAvisoDialogo("Se copiaron prendas, jugadores, diseños y especificaciones. Cliente, fechas y valores siguen siendo los del nuevo contrato.","Reposición preparada")}

 function agregarPrenda(){setForm(f=>({...f,prendas:[...f.prendas,{id:uuid(),prenda:"Camiseta Jugador",calidad:"Amateur",detalle:"",genero:"H",talla:"M",cantidad:1}]}))}
 function agregarJugador(){setForm(f=>({...f,jugadores:[...f.jugadores,{id:uuid(),nombre:"",numero:"",categoria:"Hombre",talla_superior:"M",talla_inferior:"M",manga:"Corta",calidad:"Amateur",modelo_arquero:"",tipo_uniforme:"Uniforme completo",detalle:"",mockup:""}]}))}
 // Una prenda puede llevar VARIAS especificaciones (variantes por mockup o
 // calidad), igual que en el legado: por eso se agrega por ficha.
 function agregarFicha(clave:string){setForm(f=>({...f,specs:[...f.specs,{id:uuid(),prenda_clave:clave,variante_calidad:"",mockup:"",campos:{},observacion:""}]}))}
 function agregarFact(){setForm(f=>({...f,facturacion:[...f.facturacion,{id:uuid(),concepto:"Uniforme completo",calidad:f.prendas[0]?.calidad||"Amateur",cantidad:1,obsequio:false}]}))}
 function seleccionar(tipo:"mockup"|"logo",files:FileList|null){if(!files)return;const limite=tipo==="mockup"?10:20;const nuevos=Array.from(files).slice(0,limite).map(file=>({id:uuid(),tipo,file,preview:file.type.startsWith("image/")?URL.createObjectURL(file):undefined,descripcion:file.name.replace(/\.[^.]+$/,""),color:"",prenda:"",posicion:"",tecnica:"",calidad_aplicable:"Todas",observacion:""}));setForm(f=>({...f,archivos:[...f.archivos,...nuevos]}))}

 async function importarJugadores(file:File){
  try{
   const XLSX=await import("xlsx");
   const wb=XLSX.read(await file.arrayBuffer(),{type:"array"});
   const filas=XLSX.utils.sheet_to_json<Record<string,unknown>>(wb.Sheets[wb.SheetNames[0]],{defval:""});
   if(!filas.length)throw new Error("El archivo no tiene filas de datos.");
   const avisos:string[]=[];const jugadores:Jugador[]=[];
   const mockupsActuales=mockupsDe(form).map(m=>m.descripcion);
   filas.forEach((fila,i)=>{
    const nFila=i+2; // +1 encabezado, +1 indice base 0
    const nombre=colExcel(fila,"nombre");
    const numero=colExcel(fila,"número","numero","#");
    const supRaw=colExcel(fila,"talla superior","t.sup","talla sup","talla camiseta","t.cam","talla cam","talla");
    const infRaw=colExcel(fila,"talla inferior","t.inf","talla inf","talla pantaloneta","talla pant","t.pant","talla pant.");
    // Solo se ignora la fila si esta TOTALMENTE vacia: una camiseta sin nombre
    // ni numero pero con talla es valida (camiseta generica de esa talla).
    if(!nombre&&!numero&&!supRaw&&!infRaw)return;
    const quien=nombre||(numero?`#${numero}`:"sin nombre");
    const j:Jugador={id:uuid(),nombre,numero,categoria:"Hombre",talla_superior:"",talla_inferior:"",manga:"Corta",calidad:"",modelo_arquero:"N/A",tipo_uniforme:"",detalle:colExcel(fila,"detalle/variante","detalle variante","detalle","variante"),mockup:""};

    const catRaw=colExcel(fila,"categoría","categoria","categ.","categ");
    const cat=CATEGORIAS_EXCEL[normTexto(catRaw)];
    if(cat)j.categoria=cat; else if(catRaw)avisos.push(`Fila ${nFila}: categoría "${catRaw}" no reconocida, se dejó "Hombre"`);

    const tallasValidas=[...ADULTOS,...NINOS];
    const sup=normTalla(supRaw),inf=normTalla(infRaw||supRaw);
    if(supRaw){
     if(tallasValidas.includes(sup))j.talla_superior=sup;
     else avisos.push(`⛔ Fila ${nFila} — ${quien}: la TALLA SUPERIOR "${supRaw}" está mal escrita → se subió SIN talla. Corrígela en el Excel (usa XS, S, M, L, XL, 2XL, 3XL, 4XL) y vuelve a subir.`);
    }
    if(inf&&tallasValidas.includes(inf))j.talla_inferior=inf;
    else if(infRaw)avisos.push(`⛔ Fila ${nFila} — ${quien}: la TALLA INFERIOR "${infRaw}" está mal escrita → se subió SIN talla.`);

    const cal=colExcel(fila,"calidad");const calM=matchCI(cal,CALIDADES);
    if(calM)j.calidad=calM; else if(cal)avisos.push(`Fila ${nFila}: calidad "${cal}" no reconocida`);
    const arq=colExcel(fila,"mod. arquero","mod arquero","modelo arquero","arquero");
    const arqM=matchCI(arq,MODELOS_ARQUERO.flatMap(g=>g.modelos));
    if(arqM)j.modelo_arquero=arqM; else if(arq)avisos.push(`Fila ${nFila}: modelo arquero "${arq}" no reconocido`);
    const tu=colExcel(fila,"tipo uniforme","tipo de uniforme");const tuM=matchCI(tu,TIPOS_UNIFORME);
    if(tuM)j.tipo_uniforme=tuM; else if(tu)avisos.push(`Fila ${nFila}: tipo de uniforme "${tu}" no reconocido`);
    const manga=colExcel(fila,"manga");const mangaM=matchCI(manga,["Corta","Larga"]);
    if(mangaM)j.manga=mangaM; else if(manga)avisos.push(`Fila ${nFila}: manga "${manga}" no reconocida (usa Corta o Larga)`);
    const mk=colExcel(fila,"mockup","mock");
    if(mk){j.mockup=mk;if(!mockupsActuales.includes(mk))mockupsActuales.push(mk)}
    jugadores.push(j);
   });
   if(!jugadores.length)throw new Error("Ninguna fila tenía datos utilizables.");
   // El legado ordena solo al terminar de cargar.
   setForm(f=>({...f,jugadores:ordenarJugadores(jugadores)}));
   await mostrarAvisoDialogo(
    `Se cargaron ${jugadores.length} jugador(es).`+(avisos.length?`\n\nRevisa ${avisos.length} aviso(s):\n• ${avisos.join("\n• ")}`:""),
    avisos.length?"Excel procesado con avisos":"Excel procesado", avisos.length>0);
  }catch(e){await mostrarAvisoDialogo(e instanceof Error?e.message:"No se pudo leer el archivo","Excel inválido",true)}
 }
 async function plantillaJugadores(){
  // Los encabezados son EXACTAMENTE los que reconoce colExcel al importar: si
  // aqui dijeran "Talla_superior" y alla se busca "talla superior", la plantilla
  // propia se subiria vacia.
  const XLSX=await import("xlsx");
  const ws=XLSX.utils.json_to_sheet([{"Nombre":"","Número":"","Categoría":"Hombre","Talla superior":"M","Talla inferior":"M","Manga":"Corta","Calidad":"Semiprofesional","Mod. arquero":"","Tipo uniforme":"Uniforme completo","Detalle/variante":"","Mockup":"Mockup 1"}]);
  ws["!cols"]=[24,10,14,16,16,12,18,18,24,28,16].map(wch=>({wch}));
  const wb=XLSX.utils.book_new();XLSX.utils.book_append_sheet(wb,ws,"Jugadores");XLSX.writeFile(wb,"plantilla_jugadores_boman.xlsx");
 }

 async function guardar(){const falla=[0,1,2,4,6].map(errorPaso).find(Boolean);if(falla)return mostrarAvisoDialogo(falla,"Contrato incompleto",true);if(!await confirmarDialogo(`Se registrará un contrato nuevo con ${total} prendas y saldo de $${saldo.toFixed(2)}. ¿Continuar?`))return;setGuardando(true);try{const archivos:any[]=[];for(let orden=0;orden<form.archivos.length;orden++){const a=form.archivos[orden];if(!a.file){archivos.push({...a,orden});continue}const key=uuid();const prep=await supabase.rpc("preparar_archivo_contrato_v108",{p_nombre_archivo:a.file.name,p_mime_type:a.file.type,p_tamano_bytes:a.file.size,p_idempotency_key:key});if(prep.error)throw prep.error;const path=(prep.data as any).path;const subida=await supabase.storage.from("contratos-archivos").upload(path,a.file,{contentType:a.file.type,upsert:false});if(subida.error)throw subida.error;archivos.push({...a,file:undefined,preview:undefined,pendiente_id:(prep.data as any).id,url:supabase.storage.from("contratos-archivos").getPublicUrl(path).data.publicUrl,orden})}
  const mapa=new Map<string,Prenda>();for(const x of form.prendas){const k=[x.prenda,x.calidad,x.detalle,x.genero,x.talla].join("¦");const anterior=mapa.get(k);mapa.set(k,{...x,cantidad:(anterior?.cantidad||0)+Number(x.cantidad)})}
  const payload={contrato:{...form.cab,prendas_txt:form.prendasSel.map(etiquetaPrenda).join(", "),colores_generales:form.cab.colores.split(",").map(x=>x.trim()).filter(Boolean).map(nombre=>({nombre})),adicionales:{detalle:form.cab.adicionales,items:ADICIONALES.filter(a=>form.adicCant[a.clave]>0||form.adic[a.clave]!==a.opciones[0]).map(a=>({tipo:a.titulo,valor:form.adic[a.clave],cantidad:form.adicCant[a.clave]})),medidas_bandera:form.medidasBandera}},prendas:Array.from(mapa.values()).map(({id,...x})=>x),jugadores:form.jugadores.map(({id,...x},orden)=>({...x,orden})),archivos:archivos.map(({id,...x})=>x),especificaciones:form.specs.map(({id,mockup,campos,observacion,...x},orden)=>({...x,orden,variante_mockup:mockup,spec:{campos,observacion}})),facturacion:form.facturacion.map(({id,...x},orden)=>({...x,orden}))};
  const alta=await supabase.rpc("crear_contrato_v115",{p_datos:payload,p_idempotency_key:uuid()});if(alta.error)throw alta.error;const r:any=alta.data;localStorage.removeItem(BORRADOR);setResultado({numero:r.numero,id:r.contrato_id,respaldo:"en_curso"});setPreview(false);void respaldar(r.contrato_id)}catch(e){await mostrarAvisoDialogo(e instanceof Error?e.message:"No se pudo registrar el contrato","Error al registrar",true)}finally{setGuardando(false)}}

 async function respaldar(id:string){try{const res=await fetch("/api/bomansport/respaldo-contrato",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({contrato_id:id})});const data=await res.json();setResultado(x=>x&&x.id===id?{...x,respaldo:data.ok?"ok":"pendiente"}:x)}catch{setResultado(x=>x&&x.id===id?{...x,respaldo:"pendiente"}:x)}}

 if(resultado)return <section className={`card ${estilos.exito}`}><div>✓</div><h1>Contrato registrado</h1><strong>{resultado.numero}</strong><p>Ya está disponible en Producción → Contratos y en el tablero.</p><p className={resultado.respaldo==="pendiente"?estilos.respaldoPendiente:estilos.respaldoOk}>{resultado.respaldo==="en_curso"?"Respaldando en Google Sheets…":resultado.respaldo==="ok"?"✓ Copia de respaldo guardada en Google Sheets":"El respaldo en Sheets quedó pendiente; el contrato está seguro en Supabase."}</p><div>{resultado.respaldo==="pendiente"&&<button className="secondary" onClick={()=>void respaldar(resultado.id)}>Reintentar respaldo</button>}<button onClick={()=>{setResultado(null);setForm(inicial(perfil.nombre_completo));setPaso(0)}}>Ingresar otro</button><a className="button secondary" href="/produccion/contratos">Abrir expedientes</a></div></section>;
 return <>
  <header className={estilos.cabecera}><div><span className="eyebrow">VENTAS · v115</span><h1>Ingreso de contratos</h1><p>Pedido, brief técnico, tallas, diseños y valores conectados directamente con producción.</p></div><button className="secondary" onClick={()=>setPreview(true)}>Vista previa</button></header>
  <nav className={estilos.pasos}>{PASOS.map((x,i)=><button key={x} className={i===paso?estilos.activo:i<paso?estilos.completo:""} onClick={()=>void abrirPaso(i)}><b>{i<paso?"✓":i+1}</b><span>{x}</span></button>)}</nav>
  <section className={`card ${estilos.formulario}`}>
   {paso===0&&<PasoCliente supabase={supabase} form={form} setCab={setCab} almacenes={almacenesVenta} busqueda={busqueda} setBusqueda={setBusqueda} buscar={buscarAnterior} buscando={buscando} coincidencias={coincidencias} cargar={cargarReposicion}/>} 
   {paso===1&&<PasoContrato form={form} setCab={setCab}/>}
   {paso===2&&<PasoPrendas form={form} setForm={setForm} setCab={setCab} total={total} supabase={supabase}/>}
   {paso===3&&<PasoArchivos form={form} seleccionar={seleccionar} cambiar={cambiar} quitar={quitar}/>} 
   {paso===4&&<PasoTecnica form={form} setCab={setCab} agregarFicha={agregarFicha} cambiar={cambiar} quitar={quitar}/>} 
   {paso===5&&<PasoJugadores form={form} importar={importarJugadores} plantilla={plantillaJugadores} agregar={agregarJugador} setForm={setForm} cambiar={cambiar} quitar={quitar}/>} 
   {paso===6&&<PasoCierre form={form} setCab={setCab} saldo={saldo} agregar={agregarFact} cambiar={cambiar} quitar={quitar}/>} 
   <footer className={estilos.acciones}><button className="secondary" disabled={paso===0||guardando} onClick={()=>setPaso(x=>x-1)}>Anterior</button><span>Paso {paso+1} de 7 · borrador automático</span>{paso<6?<button onClick={()=>void irSiguiente()}>Continuar</button>:<><button className="secondary" onClick={()=>setPreview(true)}>Revisar</button><button onClick={()=>void guardar()} disabled={guardando}>{guardando?"Subiendo y registrando…":"Registrar contrato"}</button></>}</footer>
  </section>
  {preview&&<VistaPrevia form={form} total={total} cerrar={()=>setPreview(false)}/>} 
 </>;
}

type SetCab=<K extends keyof Cab>(k:K,v:Cab[K])=>void;
type Cambiar=<T extends {id:string}>(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string,cambio:Partial<T>)=>void;
type Quitar=(lista:keyof Pick<Form,"prendas"|"jugadores"|"archivos"|"specs"|"facturacion">,id:string)=>void;

// Buscador del cliente real. NO crea nada: al guardar, el trigger
// asignar_cliente_contrato_v113 busca por nombre normalizado y, si no existe,
// crea la ficha solo. Por eso aqui basta con OFRECER los que ya estan: un
// nombre nuevo se escribe y ya, y elegir uno de la lista evita que "Club Los
// Andes" y "club los andes " terminen siendo dos fichas con cartera separada.
function ClienteReal({supabase,valor,setCab}:{supabase:ReturnType<typeof createClient>;valor:string;setCab:SetCab}){
 const [opciones,setOpciones]=useState<{id:string;nombre:string;contratos:number;saldo:number}[]>([]);
 const [abierto,setAbierto]=useState(false);
 useEffect(()=>{
  const q=valor.trim();
  if(q.length<2){setOpciones([]);return}
  let vivo=true;
  const t=setTimeout(()=>{
   supabase.rpc("listar_clientes_v113",{p_busqueda:q,p_pagina:1,p_por_pagina:6}).then(({data,error})=>{
    // Sin permiso clientes.acceder la RPC falla: el campo sigue siendo texto
    // libre y el contrato se guarda igual, solo se pierde la sugerencia.
    if(!vivo)return;
    setOpciones(error?[]:(((data as{filas?:{id:string;nombre:string;contratos:number;saldo:number}[]})?.filas)||[]));
   });
  },300);
  return()=>{vivo=false;clearTimeout(t)};
 },[valor,supabase]);
 const exacto=opciones.some(o=>o.nombre.trim().toLowerCase()===valor.trim().toLowerCase());
 const sugerencias=abierto&&opciones.length>0&&!exacto?opciones:[];
 return <Campo titulo="Nombre del cliente real *"><>
  <input value={valor} onChange={e=>{setCab("cliente",e.target.value);setAbierto(true)}} onFocus={()=>setAbierto(true)} onBlur={()=>setTimeout(()=>setAbierto(false),150)} placeholder="Persona o empresa que compra" autoComplete="off"/>
  {sugerencias.length>0&&<div className={estilos.clientesSug}>
   {sugerencias.map(o=><button type="button" key={o.id} onMouseDown={e=>e.preventDefault()} onClick={()=>{setCab("cliente",o.nombre);setAbierto(false)}}>
    <strong>{o.nombre}</strong><span>{o.contratos} contrato{o.contratos===1?"":"s"}{o.saldo>0?` · saldo $${o.saldo.toFixed(2)}`:""}</span>
   </button>)}
  </div>}
  {exacto?<small className={estilos.pista}>Se usara la ficha que ya existe con ese nombre.</small>
        :<small className={estilos.pista}>Busca al cliente para no duplicar su ficha. Si es nuevo, escribe el nombre y se creara solo.</small>}
 </></Campo>;
}
function PasoCliente({supabase,form,setCab,almacenes,busqueda,setBusqueda,buscar,buscando,coincidencias,cargar}:{supabase:ReturnType<typeof createClient>;form:Form;setCab:SetCab;almacenes:AlmacenVenta[];busqueda:string;setBusqueda:(x:string)=>void;buscar:()=>void;buscando:boolean;coincidencias:any[];cargar:(id:string)=>void}){return <><h2>Vendedor, contrato y cliente</h2><div className={estilos.reposicion}><div><strong>¿Es una reposición?</strong><span>Copia el brief anterior y crea un contrato nuevo.</span></div><div><input value={busqueda} onChange={e=>setBusqueda(e.target.value)} onKeyDown={e=>e.key==="Enter"&&buscar()} placeholder="Cliente, contrato o BOM-2026-…"/><button className="secondary" onClick={buscar}>{buscando?"Buscando…":"Buscar"}</button></div>{coincidencias.map(x=><button className={estilos.resultado} key={x.id} onClick={()=>cargar(x.id)}><strong>{x.numero}</strong><span>{x.cliente} · {x.total_prendas} prendas</span></button>)}</div><div className={estilos.grid}><Campo titulo="Vendedor *"><><input list="lista-vendedores" value={form.cab.vendedor} onChange={e=>setCab("vendedor",e.target.value)} placeholder="Seleccionar o escribir vendedor…"/><datalist id="lista-vendedores">{VENDEDORES.map(v=><option key={v} value={v}/>)}</datalist><small className={estilos.pista}>Selecciona de la lista o escribe otro nombre.</small></></Campo><Campo titulo="Canal de venta *"><select value={form.cab.canal} onChange={e=>setCab("canal",e.target.value)}><option value="">Seleccionar…</option>{CANALES.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="Nombre del contrato *"><><input value={form.cab.nombre_contrato_v115} onChange={e=>setCab("nombre_contrato_v115",e.target.value)} placeholder="Ej. Uniformes Club Los Andes"/><small className={estilos.pista}>Así se identificará el pedido y aparecerá en el brief.</small></></Campo><ClienteReal supabase={supabase} valor={form.cab.cliente} setCab={setCab}/>{almacenes.length>0&&<Campo titulo={`Tienda / local${almacenes.length>1?" *":""}`}><select value={form.cab.almacen_venta_id_v115} onChange={e=>setCab("almacen_venta_id_v115",e.target.value)}><option value="">{almacenes.length===1?`Automática: ${almacenes[0].nombre}`:"Seleccionar…"}</option>{almacenes.map(a=><option key={a.id} value={a.id}>{a.nombre}</option>)}</select></Campo>}<Campo titulo="Teléfono *"><input value={form.cab.telefono} onChange={e=>setCab("telefono",e.target.value)} placeholder="0999123456"/></Campo><Campo titulo="WhatsApp"><input value={form.cab.whatsapp} onChange={e=>setCab("whatsapp",e.target.value)}/></Campo><Campo titulo="Correo"><input type="email" value={form.cab.email} onChange={e=>setCab("email",e.target.value)}/></Campo></div></>}
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
  <div className={estilos.adicionales}>{ADICIONALES.map(a=><div key={a.clave} className={estilos.filaAdic}><Campo titulo={a.titulo}><select value={form.adic[a.clave]} onChange={e=>setAdic(a.clave,e.target.value)}>{(a.opciones.includes(form.adic[a.clave])?a.opciones:[...a.opciones,form.adic[a.clave]]).map(o=><option key={o}>{o}</option>)}</select></Campo><Campo titulo={a.etiquetaCant}><input type="number" min={0} value={form.adicCant[a.clave]} onChange={e=>setAdicCant(a.clave,Number(e.target.value))}/></Campo></div>)}</div>
  {form.adic.bandera!=="Sin bandera"&&<div className={estilos.grid}><Campo titulo="Medidas de la bandera" ancho><input value={form.medidasBandera} onChange={e=>setForm(f=>({...f,medidasBandera:e.target.value}))} placeholder="Ej. 1,50X90"/></Campo></div>}
 </>;
}
function PasoArchivos({form,seleccionar,cambiar,quitar}:{form:Form;seleccionar:(t:"mockup"|"logo",f:FileList|null)=>void;cambiar:Cambiar;quitar:Quitar}){
 const prendasLogo=prendasParaLogos(form.prendasSel);
 // Calidades que de verdad se pidieron, no las cinco del catalogo.
 const calidadesLogo=unicos(form.lineas.map(l=>l.calidad).filter(Boolean));
 return <><h2>Mockups y logos</h2><p className={estilos.pista}>Adjunta los mockups del diseño y los logos/sellos a aplicar.</p><div className={estilos.tituloBloque}>Mockups del diseño</div><div className={estilos.avisoInfo}>El <strong>Mockup 1</strong> es el principal: aparece solo en la primera página del brief. Los demás aparecen después, en cuadrícula.</div><div className={estilos.cargas}><label><strong>Mockups</strong><span>Hasta 10 imágenes o PDF; el primero será principal.</span><input type="file" multiple accept="image/jpeg,image/png,image/webp,application/pdf" onChange={e=>seleccionar("mockup",e.target.files)}/></label><label><strong>Logos y sellos</strong><span>Puedes seleccionar varios archivos.</span><input type="file" multiple accept="image/jpeg,image/png,image/webp,application/pdf" onChange={e=>seleccionar("logo",e.target.files)}/></label></div><div className={estilos.tituloBloque}>Logos y sellos</div><div className={estilos.contadorLogos}><span>📌 Cantidad total de logos/sellos:</span><strong>{form.archivos.filter(a=>a.tipo==="logo").length}</strong></div><div className={estilos.archivos}>{form.archivos.map(a=><article key={a.id}>{a.preview?<img src={a.preview} alt=""/>:<div className={estilos.archivoViejo}>{a.tipo.toUpperCase()}</div>}<select value={a.tipo} onChange={e=>cambiar<Archivo>("archivos",a.id,{tipo:e.target.value as Archivo["tipo"]})}><option value="mockup">Mockup</option><option value="logo">Logo / sello</option></select><input value={a.descripcion} placeholder="Descripción" onChange={e=>cambiar<Archivo>("archivos",a.id,{descripcion:e.target.value})}/>{a.tipo==="logo"&&<><select value={a.prenda} onChange={e=>cambiar<Archivo>("archivos",a.id,{prenda:e.target.value,posicion:""})}><option value="">Prenda aplicable…</option>{prendasLogo.map(p=><option key={p}>{p}</option>)}</select><select value={a.posicion} onChange={e=>cambiar<Archivo>("archivos",a.id,{posicion:e.target.value})} disabled={!a.prenda}>{a.prenda?<><option value="">Posición / zona…</option>{posicionesDePrenda(a.prenda).map(o=><option key={o}>{o}</option>)}{!!a.posicion&&!posicionesDePrenda(a.prenda).includes(a.posicion)&&<option>{a.posicion}</option>}</>:<option value="">Primero elige la prenda</option>}</select><select value={a.tecnica} onChange={e=>cambiar<Archivo>("archivos",a.id,{tecnica:e.target.value})}><option value="">Técnica del sello…</option>{TECNICAS_LOGO.map(t=><option key={t}>{t}</option>)}{!!a.tecnica&&!TECNICAS_LOGO.includes(a.tecnica)&&<option>{a.tecnica}</option>}</select><select value={a.calidad_aplicable} onChange={e=>cambiar<Archivo>("archivos",a.id,{calidad_aplicable:e.target.value})}><option value="Todas">Todas las calidades</option>{calidadesLogo.map(c=><option key={c}>{c}</option>)}</select><input value={a.observacion} placeholder="Observación del logo" onChange={e=>cambiar<Archivo>("archivos",a.id,{observacion:e.target.value})}/></>}<button className="secondary" onClick={()=>quitar("archivos",a.id)}>Quitar</button></article>)}</div></>}
function PasoTecnica({form,setCab,agregarFicha,cambiar,quitar}:{form:Form;setCab:SetCab;agregarFicha:(clave:string)=>void;cambiar:Cambiar;quitar:Quitar}){return <><h2>Especificaciones técnicas</h2><div className={estilos.grid}><Campo titulo="Nombre jugador - técnica *"><select value={form.cab.nombre_tecnica} onChange={e=>setCab("nombre_tecnica",e.target.value)}><option value="">Seleccionar…</option>{TECNICAS.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="Número jugador - técnica *"><select value={form.cab.numero_tecnica} onChange={e=>setCab("numero_tecnica",e.target.value)}><option value="">Seleccionar…</option>{TECNICAS.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="¿Lleva sellos TPU? *"><select value={form.cab.sellos_tpu} onChange={e=>setCab("sellos_tpu",e.target.value)}><option>No</option><option>Sí</option></select></Campo><Campo titulo="Ubicación TPU"><select value={form.cab.ubicacion_tpu} onChange={e=>setCab("ubicacion_tpu",e.target.value)}>{UBICACION_TPU.map(x=><option key={x} value={x==="No aplica"?"":x}>{x}</option>)}</select></Campo><Campo titulo="Bordado / observaciones" ancho><textarea rows={3} value={form.cab.bordado} onChange={e=>setCab("bordado",e.target.value)}/></Campo><Campo titulo="Colores generales" ancho><SelectorColores valor={form.cab.colores} onCambio={v=>setCab("colores",v)}/></Campo></div><div className={estilos.tituloBloque}>Detalle por prenda y calidad</div>
<p className={estilos.avisoFuerte}>Las especificaciones varían según la calidad. Elige primero la calidad de cada especificación y las opciones se ajustarán a ella.</p>
{!form.prendasSel.length&&<Vacio texto="Selecciona prendas en el paso Prendas para que aparezcan sus especificaciones técnicas."/>}
{fichasDePrendas(form.prendasSel).map(ficha=>{
 const suyas=form.specs.filter(x=>x.prenda_clave===ficha.clave);
 return <section className={estilos.bloquePrenda} key={ficha.clave}>
  <header><strong>{ficha.icon} {ficha.label}</strong><button className="secondary" onClick={()=>agregarFicha(ficha.clave)}>+ Agregar otra especificación</button></header>
  {!suyas.length&&<p className={estilos.pista}>Sin especificación: agrega una para detallar esta prenda en el brief.</p>}
  {suyas.map(sp=><TarjetaSpec key={sp.id} spec={sp} ficha={ficha} mockups={mockupsDe(form)} cambiar={cambiar} quitar={quitar}/>)}
 </section>;
})}</>}
function TarjetaSpec({spec,ficha,mockups,cambiar,quitar}:{spec:Spec;ficha:FichaPrenda;mockups:{id:string;descripcion:string}[];cambiar:Cambiar;quitar:Quitar}){
 const set=(clave:string,valor:string)=>cambiar<Spec>("specs",spec.id,{campos:{...spec.campos,[clave]:valor}});
 return <div className={estilos.tarjetaSpec}>
  <header>
   <span>{ficha.icon}</span>
   <div className={estilos.corresponde}>
    <span>Corresponde a:</span>
    <select value={spec.mockup} onChange={e=>cambiar<Spec>("specs",spec.id,{mockup:e.target.value})}><option value="">— Mockup —</option>{mockups.map(m=><option key={m.id} value={m.descripcion}>{m.descripcion}</option>)}</select>
    <select value={spec.variante_calidad} onChange={e=>cambiar<Spec>("specs",spec.id,{variante_calidad:e.target.value})}><option value="">— Calidad —</option>{CALIDADES.map(c=><option key={c}>{c}</option>)}</select>
   </div>
   <button className="secondary" onClick={()=>quitar("specs",spec.id)}>Quitar</button>
  </header>
  {ficha.calAware&&!spec.variante_calidad&&<p className={estilos.avisoFuerte}>Elige primero la calidad: varias opciones de esta ficha cambian según la calidad.</p>}
  <div className={estilos.camposSpec}>
   {ficha.campos.filter(c=>c.id!=="observacion").map(campo=>{
    const opts=opcionesCampo(ficha,campo,spec.variante_calidad,spec.campos);
    const valor=spec.campos[campo.id]??"";
    return <label key={campo.id}>
     <span>{campo.label}{campo.optsAlta&&esCalidadAlta(spec.variante_calidad)?" ✦":""}</span>
     {opts
      ?<select value={valor} onChange={e=>set(campo.id,e.target.value)}><option value="">—</option>{opts.map(o=><option key={o}>{o}</option>)}</select>
      :<input value={valor} onChange={e=>set(campo.id,e.target.value)} placeholder="Opcional"/>}
    </label>;
   })}
  </div>
  <label className={estilos.obsSpec}><span>📝 Observación {ficha.label.toLowerCase()}</span><textarea rows={2} value={spec.observacion} onChange={e=>cambiar<Spec>("specs",spec.id,{observacion:e.target.value})} placeholder="Detalles adicionales para esta prenda…"/></label>
 </div>;
}

function PasoJugadores({form,importar,plantilla,agregar,setForm,cambiar,quitar}:{form:Form;importar:(f:File)=>void;plantilla:()=>void;agregar:()=>void;setForm:SetForm;cambiar:Cambiar;quitar:Quitar}){
 async function sumarAutomatico(){
  if(!form.jugadores.length)return mostrarAvisoDialogo("Primero agrega jugadores en la lista.","Sin jugadores",true);
  const hayCargado=form.lineas.some(l=>totalLinea(l).total>0);
  if(hayCargado&&!await confirmarDialogo("Se borrará la suma actual de tallas y se volverá a calcular desde la lista de jugadores. Si escribiste cantidades a mano, se van a perder. ¿Continuar?"))return;
  const nuevas=tallasDesdeJugadores(form.jugadores);
  setForm(f=>({...f,lineas:nuevas,prendasSel:Array.from(new Set([...f.prendasSel,...nuevas.map(l=>l.prenda)]))}));
  await mostrarAvisoDialogo(`Se recalcularon ${nuevas.length} línea(s) de talla desde ${form.jugadores.length} jugador(es).`,"Tallas actualizadas");
 }
 return <>
 <Titulo titulo="Jugadores y tallas por prenda / calidad" texto={`Total de jugadores: ${form.jugadores.length}`} accion={agregar} etiqueta="+ Agregar jugador">
  <button onClick={()=>void sumarAutomatico()}>📊 Sumar automáticamente</button>
  <button className="secondary" onClick={()=>setForm(f=>({...f,jugadores:ordenarJugadores(f.jugadores)}))}>Ordenar por tipo de prenda</button>
  <button className="secondary" onClick={plantilla}>Plantilla Excel</button>
  <label className={estilos.botonArchivo}>Cargar Excel<input type="file" accept=".xlsx,.xls,.csv" onChange={e=>e.target.files?.[0]&&importar(e.target.files[0])}/></label>
 </Titulo>
 <div className={estilos.tablaJug}>
  <div className={estilos.jugCab}><span>#</span><span>Nombre</span><span>Núm.</span><span>Categ.</span><span>T.Sup</span><span>T.Inf</span><span>Manga</span><span>Calidad</span><span>Mod. arquero</span><span>Tipo uniforme</span><span>Detalle/variante</span><span>Mockup</span><span/></div>
  {form.jugadores.map((j,i)=><div className={estilos.jugFila} key={j.id}>
   <b>{i+1}</b>
   <input placeholder="Nombre" value={j.nombre} onChange={e=>cambiar<Jugador>("jugadores",j.id,{nombre:e.target.value})}/>
   <input placeholder="0" value={j.numero} onChange={e=>cambiar<Jugador>("jugadores",j.id,{numero:e.target.value})}/>
   <select value={j.categoria} onChange={e=>cambiar<Jugador>("jugadores",j.id,{categoria:e.target.value})}><option>Hombre</option><option>Mujer</option><option>Niño</option><option>Niña</option></select>
   <select value={j.talla_superior} onChange={e=>cambiar<Jugador>("jugadores",j.id,{talla_superior:e.target.value})}><option value="">—</option>{[...ADULTOS,...NINOS].map(t=><option key={t}>{t}</option>)}</select>
   <select value={j.talla_inferior} onChange={e=>cambiar<Jugador>("jugadores",j.id,{talla_inferior:e.target.value})}><option value="">—</option>{[...ADULTOS,...NINOS].map(t=><option key={t}>{t}</option>)}</select>
   <select value={j.manga} onChange={e=>cambiar<Jugador>("jugadores",j.id,{manga:e.target.value})}><option>Corta</option><option>Larga</option></select>
   <select value={j.calidad} onChange={e=>cambiar<Jugador>("jugadores",j.id,{calidad:e.target.value})}><option value="">— Cal. —</option>{CALIDADES.map(c=><option key={c}>{c}</option>)}</select>
   <select value={j.modelo_arquero} onChange={e=>cambiar<Jugador>("jugadores",j.id,{modelo_arquero:e.target.value})}><option value="N/A">— No es arquero —</option>{MODELOS_ARQUERO.map(g=><optgroup key={g.grupo} label={g.grupo}>{g.modelos.map(m=><option key={m}>{m}</option>)}</optgroup>)}</select>
   <select value={j.tipo_uniforme} onChange={e=>cambiar<Jugador>("jugadores",j.id,{tipo_uniforme:e.target.value})}><option value="">— Tipo —</option>{TIPOS_UNIFORME.map(t=><option key={t}>{t}</option>)}</select>
   <input placeholder="Ej: Cuello fucsia" value={j.detalle} onChange={e=>cambiar<Jugador>("jugadores",j.id,{detalle:e.target.value})}/>
   <select value={j.mockup} onChange={e=>cambiar<Jugador>("jugadores",j.id,{mockup:e.target.value})}><option value="">— sin mockup —</option>{mockupsDe(form).map(m=><option key={m.id} value={m.descripcion}>{m.descripcion}</option>)}</select>
   <button className="secondary" onClick={()=>quitar("jugadores",j.id)}>✕</button>
  </div>)}
 </div>
 {!form.jugadores.length&&<Vacio texto="Este contrato no tiene nómina de jugadores."/>}
 <div className={estilos.tituloBloque}>TALLAS POR PRENDA Y CALIDAD</div><p className={estilos.avisoInfo}>Para cada prenda seleccionada agrega una línea por calidad. Ingresa las cantidades de Hombres (H), Mujeres (M) y Niños por talla.</p><SeccionTallas form={form} setForm={setForm}/></>}
function PasoCierre({form,setCab,saldo,agregar,cambiar,quitar}:{form:Form;setCab:SetCab;saldo:number;agregar:()=>void;cambiar:Cambiar;quitar:Quitar}){return <><h2>Producción, valores y cierre</h2><div className={estilos.grid}><Campo titulo="Presupuesto total (USD)"><input type="number" min={0} step=".01" value={form.cab.presupuesto} onChange={e=>setCab("presupuesto",Number(e.target.value))}/></Campo><Campo titulo="Abono recibido (USD)"><input type="number" min={0} step=".01" value={form.cab.abono} onChange={e=>setCab("abono",Number(e.target.value))}/></Campo><div className={estilos.saldo}><span>Saldo pendiente</span><strong>${saldo.toFixed(2)}</strong></div><Campo titulo="Forma de entrega"><select value={form.cab.forma_entrega} onChange={e=>setCab("forma_entrega",e.target.value)}><option value="">Seleccionar…</option>{FORMAS_ENTREGA.map(x=><option key={x}>{x}</option>)}</select></Campo><Campo titulo="Dirección"><input value={form.cab.direccion} onChange={e=>setCab("direccion",e.target.value)}/></Campo><Campo titulo="Instrucciones especiales" ancho><textarea rows={4} value={form.cab.instrucciones} onChange={e=>setCab("instrucciones",e.target.value)}/></Campo><Campo titulo="Vendedor responsable *"><input value={form.cab.vendedor_responsable} onChange={e=>setCab("vendedor_responsable",e.target.value)}/></Campo></div><Titulo titulo="Detalle de facturación" texto="Cómo se factura el pedido (ej. 20 Uniforme completo + 10 Camiseta). Debe cuadrar con las prendas del contrato para poder guardar." accion={agregar} etiqueta="+ Agregar línea de facturación"/><ComprobanteFact form={form}/>{form.facturacion.map(x=><div className={estilos.filaFact} key={x.id}><select value={x.concepto} onChange={e=>cambiar<Fact>("facturacion",x.id,{concepto:e.target.value})}>{CONCEPTOS_FACT.map(o=><option key={o.l} value={o.l}>{o.l}{o.c?"":" (no valida)"}</option>)}</select><select value={x.calidad} onChange={e=>cambiar<Fact>("facturacion",x.id,{calidad:e.target.value})}>{CALIDADES.map(x=><option key={x}>{x}</option>)}</select><input type="number" min={1} value={x.cantidad} onChange={e=>cambiar<Fact>("facturacion",x.id,{cantidad:Number(e.target.value)})}/><label className={estilos.check}><input type="checkbox" checked={x.obsequio} onChange={e=>cambiar<Fact>("facturacion",x.id,{obsequio:e.target.checked})}/> Obsequio</label><button className="secondary" onClick={()=>quitar("facturacion",x.id)}>Quitar</button></div>)}<label className={estilos.autoriza}><input type="checkbox" checked={form.cab.autorizado} onChange={e=>setCab("autorizado",e.target.checked)}/><span><strong>Confirmo que revisé todos los datos.</strong> Autorizo el envío de este contrato a producción.</span></label></>}
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

// Sin presupuesto/abono/saldo a proposito: el brief es el documento que
// imprime el taller y en el legado no lleva ningun dato economico.
function VistaPrevia({form,total,cerrar}:{form:Form;total:number;cerrar:()=>void}){
 const [montado,setMontado]=useState(false);
 // El brief se monta en <body> por portal: así la regla @media print puede apagar el
 // resto de la página con un selector de hijo directo, sin tocar globals.css.
 useEffect(()=>{setMontado(true);document.body.classList.add("brief-imprimible");const esc=(e:KeyboardEvent)=>{if(e.key==="Escape")cerrar()};document.addEventListener("keydown",esc);return()=>{document.body.classList.remove("brief-imprimible");document.removeEventListener("keydown",esc)}},[cerrar]);
 if(!montado)return null;
 return createPortal(
  <div className={estilos.vistaPrevia} role="dialog" aria-modal="true" aria-label="Brief de producción" onMouseDown={e=>e.target===e.currentTarget&&cerrar()}>
   <div className={`${estilos.barraBrief} ${estilos.noPrint}`}>
    <strong>Vista previa del brief de producción</strong>
    <button onClick={()=>window.print()}>Imprimir</button>
    <button className="secondary" onClick={cerrar}>Cerrar</button>
   </div>
    <BriefHoja form={form}/>
  </div>,document.body);
}

// Reconstruye el Form a partir de un contrato YA GUARDADO, para poder pintarlo
// con el mismo BriefHoja del ingreso. Es el inverso del payload que arma
// guardar(): las columnas de contrato_prendas / _jugadores / _archivos /
// _specs / _facturacion se llaman igual que los campos del formulario, asi que
// el mapeo es directo salvo en dos sitios:
//  - `adicionales` en la cabecera es texto libre, pero guardado es un objeto
//    {detalle, items, medidas_bandera}; hay que desarmarlo o el brief imprime
//    "[object Object]".
//  - las tallas no se guardan como matriz sino como filas ya expandidas, asi
//    que se rearman con lineasDesdePrendas (lo mismo que hace una reposicion).
type FilaGuardada=Record<string,unknown>;
export function formDesdeContrato(datos:{contrato:FilaGuardada;prendas?:FilaGuardada[];jugadores?:FilaGuardada[];archivos?:FilaGuardada[];especificaciones?:FilaGuardada[];facturacion?:FilaGuardada[]}):Form{
 const co=datos.contrato||{};
 const t=(v:unknown)=>v===null||v===undefined?"":String(v);
 const cab=cabInicial(t(co.vendedor));
 for(const k of Object.keys(cab) as (keyof Cab)[]){
  if(k==="adicionales")continue;                       // objeto, no texto: se trata abajo
  const v=co[k as string];
  if(v===null||v===undefined||v==="")continue;
  (cab as Record<string,unknown>)[k]=typeof (cab as Record<string,unknown>)[k]==="number"?Number(v)
   :typeof (cab as Record<string,unknown>)[k]==="boolean"?Boolean(v):t(v);
 }
 // La cabecera del formulario lleva los colores como texto separado por comas,
 // pero la tabla los guarda en colores_generales (jsonb [{nombre}]). Sin esta
 // conversion el brief de un contrato guardado salia sin la franja de colores.
 if(Array.isArray(co.colores_generales))cab.colores=(co.colores_generales as Record<string,unknown>[]).map(x=>t(x&&x.nombre)).filter(Boolean).join(", ");
 const ad=(co.adicionales&&typeof co.adicionales==="object"?co.adicionales:{}) as Record<string,unknown>;
 cab.adicionales=t(ad.detalle);
 const adic=adicInicial(),adicCant={} as AdicCant;
 for(const a of ADICIONALES)adicCant[a.clave]=0;
 for(const it of (Array.isArray(ad.items)?ad.items:[]) as Record<string,unknown>[]){
  const def=ADICIONALES.find(x=>x.titulo===t(it.tipo));
  if(!def)continue;
  if(t(it.valor))adic[def.clave]=t(it.valor);
  adicCant[def.clave]=Number(it.cantidad)||0;
 }
 const prendas=(datos.prendas||[]).map(x=>({id:uuid(),prenda:t(x.prenda),calidad:t(x.calidad),detalle:t(x.detalle),genero:(t(x.genero)||"H") as Prenda["genero"],talla:t(x.talla),cantidad:Number(x.cantidad)||0}));
 return {
  cab,
  prendasSel:prendas.map(x=>x.prenda).filter((v,i,a)=>v&&a.indexOf(v)===i),
  lineas:lineasDesdePrendas(datos.prendas||[]),
  adic,adicCant,medidasBandera:t(ad.medidas_bandera),
  prendas,
  jugadores:(datos.jugadores||[]).map(x=>({id:uuid(),nombre:t(x.nombre),numero:t(x.numero),categoria:t(x.categoria),talla_superior:t(x.talla_superior),talla_inferior:t(x.talla_inferior),manga:t(x.manga),calidad:t(x.calidad),modelo_arquero:t(x.modelo_arquero),tipo_uniforme:t(x.tipo_uniforme),detalle:t(x.detalle),mockup:t(x.mockup)})),
  archivos:(datos.archivos||[]).map(x=>({id:uuid(),tipo:(t(x.tipo)==="logo"?"logo":"mockup") as Archivo["tipo"],url:t(x.url)||undefined,drive_id:t(x.drive_id)||undefined,descripcion:t(x.descripcion),color:t(x.color),prenda:t(x.prenda),posicion:t(x.posicion),tecnica:t(x.tecnica),calidad_aplicable:t(x.calidad_aplicable)||"Todas",observacion:t(x.observacion)})),
  specs:(datos.especificaciones||[]).map(x=>{const sp=(x.spec&&typeof x.spec==="object"?x.spec:{}) as Record<string,unknown>;
   return {id:uuid(),prenda_clave:t(x.prenda_clave),variante_calidad:t(x.variante_calidad),mockup:t(x.variante_mockup),campos:(sp.campos&&typeof sp.campos==="object"?sp.campos:{}) as Record<string,string>,observacion:t(sp.observacion)}}),
  facturacion:(datos.facturacion||[]).map(x=>({id:uuid(),concepto:t(x.concepto),calidad:t(x.calidad),cantidad:Number(x.cantidad)||0,obsequio:Boolean(x.obsequio)})),
 };
}

// El DOCUMENTO del brief, sin el modal que lo envuelve. Se exporta para que el
// expediente de un contrato ya guardado imprima EXACTAMENTE el mismo papel que
// la vista previa del ingreso, en vez de sostener dos briefs distintos.
export function BriefHoja({form}:{form:Form}){
 const c=form.cab;
 const mockups=mockupsDe(form);
 const logos=form.archivos.filter(a=>a.tipo==="logo");
 const calidades=Array.from(new Set(form.prendas.map(x=>x.calidad).filter(Boolean)));
 const calidad=calidades.length?calidades.join(" / "):"Sin calidad";
 const colores=c.colores.split(",").map(x=>x.trim()).filter(Boolean);
 // Mismo criterio que el legado: solo se imprime lo que difiere del valor por
 // defecto, con "×cantidad" cuando la hay. La bandera va en MAYUSCULA y con
 // recuadro propio porque en produccion se la saltaban.
 const adicionales=(()=>{const out:string[]=[];
  for(const a of ADICIONALES){const v=form.adic[a.clave],n=form.adicCant[a.clave]||0;
   if(!v||v===a.opciones[0])continue;
   out.push(a.clave==="bandera"?"BANDERA"+(n>0?` ×${n}`:""):v+(n>0?` ×${n}`:""));}
  if(texto(form.medidasBandera))out.push(`📏 Medidas: ${texto(form.medidasBandera)}`);
  if(texto(c.adicionales))out.push(texto(c.adicionales));
  return out})();
 // Jugadores y specs se reparten por mockup; lo que no cae en ninguno se muestra
 // aparte para que nunca desaparezca del papel (el legado tuvo ese bug y lo blinda).
 const porMockup=mockups.map((m,i)=>({m,i,jugadores:form.jugadores.filter(j=>indiceMockup(j.mockup,mockups)===i),specs:form.specs.filter(s=>indiceMockup(s.mockup,mockups)===i)}));
 // Igual que briefFotosSoloHtml del legado: un mockup sin jugadores ni specs
 // no merece una seccion entera (dejaria media hoja en blanco); va arriba en
 // un bloque compacto de solo foto.
 const mockupsConContenido=porMockup.filter(x=>x.jugadores.length>0||x.specs.length>0);
 const mockupsSoloFoto=porMockup.filter(x=>x.jugadores.length===0&&x.specs.length===0);
 // Igual que agruparPorMockup del legado: se agrupa por mockup solo si ALGUN
 // jugador o ALGUNA especificacion tiene mockup asignado. Si no, el brief usa
 // la portada: mockup grande a la derecha y resumen tecnico a la izquierda.
 const agrupado=form.jugadores.some(j=>texto(j.mockup))||form.specs.some(x=>texto(x.mockup));
 const mockupsPortada=agrupado?[]:mockups.slice(0,2);
 // En portada el legado muestra Mockup 1 (y 2) grandes; los demas bajan a la
 // cuadricula de la segunda pagina, no desaparecen.
 const mockupsCuadricula=agrupado?mockupsSoloFoto:mockups.slice(2).map((m,k)=>({m,i:k+2}));
 const jugadoresSueltos=form.jugadores.filter(j=>indiceMockup(j.mockup,mockups)<0);
 const specsSueltas=form.specs.filter(s=>indiceMockup(s.mockup,mockups)<0);
 const grupos=agruparTallas(form.prendas);
 const detalle=form.facturacion.length
  ?form.facturacion.map(f=>({cantidad:String(f.cantidad),texto:f.concepto,calidad:f.calidad,obsequio:f.obsequio}))
  :grupos.map(g=>({cantidad:String(g.lineas.reduce((s,l)=>s+l.totH+l.totM+l.totN,0)),texto:g.prenda,calidad:"",obsequio:false}));
 return <>
   <article className={estilos.hoja}>
    <div className={estilos.bTop}>
     <div className={estilos.bCal} style={calidad.length>26?{fontSize:"13px"}:calidad.length>16?{fontSize:"17px"}:undefined}>{calidad}</div>
     <div className={estilos.bNota}>NOTA: ANTES DEL ENSAMBLE, CORROBORAR QUE EL MOCKUP SEA EL CORRECTO</div>
    </div>
    <div className={estilos.bTitulo}>DETALLE DE CONTRATO: {c.nombre_contrato_v115||c.cliente||"—"}</div>
    <table className={estilos.bhTbl}><tbody>
     <tr>
      <td className={estilos.bhLbl}>CONTRATO:</td>
      <td className={estilos.bhVal}>{c.nombre_contrato_v115||c.cliente||"—"}{c.prioridad==="Urgente"&&<span className={estilos.bBadgeRojo}>⚠️ URGENTE</span>}{c.reposicion&&<span className={estilos.bBadgeRojo}>🔄 REPOSICIÓN</span>}</td>
      <td className={estilos.bhRespH} rowSpan={2}><div className={estilos.bhCod}>NUEVO CONTRATO</div>RESPONSABLE<div className={estilos.bhResp}>{c.vendedor_responsable||c.vendedor||"—"}</div></td>
     </tr>
     <tr><td className={estilos.bhLbl}>FECHA DE INGRESO:</td><td className={estilos.bhVal}>{fechaCorta(new Date().toISOString().slice(0,10))}</td></tr>
     <tr><td className={estilos.bhLbl}>CLIENTE:</td><td className={estilos.bhVal} colSpan={2}>{c.cliente||"—"}</td></tr>
     <tr><td className={estilos.bhLbl}>FECHA DE ENTREGA:</td><td className={`${estilos.bhVal} ${estilos.bhEnt}`} colSpan={2}>{fechaCorta(c.fecha_entrega)||"—"}</td></tr>
     <tr><td className={estilos.bhLbl}>ENTREGA:</td><td className={estilos.bhVal} colSpan={2}>{c.forma_entrega||"—"}{c.direccion&&` · ${c.direccion}`}</td></tr>
    </tbody></table>

    <div className={agrupado?undefined:estilos.bPortadaWrap}>
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
       {/* El legado no imprime el TPU en el brief, pero se captura como obligatorio
           y el taller lo necesita en papel: se agrega a proposito. */}
       <tr><td>Sellos TPU</td><td>{c.sellos_tpu||"—"}{c.ubicacion_tpu&&` · ${c.ubicacion_tpu}`}</td></tr>
       {!!texto(c.bordado)&&<tr><td>Bordado especial</td><td style={{color:"#7c3aed",fontWeight:700}}>{c.bordado}</td></tr>}
      </tbody></table>
     </div>
     {!!adicionales.length&&<div className={estilos.bAdic}><div className={estilos.bAdicTit}>⚠️ ADICIONALES DEL PEDIDO</div>{adicionales.map((l,i)=><div key={i} className={/^bandera/i.test(l)?estilos.bAdicBandera:estilos.bAdicLinea}>• {l}</div>)}</div>}
    </div>

    {mockupsPortada.length>0&&<div className={estilos.bPanelMockup}>{mockupsPortada.map(({id,preview,url,descripcion},i)=>
    <figure key={id}><img src={preview||url} alt=""/><figcaption>MOCKUP {i+1}{descripcion?` · ${descripcion}`:""}</figcaption></figure>)}</div>}
    </div>
    {!!colores.length&&<div className={estilos.bColores}>
     <div className={estilos.bH3}>COLORES GENERALES</div>
     <div className={estilos.bChips}>{colores.map(x=><span key={x} className={estilos.bChip}>{x}</span>)}</div>
     <div className={estilos.bAviso}>⚠️ SIEMPRE PREDOMINA EL COLOR DEL MOCKUP Y DE LA MUESTRA SOBRE EL COLOR REFERENCIAL</div>
    </div>}

    {mockupsCuadricula.length>0&&<div className={estilos.bFotosSolo}>{mockupsCuadricula.map(({m,i})=><figure key={m.id}><img src={m.preview||m.url} alt=""/><figcaption>MOCKUP {i+1}{m.descripcion?` · ${m.descripcion}`:""}</figcaption></figure>)}</div>}
    {mockupsConContenido.map(({m,i,jugadores,specs})=><section key={m.id} className={estilos.bSeccion}>
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

    <div className={estilos.bPie}>Brief generado {fechaCorta(new Date().toISOString().slice(0,10))} · Boman Sport</div>
   </article>
  </>;
}

// Tabla de jugadores del brief: cabecera azul, zebra, bandas de calidad y columnas
// que se ocultan si nadie las llenó (roban ancho para mostrar solo guiones).
function TablaJugadores({jugadores}:{jugadores:Jugador[]}){
 const arr=jugadores.slice().sort((a,b)=>posCalidad(a.calidad)-posCalidad(b.calidad)||a.tipo_uniforme.localeCompare(b.tipo_uniforme)||a.nombre.localeCompare(b.nombre));
 const hay={numero:arr.some(j=>texto(j.numero)),manga:arr.some(j=>j.manga==="Larga"),inferior:arr.some(j=>texto(j.talla_inferior)),arquero:arr.some(j=>texto(j.modelo_arquero)),calidad:arr.some(j=>texto(j.calidad)),tipo:arr.some(j=>texto(j.tipo_uniforme)),detalle:arr.some(j=>texto(j.detalle))};
 const columnas=1+Number(hay.numero)+1+1+Number(hay.manga)+Number(hay.inferior)+Number(hay.arquero)+Number(hay.tipo)+Number(hay.detalle);
 let calPrevia="";let grupoPrevio:number|null=null;
 return <table className={estilos.bJug}>
  <thead><tr>
   <th>NOMBRE</th>{hay.numero&&<th>NÚM</th>}<th>CATEG.</th><th>T.CAM</th>{hay.manga&&<th>MANGA</th>}{hay.inferior&&<th>T.PANT</th>}{hay.arquero&&<th>MOD. ARQ.</th>}{hay.tipo&&<th>TIPO</th>}{hay.detalle&&<th>DETALLE</th>}
  </tr></thead>
  <tbody>{arr.map((j,i)=>{
   const banda=hay.calidad&&texto(j.calidad)&&j.calidad!==calPrevia?j.calidad:"";
   if(banda){calPrevia=j.calidad;grupoPrevio=null}
   const g=grupoPrendaJugador(j.tipo_uniforme);
   const bandaGrupo=hay.tipo&&g!==grupoPrevio;
   if(bandaGrupo)grupoPrevio=g;
   return <Fragment key={j.id}>
    {!!banda&&<tr><td className={estilos.bBandaCal} colSpan={columnas}>■ {banda.toUpperCase()} ▼</td></tr>}
    {bandaGrupo&&<tr><td className={g===1?estilos.bGrupoSup:g===2?estilos.bGrupoInf:estilos.bGrupoComp} colSpan={columnas}>{g===1?"▲":g===2?"▼":"◆"}&nbsp; {etiquetaGrupo(arr,i)}<span className={estilos.bGrupoCuenta}>{cuentaGrupo(arr,i)} jug.</span></td></tr>}
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
  // MISMA ficha que uso el formulario para capturar. Antes el brief tenia su
  // propio catalogo con otros ids, asi que lo capturado no se imprimia.
  const ficha=FICHAS_PRENDA.find(f=>f.clave===s.prenda_clave);
  const marca=FAMILIA_MARCA[familiaPrenda(ficha?.label||s.prenda_clave)];
  const filas=(ficha?.campos||[])
   .filter(f=>f.id!=="observacion"&&f.id!=="corte")
   .map(f=>({t:f.label,v:texto(s.campos[f.id])}))
   .filter(x=>x.v&&!/^no aplica$/i.test(x.v));
  const corte=texto(s.campos.corte);
  // Con mas de 5 filas la tabla de una columna deja media hoja vacia a su
  // derecha: se parte en dos columnas lado a lado, como _specs2col del legado.
  const dos=filas.length>5;
  const mitad=Math.ceil(filas.length/2);
  return <article key={s.id} className={estilos.bSpecCard}>
   <div className={estilos.bSpecCab} style={{background:marca.color}}>{ficha?.icon||marca.icono} {(ficha?.label||s.prenda_clave).toUpperCase()}{s.variante_calidad&&` · ${s.variante_calidad}`}</div>
   {!!corte&&<div className={estilos.bCorte}>✂️ CORTE: {corte}</div>}
   {!!filas.length&&(dos
    ?<table className={estilos.bDatos}><tbody>{Array.from({length:mitad},(_,k)=>{const a=filas[k],b=filas[k+mitad];
      return <tr key={k}><td>{a.t}</td><td>{a.v}</td><td>{b?b.t:""}</td><td>{b?b.v:""}</td></tr>})}</tbody></table>
    :<table className={estilos.bDatos}><tbody>{filas.map(f=><tr key={f.t}><td>{f.t}</td><td>{f.v}</td></tr>)}</tbody></table>)}
   {!filas.length&&!corte&&!texto(s.observacion)&&<div className={estilos.bSpecVacio}>Sin detalle técnico cargado.</div>}
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

type SetForm=React.Dispatch<React.SetStateAction<Form>>;
function SeccionTallas({form,setForm}:{form:Form;setForm:SetForm}){
 const prendas=prendasConTalla(form.prendasSel);
 const setLinea=(id:string,cambio:Partial<Linea>)=>setForm(f=>({...f,lineas:f.lineas.map(l=>l.id===id?{...l,...cambio}:l)}));
 const agregar=(prenda:string)=>setForm(f=>({...f,lineas:[...f.lineas,lineaNueva(prenda)]}));
 const quitar=(id:string)=>setForm(f=>({...f,lineas:f.lineas.filter(l=>l.id!==id)}));
 if(!prendas.length)return <Vacio texto="Selecciona las prendas en el paso Prendas para ver las secciones de tallas."/>;
 return <>{prendas.map(prenda=>{
  const suyas=form.lineas.filter(l=>l.prenda===prenda);
  return <section className={estilos.bloquePrenda} key={prenda}>
   <header><strong>🎽 {etiquetaPrenda(prenda)}</strong><button className="secondary" onClick={()=>agregar(prenda)}>+ Agregar calidad</button></header>
   {!suyas.length&&<p className={estilos.pista}>Sin líneas: agrega una calidad para cargar sus tallas.</p>}
   {suyas.map(l=>{
    const t=totalLinea(l);
    const setAdulto=(talla:string,g:"H"|"M",v:number)=>setLinea(l.id,{adultos:{...l.adultos,[talla]:{...(l.adultos[talla]||{H:0,M:0}),[g]:Math.max(0,v)}}});
    const setEspA=(i:number,campo:"nombre"|"H"|"M",v:string|number)=>setLinea(l.id,{espA:l.espA.map((e,j)=>j===i?{...e,[campo]:campo==="nombre"?String(v):Math.max(0,Number(v))}:e)});
    const setNino=(talla:string,v:number)=>setLinea(l.id,{ninos:{...l.ninos,[talla]:Math.max(0,v)}});
    const setEspN=(i:number,campo:"nombre"|"N",v:string|number)=>setLinea(l.id,{espN:l.espN.map((e,j)=>j===i?{...e,[campo]:campo==="nombre"?String(v):Math.max(0,Number(v))}:e)});
    return <div className={estilos.lineaTalla} key={l.id}>
     <div className={estilos.lineaCab}>
      <select value={l.calidad} onChange={e=>setLinea(l.id,{calidad:e.target.value})}><option value="">— Calidad —</option>{CALIDADES.map(c=><option key={c}>{c}</option>)}</select>
      <input placeholder="Detalle/variante (opcional)" value={l.detalle} onChange={e=>setLinea(l.id,{detalle:e.target.value})}/>
      <span className={estilos.badgeTallas}>H:{t.h} M:{t.m} N:{t.n}</span>
      <button className="secondary" onClick={()=>quitar(l.id)}>Quitar</button>
     </div>
     <div className={estilos.tablasTalla}>
      <div><div className={estilos.subTitulo}>ADULTOS</div>
       <table className={estilos.tablaTalla}><thead><tr><th>Talla</th><th>H</th><th>M</th><th>Total</th></tr></thead><tbody>
        {ADULTOS.map(talla=>{const c=l.adultos[talla]||{H:0,M:0};return <tr key={talla}><th>{talla}</th>
         <td><input type="number" min={0} value={c.H||0} onChange={e=>setAdulto(talla,"H",Number(e.target.value))}/></td>
         <td><input type="number" min={0} value={c.M||0} onChange={e=>setAdulto(talla,"M",Number(e.target.value))}/></td>
         <td className={estilos.celdaTotal}>{(c.H||0)+(c.M||0)||""}</td></tr>})}
        {l.espA.map((e,i)=><tr key={`ea${i}`}><th><input placeholder={`Esp. adulto ${i+1}`} value={e.nombre} onChange={ev=>setEspA(i,"nombre",ev.target.value)}/></th>
         <td><input type="number" min={0} value={e.H} onChange={ev=>setEspA(i,"H",ev.target.value)}/></td>
         <td><input type="number" min={0} value={e.M} onChange={ev=>setEspA(i,"M",ev.target.value)}/></td>
         <td className={estilos.celdaTotal}>{e.nombre.trim()?(e.H+e.M)||"":""}</td></tr>)}
        <tr className={estilos.filaTotal}><th>TOTAL</th><td>{t.h}</td><td>{t.m}</td><td>{t.h+t.m}</td></tr>
       </tbody></table>
      </div>
      <div><div className={estilos.subTitulo}>NIÑOS</div>
       <table className={estilos.tablaTalla}><thead><tr><th>Talla</th><th>Cantidad</th></tr></thead><tbody>
        {NINOS.map(talla=><tr key={talla}><th>{talla}</th><td><input type="number" min={0} value={l.ninos[talla]||0} onChange={e=>setNino(talla,Number(e.target.value))}/></td></tr>)}
        {l.espN.map((e,i)=><tr key={`en${i}`}><th><input placeholder={`Esp. niño ${i+1}`} value={e.nombre} onChange={ev=>setEspN(i,"nombre",ev.target.value)}/></th>
         <td><input type="number" min={0} value={e.N} onChange={ev=>setEspN(i,"N",ev.target.value)}/></td></tr>)}
        <tr className={estilos.filaTotal}><th>TOTAL</th><td>{t.n}</td></tr>
       </tbody></table>
      </div>
     </div>
    </div>;
   })}
  </section>;
 })}</>;
}

function ComprobanteFact({form}:{form:Form}){
 const {prendas,facturacion}=form;
 const r=comprobarFacturacion(prendas,facturacion);
 // La bandera se registra en adicionales Y se factura aparte: si esta en un
 // lado y no en el otro, en produccion se la saltan.
 // OJO: este aviso SE SUMA, no reemplaza. Antes hacia return aqui y tapaba el
 // cuadre de prendas: con una bandera pendiente el vendedor no veia que le
 // faltaban camisetas por facturar (reportado con captura).
 const conBandera=form.adic.bandera!=="Sin bandera";
 const banderaFacturada=facturacion.some(f=>texto(f.concepto).toLowerCase()==="bandera");
 const avisoBandera=conBandera&&!banderaFacturada?<div className={estilos.factMal}><strong>📌 Revisa la sección de adicionales y el detalle de facturación para dejar la bandera visible en ambos lados.</strong></div>:null;
 // Las medias de adicionales son el TOTAL: ya incluyen las que van dentro de
 // los uniformes. Se desglosa para que quien factura sepa cuantas se cobran aparte.
 const totalMedias=form.adicCant.medias||0;
 const conUniforme=facturacion.reduce((n,f)=>{const c=texto(f.concepto).toLowerCase();return c.startsWith("uniforme completo")||c.startsWith("arquero completo")?n+(f.cantidad||0):n},0);
 const extra=totalMedias-conUniforme;
 const notaMedias=totalMedias>0?<div className={estilos.notaMedias}>🧦 <strong>Medias:</strong> {totalMedias} en total · {conUniforme} van dentro de uniformes/arqueros · <strong>{extra>0?`${extra} adicionales (aparte)`:extra===0?"ninguna adicional":`${Math.abs(extra)} menos que los uniformes — revisa`}</strong></div>:null;
 if(!r.hayPrendas)return <>{avisoBandera}{notaMedias}<p className={estilos.pista}>Aún no hay prendas con tallas para comprobar (llénalas en el paso Jugadores).</p></>;
 if(r.ok)return <>{avisoBandera}{notaMedias}<p className={estilos.factOk}>✓ La facturación cuadra con las prendas del contrato.</p></>;
 return <>{avisoBandera}<div className={estilos.factMal}>
  <strong>La facturación todavía no cuadra:</strong>
  {r.faltan.length>0&&<div>Faltan por facturar: {r.faltan.join(" · ")}</div>}
  {r.sobran.length>0&&<div>Facturado de más: {r.sobran.join(" · ")}</div>}
  <div>Ajusta las líneas hasta que cuadre para poder guardar.</div>
 </div>{notaMedias}</>;
}

// Paleta del legado: se eligen por nombre (el brief imprime el nombre, no el
// hex) y se guardan separados por coma, que es como viajan a colores_generales.
function SelectorColores({valor,onCambio}:{valor:string;onCambio:(v:string)=>void}){
 const [abierto,setAbierto]=useState(false);
 const elegidos=valor.split(",").map(x=>x.trim()).filter(Boolean);
 const alternar=(nombre:string)=>onCambio((elegidos.includes(nombre)?elegidos.filter(x=>x!==nombre):[...elegidos,nombre]).join(", "));
 return <div className={estilos.colores}>
  <div className={estilos.coloresElegidos}>
   {elegidos.map(n=>{const hex=TODOS_LOS_COLORES.find(c=>c[0]===n)?.[1];
    return <span key={n} className={estilos.chipColor}><i style={{background:hex||"#ccc"}}/>{n}<button onClick={()=>alternar(n)} aria-label={`Quitar ${n}`}>✕</button></span>})}
   {!elegidos.length&&<span className={estilos.pista}>Sin colores elegidos.</span>}
   <button className="secondary" onClick={()=>setAbierto(!abierto)}>{abierto?"Cerrar paleta":"Elegir colores"}</button>
  </div>
  {abierto&&<div className={estilos.paleta}>{TODOS_LOS_COLORES.map(([n,h])=>
   <button key={n} type="button" title={n} className={elegidos.includes(n)?estilos.colorSel:undefined} onClick={()=>alternar(n)}>
    <i style={{background:h}}/><span>{n}</span></button>)}</div>}
 </div>;
}
