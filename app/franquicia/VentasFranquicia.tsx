"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { exportarCSV, fecha as fmtFecha } from "@/lib/utils";
import Aviso from "@/components/Aviso";
import type { Franquicia } from "./FranquiciaCliente";
import { dinero, hoyLocalISO, MEDIOS_PAGO, mensajeError } from "./lib";
import { pedirMotivoDialogo, pedirTextoDialogo } from "@/components/Dialogo";
import DevolucionVentaFranquicia from "./DevolucionVentaFranquicia";

type Disponible = {
  producto_id: string;
  sku: string;
  producto: string;
  talla: string | null;
  color: string | null;
  precio: number;
  stock_disponible: number;
};

type Linea = {
  producto_id: string;
  sku: string;
  nombre: string;
  cantidad: number;
  precio_unitario: number;
  descuento: number;
  stock: number;
};

type PagoVenta = {
  medio_pago: string;
  monto: number;
  referencia: string | null;
};

type PagoMixto = Record<
  "efectivo" | "transferencia" | "tarjeta" | "credito",
  { monto: string; referencia: string }
>;

type Venta = {
  id: string;
  numero: number;
  fecha: string;
  estado: string;
  medio_pago: string;
  subtotal: number;
  descuento: number;
  total: number;
  unidades: number;
  vendedor: string;
  referencia: string | null;
  created_at: string;
  pagos: PagoVenta[];
};
type Cliente = { id: string; nombre: string; identificacion: string | null };

export default function VentasFranquicia({
  franquicia,
  puedePrecio,
  puedeDescuento,
  puedeCredito,
  puedeDevoluciones,
}: {
  franquicia: Franquicia;
  /** Sin esto la venta va al precio de catalogo; la base lo vuelve a validar. */
  puedePrecio: boolean;
  puedeDescuento: boolean;
  puedeCredito: boolean;
  puedeDevoluciones: boolean;
}) {
  const supabase = createClient();
  const [stock, setStock] = useState<Disponible[]>([]);
  const [ventas, setVentas] = useState<Venta[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [tituloAviso, setTituloAviso] = useState("Listo");

  /** El encabezado dice QUE paso; el detalle, que significa. */
  function confirmar(titulo: string, texto: string) {
    setTituloAviso(titulo);
    setAviso(texto);
  }

  const [busqueda, setBusqueda] = useState("");
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [medioPago, setMedioPago] = useState("efectivo");
  const [descuentoGeneral, setDescuentoGeneral] = useState("0");
  const [referencia, setReferencia] = useState("");
  const [pagosMixtos, setPagosMixtos] = useState<PagoMixto>({
    efectivo: { monto: "", referencia: "" },
    transferencia: { monto: "", referencia: "" },
    tarjeta: { monto: "", referencia: "" },
    credito: { monto: "", referencia: "" },
  });
  const [clientes, setClientes] = useState<Cliente[]>([]);
  const [clienteId, setClienteId] = useState("");
  const [vencimiento, setVencimiento] = useState("");
  const [devolviendo, setDevolviendo] = useState<Venta | null>(null);
  const [nota, setNota] = useState("");
  const [fechaVenta, setFechaVenta] = useState(hoyLocalISO());

  async function cargar() {
    setCargando(true);
    const [s, v, c] = await Promise.all([
      supabase
        .from("vista_stock_operativo")
        .select("producto_id, sku, producto, talla, color, precio, stock_disponible")
        .eq("almacen_id", franquicia.almacen_id)
        .order("producto"),
      supabase
        .from("vista_ventas_franquicia_v47")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .order("numero", { ascending: false })
        .limit(100),
      supabase.from("clientes_franquicia").select("id,nombre,identificacion").eq("franquicia_id",franquicia.id).eq("activo",true).order("nombre"),
    ]);
    if (s.error) setError(s.error.message);
    else setStock((s.data as Disponible[]) ?? []);
    if (!v.error) setVentas((v.data as Venta[]) ?? []);
    if (!c.error) setClientes((c.data as Cliente[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [franquicia.id]);

  const resultados = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return [];
    return stock
      .filter(
        (p) =>
          p.stock_disponible > 0 &&
          (p.sku.toLowerCase().includes(q) || p.producto.toLowerCase().includes(q))
      )
      .slice(0, 12);
  }, [stock, busqueda]);

  function agregar(p: Disponible) {
    setError(null);
    if (lineas.some((l) => l.producto_id === p.producto_id)) {
      // La RPC rechaza productos repetidos: se suma a la línea existente.
      setLineas(
        lineas.map((l) =>
          l.producto_id === p.producto_id
            ? { ...l, cantidad: Math.min(l.cantidad + 1, l.stock) }
            : l
        )
      );
    } else {
      setLineas([
        ...lineas,
        {
          producto_id: p.producto_id,
          sku: p.sku,
          nombre: `${p.producto}${p.talla ? ` · ${p.talla}` : ""}${p.color ? ` · ${p.color}` : ""}`,
          cantidad: 1,
          precio_unitario: Number(p.precio ?? 0),
          descuento: 0,
          stock: p.stock_disponible,
        },
      ]);
    }
    setBusqueda("");
  }

  function actualizar(id: string, campo: keyof Linea, valor: number) {
    setLineas(
      lineas.map((l) => (l.producto_id === id ? { ...l, [campo]: valor } : l))
    );
  }

  const subtotal = lineas.reduce(
    (s, l) => s + (l.cantidad * l.precio_unitario - l.descuento),
    0
  );
  const total = subtotal - Number(descuentoGeneral || 0);
  const totalPagosMixtos = Object.values(pagosMixtos).reduce(
    (s, p) => s + Number(p.monto || 0),
    0
  );
  const diferenciaPagos = Math.round((totalPagosMixtos - total) * 100) / 100;

  function actualizarPagoMixto(
    medio: keyof PagoMixto,
    campo: "monto" | "referencia",
    valor: string
  ) {
    setPagosMixtos({
      ...pagosMixtos,
      [medio]: { ...pagosMixtos[medio], [campo]: valor },
    });
  }

  const pagos: PagoVenta[] =
    medioPago === "mixto"
      ? (Object.entries(pagosMixtos) as [keyof PagoMixto, PagoMixto[keyof PagoMixto]][])
          .filter(([, p]) => Number(p.monto || 0) > 0)
          .map(([medio, p]) => ({
            medio_pago: medio,
            monto: Math.round(Number(p.monto) * 100) / 100,
            referencia: p.referencia.trim() || null,
          }))
      : total > 0
        ? [{ medio_pago: medioPago, monto: Math.round(total * 100) / 100, referencia: referencia.trim() || null }]
        : [];

  // Se avisa antes de enviar: la base rechaza la venta entera si algo no cuadra.
  const problemas = lineas
    .filter(
      (l) =>
        l.cantidad > l.stock ||
        l.cantidad <= 0 ||
        l.precio_unitario < 0 ||
        l.descuento < 0 ||
        l.descuento > l.cantidad * l.precio_unitario
    )
    .map((l) =>
      l.cantidad > l.stock
        ? `${l.sku}: solo hay ${l.stock} en el local`
        : `${l.sku}: cantidad, precio o descuento inválidos`
    );
  if (medioPago === "mixto" && Math.abs(diferenciaPagos) >= 0.005) {
    problemas.push(
      diferenciaPagos < 0
        ? `Falta distribuir ${dinero(Math.abs(diferenciaPagos))}`
        : `Los pagos exceden el total por ${dinero(diferenciaPagos)}`
    );
  }
  if (medioPago === "mixto" && pagos.length < 2) {
    problemas.push("Un pago mixto debe usar al menos dos medios");
  }
  if (pagos.some((p) => ["transferencia", "tarjeta"].includes(p.medio_pago) && !p.referencia?.trim())) problemas.push("Transferencia y tarjeta requieren número de referencia");
  if (pagos.some((p) => p.medio_pago === "credito") && (!clienteId || !vencimiento)) problemas.push("El crédito requiere cliente y fecha de vencimiento");

  async function registrar() {
    if (!lineas.length) return setError("Agrega al menos un producto.");
    if (problemas.length) return setError(problemas[0]);
    if (Number(descuentoGeneral || 0) > subtotal)
      return setError("El descuento general no puede superar el subtotal.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_venta_franquicia_v81", {
      p_fecha: fechaVenta,
      p_items: lineas.map((l) => ({
        producto_id: l.producto_id,
        cantidad: l.cantidad,
        precio_unitario: l.precio_unitario,
        descuento: l.descuento,
      })),
      p_pagos: pagos,
      p_descuento: Number(descuentoGeneral || 0),
      p_referencia: medioPago === "mixto" ? null : referencia || null,
      p_nota: nota || null,
      p_cliente_id: clienteId || null,
      p_fecha_vencimiento: vencimiento || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));

    confirmar("Venta registrada", `Por ${dinero(total)}. El stock del local ya se descontó.`);
    setLineas([]);
    setDescuentoGeneral("0");
    setReferencia("");
    setPagosMixtos({
      efectivo: { monto: "", referencia: "" },
      transferencia: { monto: "", referencia: "" },
      tarjeta: { monto: "", referencia: "" },
      credito: { monto: "", referencia: "" },
    });
    setNota("");
    setClienteId(""); setVencimiento("");
    cargar();
  }

  async function anular(v: Venta) {
    const motivo = (await pedirMotivoDialogo(`Motivo de la anulación de la venta #${v.numero} (mínimo 10 caracteres).

El stock vuelve al local y el ingreso sale de la caja. La venta queda registrada como anulada.`))?.trim();
    if (!motivo) return;
    if (motivo.length < 10) return setError("El motivo debe tener al menos 10 caracteres.");
    setGuardando(true);
    setError(null);
    const { data, error } = await supabase.rpc("anular_venta_franquicia_v47", {
      p_venta_id: v.id, p_motivo: motivo, p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    confirmar("Venta anulada", (data as { mensaje?: string } | null)?.mensaje ?? "El stock volvió al local.");
    cargar();
  }

  async function crearCliente() {
    const nombre = (await pedirTextoDialogo("Nombre completo o razón social del cliente:", ""))?.trim();
    if (!nombre) return;
    const identificacion = (await pedirTextoDialogo("Cédula o RUC (opcional):", ""))?.trim() ?? "";
    const telefono = (await pedirTextoDialogo("Teléfono (opcional):", ""))?.trim() ?? "";
    const { data, error } = await supabase.rpc("guardar_cliente_franquicia_v81", {
      p_id: null, p_identificacion: identificacion || null, p_nombre: nombre,
      p_telefono: telefono || null, p_email: null,
    });
    if (error) return setError(mensajeError(error));
    await cargar(); setClienteId(String(data));
  }

  const ventasHoy = ventas.filter((v) => v.fecha === hoyLocalISO() && v.estado === "registrada");
  const totalHoy = ventasHoy.reduce((s, v) => s + Number(v.total), 0);

  if (cargando) return <p className="ayuda">Cargando productos del local…</p>;

  return (
    <>
      <Aviso
        error={error}
        aviso={aviso}
        titulo={tituloAviso}
        onCerrar={(cual) => (cual === "error" ? setError(null) : setAviso(null))}
      />

      <div className="kpis">
        <div className="kpi">
          <span className="valor">{ventasHoy.length}</span>
          <span className="label">Ventas de hoy</span>
        </div>
        <div className="kpi">
          <span className="valor">{dinero(totalHoy)}</span>
          <span className="label">Total de hoy</span>
        </div>
        <div className="kpi">
          <span className="valor">
            {stock.filter((p) => p.stock_disponible > 0).length}
          </span>
          <span className="label">Productos con stock</span>
        </div>
      </div>

      <div className="card-interna">
        <h4>Nueva venta</h4>

        <div className="form-inline">
          <input
            type="search"
            placeholder="Buscar por código o nombre…"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            style={{ minWidth: 260 }}
          />
          <label className="check-inline">
            Fecha
            <input
              type="date"
              value={fechaVenta}
              max={hoyLocalISO()}
              onChange={(e) => setFechaVenta(e.target.value)}
            />
          </label>
        </div>

        {resultados.length > 0 && (
          <div className="fq-resultados">
            {resultados.map((p) => (
              <button
                key={p.producto_id}
                className="fq-resultado"
                onClick={() => agregar(p)}
              >
                <span className="fq-sku">{p.sku}</span>
                <span className="fq-nom">
                  {p.producto}
                  {p.talla ? ` · ${p.talla}` : ""}
                  {p.color ? ` · ${p.color}` : ""}
                </span>
                <span className="fq-datos">
                  {dinero(p.precio)} · {p.stock_disponible} disp.
                </span>
              </button>
            ))}
          </div>
        )}
        {busqueda && !resultados.length && (
          <p className="ayuda">Sin coincidencias con stock disponible en el local.</p>
        )}

        {lineas.length > 0 && (
          <>
            <div className="tabla-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Producto</th>
                    <th className="num">Cant.</th>
                    <th className="num">Precio</th>
                    <th className="num">Desc.</th>
                    <th className="num">Importe</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {lineas.map((l) => (
                    <tr key={l.producto_id}>
                      <td>
                        <strong>{l.sku}</strong>
                        <br />
                        <small>{l.nombre}</small>
                      </td>
                      <td className="num">
                        <input
                          type="number"
                          min="1"
                          max={l.stock}
                          value={l.cantidad}
                          onChange={(e) =>
                            actualizar(l.producto_id, "cantidad", Number(e.target.value))
                          }
                        />
                        {l.cantidad > l.stock && (
                          <div className="fq-alerta">solo {l.stock}</div>
                        )}
                      </td>
                      <td className="num">
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          value={l.precio_unitario}
                          readOnly={!puedePrecio}
                          title={puedePrecio ? "" : "Se vende al precio del catálogo"}
                          onChange={(e) =>
                            actualizar(
                              l.producto_id,
                              "precio_unitario",
                              Number(e.target.value)
                            )
                          }
                        />
                      </td>
                      <td className="num">
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          value={l.descuento}
                          readOnly={!puedeDescuento}
                          title={puedeDescuento ? "" : "No tienes permiso para descontar"}
                          onChange={(e) =>
                            actualizar(l.producto_id, "descuento", Number(e.target.value))
                          }
                        />
                      </td>
                      <td className="num">
                        {dinero(l.cantidad * l.precio_unitario - l.descuento)}
                      </td>
                      <td>
                        <button
                          className="btn-mini secondary"
                          onClick={() =>
                            setLineas(lineas.filter((x) => x.producto_id !== l.producto_id))
                          }
                        >
                          Quitar
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="form-grid">
              <label>
                Medio de pago
                <select value={medioPago} onChange={(e) => setMedioPago(e.target.value)}>
                  {MEDIOS_PAGO.map((m) => (
                    <option key={m.valor} value={m.valor}>
                      {m.etiqueta}
                    </option>
                  ))}
                  {puedeCredito && <option value="credito">Crédito</option>}
                </select>
              </label>
              <label>
                Descuento general
                <input
                  type="number"
                  step="0.01"
                  min="0"
                  max={subtotal}
                  value={descuentoGeneral}
                readOnly={!puedeDescuento}
                  onChange={(e) => setDescuentoGeneral(e.target.value)}
                />
              </label>
              {medioPago !== "mixto" && (
              <label>
                Referencia
                <input
                  type="text"
                  placeholder="N.º de comprobante o transferencia"
                  value={referencia}
                  onChange={(e) => setReferencia(e.target.value)}
                />
              </label>
              )}
              {(medioPago === "credito" || (medioPago === "mixto" && Number(pagosMixtos.credito.monto)>0)) && <>
                <label>Cliente<select value={clienteId} onChange={e=>setClienteId(e.target.value)}><option value="">Selecciona…</option>{clientes.map(c=><option key={c.id} value={c.id}>{c.nombre}{c.identificacion?` · ${c.identificacion}`:""}</option>)}</select><button type="button" className="btn-mini secondary" onClick={crearCliente}>+ Nuevo cliente</button></label>
                <label>Vencimiento<input type="date" min={fechaVenta} value={vencimiento} onChange={e=>setVencimiento(e.target.value)}/></label>
              </>}
              <label className="ancho-total">
                Nota
                <input
                  type="text"
                  value={nota}
                  onChange={(e) => setNota(e.target.value)}
                />
              </label>
            </div>

            {medioPago === "mixto" && (
              <div className="card-interna">
                <h4>Distribucion del pago</h4>
                <p className="ayuda">
                  Escribe cuanto se recibio por cada medio. La suma debe coincidir
                  exactamente con el total de la venta.
                </p>
                <div className="form-grid">
                  {(["efectivo", "transferencia", "tarjeta", ...(puedeCredito ? ["credito" as const] : [])] as const).map((medio) => (
                    <div key={medio}>
                      <label>
                        {medio.charAt(0).toUpperCase() + medio.slice(1)}
                        <input
                          type="number"
                          step="0.01"
                          min="0"
                          value={pagosMixtos[medio].monto}
                          onChange={(e) => actualizarPagoMixto(medio, "monto", e.target.value)}
                        />
                      </label>
                      {["transferencia", "tarjeta"].includes(medio) && (
                        <label>
                          Referencia
                          <input
                            type="text"
                            value={pagosMixtos[medio].referencia}
                            onChange={(e) =>
                              actualizarPagoMixto(medio, "referencia", e.target.value)
                            }
                          />
                        </label>
                      )}
                    </div>
                  ))}
                </div>
                <div className="fq-totales">
                  <span>Distribuido: {dinero(totalPagosMixtos)}</span>
                  <strong>
                    {Math.abs(diferenciaPagos) < 0.005
                      ? "Pago completo"
                      : diferenciaPagos < 0
                        ? `Falta ${dinero(Math.abs(diferenciaPagos))}`
                        : `Exceso ${dinero(diferenciaPagos)}`}
                  </strong>
                </div>
              </div>
            )}

            <div className="fq-totales">
              <span>Subtotal: {dinero(subtotal)}</span>
              <span>Descuento: {dinero(Number(descuentoGeneral || 0))}</span>
              <strong>Total: {dinero(total)}</strong>
            </div>

            {problemas.length > 0 && (
              <p className="aviso">{problemas.join(" · ")}</p>
            )}

            <div className="filtros">
              <button onClick={registrar} disabled={guardando || problemas.length > 0}>
                {guardando ? "Registrando…" : `Registrar venta · ${dinero(total)}`}
              </button>
              <button className="secondary" onClick={() => setLineas([])}>
                Vaciar
              </button>
            </div>
          </>
        )}
      </div>

      <div className="filtros">
        <strong>Últimas ventas</strong>
        <button
          className="secondary"
          onClick={() => exportarCSV("ventas_franquicia", ventas)}
          disabled={!ventas.length}
        >
          Exportar
        </button>
      </div>

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th className="num">N.º</th>
              <th>Fecha</th>
              <th>Medio</th>
              <th className="num">Unidades</th>
              <th className="num">Total</th>
              <th>Vendedor</th>
              <th>Estado</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {ventas.map((v) => (
              <tr key={v.id} className={v.estado !== "registrada" ? "fila-anulada" : ""}>
                <td className="num">{v.numero}</td>
                <td>{fmtFecha(v.created_at)}</td>
                <td>
                  <strong>{v.medio_pago}</strong>
                  {v.pagos?.map((p, i) => (
                    <div key={`${p.medio_pago}-${i}`} className="fq-alerta">
                      {p.medio_pago}: {dinero(p.monto)}
                      {p.referencia ? ` · ${p.referencia}` : ""}
                    </div>
                  ))}
                </td>
                <td className="num">{v.unidades}</td>
                <td className="num">
                  <strong>{dinero(v.total)}</strong>
                </td>
                <td>{v.vendedor}</td>
                <td>
                  <span className={`badge estado-${v.estado}`}>{v.estado}</span>
                </td>
                <td>
                  {v.estado === "registrada" && (
                    <>{puedeDevoluciones&&<button className="btn-mini secondary" disabled={guardando} onClick={() => setDevolviendo(v)}>Devolver</button>}<button className="btn-mini secondary" disabled={guardando} onClick={() => anular(v)}>Anular</button></>
                  )}
                </td>
              </tr>
            ))}
            {!ventas.length && (
              <tr>
                <td colSpan={8} className="vacio">
                  Todavía no hay ventas registradas en este local.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {devolviendo&&<DevolucionVentaFranquicia ventaId={devolviendo.id} numero={devolviendo.numero} factor={devolviendo.subtotal > 0 ? devolviendo.total / devolviendo.subtotal : 1} onCerrar={()=>setDevolviendo(null)} onListo={()=>{setDevolviendo(null);confirmar("Devolución registrada","El stock y el reembolso quedaron registrados.");cargar();}}/>}
    </>
  );
}
