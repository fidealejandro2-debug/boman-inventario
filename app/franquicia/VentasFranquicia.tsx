"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { exportarCSV, fecha as fmtFecha } from "@/lib/utils";
import type { Franquicia } from "./FranquiciaCliente";
import { dinero, hoyLocalISO, MEDIOS_PAGO, mensajeError } from "./lib";

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
};

export default function VentasFranquicia({ franquicia }: { franquicia: Franquicia }) {
  const supabase = createClient();
  const [stock, setStock] = useState<Disponible[]>([]);
  const [ventas, setVentas] = useState<Venta[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  const [busqueda, setBusqueda] = useState("");
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [medioPago, setMedioPago] = useState("efectivo");
  const [descuentoGeneral, setDescuentoGeneral] = useState("0");
  const [referencia, setReferencia] = useState("");
  const [nota, setNota] = useState("");
  const [fechaVenta, setFechaVenta] = useState(hoyLocalISO());

  async function cargar() {
    setCargando(true);
    const [s, v] = await Promise.all([
      supabase
        .from("vista_stock_operativo")
        .select("producto_id, sku, producto, talla, color, precio, stock_disponible")
        .eq("almacen_id", franquicia.almacen_id)
        .order("producto"),
      supabase
        .from("vista_ventas_franquicia_v42")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .order("numero", { ascending: false })
        .limit(100),
    ]);
    if (s.error) setError(s.error.message);
    else setStock((s.data as Disponible[]) ?? []);
    if (!v.error) setVentas((v.data as Venta[]) ?? []);
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

  async function registrar() {
    if (!lineas.length) return setError("Agrega al menos un producto.");
    if (problemas.length) return setError(problemas[0]);
    if (Number(descuentoGeneral || 0) > subtotal)
      return setError("El descuento general no puede superar el subtotal.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_venta_franquicia_v42", {
      p_fecha: fechaVenta,
      p_items: lineas.map((l) => ({
        producto_id: l.producto_id,
        cantidad: l.cantidad,
        precio_unitario: l.precio_unitario,
        descuento: l.descuento,
      })),
      p_medio_pago: medioPago,
      p_descuento: Number(descuentoGeneral || 0),
      p_referencia: referencia || null,
      p_nota: nota || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));

    setAviso(`Venta registrada por ${dinero(total)}. El stock del local ya se descontó.`);
    setLineas([]);
    setDescuentoGeneral("0");
    setReferencia("");
    setNota("");
    cargar();
  }

  const ventasHoy = ventas.filter((v) => v.fecha === hoyLocalISO() && v.estado === "vigente");
  const totalHoy = ventasHoy.reduce((s, v) => s + Number(v.total), 0);

  if (cargando) return <p className="ayuda">Cargando productos del local…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

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
                  onChange={(e) => setDescuentoGeneral(e.target.value)}
                />
              </label>
              <label>
                Referencia
                <input
                  type="text"
                  placeholder="N.º de comprobante o transferencia"
                  value={referencia}
                  onChange={(e) => setReferencia(e.target.value)}
                />
              </label>
              <label className="ancho-total">
                Nota
                <input
                  type="text"
                  value={nota}
                  onChange={(e) => setNota(e.target.value)}
                />
              </label>
            </div>

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
            </tr>
          </thead>
          <tbody>
            {ventas.map((v) => (
              <tr key={v.id} className={v.estado !== "vigente" ? "fila-anulada" : ""}>
                <td className="num">{v.numero}</td>
                <td>{fmtFecha(v.created_at)}</td>
                <td>{v.medio_pago}</td>
                <td className="num">{v.unidades}</td>
                <td className="num">
                  <strong>{dinero(v.total)}</strong>
                </td>
                <td>{v.vendedor}</td>
                <td>
                  <span className={`badge estado-${v.estado}`}>{v.estado}</span>
                </td>
              </tr>
            ))}
            {!ventas.length && (
              <tr>
                <td colSpan={7} className="vacio">
                  Todavía no hay ventas registradas en este local.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
