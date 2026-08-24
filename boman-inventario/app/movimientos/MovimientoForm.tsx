"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";

type Opcion = { id: string; nombre?: string; sku?: string };

export default function MovimientoForm({
  perfil,
  productos,
  entidades,
}: {
  perfil: Perfil;
  productos: Opcion[];
  entidades: Opcion[];
}) {
  const router = useRouter();
  const supabase = createClient();

  const [productoId, setProductoId] = useState("");
  const [entidadId, setEntidadId] = useState(perfil.entidad_id ?? "");
  const [entidadDestinoId, setEntidadDestinoId] = useState("");
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

    if (!productoId || !entidadId || cantidad <= 0) {
      setError("Completa producto, entidad y una cantidad válida.");
      return;
    }
    if (tipo === "transferencia_envio" && !entidadDestinoId) {
      setError("Selecciona la entidad destino de la transferencia.");
      return;
    }

    setLoading(true);
    const { error } = await supabase.rpc("registrar_movimiento", {
      p_producto_id: productoId,
      p_entidad_id: entidadId,
      p_tipo: tipo,
      p_cantidad: cantidad,
      p_nota: nota || null,
      p_usuario_id: perfil.id,
      p_entidad_destino_id: tipo === "transferencia_envio" ? entidadDestinoId : null,
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
              <option value="entrada">Entrada</option>
              <option value="salida">Salida</option>
              <option value="transferencia_envio">Transferencia entre entidades</option>
              <option value="ajuste">Ajuste (fija el stock exacto)</option>
            </select>
          </div>
          <div className="field">
            <label>Entidad {tipo === "transferencia_envio" ? "(origen)" : ""}</label>
            <select value={entidadId} onChange={(e) => setEntidadId(e.target.value)} required style={{ width: "100%" }}>
              <option value="">Selecciona...</option>
              {entidades.map((ent) => (
                <option key={ent.id} value={ent.id}>{ent.nombre}</option>
              ))}
            </select>
          </div>
          {tipo === "transferencia_envio" && (
            <div className="field">
              <label>Entidad destino</label>
              <select value={entidadDestinoId} onChange={(e) => setEntidadDestinoId(e.target.value)} required style={{ width: "100%" }}>
                <option value="">Selecciona...</option>
                {entidades.filter((ent) => ent.id !== entidadId).map((ent) => (
                  <option key={ent.id} value={ent.id}>{ent.nombre}</option>
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
