import estilos from "./Contratos.module.css";

export type Expediente = {
  contrato: Record<string, any>;
  prendas: Array<Record<string, any>>;
  jugadores: Array<Record<string, any>>;
  archivos: Array<Record<string, any>>;
  especificaciones: Array<Record<string, any>>;
  facturacion?: Array<Record<string, any>>;
  etapas?: Array<Record<string, any>>;
  eventos?: Array<Record<string, any>>;
  enlaces?: Array<Record<string, any>>;
};

const DINERO=new Intl.NumberFormat("es-EC",{style:"currency",currency:"USD"});
function f(valor:unknown){if(!valor)return "—";const s=String(valor);if(/^\d{4}-\d{2}-\d{2}$/.test(s))return new Intl.DateTimeFormat("es-EC",{dateStyle:"medium",timeZone:"UTC"}).format(new Date(`${s}T12:00:00Z`));return s}
function fh(valor:unknown){if(!valor)return "—";return new Intl.DateTimeFormat("es-EC",{dateStyle:"medium",timeStyle:"short",timeZone:"America/Guayaquil"}).format(new Date(String(valor)))}
function titulo(clave:string){return clave.replace(/_/g," ").replace(/^./,x=>x.toUpperCase())}
function limpio(obj:Record<string,any>){return Object.fromEntries(Object.entries(obj||{}).filter(([k,v])=>!['id','contrato_id','orden'].includes(k)&&v!==null&&v!==""&&!(Array.isArray(v)&&!v.length)&&!(typeof v==='object'&&v&&!Array.isArray(v)&&!Object.keys(v).length)))}

export default function ExpedienteContrato({datos,publico=false}:{datos:Expediente;publico?:boolean}){
  const c=datos.contrato||{};
  const mockups=datos.archivos.filter(a=>a.tipo==="mockup");
  const logos=datos.archivos.filter(a=>a.tipo==="logo");
  const totalFact=(datos.facturacion||[]).reduce((s,x)=>s+Number(x.cantidad||0),0);
  return <div className={estilos.expediente}>
    <div className={estilos.resumen}>
      <div className={estilos.dato}><span>Contrato</span><strong>{c.numero}</strong></div>
      <div className={estilos.dato}><span>Cliente / equipo</span><strong>{c.cliente||"—"}</strong></div>
      <div className={estilos.dato}><span>Entrega</span><strong>{f(c.fecha_entrega)}</strong></div>
      <div className={estilos.dato}><span>Estado</span><strong>{c.estado||"—"}</strong></div>
      <div className={estilos.dato}><span>Prendas</span><strong>{c.total_prendas||0}</strong></div>
      <div className={estilos.dato}><span>Prioridad</span><strong>{c.prioridad||"Normal"}</strong></div>
      <div className={estilos.dato}><span>Tipo</span><strong>{c.tipo_contrato||"Normal"}</strong></div>
      <div className={estilos.dato}><span>Diseño</span><strong>{c.estado_mockup||"Sin estado"}</strong></div>
      {!publico&&<><div className={estilos.dato}><span>Vendedor</span><strong>{c.vendedor||"—"}</strong></div><div className={estilos.dato}><span>Diseñador</span><strong>{c.disenador||"—"}</strong></div><div className={estilos.dato}><span>Presupuesto</span><strong>{DINERO.format(Number(c.presupuesto||0))}</strong></div><div className={estilos.dato}><span>Saldo</span><strong>{DINERO.format(Math.max(0,Number(c.presupuesto||0)-Number(c.abono||0)))}</strong></div></>}
    </div>

    <div className={estilos.rejilla}>
      <section className={estilos.seccion}><h3>Prendas y tallas</h3>{datos.prendas.length?<div className="tabla-scroll"><table><thead><tr><th>Prenda</th><th>Calidad</th><th>Género</th><th>Talla</th><th className="num">Cantidad</th></tr></thead><tbody>{datos.prendas.map((x,i)=><tr key={x.id||i}><td>{x.prenda}</td><td>{x.calidad||"—"}</td><td>{x.genero}</td><td>{x.talla}</td><td className="num"><strong>{x.cantidad}</strong></td></tr>)}</tbody></table></div>:<div className={estilos.vacio}>Sin desglose de prendas.</div>}</section>
      <section className={estilos.seccion}><h3>Jugadores</h3>{datos.jugadores.length?<div className="tabla-scroll"><table><thead><tr><th>Nombre</th><th>Número</th><th>Categoría</th><th>Tallas</th></tr></thead><tbody>{datos.jugadores.map((x,i)=><tr key={x.id||i}><td>{x.nombre||"—"}</td><td>{x.numero||"—"}</td><td>{x.categoria||"—"}</td><td>{[x.talla_superior,x.talla_inferior].filter(Boolean).join(" / ")||"—"}</td></tr>)}</tbody></table></div>:<div className={estilos.vacio}>Sin nómina de jugadores.</div>}</section>

      <section className={`${estilos.seccion} ${estilos.seccionCompleta}`}><h3>Mockups</h3>{mockups.length?<div className={estilos.imagenes}>{mockups.map((x,i)=>{const src=x.drive_id?`https://drive.google.com/thumbnail?id=${x.drive_id}&sz=w1000`:x.url;return <a className={estilos.imagen} href={x.url||src} target="_blank" rel="noreferrer" key={x.id||i}>{/* eslint-disable-next-line @next/next/no-img-element */}<img src={src} alt={x.descripcion||"Mockup"}/><span><strong>{x.descripcion||`Mockup ${i+1}`}</strong>{x.color?` · ${x.color}`:""}</span></a>})}</div>:<div className={estilos.vacio}>No hay mockups sincronizados.</div>}</section>

      <section className={estilos.seccion}><h3>Logos y aplicaciones</h3>{logos.length?<div className={estilos.imagenes}>{logos.map((x,i)=>{const src=x.drive_id?`https://drive.google.com/thumbnail?id=${x.drive_id}&sz=w600`:x.url;return <a className={estilos.imagen} href={x.url||src} target="_blank" rel="noreferrer" key={x.id||i}>{/* eslint-disable-next-line @next/next/no-img-element */}<img src={src} alt={x.descripcion||"Logo"}/><span>{x.descripcion||"Logo"}{x.posicion?` · ${x.posicion}`:""}{x.tecnica?` · ${x.tecnica}`:""}</span></a>})}</div>:<div className={estilos.vacio}>Sin logos adjuntos.</div>}</section>
      <section className={estilos.seccion}><h3>Indicaciones</h3><div className={estilos.json}>{['forma_entrega','direccion','instrucciones','autorizacion_produccion','observaciones_lili','nombre_tecnica','numero_tecnica','sellos_tpu','ubicacion_tpu','bordado'].filter(k=>c[k]).map(k=><div className={estilos.jsonBloque} key={k}><strong>{titulo(k)}</strong><div>{String(c[k])}</div></div>)}{!['forma_entrega','direccion','instrucciones','autorizacion_produccion','observaciones_lili','nombre_tecnica','numero_tecnica','sellos_tpu','ubicacion_tpu','bordado'].some(k=>c[k])&&<div className={estilos.vacio}>Sin indicaciones adicionales.</div>}</div></section>

      <section className={`${estilos.seccion} ${estilos.seccionCompleta}`}><h3>Especificaciones técnicas</h3>{datos.especificaciones.length?<div className={estilos.json}>{datos.especificaciones.map((x,i)=><div className={estilos.jsonBloque} key={x.id||i}><strong>{titulo(x.prenda_clave||`Prenda ${i+1}`)}{x.variante_calidad?` · ${x.variante_calidad}`:""}</strong><pre>{JSON.stringify(limpio(x.spec||{}),null,2)}</pre></div>)}</div>:<div className={estilos.vacio}>Sin especificaciones sincronizadas.</div>}</section>

      {!publico&&<><section className={estilos.seccion}><h3>Detalle de facturación · {totalFact} unidades</h3>{(datos.facturacion||[]).length?<div className="tabla-scroll"><table><thead><tr><th>Concepto</th><th>Calidad</th><th className="num">Cantidad</th><th>Tipo</th></tr></thead><tbody>{datos.facturacion!.map((x,i)=><tr key={x.id||i}><td>{x.concepto}</td><td>{x.calidad||"—"}</td><td className="num">{x.cantidad}</td><td>{x.obsequio?"Obsequio":"Facturable"}</td></tr>)}</tbody></table></div>:<div className={estilos.vacio}>Sin detalle de facturación.</div>}</section><section className={estilos.seccion}><h3>Avance de producción</h3>{(datos.etapas||[]).length?<div className={estilos.timeline}>{datos.etapas!.map((x,i)=><div className={estilos.evento} key={x.id||i}><time>{fh(x.marcado_en)}</time><div><strong>{x.area} · {x.etapa}</strong><div>{x.operario||"Sin operario"}{x.no_aplica?" · No aplica":""}</div>{x.nota&&<small>{x.nota}</small>}</div></div>)}</div>:<div className={estilos.vacio}>Todavía no hay etapas registradas.</div>}</section><section className={`${estilos.seccion} ${estilos.seccionCompleta}`}><h3>Historial del expediente</h3>{(datos.eventos||[]).length?<div className={estilos.timeline}>{datos.eventos!.map((x,i)=><div className={estilos.evento} key={x.id||i}><time>{fh(x.created_at)}</time><div><strong>{titulo(x.campo)}</strong><div>{x.valor_anterior?`${x.valor_anterior} → `:""}{x.valor_nuevo||"—"}</div><small>{x.quien||"Sistema"}</small></div></div>)}</div>:<div className={estilos.vacio}>Sin cambios auditados.</div>}</section></>}
    </div>
    {!publico&&(datos.eventos||[]).some(x=>x.motivo_gestion_v99)&&<section className={`${estilos.seccion} ${estilos.auditoriaGestion}`}><h3>Motivos de cambios de gestión</h3><div className={estilos.timeline}>{datos.eventos!.filter(x=>x.motivo_gestion_v99).map((x,i)=><div className={estilos.evento} key={`gestion-${x.id||i}`}><time>{fh(x.created_at)}</time><div><strong>{titulo(x.campo)}</strong><div>{x.valor_anterior?`${x.valor_anterior} → `:""}{x.valor_nuevo||"—"}</div><small>{x.quien||"Sistema"} · {x.motivo_gestion_v99}</small></div></div>)}</div></section>}
  </div>;
}
