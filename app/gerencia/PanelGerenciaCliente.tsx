"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import { createClient } from "@/lib/supabase/client";
import styles from "./Gerencia.module.css";

type Accesos = {
  modoBoman:boolean; comercial:boolean; produccion:boolean; costos:boolean;
  contratos:boolean; cartera:boolean; finanzasContratos:boolean; franquicias:boolean;
  inventario:boolean; reportes:boolean; tesoreria:boolean; nomina:boolean; mantenimiento:boolean;
};
type Comercial = {
  kpis:{ contratos:number; produccion_vendida:number; facturado:number; cobrado:number; saldo:number; entregados:number; a_tiempo:number; comision_futura:number };
  vendedores:Array<{ vendedor:string; contratos:number; prendas:number; facturado:number; cobrado:number; saldo:number; entregados:number; a_tiempo:number }>;
};
type Produccion = {
  kpis:{ contratos:number; prendas:number; presupuesto:number; abonos:number; saldo:number; atrasados:number; urgentes:number };
  cronograma:Array<{ fecha:string; prendas:number; capacidad:number; excede:boolean }>;
  proximas_entregas:Array<{ numero:string; cliente:string; fecha_entrega:string; dias_restantes:number; total_prendas:number }>;
};
type PanelBase = {
  inventario:{ stock_fisico:number; stock_disponible:number; productos_bajo_minimo:number; unidades_sugeridas:number };
  operaciones:{ solicitudes_pendientes:number; transferencias_preparar:number; transferencias_recibir:number; conteos_revision:number };
  compras:{ pendientes_aprobacion:number; pendientes_recepcion:number };
  produccion:{ pendientes_aprobacion:number; ordenes_activas:number; ordenes_atrasadas:number };
  nomina:{ empleados_activos:number; ausencias_solicitadas:number; documentos_por_vencer:number; documentos_vencidos:number; periodos_pendientes:number };
};
type Calidad = { estado:string; prioridad:string; costo_real:number|null; costo_estimado:number; solicita_descuento:boolean; novedad_empleado_id:string|null };
type CuentaPagar = { estado:string; saldo_pendiente:number; total_comprometido:number };
type Franquicia = { total_vendido:number; resultado_operativo:number; cierres_pendientes:number; productos_bajo_minimo:number; alertas_activas:number };
type Mantenimiento = { activos:number; detenidos:number; vencidos:number; proximos:number; ordenes_abiertas:number; ordenes_atrasadas:number };
type Datos = {
  panel:PanelBase; comercial:Comercial|null; comercialAnterior:Comercial|null;
  produccion:Produccion|null; produccionAnterior:Produccion|null;
  calidad:Calidad[]; cuentas:CuentaPagar[]; franquicias:Franquicia[];
  mantenimiento:Mantenimiento|null;
};
type Reporte = { grupo:string; titulo:string; descripcion:string; href:string; visible:boolean; clave:string };

const USD = new Intl.NumberFormat("es-EC",{style:"currency",currency:"USD",maximumFractionDigits:0});
const NUM = new Intl.NumberFormat("es-EC",{maximumFractionDigits:0});
const VACIO_PANEL:PanelBase={inventario:{stock_fisico:0,stock_disponible:0,productos_bajo_minimo:0,unidades_sugeridas:0},operaciones:{solicitudes_pendientes:0,transferencias_preparar:0,transferencias_recibir:0,conteos_revision:0},compras:{pendientes_aprobacion:0,pendientes_recepcion:0},produccion:{pendientes_aprobacion:0,ordenes_activas:0,ordenes_atrasadas:0},nomina:{empleados_activos:0,ausencias_solicitadas:0,documentos_por_vencer:0,documentos_vencidos:0,periodos_pendientes:0}};
const VACIO:Datos={panel:VACIO_PANEL,comercial:null,comercialAnterior:null,produccion:null,produccionAnterior:null,calidad:[],cuentas:[],franquicias:[],mantenimiento:null};

function iso(d:Date){return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`}
function hoy(){return iso(new Date())}
function inicioMes(){const d=new Date();d.setDate(1);return iso(d)}
function periodoAnterior(desde:string,hasta:string){const a=new Date(`${desde}T12:00:00`);const b=new Date(`${hasta}T12:00:00`);const dias=Math.round((b.getTime()-a.getTime())/86400000)+1;const fin=new Date(a);fin.setDate(fin.getDate()-1);const inicio=new Date(fin);inicio.setDate(inicio.getDate()-dias+1);return {desde:iso(inicio),hasta:iso(fin)}}
function n(valor:unknown){const numero=Number(valor);return Number.isFinite(numero)?numero:0}
function variacion(actual:number,anterior:number){if(!anterior)return actual>0?100:0;return Math.round((actual-anterior)/Math.abs(anterior)*100)}
function fechaCorta(valor:string){return new Intl.DateTimeFormat("es-EC",{day:"2-digit",month:"short",timeZone:"America/Guayaquil"}).format(new Date(`${valor}T12:00:00`))}

export default function PanelGerenciaCliente({accesos}:{accesos:Accesos}){
  const supabase=useMemo(()=>createClient(),[]);
  const[desde,setDesde]=useState(inicioMes);const[hasta,setHasta]=useState(hoy);
  const[rango,setRango]=useState({desde:inicioMes(),hasta:hoy()});
  const[datos,setDatos]=useState<Datos>(VACIO);const[cargando,setCargando]=useState(true);
  const[actualizado,setActualizado]=useState("");const[busqueda,setBusqueda]=useState("");

  const cargar=useCallback(async(manual=false)=>{
    setCargando(true);const anterior=periodoAnterior(rango.desde,rango.hasta);
    const neutro=Promise.resolve({data:null,error:null});
    const [panel,comercial,comercialPrev,produccion,produccionPrev,calidad,cuentas,franquicias,mantenimiento]=await Promise.all([
      supabase.rpc("resumen_panel_principal_v51"),
      accesos.modoBoman&&accesos.comercial?supabase.rpc("consolidado_comercial_v115",{p_desde:rango.desde,p_hasta:rango.hasta,p_vendedores:null,p_almacenes:null,p_canales:null}):neutro,
      accesos.modoBoman&&accesos.comercial?supabase.rpc("consolidado_comercial_v115",{p_desde:anterior.desde,p_hasta:anterior.hasta,p_vendedores:null,p_almacenes:null,p_canales:null}):neutro,
      accesos.produccion&&accesos.modoBoman?supabase.rpc("resumen_dashboard_produccion_v95",{p_desde:rango.desde,p_hasta:rango.hasta,p_vendedor:null,p_estado:null,p_prioridad:null,p_incluir_entregados:true}):neutro,
      accesos.produccion&&accesos.modoBoman?supabase.rpc("resumen_dashboard_produccion_v95",{p_desde:anterior.desde,p_hasta:anterior.hasta,p_vendedor:null,p_estado:null,p_prioridad:null,p_incluir_entregados:true}):neutro,
      accesos.produccion?supabase.from("vista_novedades_calidad_v74").select("estado,prioridad,costo_real,costo_estimado,solicita_descuento,novedad_empleado_id").gte("fecha_hora",`${rango.desde}T00:00:00-05:00`).lte("fecha_hora",`${rango.hasta}T23:59:59-05:00`):neutro,
      accesos.tesoreria?supabase.from("vista_cuentas_por_pagar_v73").select("estado,saldo_pendiente,total_comprometido"):neutro,
      accesos.franquicias&&accesos.modoBoman?supabase.rpc("resumen_consolidado_franquicias_v62",{p_desde:rango.desde,p_hasta:rango.hasta}):neutro,
      accesos.mantenimiento?supabase.rpc("resumen_mantenimiento_v54"):neutro,
    ]);
    const resultados=[panel,comercial,comercialPrev,produccion,produccionPrev,calidad,cuentas,franquicias,mantenimiento];
    const fallos=resultados.flatMap((resultado)=>resultado.error?[resultado.error.message]:[]);
    setDatos({
      panel:(panel.data as PanelBase|null)??VACIO_PANEL,
      comercial:comercial.data as Comercial|null,comercialAnterior:comercialPrev.data as Comercial|null,
      produccion:produccion.data as Produccion|null,produccionAnterior:produccionPrev.data as Produccion|null,
      calidad:(calidad.data as Calidad[]|null)??[],cuentas:(cuentas.data as CuentaPagar[]|null)??[],
      franquicias:(franquicias.data as Franquicia[]|null)??[],mantenimiento:mantenimiento.data as Mantenimiento|null,
    });
    setActualizado(new Date().toISOString());setCargando(false);
    if(manual&&fallos.length)await mostrarAvisoDialogo(`El panel se actualizó parcialmente. ${[...new Set(fallos)].join(" · ")}`,"Algunos indicadores no cargaron",true);
  },[accesos,rango,supabase]);
  useEffect(()=>{void cargar()},[cargar]);

  function aplicar(){if(!desde||!hasta||hasta<desde){void mostrarAvisoDialogo("Selecciona un rango de fechas válido.","Revisa las fechas",true);return}const dias=(new Date(hasta).getTime()-new Date(desde).getTime())/86400000;if(dias>366){void mostrarAvisoDialogo("El panel admite hasta 367 días por consulta.","Rango demasiado amplio",true);return}setRango({desde,hasta})}

  const resumen=useMemo(()=>{
    const comercial=datos.comercial?.kpis;const comercialPrev=datos.comercialAnterior?.kpis;
    const produccion=datos.produccion?.kpis;const produccionPrev=datos.produccionAnterior?.kpis;
    const calidadAbierta=datos.calidad.filter(x=>!["cerrada","anulada"].includes(x.estado)).length;
    const calidadUrgente=datos.calidad.filter(x=>x.prioridad==="urgente"&&!["cerrada","anulada"].includes(x.estado)).length;
    const descuentosPendientes=datos.calidad.filter(x=>x.estado==="cerrada"&&x.solicita_descuento&&!x.novedad_empleado_id).length;
    const costoCalidad=datos.calidad.filter(x=>x.estado!=="anulada").reduce((s,x)=>s+n(x.costo_real??x.costo_estimado),0);
    const vencidas=datos.cuentas.filter(x=>x.estado==="vencida");
    const totalFranquicias=datos.franquicias.reduce((s,x)=>s+n(x.total_vendido),0);
    const resultadoFranquicias=datos.franquicias.reduce((s,x)=>s+n(x.resultado_operativo),0);
    return {comercial,produccion,calidadAbierta,calidadUrgente,descuentosPendientes,costoCalidad,
      saldoVencido:vencidas.reduce((s,x)=>s+n(x.saldo_pendiente),0),cuentasVencidas:vencidas.length,
      efectivoComprometido:datos.cuentas.reduce((s,x)=>s+n(x.total_comprometido),0),totalFranquicias,resultadoFranquicias,
      cierresPendientes:datos.franquicias.reduce((s,x)=>s+n(x.cierres_pendientes),0),
      variacionVentas:variacion(n(comercial?.facturado),n(comercialPrev?.facturado)),
      variacionContratos:variacion(n(comercial?.contratos),n(comercialPrev?.contratos)),
      variacionPrendas:variacion(n(produccion?.prendas),n(produccionPrev?.prendas))};
  },[datos]);

  const alertas=useMemo(()=>[
    {titulo:"Saldo por cobrar",valor:USD.format(n(resumen.comercial?.saldo)),detalle:"Contratos del período",href:"/ventas/cartera",nivel:n(resumen.comercial?.saldo)>0?"atencion":"ok",visible:accesos.cartera},
    {titulo:"Producción atrasada",valor:NUM.format(n(resumen.produccion?.atrasados)),detalle:"Contratos fuera de fecha",href:"/produccion/dashboard",nivel:n(resumen.produccion?.atrasados)>0?"critico":"ok",visible:accesos.produccion},
    {titulo:"Calidad abierta",valor:NUM.format(resumen.calidadAbierta),detalle:`${resumen.calidadUrgente} urgentes · ${USD.format(resumen.costoCalidad)} de costo`,href:"/produccion/calidad",nivel:resumen.calidadUrgente>0?"critico":resumen.calidadAbierta>0?"atencion":"ok",visible:accesos.produccion},
    {titulo:"Facturas vencidas",valor:USD.format(resumen.saldoVencido),detalle:`${resumen.cuentasVencidas} cuentas de proveedores`,href:"/cuentas-por-pagar",nivel:resumen.cuentasVencidas>0?"critico":"ok",visible:accesos.tesoreria},
    {titulo:"Stock bajo mínimo",valor:NUM.format(datos.panel.inventario.productos_bajo_minimo),detalle:`${NUM.format(datos.panel.inventario.unidades_sugeridas)} unidades sugeridas`,href:"/inventario",nivel:datos.panel.inventario.productos_bajo_minimo>0?"atencion":"ok",visible:accesos.inventario},
    {titulo:"Cierres pendientes",valor:NUM.format(resumen.cierresPendientes),detalle:"Locales sin conciliación",href:"/franquicias/consolidado",nivel:resumen.cierresPendientes>0?"critico":"ok",visible:accesos.franquicias&&accesos.modoBoman},
  ].filter(x=>x.visible),[accesos,datos.panel.inventario,resumen]);

  const reportes:Reporte[]=[
    {grupo:"Dirección",titulo:"Panel principal",descripcion:"Pendientes y actividad diaria de toda la operación.",href:"/dashboard",visible:true,clave:"inicio"},
    {grupo:"Comercial",titulo:"Consolidado comercial",descripcion:"Facturado, cobrado, saldo, entregas y comisiones por vendedor, tienda y canal.",href:"/reportes/comercial",visible:accesos.modoBoman&&accesos.comercial,clave:"comercial"},
    {grupo:"Comercial",titulo:"Panel de vendedores",descripcion:"Contratos, mockups, prendas, fechas de entrega y saldos por asesor.",href:"/ventas/seguimiento",visible:accesos.modoBoman&&accesos.contratos,clave:"vendedores"},
    {grupo:"Comercial",titulo:"Cuentas por cobrar",descripcion:"Cartera de contratos, promesas, abonos y vencimientos.",href:"/ventas/cartera",visible:accesos.modoBoman&&accesos.cartera,clave:"cxc"},
    {grupo:"Producción",titulo:"Tablero de contratos",descripcion:"Vista visual del avance de cada contrato por etapa.",href:"/tablero",visible:accesos.modoBoman&&accesos.produccion,clave:"tablero"},
    {grupo:"Producción",titulo:"Dashboard de producción",descripcion:"Carga, capacidad, atrasos, entregas y saldos del taller.",href:"/produccion/dashboard",visible:accesos.modoBoman&&accesos.produccion,clave:"produccion"},
    {grupo:"Producción",titulo:"Reportes de producción",descripcion:"Producción por día, prenda, diseñador y contrato.",href:"/produccion/reportes",visible:accesos.produccion,clave:"reporte-produccion"},
    {grupo:"Rentabilidad",titulo:"Costos y rentabilidad",descripcion:"Costo, margen y resultado económico por contrato.",href:"/produccion/costos",visible:accesos.modoBoman&&accesos.costos,clave:"rentabilidad"},
    {grupo:"Finanzas",titulo:"Presupuestos y cobros",descripcion:"Abonos, saldos e historial financiero de contratos.",href:"/produccion/cobros",visible:accesos.modoBoman&&accesos.finanzasContratos,clave:"cobros"},
    {grupo:"Finanzas",titulo:"Cuentas por pagar",descripcion:"Vencimientos, cheques y efectivo comprometido con proveedores.",href:"/cuentas-por-pagar",visible:accesos.tesoreria,clave:"cxp"},
    {grupo:"Inventario",titulo:"Reportes de inventario",descripcion:"Valoración, rotación, cobertura, reposición y trazabilidad.",href:"/reportes",visible:accesos.reportes,clave:"inventario"},
    {grupo:"Locales",titulo:"Consolidado de locales",descripcion:"Ventas, caja, diferencias, inventario y alertas por local.",href:"/franquicias/consolidado",visible:accesos.modoBoman&&accesos.franquicias,clave:"locales"},
    {grupo:"Control",titulo:"Calidad y errores",descripcion:"Reprocesos, causas, costos y solicitudes de descuento.",href:"/produccion/calidad",visible:accesos.produccion,clave:"calidad"},
    {grupo:"Personas",titulo:"Nómina y talento humano",descripcion:"Personal, ausencias, documentos, novedades y reportes de roles.",href:"/nomina",visible:accesos.nomina,clave:"nomina"},
    {grupo:"Activos",titulo:"Mantenimiento",descripcion:"Disponibilidad, paradas, vencimientos y costos de maquinaria.",href:"/mantenimiento",visible:accesos.mantenimiento,clave:"mantenimiento"},
  ];
  const q=busqueda.trim().toLocaleLowerCase("es");const reportesVisibles=reportes.filter(x=>x.visible&&(!q||`${x.grupo} ${x.titulo} ${x.descripcion}`.toLocaleLowerCase("es").includes(q)));
  const maxVendedor=Math.max(1,...(datos.comercial?.vendedores??[]).map(x=>n(x.facturado)));
  const cobro=n(resumen.comercial?.facturado)?Math.round(n(resumen.comercial?.cobrado)/n(resumen.comercial?.facturado)*100):0;
  const cumplimiento=n(resumen.comercial?.entregados)?Math.round(n(resumen.comercial?.a_tiempo)/n(resumen.comercial?.entregados)*100):0;

  return <section className={styles.pagina}>
    <header className={styles.hero}>
      <div><span className={styles.kicker}>CENTRO DE DECISIONES</span><h1>Panel de Gerencia</h1><p>Ventas, caja, producción, cartera, calidad e inventario en un solo lugar.</p></div>
      <div className={styles.actualizacion}><span>Última actualización</span><strong>{actualizado?new Intl.DateTimeFormat("es-EC",{hour:"2-digit",minute:"2-digit",timeZone:"America/Guayaquil"}).format(new Date(actualizado)):"—"}</strong><div className={styles.heroAcciones}><button className="secondary" onClick={()=>window.print()}>Imprimir</button><button onClick={()=>void cargar(true)} disabled={cargando}>{cargando?"Actualizando…":"Actualizar"}</button></div></div>
    </header>
    <section className={styles.filtros}><div className="field"><label>Desde</label><input type="date" value={desde} max={hasta} onChange={e=>setDesde(e.target.value)}/></div><div className="field"><label>Hasta</label><input type="date" value={hasta} min={desde} max={hoy()} onChange={e=>setHasta(e.target.value)}/></div><button onClick={aplicar} disabled={cargando}>Aplicar período</button><span>Compara automáticamente con el período anterior equivalente.</span></section>

    <section className={styles.kpis} aria-busy={cargando}>
      <Kpi titulo="Facturado" valor={USD.format(n(resumen.comercial?.facturado))} cambio={resumen.variacionVentas} detalle={`${NUM.format(n(resumen.comercial?.contratos))} contratos · ${resumen.variacionContratos>=0?"+":""}${resumen.variacionContratos}%`}/>
      <Kpi titulo="Cobrado" valor={USD.format(n(resumen.comercial?.cobrado))} detalle={`${cobro}% de recuperación`}/>
      <Kpi titulo="Saldo por cobrar" valor={USD.format(n(resumen.comercial?.saldo))} detalle="Del período seleccionado" alerta={n(resumen.comercial?.saldo)>0}/>
      <Kpi titulo="Prendas programadas" valor={NUM.format(n(resumen.produccion?.prendas))} cambio={resumen.variacionPrendas} detalle={`${NUM.format(n(resumen.produccion?.contratos))} contratos en producción`}/>
      <Kpi titulo="Entregas a tiempo" valor={`${cumplimiento}%`} detalle={`${NUM.format(n(resumen.comercial?.a_tiempo))} de ${NUM.format(n(resumen.comercial?.entregados))} entregas`}/>
      <Kpi titulo="Resultado de locales" valor={USD.format(resumen.resultadoFranquicias)} detalle={`${USD.format(resumen.totalFranquicias)} vendidos`} alerta={resumen.resultadoFranquicias<0}/>
    </section>

    <section className={styles.bloque}><div className={styles.titulo}><div><span>ATENCIÓN GERENCIAL</span><h2>Qué requiere una decisión</h2></div><small>Los indicadores verdes están controlados.</small></div><div className={styles.alertas}>{alertas.map(a=><Link href={a.href} key={a.titulo} className={`${styles.alerta} ${styles[a.nivel]}`}><span>{a.titulo}</span><strong>{a.valor}</strong><small>{a.detalle}</small><b>Abrir detalle →</b></Link>)}</div></section>

    <div className={styles.dosColumnas}>
      <section className={styles.bloque}><div className={styles.titulo}><div><span>DESEMPEÑO COMERCIAL</span><h2>Vendedores por facturación</h2></div><Link href="/ventas/seguimiento">Ver panel completo</Link></div><div className={styles.ranking}>{(datos.comercial?.vendedores??[]).slice(0,6).map((v,i)=><div className={styles.vendedor} key={v.vendedor}><i>{i+1}</i><div><strong>{v.vendedor||"Sin vendedor"}</strong><span><b style={{width:`${Math.max(3,n(v.facturado)/maxVendedor*100)}%`}}/></span><small>{NUM.format(n(v.contratos))} contratos · {NUM.format(n(v.prendas))} prendas</small></div><em>{USD.format(n(v.facturado))}</em></div>)}{!datos.comercial?.vendedores?.length&&<Vacio cargando={cargando}/>}</div></section>
      <section className={styles.bloque}><div className={styles.titulo}><div><span>PRÓXIMOS 7 DÍAS</span><h2>Entregas y capacidad</h2></div><Link href="/produccion/dashboard">Ver producción</Link></div><div className={styles.entregas}>{(datos.produccion?.proximas_entregas??[]).slice(0,6).map(e=><div key={e.numero}><time>{fechaCorta(e.fecha_entrega)}</time><span><strong>{e.numero}</strong><small>{e.cliente} · {NUM.format(n(e.total_prendas))} prendas</small></span><b className={n(e.dias_restantes)<=1?styles.urgente:""}>{n(e.dias_restantes)===0?"Hoy":`${e.dias_restantes} d`}</b></div>)}{!datos.produccion?.proximas_entregas?.length&&<Vacio cargando={cargando}/>}</div><div className={styles.capacidad}><span>Días con sobrecarga en el período</span><strong>{NUM.format((datos.produccion?.cronograma??[]).filter(x=>x.excede).length)}</strong></div></section>
    </div>

    <section className={styles.bloque}><div className={styles.titulo}><div><span>BIBLIOTECA EJECUTIVA</span><h2>Todos los tableros y reportes</h2></div><div className={styles.buscar}><input type="search" value={busqueda} onChange={e=>setBusqueda(e.target.value)} placeholder="Buscar reporte…"/><b>{reportesVisibles.length}</b></div></div><div className={styles.reportes}>{reportesVisibles.map(r=><Link href={r.href} key={r.clave}><span>{r.grupo}</span><strong>{r.titulo}</strong><p>{r.descripcion}</p><b>Abrir reporte →</b></Link>)}</div>{!reportesVisibles.length&&<div className={styles.vacio}>No hay reportes que coincidan con la búsqueda.</div>}</section>
  </section>;
}

function Kpi({titulo,valor,detalle,cambio,alerta=false}:{titulo:string;valor:string;detalle:string;cambio?:number;alerta?:boolean}){return <article className={alerta?styles.kpiAlerta:""}><span>{titulo}</span><strong>{valor}</strong><small>{detalle}</small>{cambio!==undefined&&<em className={cambio>=0?styles.sube:styles.baja}>{cambio>=0?"↑":"↓"} {Math.abs(cambio)}% vs. período anterior</em>}</article>}
function Vacio({cargando}:{cargando:boolean}){return <div className={styles.vacio}>{cargando?"Calculando indicadores…":"Sin datos en este período."}</div>}
