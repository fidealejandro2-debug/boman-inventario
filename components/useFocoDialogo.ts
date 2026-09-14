"use client";

import { useEffect, type RefObject } from "react";

export function useFocoDialogo(ref: RefObject<HTMLElement>, abierto: boolean) {
  useEffect(() => {
    const dialogo = ref.current;
    if (!abierto || !dialogo) return;
    const anterior = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const bloqueados: { elemento: HTMLElement; inert: boolean }[] = [];
    let nodo: HTMLElement = dialogo;
    while (nodo.parentElement) {
      for (const hermano of Array.from(nodo.parentElement.children)) {
        if (hermano !== nodo && hermano instanceof HTMLElement && !["SCRIPT", "STYLE"].includes(hermano.tagName)) {
          bloqueados.push({ elemento: hermano, inert: hermano.inert });
          hermano.inert = true;
        }
      }
      if (nodo.parentElement === document.body) break;
      nodo = nodo.parentElement;
    }
    const controles = () => Array.from(dialogo.querySelectorAll<HTMLElement>(
      'button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]'
    )).filter(elemento => !elemento.closest('[inert], [hidden]') && elemento.getClientRects().length > 0);
    const enfocar = () => (dialogo.querySelector<HTMLElement>('[data-foco-inicial]') ?? controles()[0] ?? dialogo).focus();
    enfocar();
    function teclado(evento: KeyboardEvent) {
      if (dialogo?.closest('[inert]')) return;
      if (evento.key !== "Tab") return;
      const lista = controles();
      const primero = lista[0];
      const ultimo = lista[lista.length - 1];
      if (!primero) { evento.preventDefault(); dialogo?.focus(); return; }
      if (evento.shiftKey && (document.activeElement === primero || !lista.includes(document.activeElement as HTMLElement))) {
        evento.preventDefault(); ultimo.focus();
      } else if (!evento.shiftKey && (document.activeElement === ultimo || !lista.includes(document.activeElement as HTMLElement))) {
        evento.preventDefault(); primero.focus();
      }
    }
    function mantenerFoco(evento: FocusEvent) {
      if (dialogo?.closest('[inert]')) return;
      if (evento.target instanceof Node && !dialogo?.contains(evento.target)) enfocar();
    }
    document.addEventListener("keydown", teclado);
    document.addEventListener("focusin", mantenerFoco);
    return () => {
      document.removeEventListener("keydown", teclado);
      document.removeEventListener("focusin", mantenerFoco);
      bloqueados.forEach(({ elemento, inert }) => { elemento.inert = inert; });
      document.body.style.overflow = overflow;
      if (anterior?.isConnected) anterior.focus();
    };
  }, [abierto, ref]);
}
