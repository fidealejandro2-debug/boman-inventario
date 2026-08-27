"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type ModoAcceso = "ingreso" | "primera-vez" | "recuperar";

export default function LoginPage() {
  const router = useRouter();
  const supabase = createClient();
  const [modo, setModo] = useState<ModoAcceso>("ingreso");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [mostrarPassword, setMostrarPassword] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const motivo = new URLSearchParams(window.location.search).get("motivo");
    if (motivo === "inactivo") setError("Tu acceso fue desactivado. Comunícate con el administrador.");
    if (motivo === "sin-perfil") setError("Tu cuenta todavía no tiene un perfil habilitado en Boman.");
    if (motivo === "enlace-invalido") {
      setError("El enlace venció o ya fue utilizado. Solicita un nuevo enlace de contraseña.");
      setModo("recuperar");
    }
  }, []);

  function cambiarModo(nuevoModo: ModoAcceso) {
    setModo(nuevoModo);
    setError(null);
    setMensaje(null);
    setPassword("");
  }

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setMensaje(null);
    setLoading(true);
    const { error: loginError } = await supabase.auth.signInWithPassword({
      email: email.trim().toLowerCase(), password,
    });
    setLoading(false);

    if (loginError) {
      const codigo = (loginError as { code?: string }).code;
      if (codigo === "email_not_confirmed") setError("Tu invitación todavía no fue confirmada. Abre el enlace enviado a tu correo.");
      else if (codigo === "user_banned") setError("Tu acceso está desactivado. Comunícate con el administrador.");
      else setError("Correo o contraseña incorrectos. Si no recuerdas tu clave, solicita un nuevo enlace.");
      return;
    }
    router.push("/dashboard");
    router.refresh();
  }

  async function recuperarClave(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setMensaje(null);
    const correo = email.trim().toLowerCase();
    if (!correo || !correo.includes("@")) {
      setError("Ingresa el correo con el que fuiste registrado.");
      return;
    }

    setLoading(true);
    const redirectTo = `${window.location.origin}/auth/callback?next=/establecer-clave`;
    const { error: envioError } = await supabase.auth.resetPasswordForEmail(correo, { redirectTo });
    setLoading(false);
    if (envioError) {
      setError(envioError.message.toLowerCase().includes("rate limit")
        ? "Se enviaron demasiadas solicitudes. Espera unos minutos antes de intentarlo nuevamente."
        : "No se pudo enviar el enlace. Verifica el correo o consulta al administrador.");
      return;
    }
    setMensaje(`Enviamos un enlace seguro a ${correo}. Revisa también la carpeta de correo no deseado.`);
  }

  return (
    <main className="auth-shell">
      <section className="auth-presentacion">
        <div className="auth-marca"><span>BOMAN SPORT</span><strong>ERP DE INVENTARIO</strong></div>
        <div><h1>Inventario confiable, operación trazable.</h1><p>Solicitudes, transferencias, conteos, ventas e incidencias en un solo sistema.</p></div>
        <small>Acceso exclusivo para personal autorizado.</small>
      </section>

      <section className="auth-acceso">
        <div className="auth-card">
          <div className="auth-cabecera">
            <span className="auth-icono" aria-hidden="true">B</span>
            <div>
              <h2>{modo === "ingreso" ? "Bienvenido" : modo === "primera-vez" ? "Activa tu cuenta" : "Crea una nueva contraseña"}</h2>
              <p>{modo === "ingreso" ? "Ingresa con tu cuenta de Boman Sport." : modo === "primera-vez" ? "Abre la invitación que recibiste por correo." : "Recibirás un enlace seguro en tu correo."}</p>
            </div>
          </div>

          {error && <div className="error-box" role="alert">{error}</div>}
          {mensaje && <div className="success-box" role="status">{mensaje}</div>}

          {modo === "ingreso" && <form onSubmit={handleLogin}>
            <div className="field">
              <label htmlFor="login-email">Correo electrónico</label>
              <input id="login-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required placeholder="nombre@empresa.com" />
            </div>
            <div className="field">
              <div className="auth-label-fila"><label htmlFor="login-password">Contraseña</label><button type="button" className="auth-enlace" onClick={() => cambiarModo("recuperar")}>Olvidé mi contraseña</button></div>
              <div className="auth-password">
                <input id="login-password" type={mostrarPassword ? "text" : "password"} autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
                <button type="button" onClick={() => setMostrarPassword((valor) => !valor)}>{mostrarPassword ? "Ocultar" : "Ver"}</button>
              </div>
            </div>
            <button type="submit" disabled={loading} className="auth-principal">{loading ? "Verificando..." : "Ingresar al sistema"}</button>
            <div className="auth-separador"><span>Primer acceso</span></div>
            <button type="button" className="auth-secundario" onClick={() => cambiarModo("primera-vez")}>Recibí una invitación / crear contraseña</button>
          </form>}

          {modo === "primera-vez" && <div>
            <ol className="auth-pasos">
              <li><b>Revisa tu correo.</b><span>Busca la invitación enviada por Boman Sport.</span></li>
              <li><b>Abre el enlace.</b><span>El sistema validará automáticamente que el correo te pertenece.</span></li>
              <li><b>Crea tu contraseña.</b><span>Aparecerá la pantalla para definir y confirmar tu nueva clave.</span></li>
              <li><b>Ingresa al sistema.</b><span>Al guardar la clave entrarás directamente a tu panel.</span></li>
            </ol>
            <div className="info-box">No es posible crear una cuenta libremente. Si no recibiste la invitación, solicita al administrador que te registre.</div>
            <button type="button" className="auth-principal" onClick={() => cambiarModo("ingreso")}>Volver al ingreso</button>
          </div>}

          {modo === "recuperar" && <form onSubmit={recuperarClave}>
            <div className="field">
              <label htmlFor="recovery-email">Correo registrado</label>
              <input id="recovery-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required placeholder="nombre@empresa.com" />
              <small className="ayuda-campo">El enlace es temporal y solo puede utilizarse una vez.</small>
            </div>
            <button type="submit" disabled={loading} className="auth-principal">{loading ? "Enviando..." : "Enviar enlace para crear nueva clave"}</button>
            <button type="button" className="auth-secundario" onClick={() => cambiarModo("ingreso")}>Volver al ingreso</button>
          </form>}
        </div>
      </section>
    </main>
  );
}
