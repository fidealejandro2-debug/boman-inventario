import estilos from "./Contratos.module.css";

export type Expediente = { contrato: Record<string, any>; prendas: Record<string, any>[]; jugadores: Record<string, any>[]; archivos: Record<string, any>[]; especificaciones: Record<string, any>[]; facturacion?: Record<string, any>[]; etapas?: Record<string, any>[]; eventos?: Record<string, any>[]; enlaces?: Record<string, any>[] };
const DINERO = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const OCULTAS = new Set(["id", "contrato_id", "orden", "created_at", "updated_at", "mockup_indice"]);
const INDICACIONES = ["instrucciones", "observaciones_lili", "autorizacion_produccion", "forma_entrega", "direccion", "nombre_tecnica", "numero_tecnica", "sellos_tpu", "ubicacion_tpu", "bordado"];

function fecha(v: unknown) { if (!v) return "—"; const s = String(v).slice(0, 10); return /^\d{4}-\d{2}-\d{2}$/.test(s) ? new Intl.DateTimeFormat("es-EC", { dateStyle: "medium", timeZone: "UTC" }).format(new Date(`${s}T12:00:00Z`)) : String(v) }
function fechaHora(v: unknown) { return v ? new Intl.DateTimeFormat("es-EC", { dateStyle: "medium", timeStyle: "short", timeZone: "America/Guayaquil" }).format(new Date(String(v))) : "—" }
function titulo(k: string) { return k.replace(/_/g, " ").replace(/\b\w/g, (x) => x.toUpperCase()) }
function conValor(v: unknown) { return v !== null && v !== undefined && v !== "" && v !== false && !(Array.isArray(v) && !v.length) && !(typeof v === "object" && v && !Array.isArray(v) && !Object.keys(v).length) }
function visible(v: unknown): string { if (typeof v === "boolean") return v ? "Sí" : "No"; if (Array.isArray(v)) return v.map(visible).join(" · "); if (typeof v === "object" && v) return Object.entries(v as Record<string, unknown>).filter(([, x]) => conValor(x)).map(([k, x]) => `${titulo(k)}: ${visible(x)}`).join(" · "); return String(v ?? "—") }
function campos(spec: Record<string, unknown>) { return Object.entries(spec || {}).filter(([k, v]) => !OCULTAS.has(k) && conValor(v)) }
function src(x: Record<string, any>, ancho = 1200) { return x.drive_id ? `https://drive.google.com/thumbnail?id=${x.drive_id}&sz=w${ancho}` : x.url }

export default function ExpedienteContrato({ datos, publico = false }: { datos: Expediente; publico?: boolean }) {
  const c = datos.contrato || {}, mockups = datos.archivos.filter((a) => a.tipo === "mockup"), logos = datos.archivos.filter((a) => a.tipo === "logo");
  const calidades = Array.from(new Set([...datos.prendas.map((x) => x.calidad), ...datos.especificaciones.map((x) => x.variante_calidad)].filter(Boolean)));
  const indicaciones = INDICACIONES.filter((k) => conValor(c[k]));
  const totalFact = (datos.facturacion || []).reduce((s, x) => s + Number(x.cantidad || 0), 0);
  return <div className={estilos.expediente}>
    <article className={estilos.briefDocumento}>
      <header className={estilos.briefEncabezado}><div className={estilos.briefCalidad}>{calidades.join(" / ") || c.calidad || "PRODUCCIÓN"}</div><div className={estilos.briefAdvertencia}>ANTES DEL ENSAMBLE, CORROBORAR QUE EL MOCKUP SEA EL CORRECTO</div></header>
      <h2 className={estilos.briefTitulo}>Detalle de contrato: {c.nombre_contrato_v115 || c.cliente || "Sin contrato"}</h2>
      <table className={estilos.briefFicha}><tbody>
        <tr><th>CONTRATO:</th><td><strong>{c.nombre_contrato_v115 || c.cliente || "—"}</strong>{c.prioridad === "Urgente" && <span className={estilos.selloRojo}>URGENTE</span>}{c.reposicion === true && <span className={estilos.selloRojo}>REPOSICIÓN</span>}</td><td className={estilos.briefResponsable}><strong>{c.numero}</strong><span>RESPONSABLE</span></td></tr>
        <tr><th>FECHA DE INGRESO:</th><td>{fecha(c.fecha_ingreso || c.created_at)}</td><td rowSpan={2} className={estilos.briefResponsableNombre}>{c.vendedor || "—"}</td></tr>
        <tr><th>FECHA DE ENTREGA:</th><td className={estilos.fechaEntrega}>{fecha(c.fecha_entrega)}</td></tr>
        <tr><th>CLIENTE:</th><td colSpan={2}>{c.cliente || "—"}</td></tr>
        <tr><th>ENTREGA:</th><td colSpan={2}>{[c.forma_entrega, c.direccion].filter(Boolean).join(" · ") || "—"}</td></tr>
      </tbody></table>
      {(c.observacion || c.observaciones || c.observaciones_lili) && <div className={estilos.observacionPrincipal}><strong>OBSERVACIÓN:</strong> {c.observacion || c.observaciones || c.observaciones_lili}</div>}

      <div className={estilos.briefCuerpo}>
        <div className={estilos.briefLateral}>
          <section className={estilos.bloqueBrief}><h3>Cantidad / detalle</h3><table className={estilos.tablaCompacta}><thead><tr><th>Cant.</th><th>Prenda</th><th>Calidad</th></tr></thead><tbody>{datos.prendas.length ? datos.prendas.map((x, i) => <tr key={x.id || i}><td className="num"><strong>{x.cantidad}</strong></td><td>{x.prenda}{x.genero ? ` · ${x.genero}` : ""}{x.talla ? ` · ${x.talla}` : ""}</td><td>{x.calidad || "—"}</td></tr>) : <tr><td colSpan={3}>Sin desglose.</td></tr>}</tbody></table></section>
          <section className={estilos.bloqueBrief}><h3>Resumen técnico</h3>{datos.especificaciones.length ? datos.especificaciones.map((x, i) => <div className={estilos.specFicha} key={x.id || i}><h4>{titulo(x.prenda_clave || `Prenda ${i + 1}`)}{x.variante_calidad ? ` · ${x.variante_calidad}` : ""}</h4><dl>{campos(x.spec || {}).map(([k, v]) => <div key={k}><dt>{titulo(k)}</dt><dd>{visible(v)}</dd></div>)}</dl></div>) : <p className={estilos.textoVacio}>Sin especificaciones técnicas.</p>}</section>
          {logos.length > 0 && <section className={estilos.bloqueBrief}><h3>Logos y aplicaciones</h3><div className={estilos.logosBrief}>{logos.map((x, i) => <a href={x.url || src(x, 800)} target="_blank" rel="noreferrer" key={x.id || i}>{/* eslint-disable-next-line @next/next/no-img-element */}<img src={src(x, 500)} alt={x.descripcion || "Logo"}/><span>{x.descripcion || `Logo ${i + 1}`}{x.posicion ? ` · ${x.posicion}` : ""}{x.tecnica ? ` · ${x.tecnica}` : ""}</span></a>)}</div></section>}
        </div>
        <section className={estilos.mockupsBrief}>{mockups.length ? mockups.map((x, i) => <figure className={i === 0 ? estilos.mockupPrincipal : estilos.mockupSecundario} key={x.id || i}><a href={x.url || src(x)} target="_blank" rel="noreferrer">{/* eslint-disable-next-line @next/next/no-img-element */}<img src={src(x)} alt={x.descripcion || `Mockup ${i + 1}`}/></a><figcaption><strong>{i === 0 ? "★ MOCKUP PRINCIPAL" : `MOCKUP ${i + 1}`}</strong>{x.descripcion && <span>{x.descripcion}</span>}{x.color && <span>{x.color}</span>}</figcaption></figure>) : <div className={estilos.sinMockup}>Sin mockup adjunto</div>}{c.colores_generales && <div className={estilos.coloresBrief}><strong>COLORES GENERALES</strong><p>{visible(c.colores_generales)}</p><b>SIEMPRE PREDOMINA EL COLOR DEL MOCKUP Y DE LA MUESTRA.</b></div>}</section>
      </div>

      {indicaciones.length > 0 && <section className={estilos.instruccionesBrief}><h3>Instrucciones especiales</h3>{indicaciones.map((k) => <div key={k}><strong>{titulo(k)}:</strong> {visible(c[k])}</div>)}</section>}
      {datos.jugadores.length > 0 && <section className={estilos.seccionDocumento}><h3>Nómina de jugadores y tallas</h3><div className="tabla-scroll"><table><thead><tr><th>#</th><th>Nombre</th><th>Número</th><th>Categoría</th><th>Superior</th><th>Inferior</th><th>Calidad</th><th>Detalle</th></tr></thead><tbody>{datos.jugadores.map((x, i) => <tr key={x.id || i}><td>{i + 1}</td><td><strong>{x.nombre || "—"}</strong></td><td>{x.numero || "—"}</td><td>{x.categoria || "—"}</td><td>{x.talla_superior || "—"}</td><td>{x.talla_inferior || "—"}</td><td>{x.calidad || "—"}</td><td>{x.detalle || x.variante || "—"}</td></tr>)}</tbody></table></div></section>}
      <footer className={estilos.briefPie}>BOMAN SPORT · {c.numero} · Documento de producción</footer>
    </article>

    {!publico && <div className={estilos.soloGestion}><div className={estilos.separadorGestion}><span>Gestión interna del contrato</span></div><div className={estilos.resumenInterno}><div><span>Estado</span><strong>{c.estado || "—"}</strong></div><div><span>Diseñador</span><strong>{c.disenador || "—"}</strong></div><div><span>Presupuesto</span><strong>{DINERO.format(Number(c.presupuesto || 0))}</strong></div><div><span>Saldo</span><strong>{DINERO.format(Math.max(0, Number(c.presupuesto || 0) - Number(c.abono || 0)))}</strong></div></div><div className={estilos.rejillaGestion}>
      <section className={estilos.seccionGestion}><h3>Detalle de facturación · {totalFact} unidades</h3>{(datos.facturacion || []).length ? <div className="tabla-scroll"><table><thead><tr><th>Concepto</th><th>Calidad</th><th className="num">Cantidad</th><th>Tipo</th></tr></thead><tbody>{datos.facturacion!.map((x, i) => <tr key={x.id || i}><td>{x.concepto}</td><td>{x.calidad || "—"}</td><td className="num">{x.cantidad}</td><td>{x.obsequio ? "Obsequio" : "Facturable"}</td></tr>)}</tbody></table></div> : <div className={estilos.vacio}>Sin detalle de facturación.</div>}</section>
      <section className={estilos.seccionGestion}><h3>Avance de producción</h3>{(datos.etapas || []).length ? <div className={estilos.timeline}>{datos.etapas!.map((x, i) => <div className={estilos.evento} key={x.id || i}><time>{fechaHora(x.marcado_en)}</time><div><strong>{x.area} · {x.etapa}</strong><div>{x.operario || "Sin operario"}{x.no_aplica ? " · No aplica" : ""}</div>{x.nota && <small>{x.nota}</small>}</div></div>)}</div> : <div className={estilos.vacio}>Todavía no hay etapas registradas.</div>}</section>
      <section className={`${estilos.seccionGestion} ${estilos.completa}`}><h3>Historial del expediente</h3>{(datos.eventos || []).length ? <div className={estilos.timeline}>{datos.eventos!.map((x, i) => <div className={estilos.evento} key={x.id || i}><time>{fechaHora(x.created_at)}</time><div><strong>{titulo(x.campo)}</strong><div>{x.valor_anterior ? `${x.valor_anterior} → ` : ""}{x.valor_nuevo || "—"}</div><small>{x.quien || "Sistema"}{x.motivo_gestion_v99 ? ` · ${x.motivo_gestion_v99}` : ""}</small></div></div>)}</div> : <div className={estilos.vacio}>Sin cambios auditados.</div>}</section>
    </div></div>}
  </div>;
}
