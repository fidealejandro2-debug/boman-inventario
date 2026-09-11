"use client";

import Image from "next/image";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import BomanLogo from "@/components/BomanLogo";
import { mostrarAvisoDialogo } from "@/components/Dialogo";
import styles from "./Login.module.css";

type ModoAcceso = "ingreso" | "primera-vez" | "recuperar";

export default function LoginPage() {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
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
      const detalle = codigo === "email_not_confirmed"
        ? "Tu invitación todavía no fue confirmada. Abre el enlace enviado a tu correo."
        : codigo === "user_banned"
          ? "Tu acceso está desactivado. Comunícate con el administrador."
          : "Correo o contraseña incorrectos. Si no recuerdas tu clave, solicita un nuevo enlace.";
      void mostrarAvisoDialogo(detalle, "No pudimos iniciar sesión", true);
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
      void mostrarAvisoDialogo("Ingresa el correo con el que fuiste registrado.", "Revisa el correo", true);
      return;
    }

    setLoading(true);
    const redirectTo = `${window.location.origin}/auth/callback?next=/establecer-clave`;
    const { error: envioError } = await supabase.auth.resetPasswordForEmail(correo, { redirectTo });
    setLoading(false);
    if (envioError) {
      const detalle = envioError.message.toLowerCase().includes("rate limit")
        ? "Se enviaron demasiadas solicitudes. Espera unos minutos antes de intentarlo nuevamente."
        : "No se pudo enviar el enlace. Verifica el correo o consulta al administrador.";
      void mostrarAvisoDialogo(detalle, "No pudimos enviar el enlace", true);
      return;
    }
    setMensaje(`Enviamos un enlace seguro a ${correo}. Revisa también la carpeta de correo no deseado.`);
  }

  return (
    <main className={styles.shell}>
      <section className={styles.story} aria-label="Boman Sport">
        <Image className={styles.storyImage} src="/brand/dashboard/boman-camiseta-entrenamiento.jpg"
          alt="Camiseta técnica Boman" fill priority sizes="(max-width: 860px) 100vw, 56vw" />
        <div className={styles.storyWash} aria-hidden="true" />
        <header className={styles.storyBrand}>
          <BomanLogo className={styles.logo} priority />
          <span>GESTIÓN EMPRESARIAL</span>
        </header>
        <div className={styles.storyCopy}>
          <span className={styles.storyEyebrow}><i /> UNA SOLA OPERACIÓN</span>
          <h1>De la idea<br />a la cancha.</h1>
          <p>Ventas, producción, inventario y finanzas conectados en un mismo ritmo.</p>
        </div>
        <div className={styles.storyModules} aria-label="Áreas conectadas">
          <span>01 <b>Comercial</b></span><span>02 <b>Producción</b></span><span>03 <b>Inventario</b></span>
        </div>
      </section>

      <section className={styles.access}>
        <div className={styles.accessInner}>
          <header className={styles.accessHeader}>
            <div className={styles.mobileBrand}><BomanLogo /><span>GESTIÓN EMPRESARIAL</span></div>
            <span className={styles.accessEyebrow}>ACCESO SEGURO · BOMAN COMMAND</span>
            <h2>{modo === "ingreso" ? "Tu jornada comienza aquí." : modo === "primera-vez" ? "Activa tu cuenta." : "Recupera tu acceso."}</h2>
            <p>{modo === "ingreso" ? "Ingresa a tu espacio de trabajo según tu rol." : modo === "primera-vez" ? "Completa una sola vez la activación enviada a tu correo." : "Te enviaremos un enlace temporal y protegido."}</p>
          </header>

          {error && <div className={styles.contextNotice} role="alert"><b>Revisa tu acceso</b><span>{error}</span></div>}
          {mensaje && <div className={styles.successNotice} role="status"><b>Enlace enviado</b><span>{mensaje}</span></div>}

          {modo === "ingreso" && <form className={styles.form} onSubmit={handleLogin}>
            <div className={styles.field}>
              <label htmlFor="login-email">Correo electrónico</label>
              <input id="login-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required placeholder="nombre@empresa.com" />
            </div>
            <div className={styles.field}>
              <div className={styles.labelRow}><label htmlFor="login-password">Contraseña</label><button type="button" className={styles.textButton} onClick={() => cambiarModo("recuperar")}>Olvidé mi contraseña</button></div>
              <div className={styles.password}>
                <input id="login-password" type={mostrarPassword ? "text" : "password"} autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
                <button type="button" onClick={() => setMostrarPassword((valor) => !valor)}>{mostrarPassword ? "Ocultar" : "Ver"}</button>
              </div>
            </div>
            <button type="submit" disabled={loading} className={styles.primary}>{loading ? <><i /> Verificando acceso…</> : <>Ingresar al sistema <span>→</span></>}</button>
            <button type="button" className={styles.secondary} onClick={() => cambiarModo("primera-vez")}>Recibí una invitación</button>
          </form>}

          {modo === "primera-vez" && <div className={styles.modePanel}>
            <ol className={styles.steps}>
              <li><b>Revisa tu correo.</b><span>Busca la invitación enviada por Boman Sport.</span></li>
              <li><b>Abre el enlace.</b><span>El sistema validará automáticamente que el correo te pertenece.</span></li>
              <li><b>Crea tu contraseña.</b><span>Aparecerá la pantalla para definir y confirmar tu nueva clave.</span></li>
              <li><b>Ingresa al sistema.</b><span>Al guardar la clave entrarás directamente a tu panel.</span></li>
            </ol>
            <div className={styles.info}>Las cuentas son creadas por administración. Si no recibiste la invitación, solicita un nuevo envío.</div>
            <button type="button" className={styles.primary} onClick={() => cambiarModo("ingreso")}>Volver al ingreso <span>→</span></button>
          </div>}

          {modo === "recuperar" && <form className={styles.form} onSubmit={recuperarClave}>
            <div className={styles.field}>
              <label htmlFor="recovery-email">Correo registrado</label>
              <input id="recovery-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required placeholder="nombre@empresa.com" />
              <small>El enlace es temporal y solo puede utilizarse una vez.</small>
            </div>
            <button type="submit" disabled={loading} className={styles.primary}>{loading ? "Enviando…" : <>Enviar enlace seguro <span>→</span></>}</button>
            <button type="button" className={styles.secondary} onClick={() => cambiarModo("ingreso")}>Volver al ingreso</button>
          </form>}
          <footer className={styles.accessFooter}><span><i /> Conexión protegida</span><span>Uso exclusivo de personal autorizado</span></footer>
        </div>
      </section>
    </main>
  );
}
