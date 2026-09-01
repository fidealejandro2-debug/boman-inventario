"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import BomanLogo from "@/components/BomanLogo";

export default function EstablecerClavePage() {
  const router = useRouter();
  const supabase = createClient();
  const [clave, setClave] = useState("");
  const [confirmacion, setConfirmacion] = useState("");
  const [mostrar, setMostrar] = useState(false);
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [guardando, setGuardando] = useState(false);
  const [verificando, setVerificando] = useState(true);

  useEffect(() => {
    supabase.auth.getUser().then(({ data, error: usuarioError }) => {
      if (usuarioError || !data.user) setError("El enlace no es válido o ya expiró. Solicita uno nuevo desde el ingreso.");
      else setEmail(data.user.email ?? "");
      setVerificando(false);
    });
  }, []);

  const requisitos = useMemo(() => ({
    longitud: clave.length >= 8,
    mayuscula: /[A-ZÁÉÍÓÚÑ]/.test(clave),
    minuscula: /[a-záéíóúñ]/.test(clave),
    numero: /\d/.test(clave),
  }), [clave]);
  const claveValida = Object.values(requisitos).every(Boolean);

  async function guardar(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    if (!claveValida) {
      setError("La contraseña todavía no cumple todos los requisitos.");
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
    // Levanta la marca de clave temporal. La función comprueba en el servidor
    // que la contraseña cambió de verdad, así que no sirve llamarla sola.
    const { data: liberado } = await supabase.rpc("confirmar_cambio_clave_v44");
    if (liberado === false) {
      // Sin esto el middleware devolvería a esta misma pantalla en bucle.
      setError(
        "La contraseña se guardó, pero el sistema no pudo confirmar el cambio. Cierra sesión, vuelve a entrar con la nueva contraseña y avisa a Administración si el problema sigue."
      );
      return;
    }
    router.push("/dashboard");
    router.refresh();
  }

  return (
    <main className="auth-shell auth-shell-simple">
      <section className="auth-acceso">
        <div className="auth-card">
          <BomanLogo className="auth-logo-formulario" priority />
          <div className="auth-cabecera">
            <span className="auth-icono" aria-hidden="true">✓</span>
            <div><h2>Crea tu contraseña</h2><p>{email ? `Cuenta: ${email}` : "Protege tu acceso a Boman Sport."}</p></div>
          </div>

          {verificando ? <div className="info-box">Verificando el enlace seguro...</div> : <>
            {error && <div className="error-box" role="alert">{error}</div>}
            {email && <form onSubmit={guardar}>
              <div className="field">
                <label htmlFor="nueva-clave">Nueva contraseña</label>
                <div className="auth-password">
                  <input id="nueva-clave" type={mostrar ? "text" : "password"} autoComplete="new-password" value={clave} onChange={(e) => setClave(e.target.value)} required />
                  <button type="button" onClick={() => setMostrar((valor) => !valor)}>{mostrar ? "Ocultar" : "Ver"}</button>
                </div>
              </div>
              <ul className="auth-requisitos" aria-label="Requisitos de contraseña">
                <li className={requisitos.longitud ? "cumplido" : ""}>Mínimo 8 caracteres</li>
                <li className={requisitos.mayuscula ? "cumplido" : ""}>Una letra mayúscula</li>
                <li className={requisitos.minuscula ? "cumplido" : ""}>Una letra minúscula</li>
                <li className={requisitos.numero ? "cumplido" : ""}>Un número</li>
              </ul>
              <div className="field">
                <label htmlFor="confirmar-clave">Confirmar contraseña</label>
                <input id="confirmar-clave" type={mostrar ? "text" : "password"} autoComplete="new-password" value={confirmacion} onChange={(e) => setConfirmacion(e.target.value)} required />
                {confirmacion && <small className={`ayuda-campo ${clave === confirmacion ? "texto-ok" : "texto-error"}`}>{clave === confirmacion ? "Las contraseñas coinciden." : "Las contraseñas no coinciden."}</small>}
              </div>
              <button type="submit" disabled={guardando || !claveValida || clave !== confirmacion} className="auth-principal">{guardando ? "Activando acceso..." : "Guardar contraseña e ingresar"}</button>
            </form>}
            {!email && <button type="button" className="auth-principal" onClick={() => router.push("/login?motivo=enlace-invalido")}>Solicitar un nuevo enlace</button>}
          </>}
        </div>
      </section>
    </main>
  );
}
