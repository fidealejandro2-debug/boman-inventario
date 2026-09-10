import estilos from "./Contratos.module.css";
import { BriefHoja, formDesdeContrato } from "@/app/ventas/contratos/IngresoContratoCliente";

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
    {/* El brief se pinta con BriefHoja, el MISMO documento que la vista previa
        del ingreso. Antes habia dos briefs distintos y un contrato ya guardado
        se imprimia con un diseño que no era el que ve el taller. */}
    <BriefHoja form={formDesdeContrato(datos)}/>

    {!publico && <div className={estilos.soloGestion}><div className={estilos.separadorGestion}><span>Gestión interna del contrato</span></div><div className={estilos.resumenInterno}><div><span>Estado</span><strong>{c.estado || "—"}</strong></div><div><span>Diseñador</span><strong>{c.disenador || "—"}</strong></div><div><span>Presupuesto</span><strong>{DINERO.format(Number(c.presupuesto || 0))}</strong></div><div><span>Saldo</span><strong>{DINERO.format(Math.max(0, Number(c.presupuesto || 0) - Number(c.abono || 0)))}</strong></div></div><div className={estilos.rejillaGestion}>
      <section className={estilos.seccionGestion}><h3>Detalle de facturación · {totalFact} unidades</h3>{(datos.facturacion || []).length ? <div className="tabla-scroll"><table><thead><tr><th>Concepto</th><th>Calidad</th><th className="num">Cantidad</th><th>Tipo</th></tr></thead><tbody>{datos.facturacion!.map((x, i) => <tr key={x.id || i}><td>{x.concepto}</td><td>{x.calidad || "—"}</td><td className="num">{x.cantidad}</td><td>{x.obsequio ? "Obsequio" : "Facturable"}</td></tr>)}</tbody></table></div> : <div className={estilos.vacio}>Sin detalle de facturación.</div>}</section>
      <section className={estilos.seccionGestion}><h3>Avance de producción</h3>{(datos.etapas || []).length ? <div className={estilos.timeline}>{datos.etapas!.map((x, i) => <div className={estilos.evento} key={x.id || i}><time>{fechaHora(x.marcado_en)}</time><div><strong>{x.area} · {x.etapa}</strong><div>{x.operario || "Sin operario"}{x.no_aplica ? " · No aplica" : ""}</div>{x.nota && <small>{x.nota}</small>}</div></div>)}</div> : <div className={estilos.vacio}>Todavía no hay etapas registradas.</div>}</section>
      <section className={`${estilos.seccionGestion} ${estilos.completa}`}><h3>Historial del expediente</h3>{(datos.eventos || []).length ? <div className={estilos.timeline}>{datos.eventos!.map((x, i) => <div className={estilos.evento} key={x.id || i}><time>{fechaHora(x.created_at)}</time><div><strong>{titulo(x.campo)}</strong><div>{x.valor_anterior ? `${x.valor_anterior} → ` : ""}{x.valor_nuevo || "—"}</div><small>{x.quien || "Sistema"}{x.motivo_gestion_v99 ? ` · ${x.motivo_gestion_v99}` : ""}</small></div></div>)}</div> : <div className={estilos.vacio}>Sin cambios auditados.</div>}</section>
    </div></div>}
  </div>;
}
