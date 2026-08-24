"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";

type Opcion = { id: string; nombre?: string; sku?: string };

export default function MovimientoForm({
  perfil,
  productos,
  almacenes,
}: {
  perfil: Perfil;
  productos: Opcion[];
  almacenes: Opcion[];
}) {
  const router = useRouter();
  const supabase = createClient();

  const [productoId, setProductoId] = useState("");
  const [almacenId, setAlmacenId] = useState(perfil.entidad_id ?? "");
  const [almacenDestinoId, setAlmacenDestinoId] = useState("");
  const [tipo, setTipo] = useState<"entrada" | "salida" | "transferencia_envio" | "ajuste">("entrada");
  const [cantidad, setCantidad] = useState(1);
  const [nota, setNota] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);

    if (!productoId || !almacenId || cantidad <= 0) {
      setError("Completa producto, almacén y una cantidad válida.");
      return;
    }
    if (tipo === "transferencia_envio" && !almacenDestinoId) {
      setError("Selecciona el almacén destino de la transferencia.");
      return;
    }

    setLoading(true);
    const { error } = await supabase.rpc("registrar_movimiento", {
      p_producto_id: productoId,
      p_entidad_id: almacenId,
      p_tipo: tipo,
      p_cantidad: cantidad,
      p_nota: nota || null,
      p_usuario_id: perfil.id,
      p_entidad_destino_id: tipo === "transferencia_envio" ? almacenDestinoId : null,
    });
    setLoading(false);

    if (error) {
      setError(error.message.includes("Stock insuficiente") ? "Stock insuficiente para esa salida/transferencia." : error.message);
      return;
    }

    setSuccess("Movimiento registrado.");
    setCantidad(1);
    setNota("");
    router.refresh();
  }

  return (
    <div className="card">
      <h3 style={{ marginTop: 0 }}>Registrar movimiento</h3>
      <form onSubmit={handleSubmit}>
        <div className="grid-2">
          <div className="field">
            <label>Producto</label>
            <select value={productoId} onChange={(e) => setProductoId(e.target.value)} required style={{ width: "100%" }}>
              <option value="">Selecciona...</option>
              {productos.map((p) => (
                <option key={p.id} value={p.id}>{p.nombre} ({p.sku})</option>
              ))}
            </select>
          </div>
          <div className="field">
            <label>Tipo de movimiento</label>
            <select value={tipo} onChange={(e) => setTipo(e.target.value as any)} style={{ width: "100%" }}>
              <option value="entrada">Entrada (llega producción a bodega)</option>
              <option value="salida">Salida (venta / baja)</option>
              <option value="transferencia_envio">Despacho de Bodega a Tienda</option>
              <option value="ajuste">Ajuste (fija el stock exacto)</option>
            </select>
          </div>
          <div className="field">
            <label>Almacén {tipo === "transferencia_envio" ? "(origen)" : ""}</label>
            <select value={almacenId} onChange={(e) => setAlmacenId(e.target.value)} required style={{ width: "100%" }}>
              <option value="">Selecciona...</option>
              {almacenes.map((a) => (
                <option key={a.id} value={a.id}>{a.nombre}</option>
              ))}
            </select>
          </div>
          {tipo === "transferencia_envio" && (
            <div className="field">
              <label>Almacén destino (tienda)</label>
              <select value={almacenDestinoId} onChange={(e) => setAlmacenDestinoId(e.target.value)} required style={{ width: "100%" }}>
                <option value="">Selecciona...</option>
                {almacenes.filter((a) => a.id !== almacenId).map((a) => (
                  <option key={a.id} value={a.id}>{a.nombre}</option>
                ))}
              </select>
            </div>
          )}
          <div className="field">
            <label>Cantidad {tipo === "ajuste" ? "(stock final)" : ""}</label>
            <input type="number" min={1} value={cantidad} onChange={(e) => setCantidad(parseInt(e.target.value) || 0)} required style={{ width: "100%" }} />
          </div>
          <div className="field">
            <label>Nota (opcional)</label>
            <input type="text" value={nota} onChange={(e) => setNota(e.target.value)} style={{ width: "100%" }} />
          </div>
        </div>
        {error && <div className="error">{error}</div>}
        {success && <div className="success">{success}</div>}
        <button type="submit" disabled={loading}>{loading ? "Guardando..." : "Registrar movimiento"}</button>
      </form>
    </div>
  );
}
