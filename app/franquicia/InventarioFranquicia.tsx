"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { exportarCSV } from "@/lib/utils";
import type { Franquicia } from "./FranquiciaCliente";
import { dinero, hoyLocalISO, mensajeError } from "./lib";

type Fila = {
  producto_id: string;
  sku: string;
  producto: string;
  talla: string | null;
  color: string | null;
  precio: number;
  stock_fisico: number;
  stock_disponible: number;
  transito_entrada: number;
};

type LineaAjuste = {
  producto_id: string;
  sku: string;
  nombre: string;
  cantidad: number;
  stock: number;
};

export default function InventarioFranquicia({
  franquicia,
}: {
  franquicia: Franquicia;
}) {
  const supabase = createClient();
  const [stock, setStock] = useState<Fila[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [busqueda, setBusqueda] = useState("");

  const [mostrarAjuste, setMostrarAjuste] = useState(false);
  const [tipo, setTipo] = useState<"entrada" | "salida">("salida");
  const [motivo, setMotivo] = useState("");
  const [fechaAjuste, setFechaAjuste] = useState(hoyLocalISO());
  const [lineas, setLineas] = useState<LineaAjuste[]>([]);
  const [buscarAjuste, setBuscarAjuste] = useState("");

  async function cargar() {
    setCargando(true);
    const { data, error } = await supabase
      .from("vista_stock_operativo")
      .select(
        "producto_id, sku, producto, talla, color, precio, stock_fisico, stock_disponible, transito_entrada"
      )
      .eq("almacen_id", franquicia.almacen_id)
      .order("producto");
    if (error) setError(error.message);
    else setStock((data as Fila[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [franquicia.id]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return stock;
    return stock.filter(
      (p) => p.sku.toLowerCase().includes(q) || p.producto.toLowerCase().includes(q)
    );
  }, [stock, busqueda]);

  const candidatos = useMemo(() => {
    const q = buscarAjuste.trim().toLowerCase();
    if (!q) return [];
    return stock
      .filter(
        (p) => p.sku.toLowerCase().includes(q) || p.producto.toLowerCase().includes(q)
      )
      .slice(0, 10);
  }, [stock, buscarAjuste]);

  function agregar(p: Fila) {
    if (lineas.some((l) => l.producto_id === p.producto_id)) return setBuscarAjuste("");
    setLineas([
      ...lineas,
      {
        producto_id: p.producto_id,
        sku: p.sku,
        nombre: `${p.producto}${p.talla ? ` · ${p.talla}` : ""}`,
        cantidad: 1,
        stock: p.stock_disponible,
      },
    ]);
    setBuscarAjuste("");
  }

  // En una salida no se puede sacar más de lo que hay: la base lo rechaza.
  const excedidas = lineas.filter((l) => tipo === "salida" && l.cantidad > l.stock);

  async function registrarAjuste() {
    if (!lineas.length) return setError("Agrega al menos un producto.");
    if (motivo.trim().length < 5)
      return setError("Explica el motivo del ajuste (mínimo 5 caracteres).");
    if (excedidas.length)
      return setError(`${excedidas[0].sku}: solo hay ${excedidas[0].stock} en el local.`);

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("registrar_ajuste_franquicia_v42", {
      p_fecha: fechaAjuste,
      p_tipo: tipo,
      p_items: lineas.map((l) => ({
        producto_id: l.producto_id,
        cantidad: l.cantidad,
      })),
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(
      tipo === "entrada"
        ? "Entrada registrada; el stock del local subió."
        : "Salida registrada; el stock del local bajó."
    );
    setLineas([]);
    setMotivo("");
    setMostrarAjuste(false);
    cargar();
  }

  const valorInventario = stock.reduce(
    (s, p) => s + Number(p.precio ?? 0) * p.stock_fisico,
    0
  );
  const sinStock = stock.filter((p) => p.stock_disponible <= 0).length;
  const enTransito = stock.reduce((s, p) => s + (p.transito_entrada ?? 0), 0);

  if (cargando) return <p className="ayuda">Cargando inventario del local…</p>;

  return (
    <>
      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      <div className="kpis">
        <div className="kpi">
          <span className="valor">{stock.length}</span>
          <span className="label">Productos en el local</span>
        </div>
        <div className="kpi">
          <span className="valor">{dinero(valorInventario)}</span>
          <span className="label">Valor del inventario</span>
        </div>
        <div className={`kpi ${sinStock ? "alerta" : ""}`}>
          <span className="valor">{sinStock}</span>
          <span className="label">Sin stock</span>
        </div>
        <div className="kpi">
          <span className="valor">{enTransito}</span>
          <span className="label">Unidades en tránsito</span>
        </div>
      </div>

      <p className="ayuda">
        Para pedir mercadería usa <Link href="/operaciones">Operaciones</Link>: ahí se
        crea la solicitud de reposición y se confirma la recepción. Los ajustes de aquí
        son para corregir el stock por daño, pérdida o consumo interno, y quedan
        registrados con su motivo.
      </p>

      <div className="filtros">
        <button onClick={() => setMostrarAjuste(!mostrarAjuste)}>
          {mostrarAjuste ? "Cancelar ajuste" : "Registrar ajuste"}
        </button>
        <input
          type="search"
          placeholder="Buscar producto…"
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
        />
        <button
          className="secondary"
          onClick={() => exportarCSV("inventario_franquicia", visibles)}
          disabled={!visibles.length}
        >
          Exportar
        </button>
      </div>

      {mostrarAjuste && (
        <div className="card-interna">
          <h4>Ajuste de inventario</h4>
          <div className="form-grid">
            <label>
              Tipo
              <select
                value={tipo}
                onChange={(e) => setTipo(e.target.value as "entrada" | "salida")}
              >
                <option value="salida">Salida (daño, pérdida, consumo)</option>
                <option value="entrada">Entrada (hallazgo, devolución)</option>
              </select>
            </label>
            <label>
              Fecha
              <input
                type="date"
                value={fechaAjuste}
                max={hoyLocalISO()}
                onChange={(e) => setFechaAjuste(e.target.value)}
              />
            </label>
            <label className="ancho-total">
              Motivo
              <input
                type="text"
                placeholder="Ej. Prenda dañada por humedad en bodega del local"
                value={motivo}
                onChange={(e) => setMotivo(e.target.value)}
              />
              <small>Mínimo 5 caracteres. Queda en el registro del movimiento.</small>
            </label>
            <label className="ancho-total">
              Agregar producto
              <input
                type="search"
                placeholder="Buscar por código o nombre…"
                value={buscarAjuste}
                onChange={(e) => setBuscarAjuste(e.target.value)}
              />
            </label>
          </div>

          {candidatos.length > 0 && (
            <div className="fq-resultados">
              {candidatos.map((p) => (
                <button
                  key={p.producto_id}
                  className="fq-resultado"
                  onClick={() => agregar(p)}
                >
                  <span className="fq-sku">{p.sku}</span>
                  <span className="fq-nom">{p.producto}</span>
                  <span className="fq-datos">{p.stock_disponible} disp.</span>
                </button>
              ))}
            </div>
          )}

          {lineas.length > 0 && (
            <div className="tabla-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Producto</th>
                    <th className="num">En local</th>
                    <th className="num">Cantidad</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {lineas.map((l) => (
                    <tr key={l.producto_id}>
                      <td>
                        <strong>{l.sku}</strong> · {l.nombre}
                      </td>
                      <td className="num">{l.stock}</td>
                      <td className="num">
                        <input
                          type="number"
                          min="1"
                          value={l.cantidad}
                          onChange={(e) =>
                            setLineas(
                              lineas.map((x) =>
                                x.producto_id === l.producto_id
                                  ? { ...x, cantidad: Number(e.target.value) }
                                  : x
                              )
                            )
                          }
                        />
                        {tipo === "salida" && l.cantidad > l.stock && (
                          <div className="fq-alerta">solo {l.stock}</div>
                        )}
                      </td>
                      <td>
                        <button
                          className="btn-mini secondary"
                          onClick={() =>
                            setLineas(
                              lineas.filter((x) => x.producto_id !== l.producto_id)
                            )
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
          )}

          <button
            onClick={registrarAjuste}
            disabled={guardando || !lineas.length || excedidas.length > 0}
          >
            {guardando ? "Registrando…" : `Registrar ${tipo}`}
          </button>
        </div>
      )}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Código</th>
              <th>Producto</th>
              <th className="num">Físico</th>
              <th className="num">Disponible</th>
              <th className="num">En tránsito</th>
              <th className="num">Precio</th>
            </tr>
          </thead>
          <tbody>
            {visibles.map((p) => (
              <tr key={p.producto_id}>
                <td>{p.sku}</td>
                <td>
                  {p.producto}
                  {p.talla ? ` · ${p.talla}` : ""}
                  {p.color ? ` · ${p.color}` : ""}
                </td>
                <td className="num">{p.stock_fisico}</td>
                <td className="num">
                  {p.stock_disponible <= 0 ? (
                    <span className="badge cero">0</span>
                  ) : (
                    <strong>{p.stock_disponible}</strong>
                  )}
                </td>
                <td className="num">{p.transito_entrada || "—"}</td>
                <td className="num">{dinero(p.precio)}</td>
              </tr>
            ))}
            {!visibles.length && (
              <tr>
                <td colSpan={6} className="vacio">
                  Sin productos que coincidan.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
