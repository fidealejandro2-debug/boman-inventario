"use client";

import { useCallback, useEffect, useRef, useState } from "react";

/**
 * Diálogos del sistema, en reemplazo de window.prompt y window.confirm.
 *
 * Los nativos delatan la URL del navegador ("boman-inventario.vercel.app
 * dice"), no se pueden estilar y en algunos navegadores el usuario los puede
 * silenciar para todo el sitio, con lo que una confirmación crítica se saltaría
 * sola.
 *
 * El anfitrión se monta UNA vez en el layout y estas funciones le hablan por
 * una referencia de módulo. Así los sitios de llamada solo cambian de síncrono
 * a `await`, sin pasar props ni envolver el árbol en un provider.
 */
type Peticion =
  | { clase: "motivo"; texto: string; minimo: number; etiqueta?: string; valorInicial?: string }
  | { clase: "confirmar"; texto: string; peligro?: boolean };

type Abridor = (p: Peticion) => Promise<string | boolean | null>;

let abrirRemoto: Abridor | null = null;

/** Pide un motivo escrito. Devuelve el texto, o null si se canceló. */
export async function pedirMotivoDialogo(
  texto: string,
  minimo = 10,
  etiqueta?: string
): Promise<string | null> {
  if (!abrirRemoto) {
    // Sin anfitrión montado no se puede pedir nada: mejor cancelar que seguir
    // adelante sin el motivo que la base va a exigir igual.
    return null;
  }
  const r = await abrirRemoto({ clase: "motivo", texto, minimo, etiqueta });
  return typeof r === "string" ? r : null;
}

/** Confirma una acción. Devuelve true solo si se aceptó. */
export async function confirmarDialogo(
  texto: string,
  peligro = false
): Promise<boolean> {
  if (!abrirRemoto) return false;
  const r = await abrirRemoto({ clase: "confirmar", texto, peligro });
  return r === true;
}

/** Pide un texto libre, con un valor inicial. Sin minimo: no es un motivo. */
export async function pedirTextoDialogo(
  texto: string,
  valorInicial = "",
  etiqueta?: string
): Promise<string | null> {
  if (!abrirRemoto) return null;
  const r = await abrirRemoto({
    clase: "motivo", texto, minimo: 0, etiqueta, valorInicial,
  });
  return typeof r === "string" ? r : null;
}

export default function DialogoAnfitrion() {
  const [peticion, setPeticion] = useState<Peticion | null>(null);
  const [valor, setValor] = useState("");
  const [tocado, setTocado] = useState(false);
  const resolver = useRef<((v: string | boolean | null) => void) | null>(null);
  const campo = useRef<HTMLTextAreaElement | null>(null);

  const abrir = useCallback<Abridor>((p) => {
    setPeticion(p);
    setValor(p.clase === "motivo" ? p.valorInicial ?? "" : "");
    setTocado(false);
    return new Promise((res) => {
      resolver.current = res;
    });
  }, []);

  useEffect(() => {
    abrirRemoto = abrir;
    return () => {
      abrirRemoto = null;
    };
  }, [abrir]);

  const cerrar = useCallback((v: string | boolean | null) => {
    resolver.current?.(v);
    resolver.current = null;
    setPeticion(null);
  }, []);

  useEffect(() => {
    if (!peticion) return;
    const t = setTimeout(() => campo.current?.focus(), 30);
    const alTeclado = (e: KeyboardEvent) => {
      if (e.key === "Escape") cerrar(peticion.clase === "confirmar" ? false : null);
    };
    window.addEventListener("keydown", alTeclado);
    return () => {
      clearTimeout(t);
      window.removeEventListener("keydown", alTeclado);
    };
  }, [peticion, cerrar]);

  if (!peticion) return null;

  const esMotivo = peticion.clase === "motivo";
  const minimo = esMotivo ? peticion.minimo : 0;
  const faltan = minimo - valor.trim().length;
  const valido = !esMotivo || faltan <= 0;

  function aceptar() {
    if (!peticion) return;
    if (!esMotivo) return cerrar(true);
    if (!valido) return setTocado(true);
    cerrar(valor.trim());
  }

  return (
    <div
      className="dlg-fondo no-imprimir"
      role="dialog"
      aria-modal="true"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) cerrar(esMotivo ? null : false);
      }}
    >
      <div className="dlg-caja">
        <div className="dlg-cabecera">
          <span className="dlg-marca">BOMAN</span>
          <span className="dlg-titulo">
            {esMotivo ? "Motivo requerido" : "Confirma la acción"}
          </span>
        </div>

        <div className="dlg-cuerpo">
          <p className="dlg-texto">{peticion.texto}</p>

          {esMotivo && (
            <>
              <label className="dlg-etiqueta">
                {peticion.etiqueta ?? "Motivo"}
                <textarea
                  ref={campo}
                  rows={3}
                  value={valor}
                  onChange={(e) => setValor(e.target.value)}
                  onKeyDown={(e) => {
                    // Enter envía; Shift+Enter hace salto de línea.
                    if (e.key === "Enter" && !e.shiftKey) {
                      e.preventDefault();
                      aceptar();
                    }
                  }}
                  placeholder="Explica brevemente por qué…"
                />
              </label>
              <div className={`dlg-contador ${!valido && tocado ? "corto" : ""}`}>
                {faltan > 0
                  ? `Faltan ${faltan} caracter(es) — mínimo ${minimo}`
                  : "Queda registrado en la auditoría con tu usuario y la fecha."}
              </div>
            </>
          )}
        </div>

        <div className="dlg-acciones">
          <button
            type="button"
            className="secondary"
            onClick={() => cerrar(esMotivo ? null : false)}
          >
            Cancelar
          </button>
          <button
            type="button"
            className={!esMotivo && peticion.peligro ? "peligro" : ""}
            onClick={aceptar}
            disabled={esMotivo && !valido && tocado}
          >
            {esMotivo ? "Guardar motivo" : "Sí, continuar"}
          </button>
        </div>
      </div>
    </div>
  );
}
