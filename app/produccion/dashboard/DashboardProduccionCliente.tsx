"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import { mensajeError } from "@/lib/errores";
import { exportarCSV } from "@/lib/utils";
import estilos from "./DashboardProduccion.module.css";

type Kpis = { contratos:number; prendas:number; presupuesto:number; abonos:number; saldo:number; atrasados:number; urgentes:number };
type Estado = { estado:string; cantidad:number };
type Prenda = { prenda:string; cantidad:number };
type Vendedor = { vendedor:string; contratos:number; prendas:number; presupuesto:number };
type Cronograma = { fecha:string; tipo:string; contratos:number; prendas:number; capacidad:number; excede:boolean };
type Entrega = { numero:string; cliente:string; vendedor:string; estado:string; prioridad:string; fecha_entrega:string; total_prendas:number; dias_restantes:number };
type Resumen = { generado_at:string; ultima_actualizacion:string|null; kpis:Kpis; estados:Estado[]; prendas:Prenda[]; vendedores:Vendedor[]; cronograma:Cronograma[]; proximas_entregas:Entrega[]; filtros:{vendedores:string[];estados:string[]} };
type Contrato = { id:string; numero:string; cliente:string; vendedor:string; disenador:string|null; estado:string; prioridad:string; tipo_contrato:string; fecha_ingreso:string; fecha_inicio:string|null; fecha_entrega:string; dias_restantes:number; atrasado:boolean; total_prendas:number; prendas:Record<string,number>; presupuesto:number; abono:number; saldo:number; mockup_drive_id:string|null };
type Detalle = { total:number; pagina:number; por_pagina:number; filas:Contrato[] };

const RESUMEN_VACIO: Resumen = { generado_at:"",ultima_actualizacion:null,kpis:{contratos:0,prendas:0,presupuesto:0,abonos:0,saldo:0,atrasados:0,urgentes:0},estados:[],prendas:[],vendedores:[],cronograma:[],proximas_entregas:[],filtros:{vendedores:[],estados:[]} };
const POR_PAGINA = 50;
const DINERO = new Intl.NumberFormat("es-EC",{style:"currency",currency:"USD"});
const ENTERO = new Intl.NumberFormat("es-EC",{maximumFractionDigits:0});

function isoLocal(fecha:Date){return `${fecha.getFullYear()}-${String(fecha.getMonth()+1).padStart(2,"0")}-${String(fecha.getDate()).padStart(2,"0")}`}
function rangoMes(){const hoy=new Date();return{desde:isoLocal(new Date(hoy.getFullYear(),hoy.getMonth(),1)),hasta:isoLocal(new Date(hoy.getFullYear(),hoy.getMonth()+1,0))}}
function fechaCorta(valor:string|null){if(!valor)return "—";return new Intl.DateTimeFormat("es-EC",{day:"2-digit",month:"short",timeZone:"UTC"}).format(new Date(`${valor}T12:00:00Z`))}
function fechaHora(valor:string|null){if(!valor)return "Sin sincronización";return new Intl.DateTimeFormat("es-EC",{dateStyle:"medium",timeStyle:"short",timeZone:"America/Guayaquil"}).format(new Date(valor))}
function parametros(desde:string,hasta:string,vendedor:string,estado:string,prioridad:string,incluir:boolean){return{p_desde:desde,p_hasta:hasta,p_vendedor:vendedor||null,p_estado:estado||null,p_prioridad:prioridad||null,p_incluir_entregados:incluir}}
function textoPrendas(prendas:Record<string,number>){return Object.entries(prendas||{}).sort((a,b)=>b[1]-a[1]).map(([nombre,n])=>`${nombre} ${n}`).join(" · ")}

export default function DashboardProduccionCliente(){
  const supabase=useMemo(()=>createClient(),[]);
  const inicial=useMemo(rangoMes,[]);
  const [desde,setDesde]=useState(inicial.desde);const [hasta,setHasta]=useState(inicial.hasta);
  const [vendedor,setVendedor]=useState("");const [estado,setEstado]=useState("");const [prioridad,setPrioridad]=useState("");const [incluir,setIncluir]=useState(false);
  const [aplicados,setAplicados]=useState(()=>({...parametros(inicial.desde,inicial.hasta,"","","",false)}));
  const [resumen,setResumen]=useState<Resumen>(RESUMEN_VACIO);const [detalle,setDetalle]=useState<Detalle>({total:0,pagina:1,por_pagina:POR_PAGINA,filas:[]});
  const [pagina,setPagina]=useState(1);const [cargando,setCargando]=useState(true);const [error,setError]=useState<string|null>(null);const [exportando,setExportando]=useState(false);

  const cargar=useCallback(async(pag:number,mostrarCarga=true)=>{
    if(mostrarCarga)setCargando(true);setError(null);
    const [r,d]=await Promise.all([
      supabase.rpc("resumen_dashboard_produccion_v95",aplicados),
      supabase.rpc("listar_dashboard_produccion_v95",{...aplicados,p_pagina:pag,p_por_pagina:POR_PAGINA}),
    ]);
    const fallo=r.error||d.error;
    if(fallo){setError(mensajeError(fallo, "v95_dashboard_produccion.sql"))}
    else{setResumen(r.data as Resumen);setDetalle(d.data as Detalle)}
    setCargando(false);
  },[aplicados,supabase]);

  useEffect(()=>{void cargar(pagina)},[cargar,pagina]);

  function aplicar(){if(!desde||!hasta||hasta<desde){void mostrarAvisoDialogo("Selecciona un rango de fechas válido.","Revisa las fechas");return}setPagina(1);setAplicados(parametros(desde,hasta,vendedor,estado,prioridad,incluir))}
  function preset(dias:number){const hoy=new Date();setDesde(isoLocal(hoy));const fin=new Date(hoy);fin.setDate(fin.getDate()+dias-1);setHasta(isoLocal(fin))}

  const cronograma=useMemo(()=>{const mapa=new Map<string,{fecha:string;prendas:number;capacidad:number;excede:boolean}>();resumen.cronograma.forEach(x=>{const actual=mapa.get(x.fecha)||{fecha:x.fecha,prendas:0,capacidad:0,excede:false};actual.prendas+=Number(x.prendas);actual.capacidad+=Number(x.capacidad);actual.excede=actual.excede||x.excede;mapa.set(x.fecha,actual)});return Array.from(mapa.values()).sort((a,b)=>a.fecha.localeCompare(b.fecha))},[resumen.cronograma]);
  const maxCronograma=Math.max(1,...cronograma.map(x=>Math.max(x.prendas,x.capacidad)));
  const maxPrenda=Math.max(1,...resumen.prendas.map(x=>Number(x.cantidad)));
  const maxVendedor=Math.max(1,...resumen.vendedores.map(x=>Number(x.contratos)));
  const totalPaginas=Math.max(1,Math.ceil(detalle.total/POR_PAGINA));

  async function exportarTodo(){setExportando(true);try{const todas:Contrato[]=[];let pag=1;while(true){const {data,error}=await supabase.rpc("listar_dashboard_produccion_v95",{...aplicados,p_pagina:pag,p_por_pagina:100});if(error)throw error;const bloque=data as Detalle;todas.push(...bloque.filas);if(todas.length>=bloque.total||!bloque.filas.length)break;pag++}exportarCSV(`dashboard_produccion_${aplicados.p_desde}_${aplicados.p_hasta}`,todas.map(c=>({Contrato:c.numero,Cliente:c.cliente,Vendedor:c.vendedor,Disenador:c.disenador,Estado:c.estado,Prioridad:c.prioridad,Inicio:c.fecha_inicio,Entrega:c.fecha_entrega,Prendas:c.total_prendas,Desglose:textoPrendas(c.prendas),Presupuesto:c.presupuesto,Abono:c.abono,Saldo:c.saldo})))}catch(e){await mostrarAvisoDialogo(e instanceof Error?e.message:"No se pudo exportar.","Error al exportar",true)}finally{setExportando(false)}}

  const tarjetas=[
    ["Contratos",ENTERO.format(resumen.kpis.contratos),"en el rango",false],
    ["Prendas",ENTERO.format(resumen.kpis.prendas),"unidades",false],
    ["Presupuesto",DINERO.format(resumen.kpis.presupuesto),"valor contratado",false],
    ["Abonos",DINERO.format(resumen.kpis.abonos),"valor recibido",false],
    ["Saldo",DINERO.format(resumen.kpis.saldo),"pendiente",false],
    ["Atrasados",ENTERO.format(resumen.kpis.atrasados),`${resumen.kpis.urgentes} urgentes`,resumen.kpis.atrasados>0],
  ] as const;

  return <>
    <header className={estilos.encabezado}><div><span className="eyebrow">BOMANSPORT</span><h1>Dashboard de producción</h1><p>Carga comercial, capacidad del taller, entregas y saldos desde la base sincronizada.</p></div><div className={`${estilos.acciones} ${estilos.noImprimir}`}><button className="secondary" onClick={()=>window.print()}>Imprimir</button><button className="secondary" disabled={exportando||!detalle.total} onClick={exportarTodo}>{exportando?"Preparando…":"Exportar Excel"}</button><button onClick={()=>void cargar(pagina)} disabled={cargando}>{cargando?"Actualizando…":"Actualizar"}</button></div></header>

    <section className={`card ${estilos.noImprimir}`}><div className={estilos.filtros}>
      <div className="field"><label>Rango de entrega</label><div className={estilos.rango}><input type="date" value={desde} onChange={e=>setDesde(e.target.value)}/><input type="date" value={hasta} onChange={e=>setHasta(e.target.value)}/></div><div className={estilos.acciones} style={{marginTop:7}}><button className="secondary btn-mini" onClick={()=>preset(7)}>7 días</button><button className="secondary btn-mini" onClick={()=>preset(30)}>30 días</button><button className="secondary btn-mini" onClick={()=>{const r=rangoMes();setDesde(r.desde);setHasta(r.hasta)}}>Este mes</button></div></div>
      <div className="field"><label>Vendedor</label><select value={vendedor} onChange={e=>setVendedor(e.target.value)}><option value="">Todos</option>{resumen.filtros.vendedores.map(v=><option key={v}>{v}</option>)}</select></div>
      <div className="field"><label>Estado</label><select value={estado} onChange={e=>setEstado(e.target.value)}><option value="">Todos</option>{resumen.filtros.estados.map(v=><option key={v}>{v}</option>)}</select></div>
      <div className="field"><label>Prioridad</label><select value={prioridad} onChange={e=>setPrioridad(e.target.value)}><option value="">Todas</option><option>Normal</option><option>Urgente</option></select><label style={{fontWeight:500,marginTop:7}}><input type="checkbox" checked={incluir} onChange={e=>setIncluir(e.target.checked)} style={{marginRight:6}}/>Incluir entregados</label></div>
      <button onClick={aplicar}>Aplicar</button>
    </div><div className={estilos.actualizacion}><span>Última sincronización: {fechaHora(resumen.ultima_actualizacion)}</span><span>{detalle.total} contrato(s) encontrados</span></div></section>

    {error&&<div className="error-box">{error}</div>}
    <div className={estilos.kpis}>{tarjetas.map(([etiqueta,valor,pie,alerta])=><div className={`${estilos.kpi} ${alerta?estilos.alerta:""}`} key={etiqueta}><span>{etiqueta}</span><strong>{valor}</strong><small>{pie}</small></div>)}</div>

    <div className={estilos.rejilla}>
      <section className="card"><div className={estilos.titulo}><h2>Prendas a producir</h2><span>excluye accesorios comprados</span></div>{resumen.prendas.length?<div className={estilos.barras}>{resumen.prendas.slice(0,14).map(p=><div className={estilos.barraFila} key={p.prenda}><span className={estilos.barraNombre} title={p.prenda}>{p.prenda}</span><div className={estilos.barraPista}><div className={estilos.barraValor} style={{width:`${Math.max(2,Number(p.cantidad)*100/maxPrenda)}%`}}/></div><span className={estilos.barraNumero}>{ENTERO.format(p.cantidad)}</span></div>)}</div>:<div className={estilos.vacio}>Sin prendas en el rango. La sincronización v94 debe cargar el desglose.</div>}</section>
      <section className="card"><div className={estilos.titulo}><h2>Contratos por estado</h2><span>{resumen.kpis.contratos} total</span></div><div className={estilos.estados}>{resumen.estados.map(e=><div className={estilos.estado} key={e.estado}><span>{e.estado}</span><strong>{e.cantidad}</strong></div>)}</div>{!resumen.estados.length&&<div className={estilos.vacio}>Sin estados para mostrar.</div>}</section>
    </div>

    <section className="card" style={{marginBottom:16}}><div className={estilos.titulo}><h2>Carga por fecha de inicio</h2><span>{cronograma.length} días planificados</span></div><div className={estilos.leyenda}><span><i className={estilos.punto}/>Dentro de capacidad</span><span><i className={`${estilos.punto} ${estilos.puntoRojo}`}/>Sobrecarga</span></div>{cronograma.length?<div className={estilos.timeline}>{cronograma.map(d=><div className={estilos.dia} key={d.fecha} title={`${d.prendas} prendas · capacidad ${d.capacidad}`}><b>{d.prendas||""}</b><div className={estilos.columna}><i className={d.excede?estilos.excede:""} style={{height:`${Math.max(3,d.prendas*115/maxCronograma)}px`}}/></div><small>{fechaCorta(d.fecha)}</small></div>)}</div>:<div className={estilos.vacio}>Los contratos del rango no tienen fecha de inicio asignada.</div>}</section>

    <div className={estilos.rejilla}>
      <section className="card"><div className={estilos.titulo}><h2>Contratos por vendedor</h2><span>primeros 12</span></div><div className={estilos.barras}>{resumen.vendedores.map(v=><div className={estilos.barraFila} key={v.vendedor}><span className={estilos.barraNombre}>{v.vendedor}</span><div className={estilos.barraPista}><div className={estilos.barraValor} style={{width:`${Math.max(2,v.contratos*100/maxVendedor)}%`}}/></div><span className={estilos.barraNumero}>{v.contratos}</span></div>)}</div></section>
      <section className="card"><div className={estilos.titulo}><h2>Próximas entregas</h2><span>7 días</span></div>{resumen.proximas_entregas.length?<div className="tabla-scroll"><table><tbody>{resumen.proximas_entregas.map(e=><tr key={e.numero}><td><strong>{e.numero}</strong><small style={{display:"block"}}>{e.cliente}</small></td><td>{fechaCorta(e.fecha_entrega)}</td><td className={e.dias_restantes<=1?estilos.urgente:""}>{e.dias_restantes===0?"Hoy":`${e.dias_restantes} d`}</td><td className="num">{e.total_prendas}</td></tr>)}</tbody></table></div>:<div className={estilos.vacio}>Sin entregas durante los próximos 7 días.</div>}</section>
    </div>

    <section className="card"><div className={estilos.titulo}><h2>Contratos del período</h2><span>Página {pagina} de {totalPaginas}</span></div>{cargando?<div className={estilos.vacio}>Calculando el dashboard…</div>:<div className="tabla-scroll"><table><thead><tr><th>Contrato</th><th>Estado</th><th>Inicio / entrega</th><th>Diseñador</th><th>Prendas</th><th className="num">Presupuesto</th><th className="num">Saldo</th></tr></thead><tbody>{detalle.filas.map(c=><tr key={c.id} className={c.atrasado?estilos.atrasado:""}><td><div className={estilos.contrato}>{c.mockup_drive_id&&<img className={estilos.tablaFoto} loading="lazy" alt="" src={`https://drive.google.com/thumbnail?id=${c.mockup_drive_id}&sz=w160`}/>}<div><strong className={c.prioridad==="Urgente"?estilos.urgente:""}>{c.prioridad==="Urgente"?"● ":""}{c.numero}</strong><span>{c.cliente}</span><small>{c.vendedor||"Sin vendedor"}</small></div></div></td><td><span className={`badge ${c.atrasado?"bajo":"ok"}`}>{c.estado}</span></td><td><span>{fechaCorta(c.fecha_inicio)}</span><small style={{display:"block"}}>Entrega {fechaCorta(c.fecha_entrega)} · {c.dias_restantes===0?"hoy":`${c.dias_restantes} d`}</small></td><td>{c.disenador||<span className="conteo">Sin asignar</span>}</td><td><strong>{c.total_prendas}</strong><div className={estilos.desglose}>{textoPrendas(c.prendas)}</div></td><td className="num">{DINERO.format(c.presupuesto)}</td><td className="num"><strong>{DINERO.format(c.saldo)}</strong></td></tr>)}{!detalle.filas.length&&<tr><td colSpan={7} className={estilos.vacio}>No hay contratos con estos filtros.</td></tr>}</tbody></table></div>}{totalPaginas>1&&<div className={`${estilos.paginacion} ${estilos.noImprimir}`}><button className="secondary" disabled={pagina<=1||cargando} onClick={()=>setPagina(p=>Math.max(1,p-1))}>Anterior</button><span>Página {pagina} de {totalPaginas}</span><button className="secondary" disabled={pagina>=totalPaginas||cargando} onClick={()=>setPagina(p=>Math.min(totalPaginas,p+1))}>Siguiente</button></div>}</section>
  </>;
}
