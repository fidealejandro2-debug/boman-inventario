"use client";

import { useEffect, useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { exportarCSV } from "@/lib/utils";

type Almacen = { id: string; nombre: string; tipo: string };
type Item = { sku: string; cantidad: number };
type Preview = {
  sku: string;
  cantidad: number;
  nombre: string | null;
  actual: number;
  existe: boolean;
};

// Nombres de columna aceptados (sin distinguir mayúsculas ni acentos)
const COL_SKU = ["sku", "codigo", "código", "cod", "item", "referencia"];
const COL_CANT = ["cantidad", "cant", "stock", "existencia", "existencias", "saldo", "unidades", "conteo"];

const normalizar = (s: string) =>
  s.toString().trim().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");

export default function ImportarCliente() {
  const supabase = createClient();

  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [almacenId, setAlmacenId] = useState("");
  const [cerrarFaltantes, setCerrarFaltantes] = useState(true);
  const [nota, setNota] = useState("");

  const [items, setItems] = useState<Item[]>([]);
  const [nombreArchivo, setNombreArchivo] = useState("");
  const [preview, setPreview] = useState<Preview[]>([]);
  const [analizando, setAnalizando] = useState(false);
  const [aplicando, setAplicando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const [resultado, setResultado] = useState<any>(null);
  const [soloCambios, setSoloCambios] = useState(true);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.from("almacenes").select("id, nombre, tipo").eq("activo", true).order("tipo");
      if (data) setAlmacenes(data as Almacen[]);
    })();
  }, []);

  function limpiarTodo() {
    setItems([]); setPreview([]); setNombreArchivo(""); setResultado(null); setMsg(null);
  }

  // ---------- 1. Leer el archivo ----------
  async function leerArchivo(file: File) {
    limpiarTodo();
    setNombreArchivo(file.name);
    try {
      const buf = await file.arrayBuffer();
      const wb = XLSX.read(buf, { type: "array" });
      const hoja = wb.Sheets[wb.SheetNames[0]];
      const filas: any[] = XLSX.utils.sheet_to_json(hoja, { defval: "" });

      if (!filas.length) { setMsg({ tipo: "error", texto: "El archivo está vacío." }); return; }

      const columnas = Object.keys(filas[0]);
      const colSku = columnas.find((c) => COL_SKU.includes(normalizar(c)));
      const colCant = columnas.find((c) => COL_CANT.includes(normalizar(c)));

      if (!colSku || !colCant) {
        setMsg({
          tipo: "error",
          texto: `No encontré las columnas necesarias. El archivo tiene: ${columnas.join(", ")}. Necesito una columna de código (SKU/CODIGO) y una de cantidad (CANTIDAD/STOCK).`,
        });
        return;
      }

      const mapa = new Map<string, number>();
      let invalidas = 0;
      filas.forEach((f) => {
        const sku = String(f[colSku] ?? "").trim().toUpperCase();
        const n = Number(String(f[colCant] ?? "").toString().replace(",", "."));
        if (!sku) return;
        if (!Number.isFinite(n) || n < 0) { invalidas++; return; }
        mapa.set(sku, Math.round(n)); // si el SKU se repite, gana la última fila
      });

      if (!mapa.size) { setMsg({ tipo: "error", texto: "No se pudo leer ninguna fila válida." }); return; }

      setItems(Array.from(mapa, ([sku, cantidad]) => ({ sku, cantidad })));
      setMsg(invalidas ? { tipo: "error", texto: `Se ignoraron ${invalidas} fila(s) con cantidad vacía o inválida.` } : null);
    } catch (e: any) {
      setMsg({ tipo: "error", texto: "No pude leer el archivo: " + e.message });
    }
  }

  // ---------- 2. Comparar contra el stock actual ----------
  async function analizar() {
    if (!almacenId) { setMsg({ tipo: "error", texto: "Selecciona primero el almacén." }); return; }
    if (!items.length) { setMsg({ tipo: "error", texto: "Carga primero un archivo." }); return; }

    setAnalizando(true); setMsg(null);

    const { data: prods, error: e1 } = await supabase.from("productos").select("id, sku, nombre");
    const { data: inv, error: e2 } = await supabase
      .from("inventario").select("producto_id, cantidad").eq("entidad_id", almacenId);

    setAnalizando(false);
    if (e1 || e2) { setMsg({ tipo: "error", texto: e1?.message ?? e2!.message }); return; }

    const porSku = new Map((prods ?? []).map((p: any) => [String(p.sku).toUpperCase(), p]));
    const stockActual = new Map((inv ?? []).map((r: any) => [r.producto_id, r.cantidad]));

    const filas: Preview[] = items.map((it) => {
      const p = porSku.get(it.sku);
      return {
        sku: it.sku,
        cantidad: it.cantidad,
        nombre: p?.nombre ?? null,
        actual: p ? (stockActual.get(p.id) ?? 0) : 0,
        existe: !!p,
      };
    });

    // Productos con stock que NO vienen en el archivo
    if (cerrarFaltantes) {
      const skusArchivo = new Set(items.map((i) => i.sku));
      (prods ?? []).forEach((p: any) => {
        const actual = stockActual.get(p.id) ?? 0;
        if (actual !== 0 && !skusArchivo.has(String(p.sku).toUpperCase())) {
          filas.push({ sku: p.sku, cantidad: 0, nombre: p.nombre, actual, existe: true });
        }
      });
    }

    setPreview(filas);
  }

  // ---------- 3. Aplicar ----------
  async function aplicar() {
    const nombreAlm = almacenes.find((a) => a.id === almacenId)?.nombre ?? "";
    const ok = window.confirm(
      `Vas a REEMPLAZAR el stock de "${nombreAlm}".\n\n` +
      `• ${cambios.length} producto(s) cambiarán de cantidad\n` +
      (cerrarFaltantes ? `• ${aCero.length} producto(s) quedarán en cero por no estar en el archivo\n` : "") +
      (desconocidos.length ? `• ${desconocidos.length} código(s) del archivo no existen en el catálogo y se ignorarán\n` : "") +
      `\nCada cambio queda registrado como un ajuste en el kardex.\n\n¿Continuar?`
    );
    if (!ok) return;

    setAplicando(true); setMsg(null);
    const { data, error } = await supabase.rpc("importar_stock", {
      p_entidad_id: almacenId,
      p_items: items,
      p_nota: nota || `Importación desde ${nombreArchivo}`,
      p_cerrar_faltantes: cerrarFaltantes,
    });
    setAplicando(false);

    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setResultado(data);
    setPreview([]);
    setItems([]);
    setMsg({ tipo: "ok", texto: `Stock de "${nombreAlm}" actualizado.` });
  }

  // ---------- Derivados ----------
  const desconocidos = useMemo(() => preview.filter((p) => !p.existe), [preview]);
  const cambios = useMemo(() => preview.filter((p) => p.existe && p.actual !== p.cantidad), [preview]);
  const aCero = useMemo(() => cambios.filter((p) => p.cantidad === 0), [cambios]);
  const visibles = useMemo(
    () => (soloCambios ? preview.filter((p) => !p.existe || p.actual !== p.cantidad) : preview),
    [preview, soloCambios]
  );

  function descargarPlantilla() {
    exportarCSV("plantilla_toma_inventario", [{ SKU: "CAM-ARG-PRN-24-M", CANTIDAD: 12 }]);
  }

  return (
    <>
      <h2 style={{ color: "#1f3864" }}>Importar stock</h2>

      <div className="card" style={{ borderLeft: "4px solid #f59e0b" }}>
        <p style={{ margin: 0, fontSize: 14 }}>
          Esta herramienta <strong>reemplaza</strong> el stock del almacén que elijas con las cantidades del archivo.
          Sirve para cargar una toma física de inventario. Cada cambio queda registrado como un <strong>ajuste</strong> en
          el kardex, con quién lo hizo y la cantidad anterior — así que es reversible y auditable.
        </p>
      </div>

      {/* ---- Paso 1 ---- */}
      <div className="card">
        <h3 style={{ marginTop: 0 }}>1. Almacén y archivo</h3>
        <div className="grid-2">
          <div className="field">
            <label>Almacén a actualizar</label>
            <select value={almacenId} onChange={(e) => { setAlmacenId(e.target.value); setPreview([]); }} style={{ width: "100%" }}>
              <option value="">Selecciona...</option>
              {almacenes.map((a) => (
                <option key={a.id} value={a.id}>{a.nombre}{a.tipo === "bodega" ? " (bodega)" : ""}</option>
              ))}
            </select>
          </div>
          <div className="field">
            <label>Archivo (.xlsx, .xls o .csv)</label>
            <input type="file" accept=".xlsx,.xls,.csv"
              onChange={(e) => { const f = e.target.files?.[0]; if (f) leerArchivo(f); }}
              style={{ width: "100%" }} />
          </div>
        </div>

        <p style={{ fontSize: 13, color: "#6b7280" }}>
          El archivo necesita dos columnas: una de código (<code>SKU</code>, <code>CODIGO</code>) y otra de cantidad
          (<code>CANTIDAD</code>, <code>STOCK</code>, <code>CONTEO</code>). Las demás columnas se ignoran.{" "}
          <a onClick={descargarPlantilla} style={{ color: "#2e75b6", cursor: "pointer", textDecoration: "underline" }}>
            Descargar plantilla
          </a>
        </p>

        <div className="field">
          <label style={{ fontWeight: 500 }}>
            <input type="checkbox" checked={cerrarFaltantes}
              onChange={(e) => { setCerrarFaltantes(e.target.checked); setPreview([]); }} style={{ marginRight: 6 }} />
            Poner en cero los productos de este almacén que no aparezcan en el archivo
          </label>
          <span style={{ fontSize: 13, color: "#6b7280" }}>
            {cerrarFaltantes
              ? "Reemplazo total: el archivo pasa a ser la única verdad del almacén."
              : "Actualización parcial: solo se tocan los productos listados en el archivo."}
          </span>
        </div>

        <div className="field">
          <label>Referencia del conteo (opcional)</label>
          <input value={nota} onChange={(e) => setNota(e.target.value)}
            placeholder="Ej: Toma física agosto 2026 — acta N° 12" style={{ width: "100%" }} />
        </div>

        {nombreArchivo && (
          <p style={{ fontSize: 14 }}>
            <strong>{nombreArchivo}</strong> — {items.length} código(s) leído(s)
          </p>
        )}

        {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

        <button onClick={analizar} disabled={!items.length || !almacenId || analizando}>
          {analizando ? "Comparando..." : "2. Ver qué va a cambiar"}
        </button>
        {(items.length > 0 || preview.length > 0) && (
          <button className="chip-limpiar" onClick={limpiarTodo} style={{ marginLeft: 8 }}>Descartar</button>
        )}
      </div>

      {/* ---- Resultado final ---- */}
      {resultado && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Importación completada</h3>
          <div className="kpis">
            <div className="kpi ok"><div className="label">Actualizados</div><div className="valor">{resultado.actualizados}</div></div>
            <div className="kpi"><div className="label">Sin cambio</div><div className="valor">{resultado.sin_cambio}</div></div>
            <div className="kpi"><div className="label">Puestos en cero</div><div className="valor">{resultado.cerrados}</div></div>
            <div className={`kpi ${resultado.desconocidos?.length ? "alerta" : ""}`}>
              <div className="label">Códigos no encontrados</div>
              <div className="valor">{resultado.desconocidos?.length ?? 0}</div>
            </div>
          </div>
          {resultado.desconocidos?.length > 0 && (
            <>
              <p style={{ fontSize: 14 }}>
                Estos códigos venían en el archivo pero no existen en el catálogo, así que se ignoraron.
                Créalos en Productos y vuelve a importar si corresponde:
              </p>
              <div style={{ maxHeight: 160, overflowY: "auto", fontSize: 13, background: "#fafafa", padding: 10, borderRadius: 6 }}>
                {resultado.desconocidos.join(", ")}
              </div>
            </>
          )}
        </div>
      )}

      {/* ---- Paso 2: vista previa ---- */}
      {preview.length > 0 && (
        <div className="card">
          <div className="header-row">
            <h3>2. Vista previa — nada se ha guardado todavía</h3>
            <button className="secondary" onClick={() => exportarCSV("previa_importacion", visibles.map((p) => ({
              SKU: p.sku, Producto: p.nombre ?? "NO EXISTE EN CATÁLOGO",
              StockActual: p.existe ? p.actual : "", StockNuevo: p.existe ? p.cantidad : "",
              Diferencia: p.existe ? p.cantidad - p.actual : "",
            })))}>Exportar previa</button>
          </div>

          <div className="kpis">
            <div className="kpi"><div className="label">Cambian</div><div className="valor">{cambios.length}</div></div>
            <div className="kpi"><div className="label">Sin cambio</div><div className="valor">{preview.filter((p) => p.existe && p.actual === p.cantidad).length}</div></div>
            <div className="kpi"><div className="label">Quedan en cero</div><div className="valor">{aCero.length}</div></div>
            <div className={`kpi ${desconocidos.length ? "alerta" : ""}`}>
              <div className="label">No existen</div><div className="valor">{desconocidos.length}</div>
            </div>
          </div>

          {desconocidos.length > 0 && (
            <div className="error">
              {desconocidos.length} código(s) del archivo no están en el catálogo y se ignorarán:{" "}
              {desconocidos.slice(0, 12).map((d) => d.sku).join(", ")}
              {desconocidos.length > 12 ? ` y ${desconocidos.length - 12} más` : ""}.
            </div>
          )}

          <label style={{ fontWeight: 500, display: "block", marginBottom: 10 }}>
            <input type="checkbox" checked={soloCambios} onChange={(e) => setSoloCambios(e.target.checked)} style={{ marginRight: 6 }} />
            Mostrar solo lo que cambia
          </label>

          <div className="tabla-scroll">
            <table>
              <thead>
                <tr><th>SKU</th><th>Producto</th><th className="num">Actual</th><th className="num">Nuevo</th><th className="num">Dif.</th></tr>
              </thead>
              <tbody>
                {visibles.slice(0, 400).map((p, i) => {
                  const dif = p.cantidad - p.actual;
                  return (
                    <tr key={i} className={!p.existe ? "fila-alerta" : ""}>
                      <td>{p.sku}</td>
                      <td>{p.nombre ?? <em style={{ color: "#991b1b" }}>No existe en el catálogo</em>}</td>
                      <td className="num">{p.existe ? p.actual : "-"}</td>
                      <td className="num">{p.existe ? p.cantidad : "-"}</td>
                      <td className="num" style={{ color: !p.existe ? "#9ca3af" : dif > 0 ? "#166534" : dif < 0 ? "#991b1b" : "#9ca3af" }}>
                        {p.existe ? (dif > 0 ? `+${dif}` : dif) : "-"}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {visibles.length > 400 && (
            <p style={{ fontSize: 13, color: "#6b7280" }}>Mostrando 400 de {visibles.length}. Exporta la previa para revisarla completa.</p>
          )}

          <button className="peligro" onClick={aplicar} disabled={aplicando} style={{ marginTop: 12, fontSize: 15, padding: "10px 20px" }}>
            {aplicando ? "Aplicando..." : `3. Aplicar y reemplazar stock (${cambios.length} cambios)`}
          </button>
        </div>
      )}
    </>
  );
}
