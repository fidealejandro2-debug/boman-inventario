import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");
  const siguienteSolicitado = request.nextUrl.searchParams.get("next") ?? "/establecer-clave";
  const siguiente = siguienteSolicitado.startsWith("/") && !siguienteSolicitado.startsWith("//")
    ? siguienteSolicitado
    : "/establecer-clave";

  if (code) {
    const supabase = createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(new URL(siguiente, request.nextUrl.origin));
    }
  }

  return NextResponse.redirect(new URL("/login?motivo=enlace-invalido", request.nextUrl.origin));
}
