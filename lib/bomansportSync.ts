import "server-only";

export type MarcaEtapaSheets = {
  numero: string;
  area: string;
  etapa: string;
  operario: string;
  noAplica: boolean;
  nota: string;
};

export async function enviarMarcaEtapaSheets(payload: MarcaEtapaSheets) {
  const base = process.env.BOMANSPORT_WEBAPP_URL;
  const token = process.env.BOMANSPORT_API_TOKEN;
  if (!base || !token) {
    throw new Error("Faltan BOMANSPORT_WEBAPP_URL o BOMANSPORT_API_TOKEN");
  }

  const respuesta = await fetch(`${base}?api=marcar-etapa&token=${encodeURIComponent(token)}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
    cache: "no-store",
  });
  const texto = await respuesta.text();
  let remoto: { ok?: boolean; error?: string };
  try {
    remoto = JSON.parse(texto) as { ok?: boolean; error?: string };
  } catch {
    throw new Error(`Apps Script devolvió una respuesta inválida (${respuesta.status})`);
  }
  if (!respuesta.ok || (!remoto.ok && !/ya estaba marcad/i.test(remoto.error ?? ""))) {
    throw new Error(remoto.error || `Apps Script respondió ${respuesta.status}`);
  }
}
