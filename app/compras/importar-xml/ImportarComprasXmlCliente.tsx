"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import Aviso from "@/components/Aviso";
import { confirmarDialogo, pedirMotivoDialogo } from "@/components/Dialogo";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import type { Perfil } from "@/lib/getPerfil";
import { createClient } from "@/lib/supabase/client";
import {
  calcularHashXml,
  parsearFacturaCompraSri,
  type FacturaCompraSri,
} from "@/lib/xmlFacturaSri";

type ArchivoPreparado = {
  nombre: string;
  ruta: string;
  hash: string;
  factura: FacturaCompraSri;
};

type Producto = { id: string; sku: string; nombre: string; talla: string | null; color: string | null; tipo_inventario: string | null };
type Sustento = { codigo: string; nombre: string };
type CategoriaProducto = { id: string; nombre: string };
type SubcategoriaProducto = { id: string; categoria_id: string; nombre: string };
type UnidadMedida = { codigo: string; nombre: string; simbolo: string };
type AbreviaturaSku = { tipo: "categoria" | "entidad" | "variante"; nombre: string; nombre_normalizado: string; codigo: string };
type Importacion = {
  id: string;
  empresa_codigo: string;
  empresa: string;
  proveedor_id: string | null;
  proveedor_ruc: string;
  proveedor_razon_social: string;
  archivo_nombre: string;
  clave_acceso: string;
  numero_documento: string;
  fecha_emision: string;
  total: number;
  estado: "pendiente_homologacion" | "listo";
  lineas_total: number;
  lineas_homologadas: number;
  lineas_pendientes: number;
  created_at: string;
};
type Linea = {
  id: string;
  importacion_id: string;
  numero_linea: number;
  codigo_proveedor: string | null;
  codigo_auxiliar: string | null;
  descripcion: string;
  cantidad: number;
  precio_unitario: number;
  precio_neto: number;
  precio_referencia_unitario: number | null;
  precio_referencia_neto: number | null;
  precio_referencia_fecha: string | null;
  precio_referencia_documento: string | null;
  variacion_precio_pct: number | null;
  alerta_precio: boolean;
  subtotal: number;
  tarifa_iva: number;
  producto_id: string | null;
  homologacion_origen: string | null;
};
type ResultadoCarga = {
  cargados: number;
  duplicados: number;
  listos: number;
  pendientes_homologacion: number;
};
type NuevoProductoHomologacion = {
  nombre: string;
  categoriaId: string;
  subcategoriaId: string;
  categoriaCodigo: string;
  entidadNombre: string;
  entidadCodigo: string;
  varianteNombre: string;
  varianteCodigo: string;
  anioCodigo: string;
  talla: string;
  tallaCodigo: string;
  color: string;
  tipoInventario: string;
  unidadMedida: string;
  costoEstandar: string;
  precio: string;
  stockMinimo: string;
  motivo: string;
};

const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const fecha = new Intl.DateTimeFormat("es-EC", { dateStyle: "medium" });
const porcentaje = new Intl.NumberFormat("es-EC", { minimumFractionDigits: 1, maximumFractionDigits: 2 });

function textoNormalizado(valor: string, singularizar = false) {
  const limpio = valor.trim().toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
  return singularizar ? limpio.replace(/s$/, "") : limpio;
}

function candidatosCodigo(valor: string) {
  const limpio = textoNormalizado(valor).toUpperCase().replace(/[^A-Z0-9 ]/g, "");
  const palabras = limpio.split(/\s+/).filter(Boolean);
  const continuo = palabras.join("");
  const iniciales = palabras.map((palabra) => palabra[0]).join("");
  const consonantes = continuo.slice(0, 1) + continuo.slice(1).replace(/[AEIOU]/g, "");
  return Array.from(new Set([iniciales, consonantes, continuo]
    .filter(Boolean).map((codigo) => codigo.slice(0, 3).padEnd(3, "X"))));
}

function fechaVisible(valor: string) {
  return fecha.format(new Date(`${valor}T12:00:00`));
}

export default function ImportarComprasXmlCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [archivos, setArchivos] = useState<ArchivoPreparado[]>([]);
  const [errores, setErrores] = useState<string[]>([]);
  const [origen, setOrigen] = useState<"archivos" | "carpeta">("archivos");
  const [productos, setProductos] = useState<Producto[]>([]);
  const [sustentos, setSustentos] = useState<Sustento[]>([]);
  const [categorias, setCategorias] = useState<CategoriaProducto[]>([]);
  const [subcategorias, setSubcategorias] = useState<SubcategoriaProducto[]>([]);
  const [unidades, setUnidades] = useState<UnidadMedida[]>([]);
  const [abreviaturas, setAbreviaturas] = useState<AbreviaturaSku[]>([]);
  const [importaciones, setImportaciones] = useState<Importacion[]>([]);
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [asignaciones, setAsignaciones] = useState<Record<string, string>>({});
  const [notas, setNotas] = useState<Record<string, string>>({});
  const [sustentoPorDocumento, setSustentoPorDocumento] = useState<Record<string, string>>({});
  const [abierto, setAbierto] = useState<string | null>(null);
  const [procesando, setProcesando] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [claveLote, setClaveLote] = useState(() => nuevaClaveIdempotencia());
  const [creandoProducto, setCreandoProducto] = useState<{ importacion: Importacion; linea: Linea } | null>(null);
  const [nuevoProducto, setNuevoProducto] = useState<NuevoProductoHomologacion | null>(null);

  const puedeGestionar = ["admin", "control", "gerencia"].includes(perfil.rol);

  async function consultarProductos() {
    const acumulado: Producto[] = [];
    let desde = 0;
    while (true) {
      const respuesta = await supabase.from("productos")
        .select("id,sku,nombre,talla,color,tipo_inventario").eq("activo", true).order("sku")
        .range(desde, desde + 999);
      if (respuesta.error) return { data: acumulado, error: respuesta.error };
      acumulado.push(...((respuesta.data ?? []) as Producto[]));
      if ((respuesta.data ?? []).length < 1000) return { data: acumulado, error: null };
      desde += 1000;
    }
  }

  async function cargarBandeja() {
    setCargando(true);
    const [p, s, i, c, sc, u, ab] = await Promise.all([
      consultarProductos(),
      supabase.from("sustentos_tributarios").select("codigo,nombre").eq("activo", true).order("codigo"),
      supabase.from("vista_compras_xml_pendientes_v65").select("*")
        .in("estado", ["pendiente_homologacion", "listo"])
        .order("created_at", { ascending: false }).limit(200),
      supabase.from("categorias_productos").select("id,nombre").eq("activo", true).order("nombre"),
      supabase.from("subcategorias_productos").select("id,categoria_id,nombre").eq("activo", true).order("nombre"),
      supabase.from("unidades_medida_produccion").select("codigo,nombre,simbolo").eq("activo", true).order("familia").order("nombre"),
      supabase.from("sku_abreviaturas_v67").select("tipo,nombre,nombre_normalizado,codigo").eq("activo", true).order("tipo").order("nombre"),
    ]);
    const baseError = p.error ?? s.error ?? i.error ?? c.error ?? sc.error ?? u.error ?? ab.error;
    if (baseError) {
      setError(`No se pudo abrir la bandeja. Verifica que v65, v66 y v67 estén instaladas: ${baseError.message}`);
      setCargando(false);
      return;
    }
    const documentos = (i.data ?? []) as Importacion[];
    let detalle: Linea[] = [];
    if (documentos.length) {
      const respuesta = await supabase.from("compras_xml_importacion_lineas")
        .select("id,importacion_id,numero_linea,codigo_proveedor,codigo_auxiliar,descripcion,cantidad,precio_unitario,precio_neto,precio_referencia_unitario,precio_referencia_neto,precio_referencia_fecha,precio_referencia_documento,variacion_precio_pct,alerta_precio,subtotal,tarifa_iva,producto_id,homologacion_origen")
        .in("importacion_id", documentos.map((item) => item.id))
        .order("numero_linea");
      if (respuesta.error) setError(respuesta.error.message);
      else detalle = (respuesta.data ?? []) as Linea[];
    }
    setProductos((p.data ?? []) as Producto[]);
    setSustentos((s.data ?? []) as Sustento[]);
    setCategorias((c.data ?? []) as CategoriaProducto[]);
    setSubcategorias((sc.data ?? []) as SubcategoriaProducto[]);
    setUnidades((u.data ?? []) as UnidadMedida[]);
    setAbreviaturas((ab.data ?? []) as AbreviaturaSku[]);
    setImportaciones(documentos);
    setLineas(detalle);
    setAsignaciones(Object.fromEntries(detalle.filter((l) => l.producto_id).map((l) => [l.id, l.producto_id!] )));
    setNotas((actual) => Object.fromEntries(documentos.map((item) => [
      item.id,
      actual[item.id] ?? `Homologación de factura ${item.numero_documento}`,
    ])));
    setSustentoPorDocumento((actual) => Object.fromEntries(documentos.map((item) => [
      item.id,
      actual[item.id] ?? "06",
    ])));
    setCargando(false);
  }

  useEffect(() => { cargarBandeja(); }, []);

  async function prepararSeleccion(lista: FileList | null, tipo: "archivos" | "carpeta") {
    if (!lista?.length) return;
    setProcesando(true);
    setError(null);
    setAviso(null);
    const seleccion = Array.from(lista).filter((archivo) => archivo.name.toLowerCase().endsWith(".xml"));
    if (!seleccion.length) {
      setError("La selección no contiene archivos XML.");
      setProcesando(false);
      return;
    }
    if (seleccion.length > 200) {
      setError("Cada lote admite hasta 200 archivos XML.");
      setProcesando(false);
      return;
    }
    const validos: ArchivoPreparado[] = [];
    const problemas: string[] = [];
    const claves = new Set<string>();
    for (const archivo of seleccion) {
      try {
        if (archivo.size > 5_000_000) throw new Error("supera 5 MB");
        const contenido = await archivo.text();
        const factura = parsearFacturaCompraSri(contenido);
        if (claves.has(factura.claveAcceso)) throw new Error("está repetido dentro de esta selección");
        claves.add(factura.claveAcceso);
        validos.push({
          nombre: archivo.name.slice(0, 255),
          ruta: archivo.webkitRelativePath || archivo.name,
          hash: await calcularHashXml(contenido),
          factura,
        });
      } catch (e) {
        problemas.push(`${archivo.webkitRelativePath || archivo.name}: ${e instanceof Error ? e.message : "XML inválido"}`);
      }
    }
    setOrigen(tipo);
    setArchivos(validos);
    setErrores(problemas);
    setClaveLote(nuevaClaveIdempotencia());
    setProcesando(false);
  }

  const resumenSeleccion = useMemo(() => ({
    documentos: archivos.length,
    lineas: archivos.reduce((suma, archivo) => suma + archivo.factura.lineas.length, 0),
    total: archivos.reduce((suma, archivo) => suma + archivo.factura.importeTotal, 0),
  }), [archivos]);

  async function cargarXml() {
    if (!archivos.length) return;
    if (!await confirmarDialogo(
      `Se cargarán ${archivos.length} XML con ${resumenSeleccion.lineas} líneas.\n\n` +
      "Quedarán pendientes de homologación y no afectarán inventario ni contabilidad. ¿Continuar?"
    )) return;
    setProcesando(true);
    setError(null);
    setAviso(null);
    const payload = archivos.map(({ nombre, hash, factura }) => ({
      archivo_nombre: nombre,
      archivo_hash: hash,
      numero_autorizacion: factura.numeroAutorizacion,
      fecha_autorizacion: factura.fechaAutorizacion,
      comprobante: {
        comprador_ruc: factura.compradorRuc,
        proveedor_ruc: factura.emisorRuc,
        proveedor_razon_social: factura.razonSocialEmisor,
        clave_acceso: factura.claveAcceso,
        establecimiento: factura.establecimiento,
        punto_emision: factura.puntoEmision,
        secuencial: factura.secuencial,
        fecha_emision: factura.fechaEmision,
        base_cero: factura.baseCero,
        base_gravada: factura.baseGravada,
        tarifa_gravada: factura.tarifaGravada,
        base_no_objeto: factura.baseNoObjeto,
        base_exenta: factura.baseExenta,
        monto_iva: factura.montoIva,
        monto_ice: factura.montoIce,
        propina: factura.propina,
        total: factura.importeTotal,
        forma_pago: factura.formaPago,
      },
      lineas: factura.lineas.map((linea) => ({
        numero_linea: linea.numeroLinea,
        codigo_proveedor: linea.codigoPrincipal,
        codigo_auxiliar: linea.codigoAuxiliar,
        descripcion: linea.descripcion,
        cantidad: linea.cantidad,
        precio_unitario: linea.precioUnitario,
        descuento: linea.descuento,
        subtotal: linea.totalSinImpuesto,
        tarifa_iva: linea.tarifaIva,
        valor_iva: linea.valorIva,
      })),
    }));
    const { data, error: rpcError } = await supabase.rpc("cargar_xml_compras_v65", {
      p_archivos: payload,
      p_origen: origen,
      p_idempotency_key: claveLote,
    });
    if (rpcError) setError(rpcError.message);
    else {
      const resultado = data as ResultadoCarga;
      setAviso(`${resultado.cargados} XML cargados; ${resultado.duplicados} duplicados omitidos y ${resultado.pendientes_homologacion} pendientes de homologar.`);
      setArchivos([]);
      setErrores([]);
      setClaveLote(nuevaClaveIdempotencia());
      await cargarBandeja();
    }
    setProcesando(false);
  }

  function lineasDocumento(id: string) {
    return lineas.filter((linea) => linea.importacion_id === id);
  }

  function codigosSugeridos(tipo: AbreviaturaSku["tipo"], nombre: string) {
    const clave = textoNormalizado(nombre, tipo === "categoria");
    const guardada = abreviaturas.find((item) =>
      item.tipo === tipo
      && textoNormalizado(item.nombre_normalizado, tipo === "categoria") === clave
    );
    if (guardada) return [guardada.codigo];
    const ocupados = new Set(abreviaturas.filter((item) => item.tipo === tipo).map((item) => item.codigo));
    return candidatosCodigo(nombre).filter((codigo) => !ocupados.has(codigo));
  }

  function abrirCreacionProducto(importacion: Importacion, linea: Linea) {
    const descripcion = textoNormalizado(linea.descripcion);
    const categoriaDetectada = categorias.find((categoria) =>
      descripcion.includes(textoNormalizado(categoria.nombre, true))
    );
    const entidadNombre = importacion.proveedor_razon_social;
    const varianteNombre = "General";
    const anioCodigo = String(new Date(`${importacion.fecha_emision}T12:00:00`).getFullYear()).slice(-2);
    setCreandoProducto({ importacion, linea });
    setNuevoProducto({
      nombre: linea.descripcion,
      categoriaId: categoriaDetectada?.id ?? "",
      subcategoriaId: "",
      categoriaCodigo: categoriaDetectada ? codigosSugeridos("categoria", categoriaDetectada.nombre)[0] ?? "" : "",
      entidadNombre,
      entidadCodigo: codigosSugeridos("entidad", entidadNombre)[0] ?? "",
      varianteNombre,
      varianteCodigo: codigosSugeridos("variante", varianteNombre)[0] ?? "GEN",
      anioCodigo,
      talla: "",
      tallaCodigo: "",
      color: "",
      tipoInventario: "materia_prima",
      unidadMedida: "unidad",
      costoEstandar: String(Number(linea.precio_neto).toFixed(4)),
      precio: "",
      stockMinimo: "0",
      motivo: `Alta autorizada desde factura ${importacion.numero_documento}`,
    });
  }

  function skuPropuesto(producto: NuevoProductoHomologacion | null) {
    if (!producto) return "";
    const cat = producto.categoriaCodigo.trim().toUpperCase();
    const ent = producto.entidadCodigo.trim().toUpperCase();
    if (cat === "CTR") return `CTR-${ent}-UN`;
    const partes = [cat, ent, producto.varianteCodigo.trim().toUpperCase(), producto.anioCodigo.trim()];
    if (producto.tallaCodigo.trim()) partes.push(producto.tallaCodigo.trim().toUpperCase());
    return partes.join("-");
  }

  function actualizarNuevoProducto(cambios: Partial<NuevoProductoHomologacion>) {
    setNuevoProducto((actual) => actual ? { ...actual, ...cambios } : actual);
  }

  function elegirCodigo(tipo: AbreviaturaSku["tipo"], codigo: string) {
    if (tipo === "categoria") actualizarNuevoProducto({ categoriaCodigo: codigo });
    if (tipo === "entidad") actualizarNuevoProducto({ entidadCodigo: codigo });
    if (tipo === "variante") actualizarNuevoProducto({ varianteCodigo: codigo });
  }

  const productoSimilar = useMemo(() => {
    if (!nuevoProducto) return null;
    const nombre = textoNormalizado(nuevoProducto.nombre);
    const talla = textoNormalizado(nuevoProducto.talla);
    const color = textoNormalizado(nuevoProducto.color);
    return productos.find((producto) =>
      textoNormalizado(producto.nombre) === nombre
      && textoNormalizado(producto.talla ?? "") === talla
      && textoNormalizado(producto.color ?? "") === color
    ) ?? null;
  }, [nuevoProducto, productos]);

  async function crearYHomologarProducto(evento: React.FormEvent) {
    evento.preventDefault();
    if (!creandoProducto || !nuevoProducto) return;
    const sku = skuPropuesto(nuevoProducto);
    if (!nuevoProducto.categoriaId) return setError("Selecciona una categoría para el producto.");
    if (!/^[A-Z0-9]{3}-[A-Z0-9]{3}-(?:UN|[A-Z0-9]{3}-[0-9]{2}(?:-[A-Z0-9]{1,8})?)$/.test(sku)) {
      return setError("Completa los segmentos del SKU: cada código principal debe tener exactamente tres caracteres.");
    }
    if (productoSimilar) return setError(`Ya existe un producto equivalente: ${productoSimilar.sku}. Reutilízalo en lugar de duplicarlo.`);
    if (productos.some((producto) => producto.sku.toUpperCase() === sku)) return setError(`El SKU ${sku} ya existe.`);
    if (nuevoProducto.motivo.trim().length < 10) return setError("Documenta la autorización o motivo con al menos 10 caracteres.");
    if (!await confirmarDialogo(
      `Se creará ${sku} con stock inicial cero y quedará homologado con el código del proveedor.\n\n¿Confirmas el alta?`
    )) return;

    setProcesando(true);
    setError(null);
    const { data, error: rpcError } = await supabase.rpc("crear_producto_desde_homologacion_v67", {
      p_importacion_id: creandoProducto.importacion.id,
      p_linea_id: creandoProducto.linea.id,
      p_producto: {
        sku,
        nombre: nuevoProducto.nombre.trim(),
        categoria_id: nuevoProducto.categoriaId,
        subcategoria_id: nuevoProducto.subcategoriaId || null,
        categoria_codigo: nuevoProducto.categoriaCodigo.trim().toUpperCase(),
        entidad_nombre: nuevoProducto.entidadNombre.trim(),
        entidad_codigo: nuevoProducto.entidadCodigo.trim().toUpperCase(),
        variante_nombre: nuevoProducto.varianteNombre.trim(),
        variante_codigo: nuevoProducto.varianteCodigo.trim().toUpperCase(),
        anio_codigo: nuevoProducto.anioCodigo.trim(),
        talla: nuevoProducto.talla.trim() || null,
        talla_codigo: nuevoProducto.tallaCodigo.trim().toUpperCase() || null,
        color: nuevoProducto.color.trim() || null,
        tipo_inventario: nuevoProducto.tipoInventario,
        unidad_medida: nuevoProducto.unidadMedida,
        costo_estandar: nuevoProducto.costoEstandar || null,
        precio: nuevoProducto.precio || null,
        stock_minimo: Number(nuevoProducto.stockMinimo) || 0,
      },
      p_motivo: nuevoProducto.motivo.trim(),
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    if (rpcError) setError(rpcError.message);
    else {
      const resultado = data as { sku?: string } | null;
      setAviso(`${resultado?.sku ?? sku} fue creado con stock cero y homologado automáticamente.`);
      const importacionId = creandoProducto.importacion.id;
      setCreandoProducto(null);
      setNuevoProducto(null);
      await cargarBandeja();
      setAbierto(importacionId);
    }
    setProcesando(false);
  }

  async function guardarHomologacion(importacion: Importacion) {
    const detalle = lineasDocumento(importacion.id);
    const items = detalle
      .filter((linea) => asignaciones[linea.id])
      .map((linea) => ({ linea_id: linea.id, producto_id: asignaciones[linea.id], recordar: true }));
    if (!items.length) return setError("Selecciona al menos un producto para guardar la homologación.");
    setProcesando(true);
    setError(null);
    const { error: rpcError } = await supabase.rpc("homologar_lineas_compra_xml_v65", {
      p_importacion_id: importacion.id,
      p_lineas: items,
      p_nota: notas[importacion.id] || `Homologación de ${importacion.numero_documento}`,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    if (rpcError) setError(rpcError.message);
    else {
      setAviso(`Homologación guardada para ${importacion.numero_documento}. Los códigos se recordarán para futuros XML del proveedor.`);
      await cargarBandeja();
    }
    setProcesando(false);
  }

  async function procesarDocumento(importacion: Importacion) {
    if (!await confirmarDialogo(
      `Se registrará la factura ${importacion.numero_documento} por ${dinero.format(importacion.total)}.\n\n` +
      "Este paso la incorpora al libro de compras. ¿Continuar?"
    )) return;
    setProcesando(true);
    setError(null);
    const { error: rpcError } = await supabase.rpc("procesar_compra_xml_v65", {
      p_importacion_id: importacion.id,
      p_sustento_codigo: sustentoPorDocumento[importacion.id] || "06",
      p_nota: notas[importacion.id] || `Registro de factura ${importacion.numero_documento}`,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    if (rpcError) setError(rpcError.message);
    else {
      setAviso(`Factura ${importacion.numero_documento} registrada correctamente en el libro de compras.`);
      setAbierto(null);
      await cargarBandeja();
    }
    setProcesando(false);
  }

  async function descartar(importacion: Importacion) {
    const motivo = await pedirMotivoDialogo(
      `La factura ${importacion.numero_documento} saldrá de la bandeja sin registrarse. Explica el motivo.`,
      10,
      "Motivo para descartar",
    );
    if (!motivo) return;
    setProcesando(true);
    const { error: rpcError } = await supabase.rpc("descartar_compra_xml_v65", {
      p_importacion_id: importacion.id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    if (rpcError) setError(rpcError.message);
    else {
      setAviso(`XML ${importacion.numero_documento} descartado.`);
      await cargarBandeja();
    }
    setProcesando(false);
  }

  return (
    <div className="compras-xml-page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">COMPRAS · XML SRI</span>
          <h1>Importar y homologar compras</h1>
          <p>Carga hasta 200 facturas a la vez desde archivos o una carpeta. Primero quedan en revisión; nada afecta stock automáticamente.</p>
        </div>
        <Link href="/compras" className="btn-enlace secondary">Volver a Compras</Link>
      </header>

      <Aviso error={error} aviso={aviso} onCerrar={(tipo) => tipo === "error" ? setError(null) : setAviso(null)} titulo="Compra XML actualizada" />

      <section className="card xml-carga-card">
        <div className="card-titulo-linea">
          <div><h2>1. Seleccionar XML</h2><p>Solo se aceptan facturas electrónicas autorizadas del SRI cuyo comprador sea un RUC configurado en el sistema.</p></div>
          <span className="badge estado-pendiente">Sin movimientos de inventario</span>
        </div>
        <div className="xml-selectores">
          <label className="xml-selector">
            <strong>Elegir varios XML</strong>
            <span>Puedes marcar uno o muchos archivos.</span>
            <input type="file" accept=".xml,text/xml,application/xml" multiple disabled={procesando || !puedeGestionar}
              onChange={(e) => { prepararSeleccion(e.target.files, "archivos"); e.target.value = ""; }} />
          </label>
          <label className="xml-selector">
            <strong>Elegir una carpeta</strong>
            <span>Se leerán todos los XML contenidos en ella.</span>
            <input type="file" accept=".xml,text/xml,application/xml" multiple disabled={procesando || !puedeGestionar}
              ref={(elemento) => { if (elemento) { elemento.setAttribute("webkitdirectory", ""); elemento.setAttribute("directory", ""); } }}
              onChange={(e) => { prepararSeleccion(e.target.files, "carpeta"); e.target.value = ""; }} />
          </label>
        </div>
        {!puedeGestionar && <div className="info-box">Tu rol puede consultar Compras, pero la carga contable está reservada a Administración, Control y Gerencia.</div>}
        {archivos.length > 0 && (
          <>
            <div className="kpis compactos">
              <div className="kpi"><div className="label">XML válidos</div><div className="valor">{resumenSeleccion.documentos}</div></div>
              <div className="kpi"><div className="label">Líneas</div><div className="valor">{resumenSeleccion.lineas}</div></div>
              <div className="kpi"><div className="label">Total</div><div className="valor">{dinero.format(resumenSeleccion.total)}</div></div>
              <div className={`kpi ${errores.length ? "alerta" : "ok"}`}><div className="label">Rechazados</div><div className="valor">{errores.length}</div></div>
            </div>
            <div className="tabla-scroll" style={{ maxHeight: 280 }}>
              <table><thead><tr><th>Archivo</th><th>Proveedor</th><th>Factura</th><th>Fecha</th><th className="num">Líneas</th><th className="num">Total</th></tr></thead>
                <tbody>{archivos.map((archivo) => <tr key={archivo.hash}><td><strong>{archivo.ruta}</strong></td><td>{archivo.factura.razonSocialEmisor}<div className="conteo">{archivo.factura.emisorRuc}</div></td><td>{archivo.factura.numeroDocumento}</td><td>{fechaVisible(archivo.factura.fechaEmision)}</td><td className="num">{archivo.factura.lineas.length}</td><td className="num">{dinero.format(archivo.factura.importeTotal)}</td></tr>)}</tbody>
              </table>
            </div>
            <div className="acciones import-acciones"><button type="button" disabled={procesando} onClick={cargarXml}>{procesando ? "Cargando…" : `Cargar ${archivos.length} XML a la bandeja`}</button><button type="button" className="secondary" disabled={procesando} onClick={() => { setArchivos([]); setErrores([]); }}>Limpiar selección</button></div>
          </>
        )}
        {errores.length > 0 && <div className="import-errores"><strong>Archivos no aceptados</strong>{errores.slice(0, 30).map((item) => <span key={item}>{item}</span>)}{errores.length > 30 && <span>Y {errores.length - 30} más.</span>}</div>}
      </section>

      <section className="card" style={{ marginTop: 16 }}>
        <div className="card-titulo-linea"><div><h2>2. Bandeja de homologación</h2><p>Relaciona cada código del proveedor con un SKU interno. La relación se reutiliza en sus próximas facturas.</p></div><button type="button" className="secondary" disabled={cargando || procesando} onClick={cargarBandeja}>Actualizar</button></div>
        {cargando ? <p>Cargando bandeja…</p> : importaciones.length === 0 ? <div className="vacio">No hay XML pendientes de homologación o registro.</div> : (
          <div className="xml-documentos">
            {importaciones.map((item) => {
              const detalle = lineasDocumento(item.id);
              const alertasPrecio = detalle.filter((linea) => linea.alerta_precio).length;
              const estaAbierto = abierto === item.id;
              return <article className={`xml-documento ${item.estado === "listo" ? "listo" : ""}`} key={item.id}>
                <button type="button" className="xml-documento-resumen" onClick={() => setAbierto(estaAbierto ? null : item.id)}>
                  <span><strong>{item.numero_documento}</strong><small>{item.empresa_codigo} · {fechaVisible(item.fecha_emision)} · {item.archivo_nombre}</small></span>
                  <span><strong>{item.proveedor_razon_social}</strong><small>{item.proveedor_ruc}{!item.proveedor_id ? " · proveedor no registrado" : ""}</small></span>
                  <span className="num"><strong>{dinero.format(item.total)}</strong><small>{item.lineas_homologadas}/{item.lineas_total} homologadas</small></span>
                  <div className="xml-estados-documento"><span className={`badge ${item.estado === "listo" ? "estado-aprobado" : "estado-pendiente"}`}>{item.estado === "listo" ? "Listo para registrar" : `${item.lineas_pendientes} pendientes`}</span>{alertasPrecio > 0 && <span className="badge alerta-precio-badge">{alertasPrecio} cambio(s) de precio</span>}</div>
                </button>
                {estaAbierto && <div className="xml-documento-detalle">
                  {!item.proveedor_id && <div className="error-box">El proveedor con RUC {item.proveedor_ruc} todavía no existe o está inactivo. <Link href="/compras">Créalo en Compras → Proveedores</Link> y luego guarda la homologación para actualizarlo.</div>}
                  {alertasPrecio > 0 && <div className="alerta-precio-resumen"><strong>Revisa los precios antes de registrar.</strong> Se comparan con la última factura procesada del mismo proveedor y código. La alerta no cambia costos ni inventario automáticamente.</div>}
                  <div className="tabla-scroll"><table><thead><tr><th>Línea</th><th>Código proveedor</th><th>Descripción XML</th><th className="num">Cant.</th><th className="num">Precio</th><th className="num">Subtotal</th><th>Producto interno</th></tr></thead>
                    <tbody>{detalle.map((linea) => {
                      const variacion = Number(linea.variacion_precio_pct ?? 0);
                      return <tr key={linea.id} className={`${!asignaciones[linea.id] ? "fila-alerta " : ""}${linea.alerta_precio ? "fila-alerta-precio" : ""}`}>
                        <td>{linea.numero_linea}</td>
                        <td><strong>{linea.codigo_proveedor || linea.codigo_auxiliar || "Sin código"}</strong></td>
                        <td>{linea.descripcion}<div className="conteo">IVA {linea.tarifa_iva}%</div></td>
                        <td className="num">{linea.cantidad}</td>
                        <td className="num"><strong>{dinero.format(Number(linea.precio_unitario))}</strong><div className="conteo">Neto {dinero.format(Number(linea.precio_neto))}</div>{linea.alerta_precio && <div className={`alerta-precio-detalle ${variacion > 0 ? "sube" : variacion < 0 ? "baja" : "cambia"}`}><strong>{variacion > 0 ? "↑" : variacion < 0 ? "↓" : "↔"} {porcentaje.format(Math.abs(variacion))}%</strong><span>Anterior neto: {dinero.format(Number(linea.precio_referencia_neto ?? linea.precio_referencia_unitario ?? 0))}</span><small>{linea.precio_referencia_documento ? `Factura ${linea.precio_referencia_documento}` : "Referencia anterior"}{linea.precio_referencia_fecha ? ` · ${fechaVisible(linea.precio_referencia_fecha)}` : ""}</small></div>}</td>
                        <td className="num">{dinero.format(linea.subtotal)}</td>
                        <td className="producto-homologacion-celda">
                          <select value={asignaciones[linea.id] ?? ""} onChange={(e) => setAsignaciones((actual) => ({ ...actual, [linea.id]: e.target.value }))}>
                            <option value="">Pendiente de homologar…</option>
                            {productos.map((producto) => <option value={producto.id} key={producto.id}>{producto.sku} · {producto.nombre}{producto.talla ? ` · ${producto.talla}` : ""}{producto.tipo_inventario ? ` · ${producto.tipo_inventario.replaceAll("_", " ")}` : ""}</option>)}
                          </select>
                          {linea.homologacion_origen === "guardada" && <div className="conteo">Homologado automáticamente por proveedor y código</div>}
                          {perfil.rol === "admin" && !asignaciones[linea.id] && (
                            <button type="button" className="btn-crear-producto-homologacion"
                              disabled={procesando || !(linea.codigo_proveedor || linea.codigo_auxiliar)}
                              onClick={() => abrirCreacionProducto(item, linea)}>
                              + Crear producto y homologar
                            </button>
                          )}
                          {perfil.rol === "admin" && !asignaciones[linea.id] && !(linea.codigo_proveedor || linea.codigo_auxiliar) && <div className="conteo">El XML necesita un código de proveedor para recordar la homologación.</div>}
                        </td>
                      </tr>;
                    })}</tbody>
                  </table></div>
                  <div className="grid-2" style={{ marginTop: 12 }}><div className="field"><label>Nota de homologación</label><input value={notas[item.id] ?? ""} onChange={(e) => setNotas((actual) => ({ ...actual, [item.id]: e.target.value }))} /></div><div className="field"><label>Sustento tributario</label><select value={sustentoPorDocumento[item.id] ?? "06"} onChange={(e) => setSustentoPorDocumento((actual) => ({ ...actual, [item.id]: e.target.value }))}>{sustentos.map((sustento) => <option key={sustento.codigo} value={sustento.codigo}>{sustento.codigo} · {sustento.nombre}</option>)}</select></div></div>
                  <div className="acciones import-acciones"><button type="button" disabled={procesando} onClick={() => guardarHomologacion(item)}>Guardar homologación</button>{item.estado === "listo" && <button type="button" disabled={procesando} onClick={() => procesarDocumento(item)}>Registrar comprobante</button>}<button type="button" className="peligro" disabled={procesando || perfil.rol === "gerencia"} onClick={() => descartar(item)}>Descartar</button></div>
                </div>}
              </article>;
            })}
          </div>
        )}
      </section>

      {creandoProducto && nuevoProducto && (
        <div className="modal-operativo" role="presentation" onMouseDown={(e) => {
          if (e.target === e.currentTarget && !procesando) { setCreandoProducto(null); setNuevoProducto(null); }
        }}>
          <form className="modal-contenido ancho modal-sku" onSubmit={crearYHomologarProducto}>
            <div className="card-titulo-linea">
              <div>
                <h2>Crear producto desde la homologación</h2>
                <p>{creandoProducto.importacion.proveedor_razon_social} · código {creandoProducto.linea.codigo_proveedor || creandoProducto.linea.codigo_auxiliar}</p>
              </div>
              <button type="button" className="secondary" disabled={procesando} onClick={() => { setCreandoProducto(null); setNuevoProducto(null); }}>Cerrar</button>
            </div>

            <div className="sku-regla">
              <strong>Regla interna:</strong> CAT-ENTIDAD-VAR-AÑO y talla solo cuando identifica una variante de inventario. Las abreviaturas existentes se reutilizan; el sistema bloquea códigos y productos duplicados.
              <span>El alta queda en inventario con stock cero. La creación equivalente en CONFIABLE debe mantenerse sincronizada según el procedimiento administrativo.</span>
            </div>

            <div className="field">
              <label>Descripción recibida en el XML</label>
              <input value={creandoProducto.linea.descripcion} disabled />
            </div>
            <div className="field">
              <label>Nombre interno del producto</label>
              <input required maxLength={180} value={nuevoProducto.nombre} onChange={(e) => actualizarNuevoProducto({ nombre: e.target.value })} />
            </div>

            <div className="sku-form-grid">
              <div className="field">
                <label>Categoría</label>
                <select required value={nuevoProducto.categoriaId} onChange={(e) => {
                  const categoria = categorias.find((item) => item.id === e.target.value);
                  actualizarNuevoProducto({
                    categoriaId: e.target.value,
                    subcategoriaId: "",
                    categoriaCodigo: categoria ? codigosSugeridos("categoria", categoria.nombre)[0] ?? "" : "",
                  });
                }}>
                  <option value="">Selecciona…</option>
                  {categorias.map((item) => <option key={item.id} value={item.id}>{item.nombre}</option>)}
                </select>
              </div>
              <div className="field">
                <label>Subcategoría (opcional)</label>
                <select value={nuevoProducto.subcategoriaId} onChange={(e) => actualizarNuevoProducto({ subcategoriaId: e.target.value })}>
                  <option value="">Sin subcategoría</option>
                  {subcategorias.filter((item) => item.categoria_id === nuevoProducto.categoriaId).map((item) => <option key={item.id} value={item.id}>{item.nombre}</option>)}
                </select>
              </div>
              <div className="field segmento-sku">
                <label>Código CAT (3 caracteres)</label>
                <input required maxLength={3} pattern="[A-Za-z0-9]{3}" value={nuevoProducto.categoriaCodigo}
                  onChange={(e) => actualizarNuevoProducto({ categoriaCodigo: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "") })} />
                <div className="sku-sugerencias">{codigosSugeridos("categoria", categorias.find((item) => item.id === nuevoProducto.categoriaId)?.nombre ?? "").map((codigo) => <button type="button" key={codigo} onClick={() => elegirCodigo("categoria", codigo)}>{codigo}</button>)}</div>
              </div>

              <div className="field">
                <label>Entidad / marca / proveedor</label>
                <input required maxLength={120} value={nuevoProducto.entidadNombre} onChange={(e) => actualizarNuevoProducto({ entidadNombre: e.target.value })} />
              </div>
              <div className="field segmento-sku">
                <label>Código ENTIDAD (3 caracteres)</label>
                <input required maxLength={3} pattern="[A-Za-z0-9]{3}" value={nuevoProducto.entidadCodigo}
                  onChange={(e) => actualizarNuevoProducto({ entidadCodigo: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "") })} />
                <div className="sku-sugerencias">{codigosSugeridos("entidad", nuevoProducto.entidadNombre).map((codigo) => <button type="button" key={codigo} onClick={() => elegirCodigo("entidad", codigo)}>{codigo}</button>)}</div>
              </div>

              {nuevoProducto.categoriaCodigo !== "CTR" && <>
                <div className="field">
                  <label>Variante</label>
                  <input required maxLength={120} value={nuevoProducto.varianteNombre} onChange={(e) => actualizarNuevoProducto({ varianteNombre: e.target.value })} />
                </div>
                <div className="field segmento-sku">
                  <label>Código VAR (3 caracteres)</label>
                  <input required maxLength={3} pattern="[A-Za-z0-9]{3}" value={nuevoProducto.varianteCodigo}
                    onChange={(e) => actualizarNuevoProducto({ varianteCodigo: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "") })} />
                  <div className="sku-sugerencias">{codigosSugeridos("variante", nuevoProducto.varianteNombre).map((codigo) => <button type="button" key={codigo} onClick={() => elegirCodigo("variante", codigo)}>{codigo}</button>)}</div>
                </div>
                <div className="field">
                  <label>Año (2 dígitos)</label>
                  <input required inputMode="numeric" maxLength={2} pattern="[0-9]{2}" value={nuevoProducto.anioCodigo}
                    onChange={(e) => actualizarNuevoProducto({ anioCodigo: e.target.value.replace(/\D/g, "") })} />
                </div>
              </>}

              <div className="field">
                <label>Talla descriptiva (opcional)</label>
                <input maxLength={40} value={nuevoProducto.talla} onChange={(e) => actualizarNuevoProducto({ talla: e.target.value })} placeholder="Ej. L" />
              </div>
              <div className="field">
                <label>Talla en SKU (opcional)</label>
                <input maxLength={8} pattern="[A-Za-z0-9]{0,8}" value={nuevoProducto.tallaCodigo}
                  onChange={(e) => actualizarNuevoProducto({ tallaCodigo: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "") })} placeholder="Ej. L, 32 o T4" />
              </div>
              <div className="field">
                <label>Color (opcional)</label>
                <input maxLength={60} value={nuevoProducto.color} onChange={(e) => actualizarNuevoProducto({ color: e.target.value })} />
              </div>
              <div className="field">
                <label>Tipo de inventario</label>
                <select value={nuevoProducto.tipoInventario} onChange={(e) => actualizarNuevoProducto({ tipoInventario: e.target.value })}>
                  <option value="materia_prima">Materia prima</option><option value="insumo">Insumo</option><option value="empaque">Empaque</option><option value="subproducto">Subproducto</option><option value="producto_terminado">Producto terminado</option>
                </select>
              </div>
              <div className="field">
                <label>Unidad de medida</label>
                <select required value={nuevoProducto.unidadMedida} onChange={(e) => actualizarNuevoProducto({ unidadMedida: e.target.value })}>
                  {unidades.map((item) => <option key={item.codigo} value={item.codigo}>{item.nombre} ({item.simbolo})</option>)}
                </select>
              </div>
              <div className="field"><label>Costo estándar</label><input type="number" min="0" step="0.0001" value={nuevoProducto.costoEstandar} onChange={(e) => actualizarNuevoProducto({ costoEstandar: e.target.value })} /></div>
              <div className="field"><label>Precio de venta (opcional)</label><input type="number" min="0" step="0.01" value={nuevoProducto.precio} onChange={(e) => actualizarNuevoProducto({ precio: e.target.value })} /></div>
              <div className="field"><label>Stock mínimo</label><input required type="number" min="0" step="1" value={nuevoProducto.stockMinimo} onChange={(e) => actualizarNuevoProducto({ stockMinimo: e.target.value })} /></div>
            </div>

            <div className="sku-preview"><span>SKU propuesto</span><strong>{skuPropuesto(nuevoProducto) || "Completa los segmentos"}</strong></div>
            {productoSimilar && <div className="error-box producto-similar"><span>Ya existe un producto equivalente: <strong>{productoSimilar.sku} · {productoSimilar.nombre}</strong>.</span><button type="button" className="secondary" onClick={() => {
              setAsignaciones((actual) => ({ ...actual, [creandoProducto.linea.id]: productoSimilar.id }));
              setCreandoProducto(null); setNuevoProducto(null);
              setAviso("Se seleccionó el producto existente. Pulsa Guardar homologación para recordar la relación con el proveedor.");
            }}>Usar el existente</button></div>}

            <div className="field">
              <label>Autorización / motivo del alta</label>
              <textarea required minLength={10} rows={3} value={nuevoProducto.motivo} onChange={(e) => actualizarNuevoProducto({ motivo: e.target.value })} />
            </div>
            <div className="acciones import-acciones">
              <button type="submit" disabled={procesando || Boolean(productoSimilar)}>{procesando ? "Creando…" : "Crear con stock cero y homologar"}</button>
              <button type="button" className="secondary" disabled={procesando} onClick={() => { setCreandoProducto(null); setNuevoProducto(null); }}>Cancelar</button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
}
