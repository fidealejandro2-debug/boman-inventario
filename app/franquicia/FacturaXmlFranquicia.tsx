"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  parsearFacturaSri,
  calcularHashXml,
  type FacturaSri,
} from "@/lib/xmlFacturaSri";
import Aviso from "@/components/Aviso";
import type { Franquicia } from "./FranquiciaCliente";
import { dinero, MEDIOS_PAGO, mensajeError } from "./lib";

type Producto = {
  producto_id: string;
  sku: string;
  producto: string;
  talla: string | null;
  color: string | null;
  stock_disponible: number;
};

type Asignacion = { productoId: string; cantidad: string };
type EstadoLinea = { afectaInventario: boolean; asignaciones: Asignacion[] };
type PagoMixto = Record<
  "efectivo" | "transferencia" | "tarjeta",
  { monto: string; referencia: string }
>;

type DocumentoAplicado = {
  id: string;
  numero_documento: string;
  fecha_emision: string;
  razon_social_emisor: string;
  importe_total: number;
  estado: string;
};

export default function FacturaXmlFranquicia({
  franquicia,
}: {
  franquicia: Franquicia;
}) {
  const supabase = createClient();
  const [productos, setProductos] = useState<Producto[]>([]);
  const [historial, setHistorial] = useState<DocumentoAplicado[]>([]);
  const [factura, setFactura] = useState<FacturaSri | null>(null);
  const [lineas, setLineas] = useState<Record<number, EstadoLinea>>({});
  const [busquedas, setBusquedas] = useState<Record<number, string>>({});
  const [archivoNombre, setArchivoNombre] = useState("");
  const [archivoHash, setArchivoHash] = useState("");
  const [nota, setNota] = useState("");
  const [medioPago, setMedioPago] = useState("efectivo");
  const [referenciaPago, setReferenciaPago] = useState("");
  const [pagosMixtos, setPagosMixtos] = useState<PagoMixto>({
    efectivo: { monto: "", referencia: "" },
    transferencia: { monto: "", referencia: "" },
    tarjeta: { monto: "", referencia: "" },
  });
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  async function cargar() {
    setCargando(true);
    const [p, h] = await Promise.all([
      supabase
        .from("vista_stock_operativo")
        .select("producto_id, sku, producto, talla, color, stock_disponible")
        .eq("almacen_id", franquicia.almacen_id)
        .order("producto"),
      supabase
        .from("documentos_venta_xml")
        .select("id, numero_documento, fecha_emision, razon_social_emisor, importe_total, estado")
        .eq("almacen_id", franquicia.almacen_id)
        .order("fecha_emision", { ascending: false })
        .limit(50),
    ]);
    if (p.error) setError(p.error.message);
    else setProductos((p.data as Producto[]) ?? []);
    if (!h.error) setHistorial((h.data as DocumentoAplicado[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [franquicia.id]);

  async function leerArchivo(evento: React.ChangeEvent<HTMLInputElement>) {
    const archivo = evento.target.files?.[0];
    evento.target.value = "";
    if (!archivo) return;
    setError(null);
    setAviso(null);
    setProcesando(true);
    try {
      if (!archivo.name.toLowerCase().endsWith(".xml"))
        throw new Error("Selecciona un archivo con extensión .xml.");
      const contenido = await archivo.text();
      const nueva = parsearFacturaSri(contenido);

      // Evita descontar el inventario dos veces por la misma factura.
      const { data: repetida } = await supabase
        .from("documentos_venta_xml")
        .select("numero_documento")
        .eq("clave_acceso", nueva.claveAcceso)
        .maybeSingle();
      if (repetida)
        throw new Error(
          `La factura ${repetida.numero_documento} ya se aplicó. No se descontó inventario otra vez.`
        );

      setFactura(nueva);
      setArchivoNombre(archivo.name.slice(0, 255));
      setArchivoHash(await calcularHashXml(contenido));
      setLineas(
        Object.fromEntries(
          nueva.lineas.map((l) => [
            l.numeroLinea,
            { afectaInventario: true, asignaciones: [] as Asignacion[] },
          ])
        )
      );
      setBusquedas({});
      setNota("");
      setMedioPago("efectivo");
      setReferenciaPago("");
      setPagosMixtos({
        efectivo: { monto: "", referencia: "" },
        transferencia: { monto: "", referencia: "" },
        tarjeta: { monto: "", referencia: "" },
      });
    } catch (e: any) {
      setFactura(null);
      setError(e.message || "No se pudo leer el XML.");
    } finally {
      setProcesando(false);
    }
  }

  function candidatos(numeroLinea: number) {
    const q = (busquedas[numeroLinea] ?? "").trim().toLowerCase();
    if (!q) return [];
    return productos
      .filter(
        (p) => p.sku.toLowerCase().includes(q) || p.producto.toLowerCase().includes(q)
      )
      .slice(0, 8);
  }

  function asignar(numeroLinea: number, p: Producto) {
    const estado = lineas[numeroLinea];
    const linea = factura?.lineas.find((l) => l.numeroLinea === numeroLinea);
    if (!estado || !linea) return;
    if (estado.asignaciones.some((a) => a.productoId === p.producto_id)) return;
    const asignado = estado.asignaciones.reduce(
      (s, a) => s + Number(a.cantidad || 0),
      0
    );
    const restante = Math.max(linea.cantidad - asignado, 0);
    setLineas({
      ...lineas,
      [numeroLinea]: {
        ...estado,
        asignaciones: [
          ...estado.asignaciones,
          { productoId: p.producto_id, cantidad: String(restante || 1) },
        ],
      },
    });
    setBusquedas({ ...busquedas, [numeroLinea]: "" });
  }

  const pendientes = useMemo(() => {
    if (!factura) return [];
    return factura.lineas
      .filter((l) => lineas[l.numeroLinea]?.afectaInventario !== false)
      .map((l) => {
        const asignado = (lineas[l.numeroLinea]?.asignaciones ?? []).reduce(
          (s, a) => s + Number(a.cantidad || 0),
          0
        );
        return { linea: l, asignado, falta: l.cantidad - asignado };
      })
      .filter((x) => x.falta !== 0);
  }, [factura, lineas]);

  const totalFactura = Number(factura?.importeTotal ?? 0);
  const totalPagosMixtos = Object.values(pagosMixtos).reduce(
    (s, p) => s + Number(p.monto || 0),
    0
  );
  const diferenciaPagos = Math.round((totalPagosMixtos - totalFactura) * 100) / 100;
  const pagos =
    medioPago === "mixto"
      ? (Object.entries(pagosMixtos) as [keyof PagoMixto, PagoMixto[keyof PagoMixto]][])
          .filter(([, p]) => Number(p.monto || 0) > 0)
          .map(([medio, p]) => ({
            medio_pago: medio,
            monto: Math.round(Number(p.monto) * 100) / 100,
            referencia: p.referencia.trim() || null,
          }))
      : totalFactura > 0
        ? [{
            medio_pago: medioPago,
            monto: Math.round(totalFactura * 100) / 100,
            referencia: referenciaPago.trim() || null,
          }]
        : [];
  const pagoInvalido =
    medioPago === "mixto" &&
    (Math.abs(diferenciaPagos) >= 0.005 || pagos.length < 2);

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

  async function aplicar() {
    if (!factura) return;
    if (pendientes.length) {
      const p = pendientes[0];
      return setError(
        p.falta > 0
          ? `Falta asignar ${p.falta} unidad(es) de la línea ${p.linea.numeroLinea} (${p.linea.descripcion}).`
          : `La línea ${p.linea.numeroLinea} tiene ${-p.falta} unidad(es) asignadas de más.`
      );
    }
    if (pagoInvalido) {
      return setError(
        pagos.length < 2
          ? "Un pago mixto debe usar al menos dos medios."
          : diferenciaPagos < 0
            ? `Falta distribuir ${dinero(Math.abs(diferenciaPagos))}.`
            : `Los pagos exceden el total por ${dinero(diferenciaPagos)}.`
      );
    }

    setProcesando(true);
    setError(null);
    const documento = {
      clave_acceso: factura.claveAcceso,
      numero_documento: factura.numeroDocumento,
      numero_autorizacion: factura.numeroAutorizacion,
      estado_sri: factura.estadoSri,
      emisor_ruc: factura.emisorRuc,
      razon_social_emisor: factura.razonSocialEmisor,
      establecimiento: factura.establecimiento,
      punto_emision: factura.puntoEmision,
      secuencial: factura.secuencial,
      fecha_emision: factura.fechaEmision,
      fecha_autorizacion: factura.fechaAutorizacion,
      importe_total: factura.importeTotal,
      archivo_nombre: archivoNombre,
      archivo_hash: archivoHash,
      lineas: factura.lineas.map((l) => ({
        numero_linea: l.numeroLinea,
        codigo_principal: l.codigoPrincipal,
        codigo_auxiliar: l.codigoAuxiliar,
        descripcion: l.descripcion,
        cantidad: l.cantidad,
        precio_unitario: l.precioUnitario,
        descuento: l.descuento,
        total_sin_impuesto: l.totalSinImpuesto,
        afecta_inventario: lineas[l.numeroLinea]?.afectaInventario ?? true,
      })),
    };
    const asignaciones = factura.lineas.flatMap((l) =>
      (lineas[l.numeroLinea]?.asignaciones ?? []).map((a) => ({
        numero_linea: l.numeroLinea,
        producto_id: a.productoId,
        cantidad: Number(a.cantidad),
      }))
    );

    // El envoltorio v44 resuelve el almacen del local, admite los roles de
    // franquicia (el motor historico los rechaza) y registra el ingreso en caja.
    const { data, error } = await supabase.rpc("aplicar_factura_venta_franquicia_v47", {
      p_documento: documento,
      p_asignaciones: asignaciones,
      p_pagos: pagos,
      p_nota: nota || null,
    });
    setProcesando(false);
    if (error) return setError(mensajeError(error));

    const resultado = data as { mensaje?: string } | null;
    setAviso(resultado?.mensaje ?? "Factura aplicada: se descontó el stock del local y el total entró a la caja.");
    setFactura(null);
    setLineas({});
    setArchivoNombre("");
    setArchivoHash("");
    setNota("");
    setReferenciaPago("");
    cargar();
  }

  if (cargando) return <p className="ayuda">Cargando…</p>;

  return (
    <>
      <Aviso
        error={error}
        aviso={aviso}
        onCerrar={(cual) => (cual === "error" ? setError(null) : setAviso(null))}
      />

      <p className="ayuda">
        Sube el XML de la factura que emitió tu facturador. Cada línea se relaciona con
        el producto del local que corresponde, y al aplicarla se descuenta el stock.
        El total entra como ingreso a la caja del local y una misma factura no se puede aplicar dos veces.
      </p>

      <div className="card-interna">
        <h4>Cargar factura</h4>
        <input type="file" accept=".xml" onChange={leerArchivo} disabled={procesando} />
        {procesando && !factura && <p className="ayuda">Leyendo el XML…</p>}
      </div>

      {factura && (
        <div className="card-interna">
          <h4>
            Factura {factura.numeroDocumento} · {dinero(factura.importeTotal)}
          </h4>
          <p className="ayuda">
            {factura.razonSocialEmisor} · RUC {factura.emisorRuc} ·{" "}
            {factura.fechaEmision.split("-").reverse().join("/")}
          </p>

          {factura.emisorRuc !== undefined && (
            <p className="ayuda">
              El RUC del emisor debe estar registrado como empresa del grupo con este
              local habilitado para ventas. Si no lo está, la base rechazará la factura.
            </p>
          )}

          {factura.lineas.map((l) => {
            const estado = lineas[l.numeroLinea];
            const asignado = (estado?.asignaciones ?? []).reduce(
              (s, a) => s + Number(a.cantidad || 0),
              0
            );
            const falta = l.cantidad - asignado;
            return (
              <div key={l.numeroLinea} className="fx-linea">
                <div className="fx-cab">
                  <div>
                    <strong>
                      {l.codigoPrincipal ?? "—"} · {l.descripcion}
                    </strong>
                    <div className="ayuda">
                      {l.cantidad} × {dinero(l.precioUnitario)} ={" "}
                      {dinero(l.totalSinImpuesto)}
                    </div>
                  </div>
                  <label className="check-inline">
                    <input
                      type="checkbox"
                      checked={estado?.afectaInventario ?? true}
                      onChange={(e) =>
                        setLineas({
                          ...lineas,
                          [l.numeroLinea]: {
                            ...estado,
                            afectaInventario: e.target.checked,
                            asignaciones: e.target.checked ? estado.asignaciones : [],
                          },
                        })
                      }
                    />{" "}
                    Descuenta stock
                  </label>
                </div>

                {estado?.afectaInventario !== false && (
                  <>
                    <div className="fx-estado">
                      {falta === 0 ? (
                        <span className="badge ok">asignada</span>
                      ) : falta > 0 ? (
                        <span className="badge bajo">faltan {falta}</span>
                      ) : (
                        <span className="badge bajo">sobran {-falta}</span>
                      )}
                    </div>

                    {(estado?.asignaciones ?? []).map((a) => {
                      const p = productos.find((x) => x.producto_id === a.productoId);
                      return (
                        <div key={a.productoId} className="fx-asig">
                          <span>
                            <strong>{p?.sku}</strong> · {p?.producto}
                            {p?.talla ? ` · ${p.talla}` : ""}
                          </span>
                          <input
                            type="number"
                            min="1"
                            value={a.cantidad}
                            onChange={(e) =>
                              setLineas({
                                ...lineas,
                                [l.numeroLinea]: {
                                  ...estado,
                                  asignaciones: estado.asignaciones.map((x) =>
                                    x.productoId === a.productoId
                                      ? { ...x, cantidad: e.target.value }
                                      : x
                                  ),
                                },
                              })
                            }
                          />
                          <span className="ayuda">de {p?.stock_disponible ?? 0}</span>
                          <button
                            className="btn-mini secondary"
                            onClick={() =>
                              setLineas({
                                ...lineas,
                                [l.numeroLinea]: {
                                  ...estado,
                                  asignaciones: estado.asignaciones.filter(
                                    (x) => x.productoId !== a.productoId
                                  ),
                                },
                              })
                            }
                          >
                            Quitar
                          </button>
                        </div>
                      );
                    })}

                    <input
                      type="search"
                      placeholder="Buscar la prenda que corresponde…"
                      value={busquedas[l.numeroLinea] ?? ""}
                      onChange={(e) =>
                        setBusquedas({ ...busquedas, [l.numeroLinea]: e.target.value })
                      }
                    />
                    {candidatos(l.numeroLinea).length > 0 && (
                      <div className="fq-resultados">
                        {candidatos(l.numeroLinea).map((p) => (
                          <button
                            key={p.producto_id}
                            className="fq-resultado"
                            onClick={() => asignar(l.numeroLinea, p)}
                          >
                            <span className="fq-sku">{p.sku}</span>
                            <span className="fq-nom">
                              {p.producto}
                              {p.talla ? ` · ${p.talla}` : ""}
                            </span>
                            <span className="fq-datos">{p.stock_disponible} disp.</span>
                          </button>
                        ))}
                      </div>
                    )}
                  </>
                )}
              </div>
            );
          })}

          <div className="form-grid">
            <label>
              Medio de pago
              <select value={medioPago} onChange={(e) => setMedioPago(e.target.value)}>
                {MEDIOS_PAGO.map((medio) => (
                  <option key={medio.valor} value={medio.valor}>{medio.etiqueta}</option>
                ))}
              </select>
            </label>
            {medioPago !== "mixto" && (
              <label>
                Referencia del pago
                <input
                  type="text"
                  value={referenciaPago}
                  onChange={(e) => setReferenciaPago(e.target.value)}
                />
              </label>
            )}
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
              <div className="form-grid">
                {(["efectivo", "transferencia", "tarjeta"] as const).map((medio) => (
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
                    {medio !== "efectivo" && (
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

          {pendientes.length > 0 && (
            <p className="aviso">
              Faltan líneas por relacionar con productos del local. Si alguna no debe
              descontar stock —un servicio o un cargo— desmarca «Descuenta stock».
            </p>
          )}

          <div className="filtros">
            <button
              onClick={aplicar}
              disabled={procesando || pendientes.length > 0 || pagoInvalido}
            >
              {procesando ? "Aplicando…" : "Aplicar factura y descontar stock"}
            </button>
            <button className="secondary" onClick={() => setFactura(null)}>
              Cancelar
            </button>
          </div>
        </div>
      )}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Documento</th>
              <th>Fecha</th>
              <th>Emisor</th>
              <th className="num">Total</th>
              <th>Estado</th>
            </tr>
          </thead>
          <tbody>
            {historial.map((d) => (
              <tr key={d.id} className={d.estado === "anulado" ? "fila-anulada" : ""}>
                <td>
                  <strong>{d.numero_documento}</strong>
                </td>
                <td>{d.fecha_emision.split("-").reverse().join("/")}</td>
                <td>{d.razon_social_emisor}</td>
                <td className="num">{dinero(d.importe_total)}</td>
                <td>
                  <span className={`badge estado-${d.estado}`}>{d.estado}</span>
                </td>
              </tr>
            ))}
            {!historial.length && (
              <tr>
                <td colSpan={5} className="vacio">
                  Todavía no se aplicó ninguna factura en este local.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
