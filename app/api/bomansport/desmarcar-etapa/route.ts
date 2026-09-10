import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/* Quitar una marca de etapa desde el tablero de Vercel.
 *
 * Solo escribe en Supabase. Codigo.gs tiene desmarcarEtapa, pero exige el PIN
 * del jefe y borra filas de la bitacora del taller: replicar eso desde aqui
 * significaria mandar credenciales de otro sistema por la red. Se prefiere que
 * la hoja conserve su registro -es su bitacora- y avisar al usuario de que el
 * tablero del taller seguira mostrando la marca hasta que la quiten alli.
 */
export async function POST(request: NextRequest) {
  const supabase = createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ ok: false, error: "Sesión requerida" }, { status: 401 });

  const body = (await request.json().catch(() => null)) as {
    numero?: string; area?: string; etapa?: string; motivo?: string;
  } | null;
  if (!body?.numero || !body?.area || !body?.etapa) {
    return NextResponse.json({ ok: false, error: "Faltan número, área o etapa" }, { status: 400 });
  }

  const { data, error } = await supabase.rpc("desmarcar_etapa_contrato_v116", {
    p_numero: body.numero,
    p_area: body.area,
    p_etapa: body.etapa,
    p_motivo: body.motivo ?? "",
    p_idempotency_key: crypto.randomUUID(),
  });
  if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 400 });

  return NextResponse.json({
    ok: true, marca: data,
    aviso: "Quitada aquí. En el tablero del taller (Apps Script) la marca sigue: quítala también allí si hace falta.",
  });
}
