"use client";

import { useEffect, useState } from "react";

export default function ThemeToggle() {
  const [oscuro, setOscuro] = useState(false);

  useEffect(() => {
    setOscuro(document.documentElement.getAttribute("data-theme") === "dark");
  }, []);

  function aplicar(esOscuro: boolean) {
    document.documentElement.setAttribute("data-theme", esOscuro ? "dark" : "light");
    window.localStorage.setItem("boman-tema", esOscuro ? "dark" : "light");
    setOscuro(esOscuro);
  }

  return (
    <div className={`selector-tema${oscuro ? " oscuro" : ""}`} role="group" aria-label="Elegir tema">
      <span className="selector-marca" aria-hidden="true" />
      <button type="button" aria-pressed={!oscuro} onClick={() => aplicar(false)}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
          <circle cx="12" cy="12" r="4.2" />
          <path d="M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4" />
        </svg>
        <span className="selector-etiqueta">Claro</span>
      </button>
      <button type="button" aria-pressed={oscuro} onClick={() => aplicar(true)}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
          <path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5z" />
        </svg>
        <span className="selector-etiqueta">Oscuro</span>
      </button>
    </div>
  );
}
