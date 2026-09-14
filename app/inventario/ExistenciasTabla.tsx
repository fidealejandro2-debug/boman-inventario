"use client";

import { useState } from "react";
import ProductoConImagen from "@/components/ProductoConImagen";
import ModalOperativo from "@/components/ModalOperativo";
import type { PortadaProducto } from "@/lib/portadasProductos";
import type { Fila } from "./StockCliente";
import estilos from "./Existencias.module.css";

function Estado({ fila }: { fila: Fila }) {
  if (fila.transito_incidencia > 0 || fila.stock_cuarentena > 0) return <span className="badge bajo">Requiere revisión</span>;
  if (fila.stock_fisico === 0 && fila.transito_entrada === 0) return <span className="badge cero">Sin stock</span>;
  if (fila.bajo_minimo) return <span className="badge bajo">Reponer {fila.sugerido_reponer || ""}</span>;
  return <span className="badge ok">Disponible</span>;
}

export default function ExistenciasTabla({ filas, completa, portadas, puedeEditarFotos, onFotos }: {
  filas: Fila[]; completa: boolean; portadas: Map<string, PortadaProducto>; puedeEditarFotos: boolean;
  onFotos: (fila: Fila) => void;
}) {
  const [abierta, setAbierta] = useState<string | null>(null);
  const producto = (fila: Fila) => <ProductoConImagen nombre={fila.producto} sku={fila.sku} portada={portadas.get(fila.producto_id)} puedeAgregarFoto={puedeEditarFotos} onAbrirGaleria={portadas.has(fila.producto_id) || puedeEditarFotos ? () => onFotos(fila) : undefined} />;
  const detalle = filas.find(fila => fila.producto_id === abierta);
  return <>
    <div className={`tabla-scroll ${completa ? estilos.completa : estilos.resumida}`}>
      <table aria-label={completa ? "Existencias con desglose de stock" : "Disponibilidad de productos"}>
        <thead>{completa
          ? <tr>{["SKU", "Producto", "Categoría", "Talla / color", "Ubicación", "Físico", "Reservado", "Disponible", "Tránsito de entrada", "Tránsito de salida", "Incidencias", "Cuarentena", "Estado"].map((titulo, i) => <th scope="col" key={titulo} className={i >= 5 && i <= 11 ? "num" : undefined}>{titulo}</th>)}</tr>
          : <tr><th scope="col">Producto</th><th scope="col">Talla / color</th><th scope="col" className="num">Disponible</th><th scope="col">Estado</th><th scope="col">Detalle</th></tr>}
        </thead>
        <tbody>{filas.map(fila => <tr key={`${fila.producto_id}-${fila.almacen_id}`}>
          {completa && <td><strong>{fila.sku}</strong></td>}
          <td data-label="Producto" className={estilos.producto}>{producto(fila)}{!completa && <small>{fila.sku}</small>}</td>
          {completa && <td>{fila.categoria ?? "—"}<small>{fila.subcategoria}</small></td>}
          <td data-label="Talla / color">{[fila.talla, fila.color].filter(Boolean).join(" · ") || "—"}</td>
          {completa && <><td>{fila.ubicacion ?? "—"}</td><td className="num">{fila.stock_fisico}</td><td className="num">{fila.stock_reservado}</td></>}
          <td data-label="Disponible" className="num"><strong>{fila.stock_disponible}</strong></td>
          {completa && <><td className="num">{fila.transito_entrada}</td><td className="num">{fila.transito_salida}</td><td className="num">{fila.transito_incidencia}</td><td className="num">{fila.stock_cuarentena}</td></>}
          <td data-label="Estado"><Estado fila={fila}/></td>
          {!completa && <td data-label="Detalle"><button type="button" className="secondary" aria-expanded={abierta === fila.producto_id} aria-controls={abierta === fila.producto_id ? "stock-desglose" : undefined} onClick={() => setAbierta(abierta === fila.producto_id ? null : fila.producto_id)}>{abierta === fila.producto_id ? "Cerrar detalle" : "Ver stock"}</button></td>}
        </tr>)}</tbody>
      </table>
    </div>
    {!completa && detalle && <ModalOperativo titulo={detalle.producto} onCerrar={() => setAbierta(null)}><section className={estilos.detalle} id="stock-desglose">
      <p>{detalle.sku} · {detalle.almacen}</p>
      <dl>{[
        ["Físico", detalle.stock_fisico], ["Reservado", detalle.stock_reservado], ["Disponible", detalle.stock_disponible],
        ["Tránsito de entrada", detalle.transito_entrada], ["Tránsito de salida", detalle.transito_salida],
        ["Tránsito con incidencia", detalle.transito_incidencia], ["Cuarentena", detalle.stock_cuarentena],
        ["Ubicación", detalle.ubicacion || "Sin asignar"], ["Categoría", [detalle.categoria, detalle.subcategoria].filter(Boolean).join(" / ") || "Sin categoría"],
        ["Mínimo", detalle.stock_minimo], ["Punto de reposición", detalle.punto_reposicion], ["Reposición sugerida", detalle.sugerido_reponer],
      ].map(([etiqueta, valor]) => <div key={String(etiqueta)}><dt>{etiqueta}</dt><dd>{valor}</dd></div>)}</dl>
      <p className="ayuda">El disponible es el saldo utilizable. Las incidencias de tránsito y la cuarentena se muestran por separado para facilitar su revisión.</p>
    </section></ModalOperativo>}
  </>;
}
