"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { confirmarDialogo } from "@/components/Dialogo";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { descargarPlantillaExcel } from "@/lib/plantillasExcel";
import type { Perfil } from "@/lib/permisos";

type Almacen = { id: string; nombre: string; codigo: string; tipo: string };
type Producto = { id: string; sku: string; nombre: string; talla: string | null };
type FilaArchivo = { fila: number; sku: string; cantidad: number; observacion: string };
type FilaVista = FilaArchivo & {
  producto: Producto | null;
  stockActual: number | null;
  diferencia: number | null;
  problema: string | null;
};
type Resultado = {
  documento_id: string;
  numero: string;
  total?: number;
  diferencias?: number;
  estado?: string;
  duplicado: boolean;
  mensaje: string;
};

const normalizar = (valor: unknown) => String(valor ?? "")
  .trim().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  .replace(/[\s.\/-]+/g, "_");

const ALIASES_SKU = ["sku", "codigo", "cod", "referencia"];
const ALIASES_CANTIDAD = ["cantidad", "stock", "conteo", "existencia", "saldo", "stock_fisico"];
const ALIASES_OBSERVACION = ["observacion", "nota", "detalle", "comentario"];

function columna(columnas: string[], aliases: string[]) {
  return columnas.find((nombre) => aliases.includes(normalizar(nombre)));
}

function entero(valor: unknown) {
  if (typeof valor === "number") return Number.isInteger(valor) && valor >= 0 ? valor : null;
  const texto = String(valor ?? "").trim();
  return /^\d+$/.test(texto) ? Number(texto) : null;
}

export default function ImportarStockGeneral({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [permitidos, setPermitidos] = useState<string[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [almacenId, setAlmacenId] = useState(perfil.entidad_id ?? "");
  const [stock, setStock] = useState<Record<string, number>>({});
  const [archivo, setArchivo] = useState("");
  const [filas, setFilas] = useState<FilaArchivo[]>([]);
  const [erroresArchivo, setErroresArchivo] = useState<string[]>([]);
  const [duplicados, setDuplicados] = useState(0);
  const [nota, setNota] = useState("");
  const [clave, setClave] = useState(() => nuevaClaveIdempotencia());
  const [procesando, setProcesando] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const [resultado, setResultado] = useState<Resultado | null>(null);

  const rolGlobal = perfil.rol === "admin" || perfil.rol === "control";

  useEffect(() => {
    async function cargarBase() {
      async function consultarProductos() {
        const acumulado: Producto[] = [];
        let desde = 0;
        while (true) {
          const respuesta = await supabase.from("productos")
            .select("id, sku, nombre, talla").eq("activo", true).order("sku")
            .range(desde, desde + 999);
          if (respuesta.error) return { data: acumulado, error: respuesta.error };
          acumulado.push(...((respuesta.data ?? []) as Producto[]));
          if ((respuesta.data ?? []).length < 1000) return { data: acumulado, error: null };
          desde += 1000;
        }
      }
      const [a, pa, p] = await Promise.all([
        supabase.from("almacenes").select("id, nombre, codigo, tipo").eq("activo", true).order("nombre"),
        supabase.from("perfil_almacenes").select("almacen_id").eq("perfil_id", perfil.id),
        consultarProductos(),
      ]);
      const error = a.error ?? pa.error ?? p.error;
      if (error) setMsg({ tipo: "error", texto: error.message });
      const ids = (pa.data ?? []).map((item: { almacen_id: string }) => item.almacen_id);
      setPermitidos(ids);
      setAlmacenes((a.data ?? []) as Almacen[]);
      setProductos((p.data ?? []) as Producto[]);
      if (!almacenId && ids.length) setAlmacenId(ids[0]);
      setCargando(false);
    }
    cargarBase();
  }, []);

  const almacenesVisibles = useMemo(
    () => rolGlobal
      ? almacenes
      : almacenes.filter((item) => permitidos.includes(item.id) || item.id === perfil.entidad_id),
    [almacenes, permitidos, perfil.entidad_id, rolGlobal]
  );

  useEffect(() => {
    async function cargarStock() {
      if (!almacenId) { setStock({}); return; }
      const acumulado: Record<string, number> = {};
      let desde = 0;
      let continuar = true;
      while (continuar) {
        const { data, error } = await supabase
          .from("vista_stock_operativo")
          .select("sku, stock_fisico")
          .eq("almacen_id", almacenId)
          .range(desde, desde + 999);
        if (error) {
          setMsg({ tipo: "error", texto: error.message });
          return;
        }
        (data ?? []).forEach((item: { sku: string; stock_fisico: number }) => {
          acumulado[item.sku.trim().toUpperCase()] = item.stock_fisico ?? 0;
        });
        continuar = (data ?? []).length === 1000;
        desde += 1000;
      }
      setStock(acumulado);
    }
    cargarStock();
  }, [almacenId]);

  const productosPorSku = useMemo(() => new Map(
    productos.map((producto) => [producto.sku.trim().toUpperCase(), producto])
  ), [productos]);

  const vista = useMemo<FilaVista[]>(() => filas.map((fila) => {
    const producto = productosPorSku.get(fila.sku) ?? null;
    const habilitado = Object.prototype.hasOwnProperty.call(stock, fila.sku);
    const actual = habilitado ? stock[fila.sku] : null;
    return {
      ...fila,
      producto,
      stockActual: actual,
      diferencia: actual === null ? null : fila.cantidad - actual,
      problema: !producto
        ? "SKU inexistente o inactivo"
        : almacenId && !habilitado
          ? "No está habilitado en este almacén"
          : null,
    };
  }), [filas, productosPorSku, stock, almacenId]);

  const erroresVista = vista.filter((fila) => fila.problema);
  const diferencias = vista.filter((fila) => fila.diferencia !== null && fila.diferencia !== 0).length;

  async function leerArchivo(file: File) {
    setProcesando(true);
    setMsg(null);
    setResultado(null);
    setClave(nuevaClaveIdempotencia());
    try {
      const libro = XLSX.read(await file.arrayBuffer(), { type: "array" });
      const hoja = libro.Sheets[libro.SheetNames[0]];
      const datos = XLSX.utils.sheet_to_json<Record<string, unknown>>(hoja, { defval: "" });
      if (!datos.length) throw new Error("El archivo está vacío.");
      if (datos.length > 5000) throw new Error("El archivo supera el máximo de 5.000 filas.");

      const columnas = Object.keys(datos[0]);
      const colSku = columna(columnas, ALIASES_SKU);
      const colCantidad = columna(columnas, ALIASES_CANTIDAD);
      const colObservacion = columna(columnas, ALIASES_OBSERVACION);
      if (!colSku || !colCantidad) throw new Error("Faltan las columnas obligatorias SKU y CANTIDAD.");

      const mapa = new Map<string, FilaArchivo>();
      const problemas: string[] = [];
      let repetidos = 0;
      datos.forEach((dato, indice) => {
        const numeroFila = indice + 2;
        const sku = String(dato[colSku] ?? "").trim().toUpperCase();
        const valor = entero(dato[colCantidad]);
        if (!sku && String(dato[colCantidad] ?? "").trim() === "") return;
        if (!sku) { problemas.push(`Fila ${numeroFila}: falta el SKU.`); return; }
        if (valor === null) { problemas.push(`Fila ${numeroFila} (${sku}): la cantidad debe ser un entero igual o mayor que cero.`); return; }
        if (mapa.has(sku)) repetidos += 1;
        mapa.set(sku, {
          fila: numeroFila,
          sku,
          cantidad: valor,
          observacion: colObservacion ? String(dato[colObservacion] ?? "").trim() : "",
        });
      });
      if (!mapa.size) throw new Error("No encontré filas válidas para importar.");
      setArchivo(file.name);
      setFilas(Array.from(mapa.values()));
      setErroresArchivo(problemas);
      setDuplicados(repetidos);
    } catch (error) {
      setArchivo(file.name);
      setFilas([]);
      setErroresArchivo([]);
      setDuplicados(0);
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo leer el archivo." });
    } finally {
      setProcesando(false);
    }
  }

  async function importar() {
    if (!almacenId) return setMsg({ tipo: "error", texto: "Selecciona el almacén contado." });
    if (!nota.trim()) return setMsg({ tipo: "error", texto: "Indica el motivo o referencia del conteo." });
    if (!filas.length || erroresArchivo.length || erroresVista.length) {
      return setMsg({ tipo: "error", texto: "Corrige las filas observadas antes de importar." });
    }
    const almacen = almacenesVisibles.find((item) => item.id === almacenId)?.nombre ?? "el almacén";
    const confirmar = await confirmarDialogo(
      `Se importarán ${filas.length} SKU para ${almacen}.\n\n` +
      `El archivo NO cambiará el stock de inmediato. Creará un conteo parcial pendiente de revisión por Control.\n\n¿Continuar?`
    );
    if (!confirmar) return;

    setProcesando(true);
    setMsg(null);
    const { data, error } = await supabase.rpc("importar_conteo_fisico_v63", {
      p_almacen_id: almacenId,
      p_items: filas.map((fila) => ({ sku: fila.sku, cantidad: fila.cantidad, observacion: fila.observacion })),
      p_nota: `${nota.trim()} · Archivo: ${archivo}`,
      p_idempotency_key: clave,
    });
    if (error) {
      setMsg({ tipo: "error", texto: error.message });
      setProcesando(false);
      return;
    }
    const respuesta = data as Resultado;
    setResultado(respuesta);
    setMsg({ tipo: "ok", texto: respuesta.mensaje });
    setClave(nuevaClaveIdempotencia());
    setProcesando(false);
  }

  async function descargarPlantilla() {
    try {
      await descargarPlantillaExcel({
        archivo: "plantilla_conteo_fisico.xlsx",
        titulo: "Conteo físico de existencias",
        descripcion: "Selecciona el SKU del catálogo y registra únicamente la cantidad físicamente contada. Los SKU omitidos no cambian.",
        filasDisponibles: 5000,
        ejemplos: [
          { SKU: productos[0]?.sku ?? "CAM-001-M", CANTIDAD: 12, OBSERVACION: "Conteo estante A1" },
          { SKU: productos[1]?.sku ?? "", CANTIDAD: 8, OBSERVACION: "" },
        ],
        columnas: [
          { encabezado: "SKU", ancho: 24, obligatoria: true, ayuda: "Selecciona un SKU activo del catálogo.", regla: { tipo: "lista", valores: productos.map((p) => p.sku) } },
          { encabezado: "CANTIDAD", ancho: 16, obligatoria: true, ayuda: "Cantidad física contada: entero igual o mayor que cero.", regla: { tipo: "entero", minimo: 0, maximo: 999999999 } },
          { encabezado: "OBSERVACION", ancho: 48, ayuda: "Ubicación, incidencia o aclaración del conteo.", regla: { tipo: "longitud", maximo: 300 } },
        ],
        instrucciones: [
          { campo: "SKU", regla: "Obligatorio. Elige un código de la lista del catálogo activo; no escribas nombres de producto.", ejemplo: productos[0]?.sku ?? "CAM-001-M" },
          { campo: "CANTIDAD", regla: "Obligatoria. Debe ser un número entero igual o mayor que cero.", ejemplo: "12" },
          { campo: "OBSERVACION", regla: "Opcional. Úsala para dejar ubicación o explicación de una diferencia.", ejemplo: "Conteo estante A1" },
          { campo: "ALCANCE", regla: "Solo se cuentan los SKU incluidos. El archivo crea un conteo pendiente de revisión; no altera stock directamente.", ejemplo: "" },
        ],
      });
    } catch (e) {
      setMsg({ tipo: "error", texto: e instanceof Error ? e.message : "No se pudo generar la plantilla Excel." });
    }
  }

  if (cargando) return <div className="card"><p>Cargando permisos, productos y almacenes…</p></div>;

  return (
    <section className="card import-stock">
      <div className="card-titulo-linea">
        <div>
          <h2>Importar conteo físico</h2>
          <p>Solo se cuentan los SKU incluidos en el archivo; los productos omitidos conservan su stock.</p>
        </div>
        <button type="button" className="secondary" onClick={descargarPlantilla}>Descargar plantilla Excel validada</button>
      </div>

      <div className="import-pasos" aria-label="Proceso de importación">
        <span className={archivo ? "completo" : "activo"}>1. Archivo</span>
        <span className={archivo && !resultado ? "activo" : resultado ? "completo" : ""}>2. Validar</span>
        <span className={resultado ? "completo" : ""}>3. Enviar a Control</span>
      </div>

      <div className="import-form-grid">
        <div className="field">
          <label>Almacén contado</label>
          <select value={almacenId} onChange={(evento) => { setAlmacenId(evento.target.value); setResultado(null); }}>
            <option value="">Seleccionar…</option>
            {almacenesVisibles.map((almacen) => <option value={almacen.id} key={almacen.id}>{almacen.nombre}</option>)}
          </select>
        </div>
        <div className="field">
          <label>Archivo Excel o CSV</label>
          <input type="file" accept=".xlsx,.xls,.csv" disabled={procesando} onChange={(evento) => {
            const file = evento.target.files?.[0];
            if (file) leerArchivo(file);
          }} />
        </div>
        <div className="field import-nota">
          <label>Motivo o referencia</label>
          <input value={nota} onChange={(evento) => setNota(evento.target.value)} placeholder="Ej. Conteo de cierre septiembre 2026" maxLength={180} />
        </div>
      </div>

      {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}

      {resultado && (
        <div className="import-resultado">
          <div><span>Documento</span><strong>{resultado.numero}</strong></div>
          <div><span>SKU procesados</span><strong>{resultado.total ?? filas.length}</strong></div>
          <div><span>Con diferencia</span><strong>{resultado.diferencias ?? diferencias}</strong></div>
          <div><span>Estado</span><strong>Pendiente de Control</strong></div>
          <Link href="/conteos" className="btn-enlace">Abrir conteos</Link>
        </div>
      )}

      {archivo && (
        <div className="import-resumen">
          <strong>{archivo}</strong>
          <span>{filas.length} SKU únicos</span>
          <span>{diferencias} diferencias previstas</span>
          {duplicados > 0 && <span>{duplicados} duplicados: se usó la última fila</span>}
          {(erroresArchivo.length + erroresVista.length) > 0 && <span className="import-resumen-error">{erroresArchivo.length + erroresVista.length} errores</span>}
        </div>
      )}

      {erroresArchivo.length > 0 && (
        <div className="import-errores"><strong>Errores del archivo</strong>{erroresArchivo.slice(0, 20).map((error) => <span key={error}>{error}</span>)}</div>
      )}

      {vista.length > 0 && (
        <>
          <div className="tabla-scroll import-preview">
            <table>
              <thead><tr><th>Fila</th><th>SKU</th><th>Producto</th><th className="num">Stock sistema</th><th className="num">Conteo</th><th className="num">Diferencia</th><th>Validación</th></tr></thead>
              <tbody>{vista.slice(0, 500).map((fila) => (
                <tr key={fila.sku} className={fila.problema ? "fila-alerta" : ""}>
                  <td>{fila.fila}</td>
                  <td><strong>{fila.sku}</strong></td>
                  <td>{fila.producto ? `${fila.producto.nombre}${fila.producto.talla ? ` · ${fila.producto.talla}` : ""}` : "-"}</td>
                  <td className="num">{fila.stockActual ?? "-"}</td>
                  <td className="num"><strong>{fila.cantidad}</strong></td>
                  <td className={`num ${fila.diferencia && fila.diferencia !== 0 ? "texto-alerta" : ""}`}>{fila.diferencia === null ? "-" : fila.diferencia > 0 ? `+${fila.diferencia}` : fila.diferencia}</td>
                  <td>{fila.problema ? <span className="badge estado-rechazado">{fila.problema}</span> : <span className="badge estado-aprobado">Correcto</span>}</td>
                </tr>
              ))}</tbody>
            </table>
          </div>
          {vista.length > 500 && <p className="conteo">Vista previa limitada a 500 de {vista.length} filas.</p>}
          <div className="acciones import-acciones">
            <button type="button" onClick={importar} disabled={procesando || !almacenId || !nota.trim() || Boolean(erroresArchivo.length || erroresVista.length || resultado)}>
              {procesando ? "Procesando…" : "Crear conteo y enviar a Control"}
            </button>
          </div>
        </>
      )}
    </section>
  );
}
