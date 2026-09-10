import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/* Marcar una etapa desde el tablero de Vercel.
 *
 * Se escribe en DOS sitios a proposito. La marca vive en Supabase (para que el
 * tablero se actualice al instante) y ademas se devuelve a la hoja, porque las
 * estaciones del taller siguen trabajando en el tablero de Apps Script: si solo
 * guardaramos aqui, el operario de Corte nunca veria el avance y COL_ESTADO no
 * se moveria. Serian dos verdades distintas del mismo contrato.
 *
 * Orden: primero Supabase. Si la marca falla ahi (permiso, etapa repetida) no
 * se toca la hoja. Si la hoja falla despues, la marca YA quedo registrada y se
 * devuelve `hoja:false` para poder avisarlo: es un desfase visible y
 * recuperable, no un dato perdido. Al reves seria peor -la hoja marcada y
 * Supabase sin rastro.
 *
 * La marca no se duplica al volver: (contrato, area, etapa) es unico en
 * contrato_etapas y el importador salta lo que ya existe.
 */
export async function POST(request: NextRequest) {
  const supabase = createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ ok: false, error: "Sesión requerida" }, { status: 401 });

  const body = (await request.json().catch(() => null)) as {
    numero?: string; area?: string; etapa?: string;
    operario?: string; no_aplica?: boolean; nota?: string;
  } | null;
  if (!body?.numero || !body?.area || !body?.etapa) {
    return NextResponse.json({ ok: false, error: "Faltan número, área o etapa" }, { status: 400 });
  }

  // El permiso lo controla la RPC (contratos.marcar_etapa); aqui no se repite
  // para no tener dos reglas que puedan discrepar.
  const { data, error } = await supabase.rpc("marcar_etapa_contrato_v116", {
    p_numero: body.numero,
    p_area: body.area,
    p_etapa: body.etapa,
    p_operario: body.operario ?? "",
    p_no_aplica: Boolean(body.no_aplica),
    p_nota: body.nota ?? "",
    p_idempotency_key: crypto.randomUUID(),
  });
  if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 400 });
  if ((data as { repetida?: boolean })?.repetida) return NextResponse.json({ ok: true, hoja: false, repetida: true });

  const base = process.env.BOMANSPORT_WEBAPP_URL, token = process.env.BOMANSPORT_API_TOKEN;
  if (!base || !token) {
    return NextResponse.json({ ok: true, hoja: false, marca: data, aviso: "Marcado en el sistema, pero faltan BOMANSPORT_WEBAPP_URL o BOMANSPORT_API_TOKEN: el taller no lo verá en su tablero." });
  }

  try {
    const respuesta = await fetch(`${base}?api=marcar-etapa&token=${encodeURIComponent(token)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        numero: body.numero, area: body.area, etapa: body.etapa,
        operario: body.operario ?? "", noAplica: Boolean(body.no_aplica), nota: body.nota ?? "",
      }),
      cache: "no-store",
    });
    const texto = await respuesta.text();
    let remoto: { ok?: boolean; error?: string };
    try { remoto = JSON.parse(texto) as { ok?: boolean; error?: string } }
    catch { throw new Error(`Apps Script devolvió una respuesta inválida (${respuesta.status})`) }
    // "ya estaba marcada" no es un fallo: significa que el taller llego primero
    // y los dos lados coinciden, que es justo lo que se busca.
    if (!respuesta.ok || (!remoto?.ok && !/ya estaba marcad/i.test(remoto?.error || ""))) {
      throw new Error(remoto?.error || `Apps Script respondió ${respuesta.status}`);
    }
    return NextResponse.json({ ok: true, hoja: true, marca: data });
  } catch (e) {
    const mensaje = e instanceof Error ? e.message : "No se pudo avisar a la hoja";
    return NextResponse.json({ ok: true, hoja: false, marca: data, aviso: `Marcado en el sistema, pero el tablero del taller no se enteró: ${mensaje}` });
  }
}
