"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function ProductoForm() {
  const router = useRouter();
  const supabase = createClient();

  const [sku, setSku] = useState("");
  const [nombre, setNombre] = useState("");
  const [categoria, setCategoria] = useState("");
  const [talla, setTalla] = useState("");
  const [color, setColor] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    setLoading(true);

    const { error } = await supabase.from("productos").insert({
      sku,
      nombre,
      categoria,
      talla: talla || null,
      color: color || null,
    });

    setLoading(false);

    if (error) {
      setError(error.message.includes("duplicate") ? "Ese SKU ya existe." : error.message);
      return;
    }

    setSuccess("Producto creado.");
    setSku("");
    setNombre("");
    setCategoria("");
    setTalla("");
    setColor("");
    router.refresh();
  }

  return (
    <div className="card">
      <h3 style={{ marginTop: 0 }}>Nuevo producto</h3>
      <form onSubmit={handleSubmit}>
        <div className="grid-2">
          <div className="field">
            <label>SKU</label>
            <input value={sku} onChange={(e) => setSku(e.target.value)} required style={{ width: "100%" }} />
          </div>
          <div className="field">
            <label>Nombre</label>
            <input value={nombre} onChange={(e) => setNombre(e.target.value)} required style={{ width: "100%" }} />
          </div>
          <div className="field">
            <label>Categoría</label>
            <input value={categoria} onChange={(e) => setCategoria(e.target.value)} placeholder="camiseta, short, buzo..." required style={{ width: "100%" }} />
          </div>
          <div className="field">
            <label>Talla</label>
            <input value={talla} onChange={(e) => setTalla(e.target.value)} placeholder="S, M, L, XL..." style={{ width: "100%" }} />
          </div>
          <div className="field">
            <label>Color</label>
            <input value={color} onChange={(e) => setColor(e.target.value)} style={{ width: "100%" }} />
          </div>
        </div>
        {error && <div className="error">{error}</div>}
        {success && <div className="success">{success}</div>}
        <button type="submit" disabled={loading}>{loading ? "Guardando..." : "Crear producto"}</button>
      </form>
    </div>
  );
}
