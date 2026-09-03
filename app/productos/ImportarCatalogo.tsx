"use client";

import { useEffect, useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { fecha } from "@/lib/utils";
import { confirmarDialogo } from "@/components/Dialogo";
import { descargarPlantillaExcel } from "@/lib/plantillasExcel";

type ProductoActual = { sku: string; nombre: string };
type ItemCatalogo = {
  sku: string;
  nombre: string;
  categoria: string;
  subcategoria: string | null;
  talla: string | null;
  color: string | null;
  stock_minimo: number | null;
  precio: number | null;
  actualizar_subcategoria: boolean;
  actualizar_talla: boolean;
  actualizar_color: boolean;
};
type Resultado = { total: number; creados: number; actualizados: number; sin_cambio: number };
type ImportacionAnterior = Resultado & { id: string; nota: string | null; created_at: string };

const normalizar = (valor: unknown) => String(valor ?? "")
  .trim().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  .replace(/[\s.\/-]+/g, "_");

const COLUMNAS = {
  sku: ["sku", "codigo", "cod", "referencia"],
  nombre: ["nombre", "producto", "descripcion", "detalle"],
  categoria: ["categoria", "familia", "tipo"],
  subcategoria: ["subcategoria", "sub_categoria", "subfamilia"],
  talla: ["talla", "size"],
  color: ["color", "tono"],
  stock_minimo: ["stock_minimo", "stockminimo", "minimo", "stock_alerta"],
  precio: ["precio", "pvp", "precio_venta", "valor"],
} as const;

function buscarColumna(columnas: string[], aliases: readonly string[]) {
  return columnas.find((columna) => aliases.includes(normalizar(columna)));
}

function numeroOpcional(valor: unknown): number | null | "invalido" {
  if (valor === null || valor === undefined || String(valor).trim() === "") return null;
  if (typeof valor === "number") return Number.isFinite(valor) ? valor : "invalido";
  let texto = String(valor).trim().replace(/[$\s]/g, "");
  if (texto.includes(",") && texto.includes(".")) {
    texto = texto.lastIndexOf(",") > texto.lastIndexOf(".")
      ? texto.replace(/\./g, "").replace(",", ".")
      : texto.replace(/,/g, "");
  } else if (texto.includes(",")) {
    texto = texto.replace(",", ".");
  }
  const numero = Number(texto);
  return Number.isFinite(numero) ? numero : "invalido";
}

export default function ImportarCatalogo({
  productos,
  alCompletar,
  alCerrar,
}: {
  productos: ProductoActual[];
  alCompletar: () => Promise<void>;
  alCerrar: () => void;
}) {
  const supabase = createClient();
  const [items, setItems] = useState<ItemCatalogo[]>([]);
  const [archivo, setArchivo] = useState("");
  const [errores, setErrores] = useState<string[]>([]);
  const [duplicados, setDuplicados] = useState(0);
  const [procesando, setProcesando] = useState(false);
  const [resultado, setResultado] = useState<Resultado | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [historial, setHistorial] = useState<ImportacionAnterior[]>([]);

  const skusActuales = useMemo(
    () => new Set(productos.map((p) => p.sku.trim().toUpperCase())),
    [productos]
  );
  const nuevos = useMemo(() => items.filter((i) => !skusActuales.has(i.sku)).length, [items, skusActuales]);
  const existentes = items.length - nuevos;

  async function cargarHistorial() {
    const { data } = await supabase
      .from("catalogo_importaciones")
      .select("id, nota, total:total_filas, creados, actualizados, sin_cambio, created_at")
      .order("created_at", { ascending: false })
      .limit(5);
    if (data) setHistorial(data as unknown as ImportacionAnterior[]);
  }

  useEffect(() => { cargarHistorial(); }, []);

  async function leerArchivo(file: File) {
    setProcesando(true);
    setResultado(null);
    setMsg(null);
    try {
      const libro = XLSX.read(await file.arrayBuffer(), { type: "array" });
      const hoja = libro.Sheets[libro.SheetNames[0]];
      const filas = XLSX.utils.sheet_to_json<Record<string, unknown>>(hoja, { defval: "" });
      if (!filas.length) throw new Error("El archivo está vacío.");
      if (filas.length > 5000) throw new Error("El archivo supera el máximo de 5.000 filas.");

      const columnas = Object.keys(filas[0]);
      const col = {
        sku: buscarColumna(columnas, COLUMNAS.sku),
        nombre: buscarColumna(columnas, COLUMNAS.nombre),
        categoria: buscarColumna(columnas, COLUMNAS.categoria),
        subcategoria: buscarColumna(columnas, COLUMNAS.subcategoria),
        talla: buscarColumna(columnas, COLUMNAS.talla),
        color: buscarColumna(columnas, COLUMNAS.color),
        stock_minimo: buscarColumna(columnas, COLUMNAS.stock_minimo),
        precio: buscarColumna(columnas, COLUMNAS.precio),
      };
      if (!col.sku || !col.nombre || !col.categoria) {
        throw new Error("Faltan columnas obligatorias: SKU, NOMBRE y CATEGORIA.");
      }

      const mapa = new Map<string, ItemCatalogo>();
      const problemas: string[] = [];
      let repetidos = 0;
      filas.forEach((fila, indice) => {
        const numeroFila = indice + 2;
        const sku = String(fila[col.sku!] ?? "").trim().toUpperCase();
        const nombre = String(fila[col.nombre!] ?? "").trim();
        const categoria = String(fila[col.categoria!] ?? "").trim();
        if (!sku && !nombre && !categoria) return;
        if (!sku || !nombre || !categoria) {
          problemas.push(`Fila ${numeroFila}: debe tener SKU, nombre y categoría.`);
          return;
        }
        const minimo = col.stock_minimo ? numeroOpcional(fila[col.stock_minimo]) : null;
        const precio = col.precio ? numeroOpcional(fila[col.precio]) : null;
        if (minimo === "invalido" || precio === "invalido" || (minimo !== null && minimo < 0) || (precio !== null && precio < 0)) {
          problemas.push(`Fila ${numeroFila} (${sku}): precio o stock mínimo inválido.`);
          return;
        }
        if (mapa.has(sku)) repetidos++;
        mapa.set(sku, {
          sku,
          nombre,
          categoria,
          subcategoria: col.subcategoria ? String(fila[col.subcategoria] ?? "").trim() || null : null,
          talla: col.talla ? String(fila[col.talla] ?? "").trim() || null : null,
          color: col.color ? String(fila[col.color] ?? "").trim() || null : null,
          stock_minimo: minimo === null ? null : Math.round(minimo),
          precio: precio === null ? null : Math.round(precio * 100) / 100,
          actualizar_subcategoria: Boolean(col.subcategoria),
          actualizar_talla: Boolean(col.talla),
          actualizar_color: Boolean(col.color),
        });
      });

      setArchivo(file.name);
      setItems(Array.from(mapa.values()));
      setErrores(problemas);
      setDuplicados(repetidos);
      if (!mapa.size) throw new Error("No encontré ninguna fila válida para importar.");
    } catch (error) {
      setItems([]);
      setErrores([]);
      setArchivo(file.name);
      setMsg(error instanceof Error ? error.message : "No se pudo leer el archivo.");
    } finally {
      setProcesando(false);
    }
  }

  async function importar() {
    if (!items.length || errores.length) return;
    if (!await confirmarDialogo(`Se procesarán ${items.length} productos.\n\n` +
      `• ${nuevos} productos nuevos\n• ${existentes} productos existentes\n\n` +
      `No se modificará el stock de ningún almacén. ¿Continuar?`)) return;

    setProcesando(true);
    setMsg(null);
    const { data, error } = await supabase.rpc("admin_importar_catalogo_productos", {
      p_items: items,
      p_nota: `Archivo: ${archivo}`,
    });
    if (error) {
      setMsg(error.message);
      setProcesando(false);
      return;
    }
    setResultado(data as Resultado);
    await alCompletar();
    await cargarHistorial();
    setProcesando(false);
  }

  async function descargarPlantilla() {
    setProcesando(true);
    setMsg(null);
    const [categoriasRes, subcategoriasRes] = await Promise.all([
      supabase.from("categorias_productos").select("nombre").eq("activo", true).order("nombre"),
      supabase.from("subcategorias_productos").select("nombre").eq("activo", true).order("nombre"),
    ]);
    const error = categoriasRes.error ?? subcategoriasRes.error;
    if (error) {
      setMsg(`No se pudieron preparar los catálogos de la plantilla: ${error.message}`);
      setProcesando(false);
      return;
    }
    const categorias = (categoriasRes.data ?? []).map((item) => item.nombre);
    const subcategorias = (subcategoriasRes.data ?? []).map((item) => item.nombre);
    try {
      await descargarPlantillaExcel({
        archivo: "plantilla_catalogo_productos.xlsx",
        titulo: "Importación del catálogo maestro",
        descripcion: "Usa una fila por SKU. Categoría y subcategoría se eligen de los catálogos activos; crea primero cualquier valor que todavía no exista.",
        filasDisponibles: 5000,
        ejemplos: [{
          SKU: "CAM-001-M",
          NOMBRE: "Camiseta local",
          CATEGORIA: categorias[0] ?? "Camisetas",
          SUBCATEGORIA: subcategorias[0] ?? "",
          TALLA: "M",
          COLOR: "Azul",
          STOCK_MINIMO: 5,
          PRECIO: 19.90,
        }],
        columnas: [
          { encabezado: "SKU", ancho: 22, obligatoria: true, ayuda: "Código único del producto, sin espacios al inicio o al final.", regla: { tipo: "longitud", maximo: 80 } },
          { encabezado: "NOMBRE", ancho: 40, obligatoria: true, ayuda: "Nombre comercial del producto.", regla: { tipo: "longitud", maximo: 200 } },
          { encabezado: "CATEGORIA", ancho: 26, obligatoria: true, ayuda: "Selecciona una categoría activa. Crea antes las categorías nuevas.", regla: { tipo: "lista", valores: categorias } },
          { encabezado: "SUBCATEGORIA", ancho: 28, ayuda: "Selecciona una subcategoría activa que corresponda a la categoría.", regla: { tipo: "lista", valores: subcategorias } },
          { encabezado: "TALLA", ancho: 14, ayuda: "Talla o variante. Déjala vacía cuando no aplique.", regla: { tipo: "longitud", maximo: 40 } },
          { encabezado: "COLOR", ancho: 18, ayuda: "Color o tono. Déjalo vacío cuando no aplique.", regla: { tipo: "longitud", maximo: 60 } },
          { encabezado: "STOCK_MINIMO", ancho: 18, ayuda: "Número entero igual o mayor que cero. Vacío conserva el valor existente.", regla: { tipo: "entero", minimo: 0, maximo: 999999999 } },
          { encabezado: "PRECIO", ancho: 15, ayuda: "Precio de venta en USD, igual o mayor que cero. Vacío conserva el valor existente.", regla: { tipo: "decimal", minimo: 0, maximo: 999999999 } },
        ],
        instrucciones: [
          { campo: "SKU", regla: "Obligatorio y único. Si aparece repetido, el importador conserva la última fila.", ejemplo: "CAM-001-M" },
          { campo: "NOMBRE", regla: "Obligatorio. Escribe una descripción clara del producto.", ejemplo: "Camiseta local" },
          { campo: "CATEGORIA", regla: "Obligatoria. Debe elegirse de la lista de categorías activas de la hoja CATÁLOGOS.", ejemplo: categorias[0] ?? "Camisetas" },
          { campo: "SUBCATEGORIA", regla: "Opcional. Debe existir y pertenecer a la categoría seleccionada; el sistema lo volverá a comprobar.", ejemplo: subcategorias[0] ?? "" },
          { campo: "STOCK_MINIMO", regla: "Entero no negativo. No cambia existencias; solo configura la alerta mínima.", ejemplo: "5" },
          { campo: "PRECIO", regla: "Decimal no negativo en USD. No escribas el símbolo $. Vacío conserva el precio actual.", ejemplo: "19.90" },
        ],
      });
    } catch (e) {
      setMsg(e instanceof Error ? e.message : "No se pudo generar la plantilla Excel.");
    } finally {
      setProcesando(false);
    }
  }

  return (
    <div className="card" style={{ borderLeft: "4px solid #2e75b6" }}>
      <div className="header-row">
        <div>
          <h3 style={{ margin: 0 }}>Importar catálogo maestro</h3>
          <p className="conteo" style={{ margin: "5px 0 0" }}>
            Crea y actualiza productos, categorías, subcategorías, precios y mínimos. No modifica existencias.
          </p>
        </div>
        <button type="button" className="chip-limpiar" onClick={alCerrar}>Cerrar</button>
      </div>

      <div className="grid-2">
        <div className="field">
          <label>Archivo Excel o CSV</label>
          <input type="file" accept=".xlsx,.xls,.csv" disabled={procesando}
            onChange={(e) => { const file = e.target.files?.[0]; if (file) leerArchivo(file); }}
            style={{ width: "100%" }} />
        </div>
        <div className="field">
          <label>Plantilla</label>
          <button type="button" className="secondary" disabled={procesando} onClick={descargarPlantilla}>Descargar Excel validado</button>
        </div>
      </div>

      {archivo && <div className="conteo" style={{ marginBottom: 10 }}><strong>{archivo}</strong></div>}
      {msg && <div className="error" style={{ marginBottom: 10 }}>{msg}</div>}
      {errores.length > 0 && (
        <div className="error-box">
          <strong>{errores.length} fila(s) requieren corrección:</strong>
          <ul style={{ margin: "7px 0 0", paddingLeft: 20 }}>
            {errores.slice(0, 12).map((error, i) => <li key={i}>{error}</li>)}
          </ul>
          {errores.length > 12 && <div>Y {errores.length - 12} más.</div>}
        </div>
      )}

      {items.length > 0 && (
        <>
          <div className="kpis compactos">
            <div className="kpi"><div className="label">Filas válidas</div><div className="valor">{items.length}</div></div>
            <div className="kpi ok"><div className="label">Productos nuevos</div><div className="valor">{nuevos}</div></div>
            <div className="kpi"><div className="label">Existentes</div><div className="valor">{existentes}</div></div>
            <div className={`kpi ${errores.length ? "alerta" : "ok"}`}><div className="label">Con error</div><div className="valor">{errores.length}</div></div>
          </div>
          {duplicados > 0 && <div className="info-box">Se encontraron {duplicados} SKU repetidos; se usará la última fila de cada uno.</div>}
          <div className="tabla-scroll" style={{ maxHeight: 330 }}>
            <table>
              <thead><tr><th>Estado</th><th>SKU</th><th>Producto</th><th>Categoría / subcategoría</th><th>Talla</th><th className="num">Mín.</th><th className="num">Precio</th></tr></thead>
              <tbody>
                {items.slice(0, 200).map((item) => (
                  <tr key={item.sku}>
                    <td><span className={`badge ${skusActuales.has(item.sku) ? "cero" : "ok"}`}>{skusActuales.has(item.sku) ? "Actualizar" : "Nuevo"}</span></td>
                    <td>{item.sku}</td><td>{item.nombre}</td>
                    <td>{item.categoria}{item.subcategoria ? <div className="conteo">{item.subcategoria}</div> : null}</td>
                    <td>{item.talla ?? "-"}</td><td className="num">{item.stock_minimo ?? "Conservar"}</td>
                    <td className="num">{item.precio == null ? "Conservar" : `$${item.precio.toFixed(2)}`}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {items.length > 200 && <p className="conteo">Vista previa de 200 filas. Se procesarán las {items.length} filas válidas.</p>}
          <button type="button" onClick={importar} disabled={procesando || errores.length > 0} style={{ marginTop: 12 }}>
            {procesando ? "Procesando catálogo..." : `Importar ${items.length} productos`}
          </button>
        </>
      )}

      {resultado && (
        <div className="success-box">
          <strong>Importación terminada:</strong> {resultado.creados} creados, {resultado.actualizados} actualizados y {resultado.sin_cambio} sin cambios.
        </div>
      )}

      {historial.length > 0 && (
        <div style={{ marginTop: 18 }}>
          <h4 style={{ margin: "0 0 8px", color: "#1f3864" }}>Últimas importaciones</h4>
          <div className="tabla-scroll" style={{ maxHeight: 240 }}>
            <table>
              <thead><tr><th>Fecha</th><th>Referencia</th><th className="num">Total</th><th className="num">Nuevos</th><th className="num">Actualizados</th><th className="num">Sin cambio</th></tr></thead>
              <tbody>
                {historial.map((h) => (
                  <tr key={h.id}>
                    <td style={{ whiteSpace: "nowrap" }}>{fecha(h.created_at)}</td>
                    <td>{h.nota ?? "-"}</td>
                    <td className="num">{h.total}</td><td className="num">{h.creados}</td>
                    <td className="num">{h.actualizados}</td><td className="num">{h.sin_cambio}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
