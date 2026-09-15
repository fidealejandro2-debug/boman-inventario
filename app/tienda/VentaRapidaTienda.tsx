"use client";

// Pestaña "Venta rápida" del panel de tienda propia. Solo registra CAJA
// (ingreso), nunca descuenta inventario: el único movimiento de stock real
// sigue siendo el de la factura XML cuando se aplica desde /ventas. Por eso
// las líneas de producto aquí son de referencia -para que el vendedor sepa
// qué vendió-, no una venta con descuento de stock como en Franquicia.
// Ver sql/v148_venta_rapida_tienda.sql.

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { dinero, hoyLocalISO, mensajeError } from "@/app/franquicia/lib";
import { pedirMotivoDialogo } from "@/components/Dialogo";
import ComprobanteDeposito, { type ArchivoComprobante } from "@/app/franquicia/ComprobanteDeposito";

const BUCKET_COMPROBANTES_VENTA = "ventas-comprobantes";
const MEDIOS = [
  { valor: "efectivo", etiqueta: "Efectivo" },
  { valor: "transferencia", etiqueta: "Transferencia" },
  { valor: "tarjeta", etiqueta: "Tarjeta" },
  { valor: "otro", etiqueta: "Otro" },
];
const ESTADOS: Record<string, string> = {
  registrada: "Registrada",
  vinculada_factura: "Vinculada a factura",
  sin_factura: "Sin factura",
  anulada: "Anulada",
};

type Producto = { producto_id: string; sku: string; producto: string; precio: number };
type LineaVenta = { producto_id: string | null; descripcion: string; cantidad: string; precio_unitario: string };
type Pago = { medio_pago: string; monto: string; referencia: string; comprobante: ArchivoComprobante | null };
type Venta = {
  id: string; numero: number; fecha: string; concepto: string; total: number;
  estado: string; documento_venta_xml_id: string | null; created_at: string;
};
type Factura = { id: string; numero_documento: string; fecha_emision: string; importe_total: number };

function nuevaLinea(): LineaVenta {
  return { producto_id: null, descripcion: "", cantidad: "1", precio_unitario: "" };
}
function nuevoPago(): Pago {
  return { medio_pago: "efectivo", monto: "", referencia: "", comprobante: null };
}

export default function VentaRapidaTienda({ almacenId, soloLectura = false }: { almacenId: string; soloLectura?: boolean }) {
  const supabase = createClient();
  const [productos, setProductos] = useState<Producto[]>([]);
  const [ventas, setVentas] = useState<Venta[]>([]);
  const [facturasSinVincular, setFacturasSinVincular] = useState<Factura[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [fecha, setFecha] = useState(hoyLocalISO());
  const [concepto, setConcepto] = useState("");
  const [conItems, setConItems] = useState(false);
  const [lineas, setLineas] = useState<LineaVenta[]>([nuevaLinea()]);
  const [medioPago, setMedioPago] = useState<"unico" | "mixto">("unico");
  const [pago, setPago] = useState<Pago>(nuevoPago());
  const [pagosMixtos, setPagosMixtos] = useState<Pago[]>([nuevoPago(), nuevoPago()]);
  const [nota, setNota] = useState("");
  const [vinculando, setVinculando] = useState<Venta | null>(null);
  const [facturaSeleccionada, setFacturaSeleccionada] = useState("");

  async function cargar() {
    setCargando(true);
    const [p, v, f] = await Promise.all([
      supabase.from("vista_stock_operativo").select("producto_id, sku, producto, precio").eq("almacen_id", almacenId).order("producto"),
      supabase.from("venta_rapida_v148").select("id, numero, fecha, concepto, total, estado, documento_venta_xml_id, created_at")
        .eq("almacen_id", almacenId).order("fecha", { ascending: false }).order("numero", { ascending: false }).limit(50),
      supabase.from("documentos_venta_xml").select("id, numero_documento, fecha_emision, importe_total")
        .eq("almacen_id", almacenId).eq("anulado", false)
        .order("fecha_emision", { ascending: false }).limit(200),
    ]);
    if (p.error) setError(mensajeError(p.error));
    else setProductos((p.data as Producto[]) ?? []);
    if (v.error) setError(mensajeError(v.error));
    else setVentas((v.data as Venta[]) ?? []);
    if (!f.error) {
      const yaVinculadas = new Set((v.data as Venta[] ?? []).map((x) => x.documento_venta_xml_id).filter(Boolean));
      setFacturasSinVincular(((f.data as Factura[]) ?? []).filter((x) => !yaVinculadas.has(x.id)));
    }
    setCargando(false);
  }

  useEffect(() => {
    void cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [almacenId]);

  const totalItems = conItems
    ? lineas.reduce((s, l) => s + (Number(l.cantidad) || 0) * (Number(l.precio_unitario) || 0), 0)
    : 0;
  const pagosActivos: Pago[] = medioPago === "unico" ? [pago] : pagosMixtos.filter((p) => Number(p.monto) > 0);
  const totalPagos = pagosActivos.reduce((s, p) => s + (Number(p.monto) || 0), 0);

  function agregarLinea() { setLineas([...lineas, nuevaLinea()]); }
  function quitarLinea(i: number) { setLineas(lineas.filter((_, idx) => idx !== i)); }
  function cambiarLinea(i: number, cambios: Partial<LineaVenta>) {
    setLineas(lineas.map((l, idx) => (idx === i ? { ...l, ...cambios } : l)));
  }
  function elegirProducto(i: number, productoId: string) {
    const p = productos.find((x) => x.producto_id === productoId);
    cambiarLinea(i, { producto_id: productoId || null, descripcion: p?.producto ?? "", precio_unitario: p ? String(p.precio) : "" });
  }

  async function registrar() {
    if (!concepto.trim()) return setError("Describe brevemente la venta.");
    if (conItems && lineas.some((l) => !l.descripcion.trim() || Number(l.cantidad) <= 0 || Number(l.precio_unitario) < 0)) {
      return setError("Revisa las líneas: descripción, cantidad y precio deben ser válidos.");
    }
    if (!pagosActivos.length || pagosActivos.some((p) => Number(p.monto) <= 0)) {
      return setError("Indica el monto cobrado.");
    }
    if (medioPago === "mixto" && pagosActivos.length < 2) return setError("Un pago mixto debe usar al menos dos medios.");
    if (pagosActivos.some((p) => ["transferencia", "tarjeta"].includes(p.medio_pago) && !p.referencia.trim())) {
      return setError("Transferencia y tarjeta requieren número de referencia.");
    }
    if (pagosActivos.some((p) => p.medio_pago === "transferencia" && !p.comprobante)) {
      return setError("Adjunta el comprobante de la transferencia.");
    }
    const totalEsperado = conItems ? totalItems : totalPagos;
    if (conItems && Math.abs(totalPagos - totalEsperado) >= 0.005) {
      return setError(`La suma de pagos (${dinero(totalPagos)}) debe ser igual al total de items (${dinero(totalEsperado)}).`);
    }

    setGuardando(true);
    setError(null);
    try {
      const pagosConComprobante = [];
      for (const p of pagosActivos) {
        let comprobanteId: string | null = null;
        if (p.medio_pago === "transferencia" && p.comprobante) {
          const { data: preparado, error: errorPreparacion } = await supabase.rpc("preparar_comprobante_venta_v148", {
            p_almacen_id: almacenId,
            p_nombre_archivo: p.comprobante.file.name,
            p_mime_type: p.comprobante.file.type,
            p_tamano_bytes: p.comprobante.file.size,
            p_idempotency_key: p.comprobante.id,
          });
          if (errorPreparacion) throw errorPreparacion;
          const path = (preparado as { path: string }).path;
          const { error: errorSubida } = await supabase.storage
            .from(BUCKET_COMPROBANTES_VENTA)
            .upload(path, p.comprobante.file, { contentType: p.comprobante.file.type, upsert: false });
          if (errorSubida && !/already exists|duplicate/i.test(errorSubida.message)) throw errorSubida;
          comprobanteId = p.comprobante.id;
        }
        pagosConComprobante.push({
          medio_pago: p.medio_pago, monto: Math.round(Number(p.monto) * 100) / 100,
          referencia: p.referencia.trim() || null, comprobante_id: comprobanteId,
        });
      }

      const { data, error } = await supabase.rpc("registrar_venta_rapida_v148", {
        p_fecha: fecha,
        p_concepto: concepto.trim(),
        p_items: conItems
          ? lineas.map((l) => ({
              producto_id: l.producto_id, descripcion: l.descripcion.trim(),
              cantidad: Number(l.cantidad), precio_unitario: Number(l.precio_unitario),
            }))
          : [],
        p_pagos: pagosConComprobante,
        p_descuento: 0,
        p_nota: nota.trim() || null,
        p_idempotency_key: nuevaClaveIdempotencia(),
        p_almacen_id: almacenId,
      });
      if (error) throw error;
      const numero = (data as { numero?: number } | null)?.numero;
      setError(null);
      alert(`Venta rápida #${numero ?? ""} registrada.`);
      setConcepto(""); setLineas([nuevaLinea()]); setConItems(false); setNota("");
      setPago(nuevoPago()); setPagosMixtos([nuevoPago(), nuevoPago()]); setMedioPago("unico");
      void cargar();
    } catch (e) {
      setError(mensajeError(e instanceof Error ? e : { message: String(e) }));
    } finally {
      setGuardando(false);
    }
  }

  async function vincular() {
    if (!vinculando || !facturaSeleccionada) return;
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("vincular_venta_rapida_factura_v148", {
      p_venta_id: vinculando.id, p_documento_venta_xml_id: facturaSeleccionada,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setVinculando(null); setFacturaSeleccionada("");
    void cargar();
  }

  async function marcarSinFactura(v: Venta) {
    const motivo = (await pedirMotivoDialogo(`¿Por qué la venta #${v.numero} no va a tener factura XML? (ej. "Abono de contrato de producción", mínimo 10 caracteres)`))?.trim();
    if (!motivo) return;
    if (motivo.length < 10) return setError("El motivo debe tener al menos 10 caracteres.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("marcar_venta_rapida_sin_factura_v148", { p_venta_id: v.id, p_motivo: motivo });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    void cargar();
  }

  async function anular(v: Venta) {
    const motivo = (await pedirMotivoDialogo(`Motivo de anulación de la venta #${v.numero} (mínimo 10 caracteres). El ingreso sale de la caja.`))?.trim();
    if (!motivo) return;
    if (motivo.length < 10) return setError("El motivo debe tener al menos 10 caracteres.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("anular_venta_rapida_v148", { p_venta_id: v.id, p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia() });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    void cargar();
  }

  return (
    <div>
      {error && <div className="error-box">{error}</div>}
      <div className="info-box">
        Esto <strong>no descuenta inventario</strong>: solo registra el cobro en caja. El
        inventario se descuenta al aplicar la factura XML real (pestaña Factura XML). Usa
        &quot;Vincular con factura XML&quot; cuando esa factura llegue, o &quot;Marcar sin
        factura&quot; si esta venta nunca la va a tener (ej. un abono de contrato).
      </div>

      {!soloLectura && (
        <div className="card-interna">
          <h4>Registrar venta rápida</h4>
          <div className="form-grid">
            <label>
              Fecha
              <input type="date" value={fecha} max={hoyLocalISO()} onChange={(e) => setFecha(e.target.value)} />
            </label>
            <label className="ancho-total">
              Concepto
              <input type="text" placeholder="Ej: Venta mostrador, Abono contrato #123…" value={concepto} onChange={(e) => setConcepto(e.target.value)} />
            </label>
          </div>

          <label style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <input type="checkbox" checked={conItems} onChange={(e) => setConItems(e.target.checked)} />
            Detallar productos vendidos (opcional — solo referencia, no descuenta stock)
          </label>

          {conItems && (
            <div className="tabla-scroll">
              <table>
                <thead><tr><th>Producto</th><th>Descripción</th><th className="num">Cant.</th><th className="num">P. unit.</th><th className="num">Total</th><th></th></tr></thead>
                <tbody>
                  {lineas.map((l, i) => (
                    <tr key={i}>
                      <td>
                        <select value={l.producto_id ?? ""} onChange={(e) => elegirProducto(i, e.target.value)}>
                          <option value="">Texto libre…</option>
                          {productos.map((p) => <option key={p.producto_id} value={p.producto_id}>{p.sku} — {p.producto}</option>)}
                        </select>
                      </td>
                      <td><input type="text" value={l.descripcion} onChange={(e) => cambiarLinea(i, { descripcion: e.target.value })} /></td>
                      <td><input type="number" min="0" step="0.01" className="num" value={l.cantidad} onChange={(e) => cambiarLinea(i, { cantidad: e.target.value })} /></td>
                      <td><input type="number" min="0" step="0.01" className="num" value={l.precio_unitario} onChange={(e) => cambiarLinea(i, { precio_unitario: e.target.value })} /></td>
                      <td className="num">{dinero((Number(l.cantidad) || 0) * (Number(l.precio_unitario) || 0))}</td>
                      <td>{lineas.length > 1 && <button type="button" className="secondary btn-mini" onClick={() => quitarLinea(i)}>Quitar</button>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <button type="button" className="secondary btn-mini" onClick={agregarLinea}>+ Agregar línea</button>
              <p className="ayuda">Total de items: {dinero(totalItems)}</p>
            </div>
          )}

          <div className="card-interna">
            <h4>Cobro</h4>
            <label>
              <select value={medioPago} onChange={(e) => setMedioPago(e.target.value as "unico" | "mixto")}>
                <option value="unico">Un solo medio</option>
                <option value="mixto">Mixto (varios medios)</option>
              </select>
            </label>
            {medioPago === "unico" ? (
              <div className="form-grid">
                <label>
                  Medio
                  <select value={pago.medio_pago} onChange={(e) => setPago({ ...pago, medio_pago: e.target.value })}>
                    {MEDIOS.map((m) => <option key={m.valor} value={m.valor}>{m.etiqueta}</option>)}
                  </select>
                </label>
                <label>
                  Monto
                  <input type="number" step="0.01" min="0" value={pago.monto} onChange={(e) => setPago({ ...pago, monto: e.target.value })} />
                </label>
                {["transferencia", "tarjeta"].includes(pago.medio_pago) && (
                  <label>
                    Referencia
                    <input type="text" value={pago.referencia} onChange={(e) => setPago({ ...pago, referencia: e.target.value })} />
                  </label>
                )}
                {pago.medio_pago === "transferencia" && (
                  <div className="ancho-total">
                    <ComprobanteDeposito archivo={pago.comprobante} onChange={(a) => setPago({ ...pago, comprobante: a })} titulo="Comprobante de la transferencia" />
                  </div>
                )}
              </div>
            ) : (
              <>
                {pagosMixtos.map((p, i) => (
                  <div key={i} className="form-grid">
                    <label>
                      Medio
                      <select value={p.medio_pago} onChange={(e) => setPagosMixtos(pagosMixtos.map((x, idx) => idx === i ? { ...x, medio_pago: e.target.value } : x))}>
                        {MEDIOS.map((m) => <option key={m.valor} value={m.valor}>{m.etiqueta}</option>)}
                      </select>
                    </label>
                    <label>
                      Monto
                      <input type="number" step="0.01" min="0" value={p.monto} onChange={(e) => setPagosMixtos(pagosMixtos.map((x, idx) => idx === i ? { ...x, monto: e.target.value } : x))} />
                    </label>
                    {["transferencia", "tarjeta"].includes(p.medio_pago) && (
                      <label>
                        Referencia
                        <input type="text" value={p.referencia} onChange={(e) => setPagosMixtos(pagosMixtos.map((x, idx) => idx === i ? { ...x, referencia: e.target.value } : x))} />
                      </label>
                    )}
                    {p.medio_pago === "transferencia" && Number(p.monto) > 0 && (
                      <ComprobanteDeposito archivo={p.comprobante} onChange={(a) => setPagosMixtos(pagosMixtos.map((x, idx) => idx === i ? { ...x, comprobante: a } : x))} titulo="Comprobante de la transferencia" />
                    )}
                  </div>
                ))}
                <button type="button" className="secondary btn-mini" onClick={() => setPagosMixtos([...pagosMixtos, nuevoPago()])}>+ Agregar medio</button>
                <p className="ayuda">Distribuido: {dinero(totalPagos)}</p>
              </>
            )}
          </div>

          <label className="ancho-total">
            Nota
            <input type="text" value={nota} onChange={(e) => setNota(e.target.value)} />
          </label>
          <button type="button" onClick={registrar} disabled={guardando}>
            {guardando ? "Guardando…" : "Registrar venta rápida"}
          </button>
        </div>
      )}

      <div className="card-interna">
        <h4>Ventas recientes</h4>
        {cargando ? <p className="ayuda">Cargando…</p> : !ventas.length ? (
          <p className="ayuda">Todavía no hay ventas rápidas registradas en este local.</p>
        ) : (
          <div className="tabla-scroll">
            <table>
              <thead><tr><th>#</th><th>Fecha</th><th>Concepto</th><th className="num">Total</th><th>Estado</th><th></th></tr></thead>
              <tbody>
                {ventas.map((v) => (
                  <tr key={v.id} className={v.estado === "anulada" ? "fila-anulada" : ""}>
                    <td>{v.numero}</td>
                    <td>{v.fecha.split("-").reverse().join("/")}</td>
                    <td>{v.concepto}</td>
                    <td className="num">{dinero(v.total)}</td>
                    <td>{ESTADOS[v.estado] ?? v.estado}</td>
                    <td>
                      {!soloLectura && v.estado === "registrada" && (
                        <>
                          <button type="button" className="secondary btn-mini" onClick={() => setVinculando(v)}>Vincular con factura XML</button>{" "}
                          <button type="button" className="secondary btn-mini" onClick={() => marcarSinFactura(v)}>Marcar sin factura</button>{" "}
                        </>
                      )}
                      {!soloLectura && v.estado !== "anulada" && (
                        <button type="button" className="secondary btn-mini" onClick={() => anular(v)}>Anular</button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {vinculando && (
        <div className="modal-operativo" onClick={() => setVinculando(null)}>
          <div className="modal-contenido" onClick={(e) => e.stopPropagation()}>
            <h3>Vincular venta #{vinculando.numero} con una factura XML</h3>
            {!facturasSinVincular.length ? (
              <p className="ayuda">No hay facturas XML de este local sin vincular todavía. Impórtala primero desde la pestaña Factura XML.</p>
            ) : (
              <label>
                Factura
                <select value={facturaSeleccionada} onChange={(e) => setFacturaSeleccionada(e.target.value)}>
                  <option value="">Selecciona…</option>
                  {facturasSinVincular.map((f) => (
                    <option key={f.id} value={f.id}>{f.numero_documento} · {f.fecha_emision.split("-").reverse().join("/")} · {dinero(f.importe_total)}</option>
                  ))}
                </select>
              </label>
            )}
            <div className="modal-acciones">
              <button type="button" className="secondary" onClick={() => setVinculando(null)}>Cancelar</button>
              <button type="button" onClick={vincular} disabled={!facturaSeleccionada || guardando}>Vincular</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
