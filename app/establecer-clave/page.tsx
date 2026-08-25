"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function EstablecerClavePage() {
  const router = useRouter();
  const supabase = createClient();
  const [clave, setClave] = useState("");
  const [confirmacion, setConfirmacion] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);

  async function guardar(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (clave.length < 8) {
      setError("La contraseña debe tener al menos 8 caracteres.");
      return;
    }
    if (clave !== confirmacion) {
      setError("Las contraseñas no coinciden.");
      return;
    }

    setGuardando(true);
    const { error: actualizarError } = await supabase.auth.updateUser({ password: clave });
    setGuardando(false);

    if (actualizarError) {
      setError(actualizarError.message);
      return;
    }

    router.push("/dashboard");
    router.refresh();
  }

  return (
    <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", padding: 16 }}>
      <div className="card" style={{ width: 390 }}>
        <h2 style={{ marginTop: 0, color: "#1f3864" }}>Crea tu contraseña</h2>
        <p className="conteo">Usa una contraseña segura que solo tú conozcas.</p>
        <form onSubmit={guardar}>
          <div className="field">
            <label>Nueva contraseña</label>
            <input type="password" minLength={8} required value={clave}
              onChange={(e) => setClave(e.target.value)} style={{ width: "100%" }} />
          </div>
          <div className="field">
            <label>Confirmar contraseña</label>
            <input type="password" minLength={8} required value={confirmacion}
              onChange={(e) => setConfirmacion(e.target.value)} style={{ width: "100%" }} />
          </div>
          {error && <div className="error">{error}</div>}
          <button type="submit" disabled={guardando} style={{ width: "100%", marginTop: 8 }}>
            {guardando ? "Guardando..." : "Guardar contraseña"}
          </button>
        </form>
      </div>
    </div>
  );
}
