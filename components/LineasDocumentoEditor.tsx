"use client";

import { useMemo, useState } from "react";

export type ProductoDocumento = {
  id: string;
  sku: string;
  nombre: string;
  talla: string | null;
  color?: string | null;
};

export type LineaDocumentoEdicion = {
  producto_id: string;
  cantidad: number;
  observacion?: string;
};

export default function LineasDocumentoEditor({
  productos,
  lineas,
  onChange,
}: {
  productos: ProductoDocumento[];
  lineas: LineaDocumentoEdicion[];
  onChange: (lineas: LineaDocumentoEdicion[]) => void;
}) {
  const [busqueda, setBusqueda] = useState("");
  const [pegado, setPegado] = useState("");

  const sugerencias = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return [];
    const usados = new Set(lineas.map((linea) => linea.producto_id));
    return productos.filter((producto) =>
      !usados.has(producto.id) &&
      (producto.sku.toLowerCase().includes(q) ||
       producto.nombre.toLowerCase().includes(q) ||
       (producto.talla ?? "").toLowerCase().includes(q))
    ).slice(0, 8);
  }, [busqueda, lineas, productos]);

  function agregar(producto: ProductoDocumento) {
    onChange([...lineas, { producto_id: producto.id, cantidad: 1, observacion: "" }]);
    setBusqueda("");
  }

  function actualizar(indice: number, cambio: Partial<LineaDocumentoEdicion>) {
    onChange(lineas.map((linea, i) => i === indice ? { ...linea, ...cambio } : linea));
  }

  function importarPegado() {
    const porSku = new Map(productos.map((producto) => [producto.sku.trim().toUpperCase(), producto]));
    const acumulado = new Map(lineas.map((linea) => [linea.producto_id, { ...linea }]));
    let invalidas = 0;

    pegado.split(/\r?\n/).forEach((fila) => {
      const [skuRaw, cantidadRaw] = fila.trim().split(/[;,\t ]+/);
      if (!skuRaw && !cantidadRaw) return;
      const producto = porSku.get(String(skuRaw || "").toUpperCase());
      const cantidad = Number(cantidadRaw);
      if (!producto || !Number.isInteger(cantidad) || cantidad <= 0) {
        invalidas++;
        return;
      }
      const anterior = acumulado.get(producto.id);
      acumulado.set(producto.id, {
        producto_id: producto.id,
        cantidad: (anterior?.cantidad ?? 0) + cantidad,
        observacion: anterior?.observacion ?? "",
      });
    });

    onChange(Array.from(acumulado.values()));
    setPegado(invalidas ? `${invalidas} línea(s) no reconocida(s). Corrige y vuelve a pegar.` : "");
  }

  return (
    <div className="lineas-editor">
      <div className="field" style={{ position: "relative" }}>
        <label>Agregar producto</label>
        <input
          value={busqueda}
          onChange={(e) => setBusqueda(e.target.value)}
          placeholder="Buscar por SKU, producto o talla..."
          style={{ width: "100%" }}
        />
        {sugerencias.length > 0 && (
          <div className="sugerencias-documento">
            {sugerencias.map((producto) => (
              <button type="button" key={producto.id} onClick={() => agregar(producto)}>
                <strong>{producto.sku}</strong>
                <span>{producto.nombre}{producto.talla ? ` · ${producto.talla}` : ""}</span>
              </button>
            ))}
          </div>
        )}
      </div>

      <details className="pegado-masivo">
        <summary>Agregar muchas líneas pegando SKU y cantidad</summary>
        <p className="conteo">Una línea por producto. Ejemplo: <code>CAM-001;12</code></p>
        <textarea
          rows={4}
          value={pegado}
          onChange={(e) => setPegado(e.target.value)}
          placeholder={"CAM-001;12\nPAN-023;8"}
          style={{ width: "100%" }}
        />
        <button type="button" className="secondary" onClick={importarPegado}>Incorporar lista</button>
      </details>

      <div className="tabla-scroll tabla-lineas-documento">
        <table>
          <thead><tr><th>SKU</th><th>Producto</th><th className="num">Cantidad</th><th>Observación</th><th></th></tr></thead>
          <tbody>
            {lineas.map((linea, indice) => {
              const producto = productos.find((p) => p.id === linea.producto_id);
              return (
                <tr key={linea.producto_id}>
                  <td><strong>{producto?.sku ?? "-"}</strong></td>
                  <td>{producto?.nombre ?? "Producto"}{producto?.talla ? <small> · {producto.talla}</small> : null}</td>
                  <td className="num">
                    <input type="number" min={1} value={linea.cantidad}
                      onChange={(e) => actualizar(indice, { cantidad: Math.max(0, Number(e.target.value) || 0) })}
                      style={{ width: 82, textAlign: "right" }} />
                  </td>
                  <td><input value={linea.observacion ?? ""}
                    onChange={(e) => actualizar(indice, { observacion: e.target.value })}
                    placeholder="Opcional" style={{ width: "100%" }} /></td>
                  <td><button type="button" className="peligro" onClick={() => onChange(lineas.filter((_, i) => i !== indice))}>×</button></td>
                </tr>
              );
            })}
            {!lineas.length && <tr><td colSpan={5} className="vacio">Agrega al menos un producto.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
