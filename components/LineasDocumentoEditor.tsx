"use client";

import { useMemo, useState } from "react";

export type ProductoDocumento = {
  id: string;
  sku: string;
  nombre: string;
  talla: string | null;
  color?: string | null;
  tipo_inventario?: string;
};

export type LineaDocumentoEdicion = {
  producto_id: string;
  cantidad: number;
  observacion?: string;
};

function normalizar(valor: string) {
  return valor
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase();
}

function detalleProducto(producto: ProductoDocumento) {
  return [producto.nombre, producto.talla, producto.color].filter(Boolean).join(" · ");
}

export default function LineasDocumentoEditor({
  productos,
  lineas,
  onChange,
  permitirDecimales = false,
}: {
  productos: ProductoDocumento[];
  lineas: LineaDocumentoEdicion[];
  onChange: (lineas: LineaDocumentoEdicion[]) => void;
  permitirDecimales?: boolean;
}) {
  const [busqueda, setBusqueda] = useState("");
  const [cantidadRapida, setCantidadRapida] = useState(1);
  const [pegado, setPegado] = useState("");
  const [resultadoPegado, setResultadoPegado] = useState<{ tipo: "ok" | "error"; texto: string } | null>(null);

  // Las cantidades decimales se usan en las BOM de Producción. En ese flujo
  // los productos terminados nunca deben sugerirse como materia consumible.
  const productosBuscables = useMemo(() => permitirDecimales
    ? productos.filter((producto) => [
        "materia_prima", "insumo", "empaque", "subproducto",
      ].includes(producto.tipo_inventario ?? ""))
    : productos,
  [permitirDecimales, productos]);

  // Se recorta a 12 para no pintar cientos de filas, pero sin avisar de que
  // hay mas el usuario ve una caja llena y cree que esa es toda la lista
  // ("no hay mas con esa inicial") cuando en realidad quedan afuera.
  const coincidencias = useMemo(() => {
    const q = normalizar(busqueda);
    if (!q) return [];

    return productosBuscables
      .filter((producto) => normalizar([
        producto.sku,
        producto.nombre,
        producto.talla ?? "",
        producto.color ?? "",
      ].join(" ")).includes(q))
      .sort((a, b) => {
        const skuA = normalizar(a.sku);
        const skuB = normalizar(b.sku);
        const nombreA = normalizar(a.nombre);
        const nombreB = normalizar(b.nombre);
        const prioridadA = skuA === q ? 0 : nombreA === q ? 1 : skuA.startsWith(q) ? 2 : nombreA.startsWith(q) ? 3 : 4;
        const prioridadB = skuB === q ? 0 : nombreB === q ? 1 : skuB.startsWith(q) ? 2 : nombreB.startsWith(q) ? 3 : 4;
        return prioridadA - prioridadB || nombreA.localeCompare(nombreB) || skuA.localeCompare(skuB);
      });
  }, [busqueda, productosBuscables]);
  const sugerencias = coincidencias.slice(0, 12);
  const ocultas = coincidencias.length - sugerencias.length;

  function agregar(producto: ProductoDocumento, cantidad = cantidadRapida) {
    const cantidadValida = cantidad > 0 && (permitirDecimales || Number.isInteger(cantidad)) ? cantidad : 1;
    const existente = lineas.find((linea) => linea.producto_id === producto.id);

    if (existente) {
      onChange(lineas.map((linea) => linea.producto_id === producto.id
        ? { ...linea, cantidad: linea.cantidad + cantidadValida }
        : linea));
    } else {
      onChange([...lineas, { producto_id: producto.id, cantidad: cantidadValida, observacion: "" }]);
    }
    setBusqueda("");
  }

  function actualizar(indice: number, cambio: Partial<LineaDocumentoEdicion>) {
    onChange(lineas.map((linea, i) => i === indice ? { ...linea, ...cambio } : linea));
  }

  function buscarProductoExacto(identificador: string) {
    const q = normalizar(identificador);
    if (!q) return { producto: null, coincidencias: 0 };

    const porSku = productosBuscables.filter((producto) => normalizar(producto.sku) === q);
    if (porSku.length === 1) return { producto: porSku[0], coincidencias: 1 };

    const exactos = productosBuscables.filter((producto) => {
      const nombre = normalizar(producto.nombre);
      const nombreTalla = normalizar([producto.nombre, producto.talla].filter(Boolean).join(" "));
      const descripcion = normalizar([producto.nombre, producto.talla, producto.color].filter(Boolean).join(" "));
      return nombre === q || nombreTalla === q || descripcion === q;
    });
    if (exactos.length === 1) return { producto: exactos[0], coincidencias: 1 };
    if (exactos.length > 1) return { producto: null, coincidencias: exactos.length };

    const parciales = productosBuscables.filter((producto) => normalizar([
      producto.sku,
      producto.nombre,
      producto.talla ?? "",
      producto.color ?? "",
    ].join(" ")).includes(q));
    return parciales.length === 1
      ? { producto: parciales[0], coincidencias: 1 }
      : { producto: null, coincidencias: parciales.length };
  }

  function importarPegado() {
    const acumulado = new Map(lineas.map((linea) => [linea.producto_id, { ...linea }]));
    const errores: string[] = [];
    const filasPendientes: string[] = [];
    let incorporadas = 0;

    pegado.split(/\r?\n/).forEach((fila, indice) => {
      const limpia = fila.trim();
      if (!limpia) return;

      // Se separa únicamente por ;, tabulación o la última coma. Así los nombres
      // de producto pueden contener espacios sin quedar partidos.
      const patronCantidad = permitirDecimales ? "(\\d+(?:[.,]\\d+)?)" : "(\\d+)";
      const partes = limpia.match(new RegExp(`^(.*?)[;\\t]\\s*${patronCantidad}\\s*$`))
        ?? limpia.match(new RegExp(`^(.*),\\s*${patronCantidad}\\s*$`));
      if (!partes) {
        errores.push(`Línea ${indice + 1}: usa "nombre o SKU; cantidad".`);
        filasPendientes.push(limpia);
        return;
      }

      const identificador = partes[1].trim();
      const cantidad = Number(partes[2].replace(",", "."));
      const coincidencia = buscarProductoExacto(identificador);

      if ((!permitirDecimales && !Number.isInteger(cantidad)) || !Number.isFinite(cantidad) || cantidad <= 0) {
        errores.push(`Línea ${indice + 1}: la cantidad debe ser ${permitirDecimales ? "numérica y " : "entera y "}mayor que cero.`);
        filasPendientes.push(limpia);
        return;
      }
      if (!coincidencia.producto) {
        errores.push(coincidencia.coincidencias > 1
          ? `Línea ${indice + 1}: "${identificador}" coincide con ${coincidencia.coincidencias} productos; agrega talla/color o usa el SKU.`
          : `Línea ${indice + 1}: no se encontró "${identificador}".`);
        filasPendientes.push(limpia);
        return;
      }

      const anterior = acumulado.get(coincidencia.producto.id);
      acumulado.set(coincidencia.producto.id, {
        producto_id: coincidencia.producto.id,
        cantidad: (anterior?.cantidad ?? 0) + cantidad,
        observacion: anterior?.observacion ?? "",
      });
      incorporadas++;
    });

    onChange(Array.from(acumulado.values()));
    if (errores.length) {
      // Conserva únicamente las filas que necesitan corrección para que volver a
      // pulsar "Incorporar" no duplique las que ya se agregaron correctamente.
      setPegado(filasPendientes.join("\n"));
      setResultadoPegado({
        tipo: "error",
        texto: `${incorporadas} línea(s) incorporada(s). ${errores.join(" ")}`,
      });
      return;
    }

    setResultadoPegado({ tipo: "ok", texto: `${incorporadas} línea(s) incorporada(s) correctamente.` });
    setPegado("");
  }

  return (
    <div className="lineas-editor">
      <div className="field buscador-producto-documento">
        <label>Agregar productos por nombre o código</label>
        <div className="buscador-producto-fila">
          <div className="buscador-producto-caja">
            <input
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && sugerencias.length) {
                  e.preventDefault();
                  agregar(sugerencias[0]);
                }
              }}
              placeholder="Escribe el nombre, SKU, talla o color..."
              autoComplete="off"
            />
            {busqueda.trim() && (
              <div className="sugerencias-documento">
                {sugerencias.map((producto) => {
                  const existente = lineas.find((linea) => linea.producto_id === producto.id);
                  return (
                    <button type="button" key={producto.id} onClick={() => agregar(producto)}>
                      <strong>{producto.sku}</strong>
                      <span>{detalleProducto(producto)}</span>
                      <small>{existente ? `Ya agregado: ${existente.cantidad} · sumar ${cantidadRapida}` : `Agregar ${cantidadRapida}`}</small>
                    </button>
                  );
                })}
                {!sugerencias.length && <div className="sugerencias-vacio">No se encontraron productos.</div>}
                {ocultas > 0 && (
                  <div className="sugerencias-vacio">
                    + {ocultas} resultado{ocultas === 1 ? "" : "s"} más — sigue escribiendo para acotar la búsqueda.
                  </div>
                )}
              </div>
            )}
          </div>
          <label className="cantidad-rapida">
            <span>Cantidad</span>
            <input
              type="number"
              min={permitirDecimales ? 0.000001 : 1}
              step={permitirDecimales ? "any" : 1}
              value={cantidadRapida}
              onChange={(e) => setCantidadRapida(Math.max(permitirDecimales ? 0.000001 : 1, Number(e.target.value) || 1))}
            />
          </label>
        </div>
        <small className="ayuda-campo">{permitirDecimales
          ? "Solo aparecen materias primas, insumos, empaques y subproductos previamente clasificados."
          : "Escribe unas letras, elige el producto sugerido y continúa con el siguiente. Si ya estaba agregado, la cantidad se suma."}</small>
      </div>

      <details className="pegado-masivo">
        <summary>Pegado masivo por nombre o SKU</summary>
        <p className="conteo">Una línea por producto con el formato <code>nombre o SKU; cantidad</code>. Si un nombre se repite por talla o color, escribe también ese dato o utiliza el SKU.</p>
        <textarea
          rows={5}
          value={pegado}
          onChange={(e) => { setPegado(e.target.value); setResultadoPegado(null); }}
          placeholder={"Camiseta entrenamiento M;12\nPantaloneta azul;8\nCAM-001;5"}
          style={{ width: "100%" }}
        />
        <button type="button" className="secondary" onClick={importarPegado} disabled={!pegado.trim()}>Incorporar lista</button>
        {resultadoPegado && <div className={resultadoPegado.tipo === "error" ? "error pegado-resultado" : "success pegado-resultado"}>{resultadoPegado.texto}</div>}
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
                  <td>{producto ? detalleProducto(producto) : "Producto"}</td>
                  <td className="num">
                    <input type="number" min={permitirDecimales ? 0.000001 : 1}
                      step={permitirDecimales ? "any" : 1} value={linea.cantidad}
                      onChange={(e) => actualizar(indice, { cantidad: Math.max(0, Number(e.target.value) || 0) })}
                      style={{ width: 82, textAlign: "right" }} />
                  </td>
                  <td><input value={linea.observacion ?? ""}
                    onChange={(e) => actualizar(indice, { observacion: e.target.value })}
                    placeholder="Opcional" style={{ width: "100%" }} /></td>
                  <td><button type="button" className="peligro" aria-label={`Quitar ${producto?.nombre ?? "producto"}`} onClick={() => onChange(lineas.filter((_, i) => i !== indice))}>×</button></td>
                </tr>
              );
            })}
            {!lineas.length && <tr><td colSpan={5} className="vacio">Busca un producto por nombre o código para agregarlo.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}
