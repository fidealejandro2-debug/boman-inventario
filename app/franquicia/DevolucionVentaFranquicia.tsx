"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { dinero, hoyLocalISO, mensajeError } from "./lib";

type Linea = {
  id: string;
  cantidad: number;
  total: number;
  devuelta: number;
  producto: { sku: string; nombre: string } | null;
};

export default function DevolucionVentaFranquicia({ ventaId, numero, factor, onCerrar, onListo }: {
  ventaId: string;
  numero: number;
  factor: number;
  onCerrar: () => void;
  onListo: () => void;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [cantidades, setCantidades] = useState<Record<string, string>>({});
  const [saldoCredito, setSaldoCredito] = useState(0);
  const [medio, setMedio] = useState("efectivo");
  const [referencia, setReferencia] = useState("");
  const [motivo, setMotivo] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [procesando, setProcesando] = useState(false);

  useEffect(() => {
    (async () => {
      const [{ data, error }, { data: cuenta }] = await Promise.all([
        supabase.from("venta_franquicia_lineas")
          .select("id,cantidad,total,producto:productos(sku,nombre)").eq("venta_id", ventaId),
        supabase.from("cuentas_cobrar_franquicia").select("saldo")
          .eq("venta_id", ventaId).eq("estado", "pendiente").maybeSingle(),
      ]);
      if (error) return setError(error.message);
      setSaldoCredito(Number(cuenta?.saldo ?? 0));
      const base = (data ?? []) as unknown as Omit<Linea, "devuelta">[];
      const ids = base.map((l) => l.id);
      const { data: devueltas, error: errorDevueltas } = ids.length
        ? await supabase.from("devolucion_franquicia_lineas")
            .select("venta_linea_id,cantidad").in("venta_linea_id", ids)
        : { data: [], error: null };
      if (errorDevueltas) return setError(errorDevueltas.message);
      const acumulado = new Map<string, number>();
      (devueltas ?? []).forEach((d) => acumulado.set(
        d.venta_linea_id,
        (acumulado.get(d.venta_linea_id) ?? 0) + Number(d.cantidad)
      ));
      setLineas(base.map((l) => ({ ...l, devuelta: acumulado.get(l.id) ?? 0 })));
    })();
  }, [supabase, ventaId]);

  // Suma antes de redondear, igual que la RPC, para evitar diferencias de un centavo.
  const elegidas = lineas.map((l) => ({
    linea_id: l.id,
    cantidad: Number(cantidades[l.id] || 0),
    disponible: l.cantidad - l.devuelta,
    montoBruto: Number(cantidades[l.id] || 0) * (Number(l.total) / l.cantidad) * factor,
  })).filter((x) => x.cantidad > 0);
  const total = Math.round(elegidas.reduce((s, x) => s + x.montoBruto, 0) * 100) / 100;

  async function guardar() {
    if (!elegidas.length) return setError("Indica al menos una unidad.");
    if (elegidas.some((x) => x.cantidad > x.disponible))
      return setError("Una cantidad supera las unidades disponibles para devolver.");
    if (motivo.trim().length < 10)
      return setError("Explica el motivo con al menos 10 caracteres.");
    if (["transferencia", "tarjeta"].includes(medio) && !referencia.trim())
      return setError("La referencia es obligatoria.");
    if (medio === "credito" && total > saldoCredito)
      return setError("El ajuste supera el saldo pendiente del cliente.");
    setProcesando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_devolucion_franquicia_v81", {
      p_venta_id: ventaId,
      p_fecha: hoyLocalISO(),
      p_items: elegidas.map(({ linea_id, cantidad }) => ({ linea_id, cantidad })),
      p_reembolsos: [{ medio_pago: medio, monto: total, referencia: referencia || null }],
      p_motivo: motivo.trim(),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) return setError(mensajeError(error));
    onListo();
  }

  return <div className="modal-operativo" onMouseDown={(e) => e.target === e.currentTarget && onCerrar()}>
    <div className="modal-contenido">
      <div className="header-row"><h2>Cambio o devolución · venta #{numero}</h2><button className="secondary" onClick={onCerrar}>Cerrar</button></div>
      {error && <p className="error">{error}</p>}
      <p className="ayuda">Selecciona únicamente lo que regresa al local. Para un cambio, registra después la prenda entregada como nueva venta; así ambos movimientos conservan trazabilidad.</p>
      <div className="tabla-scroll"><table>
        <thead><tr><th>Producto</th><th>Disponibles para devolver</th><th>A devolver</th><th className="num">Valor</th></tr></thead>
        <tbody>{lineas.map((l) => { const disponible = l.cantidad - l.devuelta; return <tr key={l.id}>
          <td>{l.producto?.sku} · {l.producto?.nombre}</td>
          <td>{disponible}{l.devuelta > 0 ? ` (${l.devuelta} ya devuelta${l.devuelta === 1 ? "" : "s"})` : ""}</td>
          <td><input type="number" min="0" max={disponible} value={cantidades[l.id] || ""} onChange={(e) => setCantidades({ ...cantidades, [l.id]: e.target.value })} /></td>
          <td className="num">{dinero(Number(cantidades[l.id] || 0) * (Number(l.total) / l.cantidad) * factor)}</td>
        </tr>; })}</tbody>
      </table></div>
      <div className="form-grid">
        <label>Forma de reembolso<select value={medio} onChange={(e) => setMedio(e.target.value)}>
          <option value="efectivo">Efectivo</option><option value="transferencia">Transferencia</option><option value="tarjeta">Tarjeta</option>
          {saldoCredito > 0 && <option value="credito">Reducir saldo a crédito ({dinero(saldoCredito)})</option>}
        </select></label>
        {["transferencia", "tarjeta"].includes(medio) && <label>Referencia *<input value={referencia} onChange={(e) => setReferencia(e.target.value)} /></label>}
        <label className="ancho-total">Motivo *<input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Motivo del cambio o devolución" /></label>
      </div>
      <div className="fq-totales"><strong>A reembolsar: {dinero(total)}</strong></div>
      <button onClick={guardar} disabled={procesando || !elegidas.length}>{procesando ? "Procesando…" : "Confirmar devolución"}</button>
    </div>
  </div>;
}
