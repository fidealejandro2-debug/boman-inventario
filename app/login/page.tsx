"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();
  const supabase = createClient();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const motivo = new URLSearchParams(window.location.search).get("motivo");
    if (motivo === "inactivo") setError("Tu cuenta está inactiva. Solicita acceso al administrador.");
    if (motivo === "sin-perfil") setError("Tu cuenta no tiene un perfil habilitado en el sistema.");
    if (motivo === "enlace-invalido") setError("El enlace de invitación venció o ya fue utilizado. Solicita uno nuevo.");
  }, []);

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { error } = await supabase.auth.signInWithPassword({ email, password });

    setLoading(false);

    if (error) {
      setError("Correo o contraseña incorrectos.");
      return;
    }

    router.push("/dashboard");
    router.refresh();
  }

  return (
    <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center" }}>
      <div className="card" style={{ width: 360 }}>
        <h2 style={{ marginTop: 0, color: "#1f3864" }}>Boman Sport</h2>
        <p style={{ color: "#6b7280", marginTop: -8, fontSize: 14 }}>Inventario de producto terminado</p>

        <form onSubmit={handleLogin}>
          <div className="field">
            <label>Correo</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              style={{ width: "100%" }}
            />
          </div>
          <div className="field">
            <label>Contraseña</label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              style={{ width: "100%" }}
            />
          </div>
          {error && <div className="error">{error}</div>}
          <button type="submit" disabled={loading} style={{ width: "100%", marginTop: 6 }}>
            {loading ? "Ingresando..." : "Ingresar"}
          </button>
        </form>
      </div>
    </div>
  );
}
