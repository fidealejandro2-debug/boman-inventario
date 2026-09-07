"use client";

import { useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { mostrarAvisoDialogo } from "@/components/Dialogo";

export type ProductoResueltoV91 = {
  producto_id: string;
  sku: string;
  producto: string;
  talla: string | null;
  color: string | null;
  codigo: string;
  tipo_codigo: string;
};

export default function BuscadorCodigoProducto({
  onEncontrado,
  etiqueta = "Escáner / código",
  placeholder = "Escanea SKU, EAN, UPC o QR",
  compacto = false,
}: {
  onEncontrado: (producto: ProductoResueltoV91) => void | Promise<void>;
  etiqueta?: string;
  placeholder?: string;
  compacto?: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [codigo, setCodigo] = useState("");
  const [procesando, setProcesando] = useState(false);

  async function buscar(evento: React.FormEvent) {
    evento.preventDefault();
    const valor = codigo.trim();
    if (!valor || procesando) return;
    setProcesando(true);
    const { data, error } = await supabase.rpc("resolver_codigo_producto_v91", { p_codigo: valor });
    setProcesando(false);
    if (error) {
      await mostrarAvisoDialogo(error.message, "No se pudo leer el código", true);
      return;
    }
    const encontrado = Array.isArray(data) ? data[0] as ProductoResueltoV91 | undefined : undefined;
    if (!encontrado) {
      await mostrarAvisoDialogo("No existe un producto visible con ese código.", "Código no encontrado");
      return;
    }
    setCodigo("");
    await onEncontrado(encontrado);
  }

  return <form className={`field buscador-codigo${compacto ? " compacto" : ""}`} onSubmit={buscar}>
    <label>{etiqueta}</label>
    <div>
      <input autoComplete="off" autoCapitalize="off" spellCheck={false} value={codigo}
        onChange={(e) => setCodigo(e.target.value)} placeholder={placeholder} />
      <button type="submit" disabled={procesando || !codigo.trim()}>{procesando ? "Leyendo…" : "Buscar"}</button>
    </div>
  </form>;
}
