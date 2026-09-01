import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

type CookieToSet = { name: string; value: string; options?: CookieOptions };

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  function redirectConCookies(url: URL) {
    const redirectResponse = NextResponse.redirect(url);
    response.cookies.getAll().forEach((cookie) => redirectResponse.cookies.set(cookie));
    return redirectResponse;
  }

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet: CookieToSet[]) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const isLoginPage = request.nextUrl.pathname.startsWith("/login");
  const isAuthCallback = request.nextUrl.pathname.startsWith("/auth/callback")
    || request.nextUrl.pathname.startsWith("/auth/confirm");

  if (!user && !isLoginPage && !isAuthCallback) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    return redirectConCookies(url);
  }

  if (user) {
    const { data: perfil, error: perfilError } = await supabase
      .from("perfiles")
      .select("activo, clave_temporal_desde")
      .eq("id", user.id)
      .maybeSingle();

    if (perfilError || !perfil?.activo) {
      await supabase.auth.signOut({ scope: "local" });
      const url = request.nextUrl.clone();
      url.pathname = "/login";
      url.search = `?motivo=${perfil ? "inactivo" : "sin-perfil"}`;
      return redirectConCookies(url);
    }

    // Con clave temporal vigente no se entra a ninguna otra pantalla: la clave
    // se entrego por fuera del sistema y deja de servir recien cuando la cambia.
    if (perfil.clave_temporal_desde && !request.nextUrl.pathname.startsWith("/establecer-clave")) {
      const url = request.nextUrl.clone();
      url.pathname = "/establecer-clave";
      url.search = "?motivo=clave-temporal";
      return redirectConCookies(url);
    }
  }

  if (user && isLoginPage) {
    const url = request.nextUrl.clone();
    url.pathname = "/dashboard";
    url.search = "";
    return redirectConCookies(url);
  }

  return response;
}

export const config = {
  // Los recursos públicos deben llegar directamente al navegador. Si pasan por
  // autenticación, Next/Image recibe la redirección al login en lugar del PNG.
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|css|js|map|txt|xml|webmanifest)$).*)",
  ],
};
