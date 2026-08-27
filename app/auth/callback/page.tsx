"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

function destinoSeguro(valor: string | null) {
  return valor && valor.startsWith("/") && !valor.startsWith("//") ? valor : "/establecer-clave";
}

export default function AuthCallbackPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function confirmarEnlace() {
      const supabase = createClient();
      const query = new URLSearchParams(window.location.search);
      const fragmento = new URLSearchParams(window.location.hash.replace(/^#/, ""));
      const next = destinoSeguro(query.get("next"));
      const descripcionError = query.get("error_description") ?? fragmento.get("error_description");
      if (descripcionError) {
        setError(decodeURIComponent(descripcionError.replaceAll("+", " ")));
        return;
      }

      const code = query.get("code");
      let errorSesion: Error | null = null;
      if (code) {
        const { error } = await supabase.auth.exchangeCodeForSession(code);
        errorSesion = error;
      } else {
        const accessToken = fragmento.get("access_token");
        const refreshToken = fragmento.get("refresh_token");
        if (accessToken && refreshToken) {
          const { error } = await supabase.auth.setSession({ access_token: accessToken, refresh_token: refreshToken });
          errorSesion = error;
        } else {
          const { data, error } = await supabase.auth.getSession();
          errorSesion = error ?? (data.session ? null : new Error("El enlace no contiene una sesión válida."));
        }
      }

      if (errorSesion) {
        setError("El enlace venció, ya fue utilizado o no es válido.");
        return;
      }
      window.history.replaceState({}, "", window.location.pathname);
      router.replace(next);
      router.refresh();
    }
    confirmarEnlace();
  }, [router]);

  return (
    <main className="auth-shell auth-shell-simple">
      <section className="auth-acceso">
        <div className="auth-card">
          <div className="auth-cabecera"><span className="auth-icono" aria-hidden="true">B</span><div><h2>Validando tu acceso</h2><p>Estamos comprobando que el enlace sea seguro.</p></div></div>
          {error ? <><div className="error-box">{error}</div><button className="auth-principal" onClick={() => router.replace("/login?motivo=enlace-invalido")}>Solicitar otro enlace</button></> : <div className="info-box">Un momento, serás dirigido a crear tu contraseña...</div>}
        </div>
      </section>
    </main>
  );
}
