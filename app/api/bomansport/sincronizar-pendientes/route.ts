import { NextRequest, NextResponse } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import { enviarMarcaEtapaSheets, type MarcaEtapaSheets } from "@/lib/bomansportSync";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

type Pendiente = {
  id: string;
  operacion: "marcar_etapa";
  payload: MarcaEtapaSheets;
};

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
  const { data, error } = await admin.rpc("reclamar_sincronizaciones_bomansport_v131", {
    p_limite: 20,
  });
  if (error) {
    return NextResponse.json({ ok: false, error: `No se pudo reclamar la cola: ${error.message}` }, { status: 500 });
  }

  const pendientes = (data ?? []) as Pendiente[];
  let sincronizadas = 0;
  let fallidas = 0;
  for (const pendiente of pendientes) {
    try {
      if (pendiente.operacion !== "marcar_etapa") throw new Error("Operación de cola no soportada");
      await enviarMarcaEtapaSheets(pendiente.payload);
      const { error: resolverError } = await admin.rpc("resolver_sincronizacion_bomansport_v131", {
        p_id: pendiente.id,
        p_exitosa: true,
        p_error: null,
      });
      if (resolverError) throw resolverError;
      sincronizadas += 1;
    } catch (errorPendiente) {
      const mensaje = errorPendiente instanceof Error ? errorPendiente.message : "Error no especificado";
      await admin.rpc("resolver_sincronizacion_bomansport_v131", {
        p_id: pendiente.id,
        p_exitosa: false,
        p_error: mensaje,
      });
      fallidas += 1;
    }
  }

  return NextResponse.json({ ok: true, reclamadas: pendientes.length, sincronizadas, fallidas });
}

export async function GET(request: NextRequest) {
  return procesar(request);
}

export async function POST(request: NextRequest) {
  return procesar(request);
}
