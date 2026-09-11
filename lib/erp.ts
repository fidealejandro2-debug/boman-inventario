export const ETIQUETAS_ESTADO: Record<string, string> = {
  borrador: "Borrador",
  solicitado: "Solicitada",
  aprobado: "Aprobada",
  rechazado: "Rechazada",
  preparando: "En preparación",
  despachado: "Despachada",
  en_transito: "En tránsito",
  recibido: "Recibida",
  recibido_con_diferencia: "Recibida con diferencia",
  cerrado_con_diferencia: "Diferencia cerrada",
  en_conteo: "En conteo",
  pendiente_revision: "Pendiente de Control",
  aplicado: "Aplicado",
  anulado: "Anulado",
};

export const ETIQUETAS_DOCUMENTO: Record<string, string> = {
  solicitud_reposicion: "Solicitud de reposición",
  transferencia: "Transferencia",
  conteo: "Conteo físico",
};

export function nuevaClaveIdempotencia() {
  return typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random()}`;
}

function escaparHtml(valor: string) {
  return valor.replace(/[&<>"']/g, (caracter) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[caracter] ?? caracter);
}

/**
 * Los documentos se construyen con plantillas HTML, pero varios de sus textos
 * proceden de la base. Esta lista blanca conserva únicamente el marcado que
 * usan las actas y elimina etiquetas, atributos y eventos inyectados.
 */
function sanitizarHtmlImpresion(contenido: string) {
  const plantilla = document.createElement("template");
  plantilla.innerHTML = contenido;
  const permitidas = new Set([
    "H1", "H2", "H3", "P", "B", "STRONG", "EM", "BR", "DIV", "SPAN",
    "TABLE", "THEAD", "TBODY", "TR", "TH", "TD",
  ]);

  [...plantilla.content.querySelectorAll("*")].forEach((elemento) => {
    if (!permitidas.has(elemento.tagName)) {
      elemento.replaceWith(document.createTextNode(elemento.textContent ?? ""));
      return;
    }
    [...elemento.attributes].forEach((atributo) => {
      const clasePermitida = atributo.name === "class" && atributo.value === "num";
      const colspanPermitido = atributo.name === "colspan" && /^\d{1,2}$/.test(atributo.value);
      if (!clasePermitida && !colspanPermitido) elemento.removeAttribute(atributo.name);
    });
  });
  return plantilla.innerHTML;
}

export function imprimirDocumento(titulo: string, contenido: string) {
  const ventana = window.open("", "_blank", "width=980,height=760");
  if (!ventana) return;
  ventana.opener = null;
  const tituloSeguro = escaparHtml(titulo);
  const contenidoSeguro = sanitizarHtmlImpresion(contenido);
  ventana.document.write(`<!doctype html><html lang="es"><head><meta charset="utf-8"><title>${tituloSeguro}</title>
    <style>body{font-family:Arial,sans-serif;color:#172033;padding:24px}h1{color:#1f3864;font-size:22px}
    table{width:100%;border-collapse:collapse;margin-top:16px}th,td{border:1px solid #cbd5e1;padding:8px;text-align:left}
    th{background:#1f3864;color:#fff}.num{text-align:right}.firma{display:flex;gap:60px;margin-top:70px}.firma div{flex:1;border-top:1px solid #111;padding-top:6px;text-align:center}
    @media print{button{display:none}}</style></head><body>${contenidoSeguro}<div class="firma"><div>Entrega</div><div>Transporta</div><div>Recibe</div></div>
    <script>window.onload=()=>window.print()</script></body></html>`);
  ventana.document.close();
}
