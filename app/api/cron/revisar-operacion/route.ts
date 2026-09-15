import { NextRequest, NextResponse } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

function secretoValido(request: NextRequest) {
  const secreto = process.env.CRON_SECRET;
  return Boolean(secreto) && request.headers.get("authorization") === `Bearer ${secreto}`;
}

async function esAdminActivo() {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return false;
  const { data: perfil } = await supabase
    .from("perfiles")
    .select("activo, rol")
    .eq("id", auth.user.id)
    .maybeSingle();
  return perfil?.activo === true && perfil.rol === "admin";
}

async function procesar(request: NextRequest) {
  if (!secretoValido(request) && !(await esAdminActivo())) {
    return NextResponse.json({ ok: false, error: "Acceso no autorizado" }, { status: 401 });
  }

  const admin = createAdminClient();
  const { data, error } = await admin.rpc("revisar_operacion_diaria_v155");
  if (error) {
    return NextResponse.json({ ok: false, error: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true, resultado: data });
}

export async function GET(request: NextRequest) {
  return procesar(request);
}

export async function POST(request: NextRequest) {
  return procesar(request);
}
