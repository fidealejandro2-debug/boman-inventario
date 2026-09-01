"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";
import { fecha } from "@/lib/utils";
import { calcularHashXml, parsearFacturaSri, type FacturaSri, type LineaFacturaSri } from "@/lib/xmlFacturaSri";

type Almacen = { id: string; nombre: string; tipo: string };
type Producto = { id: string; sku: string; nombre: string; talla: string | null; color: string | null };
type CodigoAprendido = { emisor_ruc: string; codigo_externo: string; producto_id: string; usos: number };
type Establecimiento = {
  emisor_ruc: string;
  establecimiento: string;
  punto_emision: string;
  almacen_id: string;
  empresa_establecimiento_id: string | null;
  empresa_punto_emision_id: string | null;
  empresa_equivalencia_id: string | null;
};
type EquivalenciaFacturacion = {
  id: string;
  emisor_ruc: string;
  establecimiento_xml: string;
  punto_emision_xml: string;
  establecimiento_oficial: string;
  establecimiento_nombre: string;
  punto_emision_oficial: string;
  almacen_id: string | null;
  almacen: string | null;
  motivo: string;
};
type Asignacion = { productoId: string; cantidad: string };
type EstadoLinea = { afectaInventario: boolean; asignaciones: Asignacion[] };
type DocumentoVenta = {
  id: string;
  numero_documento: string;
  razon_social_emisor: string;
  fecha_emision: string;
  importe_total: number;
  unidades_inventario: number;
  created_at: string;
  anulado: boolean;
  anulacion_stock_estado: "sin_anulacion" | "sin_retorno" | "devuelto_parcial" | "devuelto_total" | "reversion_tecnica" | "reversion_tecnica_legacy";
  ultima_devolucion_at: string | null;
  motivo_anulacion: string | null;
  anulado_at: string | null;
  almacen: { nombre: string } | null;
  creador: { nombre_completo: string } | null;
  anulador: { nombre_completo: string } | null;
};
type SaldoDevolucion = {
  producto_id: string;
  sku: string;
  producto: string;
  vendido: number;
  devuelto: number;
  pendiente: number;
};
type ItemDevolucion = { cantidad: string; destinoEstado: "disponible" | "cuarentena" };

const normalizar = (valor: string | null | undefined) => (valor ?? "")
  .trim().toLocaleLowerCase("es").normalize("NFD").replace(/[\u0300-\u036f]/g, "");
const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });

export default function VentasXmlCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const puedeImportar = ["admin", "control", "tienda", "bodega"].includes(perfil.rol);
  const rolGlobal = ["admin", "control", "gerencia"].includes(perfil.rol);
  const [tab, setTab] = useState<"importar" | "historial">(puedeImportar ? "importar" : "historial");
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [permitidos, setPermitidos] = useState<string[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [codigos, setCodigos] = useState<CodigoAprendido[]>([]);
  const [establecimientos, setEstablecimientos] = useState<Establecimiento[]>([]);
  const [equivalencias, setEquivalencias] = useState<EquivalenciaFacturacion[]>([]);
  const [emisores, setEmisores] = useState<string[]>([]);
  const [historial, setHistorial] = useState<DocumentoVenta[]>([]);
  const [devolviendo, setDevolviendo] = useState<DocumentoVenta | null>(null);
  const [saldoDevolucion, setSaldoDevolucion] = useState<SaldoDevolucion[]>([]);
  const [itemsDevolucion, setItemsDevolucion] = useState<Record<string, ItemDevolucion>>({});
  const [motivoDevolucion, setMotivoDevolucion] = useState("");
  const [factura, setFactura] = useState<FacturaSri | null>(null);
  const [archivoNombre, setArchivoNombre] = useState("");
  const [archivoHash, setArchivoHash] = useState("");
  const [almacenId, setAlmacenId] = useState(perfil.entidad_id ?? "");
  const [lineas, setLineas] = useState<Record<number, EstadoLinea>>({});
  const [busquedas, setBusquedas] = useState<Record<number, string>>({});
  const [selectorLinea, setSelectorLinea] = useState<number | null>(null);
  const [seleccionCatalogo, setSeleccionCatalogo] = useState<Set<string>>(new Set());
  const [busquedaCatalogo, setBusquedaCatalogo] = useState("");
  const [stock, setStock] = useState<Record<string, number>>({});
  const [nota, setNota] = useState("");
  const [codigoConfirmado, setCodigoConfirmado] = useState(false);
  const [codigoNota, setCodigoNota] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  async function cargarDatos() {
    setCargando(true);
    const [a, pa, p, c, e, eq, em, h] = await Promise.all([
      supabase.from("almacenes").select("id, nombre, tipo").eq("activo", true).order("nombre"),
      supabase.from("perfil_almacenes").select("almacen_id").eq("perfil_id", perfil.id),
      supabase.from("productos").select("id, sku, nombre, talla, color").eq("activo", true).order("nombre"),
      supabase.from("producto_codigos_facturacion").select("emisor_ruc, codigo_externo, producto_id, usos"),
      supabase.from("establecimiento_almacen_facturacion").select("emisor_ruc, establecimiento, punto_emision, almacen_id, empresa_establecimiento_id, empresa_punto_emision_id, empresa_equivalencia_id"),
      supabase.from("vista_equivalencias_facturacion").select("id,emisor_ruc,establecimiento_xml,punto_emision_xml,establecimiento_oficial,establecimiento_nombre,punto_emision_oficial,almacen_id,almacen,motivo").eq("activo", true),
      supabase.from("emisores_facturacion").select("ruc").eq("activo", true),
      supabase.from("documentos_venta_xml").select(`
        id, numero_documento, razon_social_emisor, fecha_emision, importe_total,
        unidades_inventario, created_at, anulado, motivo_anulacion, anulado_at,
        anulacion_stock_estado, ultima_devolucion_at,
        almacen:almacenes!documentos_venta_xml_almacen_id_fkey(nombre),
        creador:perfiles!documentos_venta_xml_creado_por_fkey(nombre_completo),
        anulador:perfiles!documentos_venta_xml_anulado_por_fkey(nombre_completo)
      `).order("created_at", { ascending: false }).limit(150),
    ]);
    const error = a.error ?? pa.error ?? p.error ?? c.error ?? e.error ?? eq.error ?? em.error ?? h.error;
    if (error) setMsg({ tipo: "error", texto: `No se pudo cargar Ventas XML. Verifica que las migraciones v13-v20 estén instaladas: ${error.message}` });
    setAlmacenes((a.data ?? []) as Almacen[]);
    setPermitidos((pa.data ?? []).map((fila: any) => fila.almacen_id));
    setProductos((p.data ?? []) as Producto[]);
    setCodigos((c.data ?? []) as CodigoAprendido[]);
    setEstablecimientos((e.data ?? []) as Establecimiento[]);
    setEquivalencias((eq.data ?? []) as EquivalenciaFacturacion[]);
    setEmisores((em.data ?? []).map((fila: any) => fila.ruc));
    setHistorial((h.data ?? []) as any as DocumentoVenta[]);
    if (!almacenId && (pa.data ?? []).length) setAlmacenId((pa.data as any[])[0].almacen_id);
    setCargando(false);
  }

  useEffect(() => { cargarDatos(); }, []);

  const almacenesDisponibles = useMemo(
    () => rolGlobal ? almacenes : almacenes.filter((a) => permitidos.includes(a.id) || a.id === perfil.entidad_id),
    [almacenes, permitidos, perfil.entidad_id, rolGlobal]
  );

  useEffect(() => {
    if (!almacenId) { setStock({}); return; }
    supabase.from("inventario").select("producto_id, cantidad").eq("entidad_id", almacenId).then(({ data }) => {
      setStock(Object.fromEntries((data ?? []).map((fila: any) => [fila.producto_id, Number(fila.cantidad)])));
    });
  }, [almacenId]);

  function estadoInicial(nueva: FacturaSri) {
    const estados: Record<number, EstadoLinea> = {};
    nueva.lineas.forEach((linea) => {
      const codigosLinea = [linea.codigoPrincipal, linea.codigoAuxiliar]
        .filter((codigo): codigo is string => Boolean(codigo) && codigo!.toUpperCase() !== "N/A");
      const skuExactos = productos.filter((producto) => codigosLinea.some((codigo) => normalizar(codigo) === normalizar(producto.sku)));
      const aprendidos = codigos
        .filter((codigo) => codigo.emisor_ruc === nueva.emisorRuc && codigosLinea.some((valor) => normalizar(valor) === normalizar(codigo.codigo_externo)))
        .map((codigo) => codigo.producto_id);
      const candidatos = Array.from(new Set([...skuExactos.map((p) => p.id), ...aprendidos]));
      const entero = Number.isInteger(linea.cantidad);
      estados[linea.numeroLinea] = {
        afectaInventario: entero,
        asignaciones: candidatos.length === 1 && entero
          ? [{ productoId: candidatos[0], cantidad: String(linea.cantidad) }]
          : [],
      };
    });
    return estados;
  }

  async function leerArchivo(evento: React.ChangeEvent<HTMLInputElement>) {
    const archivo = evento.target.files?.[0];
    evento.target.value = "";
    if (!archivo) return;
    setMsg(null);
    setProcesando(true);
    try {
      if (!archivo.name.toLowerCase().endsWith(".xml")) throw new Error("Selecciona un archivo con extensión .xml.");
      const contenido = await archivo.text();
      const nueva = parsearFacturaSri(contenido);
      const hash = await calcularHashXml(contenido);
      const { data: repetida, error } = await supabase
        .from("documentos_venta_xml").select("id, numero_documento").eq("clave_acceso", nueva.claveAcceso).maybeSingle();
      if (error) throw error;
      if (repetida) throw new Error(`La factura ${repetida.numero_documento} ya fue aplicada. No se descontó inventario nuevamente.`);

      const mapeo = establecimientos.find((item) =>
        item.emisor_ruc === nueva.emisorRuc && item.establecimiento === nueva.establecimiento && item.punto_emision === nueva.puntoEmision
      );
      const equivalencia = equivalencias.find((item) =>
        item.emisor_ruc === nueva.emisorRuc
        && item.establecimiento_xml === nueva.establecimiento
        && item.punto_emision_xml === nueva.puntoEmision
      );
      if (mapeo) setAlmacenId(mapeo.almacen_id);
      else if (almacenesDisponibles.length === 1) setAlmacenId(almacenesDisponibles[0].id);
      setFactura(nueva);
      setArchivoNombre(archivo.name.slice(0, 255));
      setArchivoHash(hash);
      setLineas(estadoInicial(nueva));
      setBusquedas({});
      setNota("");
      setCodigoConfirmado(false);
      setCodigoNota(equivalencia?.motivo ?? "");
    } catch (error: any) {
      setFactura(null);
      setMsg({ tipo: "error", texto: error.message || "No se pudo leer el XML." });
    } finally {
      setProcesando(false);
    }
  }

  function agregarProducto(numeroLinea: number, productoId: string) {
    const estado = lineas[numeroLinea];
    const linea = factura?.lineas.find((item) => item.numeroLinea === numeroLinea);
    if (!estado || !linea || estado.asignaciones.some((a) => a.productoId === productoId)) return;
    const asignado = estado.asignaciones.reduce((suma, a) => suma + Number(a.cantidad || 0), 0);
    const restante = Math.max(linea.cantidad - asignado, 0);
    setLineas({
      ...lineas,
      [numeroLinea]: { ...estado, asignaciones: [...estado.asignaciones, { productoId, cantidad: String(restante || 1) }] },
    });
    setBusquedas({ ...busquedas, [numeroLinea]: "" });
  }

  function actualizarCantidad(numeroLinea: number, productoId: string, cantidad: string) {
    const estado = lineas[numeroLinea];
    setLineas({
      ...lineas,
      [numeroLinea]: {
        ...estado,
        asignaciones: estado.asignaciones.map((a) => a.productoId === productoId ? { ...a, cantidad } : a),
      },
    });
  }

  function quitarProducto(numeroLinea: number, productoId: string) {
    const estado = lineas[numeroLinea];
    setLineas({ ...lineas, [numeroLinea]: { ...estado, asignaciones: estado.asignaciones.filter((a) => a.productoId !== productoId) } });
  }

  function cambiarAfectacion(numeroLinea: number, afectaInventario: boolean) {
    const estado = lineas[numeroLinea];
    setLineas({ ...lineas, [numeroLinea]: { afectaInventario, asignaciones: afectaInventario ? estado.asignaciones : [] } });
  }

  function abrirSelectorCatalogo(linea: LineaFacturaSri) {
    setSelectorLinea(linea.numeroLinea);
    setSeleccionCatalogo(new Set(lineas[linea.numeroLinea]?.asignaciones.map((a) => a.productoId) ?? []));
    setBusquedaCatalogo(linea.descripcion);
  }

  function alternarProductoCatalogo(productoId: string, seleccionado: boolean) {
    const siguiente = new Set(seleccionCatalogo);
    seleccionado ? siguiente.add(productoId) : siguiente.delete(productoId);
    setSeleccionCatalogo(siguiente);
  }

  function guardarSeleccionCatalogo(repartir: boolean) {
    if (selectorLinea == null || !factura) return;
    const lineaXml = factura.lineas.find((linea) => linea.numeroLinea === selectorLinea);
    if (!lineaXml) return;
    const ids = Array.from(seleccionCatalogo);
    if (!ids.length) {
      setMsg({ tipo: "error", texto: `Selecciona al menos un producto para la línea ${selectorLinea}.` });
      return;
    }
    if (!Number.isInteger(lineaXml.cantidad) || ids.length > lineaXml.cantidad) {
      setMsg({ tipo: "error", texto: `No se pueden distribuir ${lineaXml.cantidad} unidades entre ${ids.length} productos con cantidades enteras positivas.` });
      return;
    }

    const anteriores = new Map((lineas[selectorLinea]?.asignaciones ?? []).map((a) => [a.productoId, a.cantidad]));
    const base = Math.floor(lineaXml.cantidad / ids.length);
    const residuo = lineaXml.cantidad % ids.length;
    const asignaciones = ids.map((productoId, indice) => ({
      productoId,
      cantidad: repartir
        ? String(base + (indice < residuo ? 1 : 0))
        : (anteriores.get(productoId) ?? (ids.length === 1 ? String(lineaXml.cantidad) : "1")),
    }));
    setLineas({ ...lineas, [selectorLinea]: { afectaInventario: true, asignaciones } });
    setSelectorLinea(null);
    setSeleccionCatalogo(new Set());
    setBusquedaCatalogo("");
    setMsg(repartir ? { tipo: "ok", texto: "Reparto provisional creado. Revisa las cantidades por talla o color antes de aplicar." } : null);
  }

  function repartirLineaPorIgual(numeroLinea: number) {
    if (!factura) return;
    const lineaXml = factura.lineas.find((linea) => linea.numeroLinea === numeroLinea);
    const estado = lineas[numeroLinea];
    if (!lineaXml || !estado?.asignaciones.length) return;
    if (!Number.isInteger(lineaXml.cantidad) || estado.asignaciones.length > lineaXml.cantidad) {
      setMsg({ tipo: "error", texto: "No es posible repartir esa cantidad en enteros positivos." });
      return;
    }
    const base = Math.floor(lineaXml.cantidad / estado.asignaciones.length);
    const residuo = lineaXml.cantidad % estado.asignaciones.length;
    setLineas({
      ...lineas,
      [numeroLinea]: {
        ...estado,
        asignaciones: estado.asignaciones.map((a, indice) => ({ ...a, cantidad: String(base + (indice < residuo ? 1 : 0)) })),
      },
    });
    setMsg({ tipo: "ok", texto: "Reparto provisional actualizado. Confirma las cantidades reales antes de aplicar." });
  }

  const totalesProducto = useMemo(() => {
    const totales: Record<string, number> = {};
    Object.values(lineas).forEach((linea) => linea.asignaciones.forEach((a) => {
      totales[a.productoId] = (totales[a.productoId] ?? 0) + Number(a.cantidad || 0);
    }));
    return totales;
  }, [lineas]);

  const validacionCodigo = useMemo(() => {
    if (!factura) return null;
    const equivalencia = equivalencias.find((item) =>
      item.emisor_ruc === factura.emisorRuc
      && item.establecimiento_xml === factura.establecimiento
      && item.punto_emision_xml === factura.puntoEmision
    );
    if (equivalencia) return { tipo: "equivalencia" as const, equivalencia };
    const mapeo = establecimientos.find((item) =>
      item.emisor_ruc === factura.emisorRuc
      && item.establecimiento === factura.establecimiento
      && item.punto_emision === factura.puntoEmision
    );
    if (mapeo?.empresa_establecimiento_id && mapeo.empresa_punto_emision_id) {
      return { tipo: "oficial" as const, mapeo };
    }
    return { tipo: "pendiente" as const, mapeo };
  }, [equivalencias, establecimientos, factura]);

  const errores = useMemo(() => {
    if (!factura) return [];
    const lista: string[] = [];
    if (!almacenId) lista.push("Selecciona el almacén que realizó la venta.");
    if (emisores.length > 0 && !emisores.includes(factura.emisorRuc)) lista.push("El RUC emisor no está habilitado en el sistema.");
    if (emisores.length === 0 && !["admin", "control"].includes(perfil.rol)) lista.push("Administración o Control deben confirmar el primer RUC emisor.");
    if (validacionCodigo?.tipo !== "oficial" && !codigoConfirmado) {
      lista.push("Confirma la validación de la numeración del establecimiento y punto de emisión.");
    }
    if (validacionCodigo?.tipo === "pendiente" && !codigoNota.trim()) {
      lista.push("Describe por qué la numeración del XML no coincide con la estructura legal.");
    }
    if (validacionCodigo?.tipo === "equivalencia"
        && validacionCodigo.equivalencia.almacen_id
        && validacionCodigo.equivalencia.almacen_id !== almacenId) {
      lista.push(`La equivalencia validada corresponde al almacén ${validacionCodigo.equivalencia.almacen ?? "configurado"}.`);
    }
    factura.lineas.forEach((linea) => {
      const estado = lineas[linea.numeroLinea];
      if (!estado?.afectaInventario) return;
      if (!Number.isInteger(linea.cantidad)) lista.push(`La línea ${linea.numeroLinea} tiene cantidad decimal; márcala como servicio/no inventariable.`);
      const total = estado.asignaciones.reduce((suma, a) => suma + Number(a.cantidad || 0), 0);
      if (total !== linea.cantidad) lista.push(`Distribuye exactamente ${linea.cantidad} unidades en la línea ${linea.numeroLinea}; ahora hay ${total || 0}.`);
      if (estado.asignaciones.some((a) => !Number.isInteger(Number(a.cantidad)) || Number(a.cantidad) <= 0)) lista.push(`La línea ${linea.numeroLinea} contiene una asignación inválida.`);
    });
    Object.entries(totalesProducto).forEach(([productoId, cantidad]) => {
      if (cantidad > (stock[productoId] ?? 0)) {
        const producto = productos.find((p) => p.id === productoId);
        lista.push(`Stock insuficiente para ${producto?.sku ?? "un producto"}: requiere ${cantidad} y hay ${stock[productoId] ?? 0}.`);
      }
    });
    return Array.from(new Set(lista));
  }, [factura, almacenId, emisores, lineas, perfil.rol, productos, stock, totalesProducto, validacionCodigo, codigoConfirmado, codigoNota]);

  async function aplicarFactura() {
    if (!factura || errores.length) return;
    const unidades = Object.values(totalesProducto).reduce((suma, cantidad) => suma + cantidad, 0);
    const avisoCodigo = validacionCodigo?.tipo === "oficial"
      ? ""
      : `\nNovedad confirmada: XML ${factura.establecimiento}-${factura.puntoEmision}.`;
    if (!window.confirm(`Se descontarán ${unidades} unidades del inventario.\n\nFactura: ${factura.numeroDocumento}\nAlmacén: ${almacenes.find((a) => a.id === almacenId)?.nombre}${avisoCodigo}\n\n¿Confirmas la aplicación definitiva?`)) return;
    setProcesando(true); setMsg(null);
    const documento = {
      clave_acceso: factura.claveAcceso,
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
      lineas: factura.lineas.map((linea) => ({
        numero_linea: linea.numeroLinea,
        codigo_principal: linea.codigoPrincipal,
        codigo_auxiliar: linea.codigoAuxiliar,
        descripcion: linea.descripcion,
        cantidad: linea.cantidad,
        precio_unitario: linea.precioUnitario,
        descuento: linea.descuento,
        total_sin_impuesto: linea.totalSinImpuesto,
        afecta_inventario: lineas[linea.numeroLinea]?.afectaInventario ?? true,
      })),
    };
    const asignaciones = factura.lineas.flatMap((linea) =>
      (lineas[linea.numeroLinea]?.asignaciones ?? []).map((a) => ({
        numero_linea: linea.numeroLinea, producto_id: a.productoId, cantidad: Number(a.cantidad),
      }))
    );
    // v46 concentra la entrada operativa en una RPC que valida rol y permiso.
    // Las funciones historicas quedan internas para impedir que una franquicia
    // descuente stock por fuera de su envoltorio (que tambien registra caja).
    const { data, error } = await supabase.rpc("aplicar_factura_venta_xml_operativa_v46", {
      p_documento: documento, p_almacen_id: almacenId, p_asignaciones: asignaciones, p_nota: nota || null,
      p_confirmar_codigo_no_estandar: validacionCodigo?.tipo !== "oficial" ? codigoConfirmado : false,
      p_codigo_nota: validacionCodigo?.tipo !== "oficial" ? codigoNota.trim() || null : null,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { mensaje?: string; numero_documento?: string } | null;
    setMsg({ tipo: "ok", texto: resultado?.mensaje ?? "Factura aplicada correctamente." });
    setFactura(null); setLineas({}); setArchivoNombre(""); setArchivoHash(""); setNota("");
    setCodigoConfirmado(false); setCodigoNota("");
    setTab("historial");
    await cargarDatos();
  }

  async function anularFactura(documento: DocumentoVenta) {
    const motivo = window.prompt(
      `Motivo obligatorio para registrar la anulación fiscal de ${documento.numero_documento}:\n\n` +
      "Esta acción NO modifica el inventario. Si la mercadería regresó, deberás registrar también su devolución física."
    )?.trim();
    if (!motivo) return;
    if (!window.confirm(
      "Se marcará el documento como anulado para trazabilidad, sin sumar stock.\n\n" +
      "La anulación real ante el SRI o facturador debe realizarse por separado. ¿Deseas continuar?"
    )) return;

    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("admin_anular_factura_venta_xml", {
      p_documento_id: documento.id,
      p_motivo: motivo,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { mensaje?: string } | null;
    setMsg({ tipo: "ok", texto: resultado?.mensaje ?? "Anulación fiscal registrada sin modificar stock." });
    await cargarDatos();
  }

  async function abrirDevolucion(documento: DocumentoVenta) {
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("consultar_saldo_devolucion_venta_xml", {
      p_documento_id: documento.id,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { lineas?: SaldoDevolucion[] } | null;
    const saldos = (resultado?.lineas ?? []).filter((linea) => linea.pendiente > 0);
    if (!saldos.length) {
      setMsg({ tipo: "error", texto: "Esta factura ya no tiene unidades pendientes de devolución." });
      return;
    }
    setDevolviendo(documento);
    setSaldoDevolucion(saldos);
    setItemsDevolucion(Object.fromEntries(saldos.map((linea) => [
      linea.producto_id, { cantidad: "0", destinoEstado: "disponible" as const },
    ])));
    setMotivoDevolucion("");
  }

  async function registrarDevolucion() {
    if (!devolviendo) return;
    const items = saldoDevolucion.flatMap((linea) => {
      const item = itemsDevolucion[linea.producto_id];
      const cantidad = Number(item?.cantidad || 0);
      return cantidad > 0 ? [{
        producto_id: linea.producto_id,
        cantidad,
        destino_estado: item.destinoEstado,
      }] : [];
    });
    if (!motivoDevolucion.trim()) {
      setMsg({ tipo: "error", texto: "Indica el motivo o referencia de la devolución." });
      return;
    }
    if (!items.length || items.some((item) => !Number.isInteger(item.cantidad))) {
      setMsg({ tipo: "error", texto: "Ingresa al menos una cantidad entera para devolver." });
      return;
    }
    if (items.some((item) => item.cantidad > (saldoDevolucion.find((linea) => linea.producto_id === item.producto_id)?.pendiente ?? 0))) {
      setMsg({ tipo: "error", texto: "Una cantidad supera el saldo pendiente de devolución." });
      return;
    }
    const disponibles = items.filter((item) => item.destino_estado === "disponible").reduce((s, item) => s + item.cantidad, 0);
    const cuarentena = items.filter((item) => item.destino_estado === "cuarentena").reduce((s, item) => s + item.cantidad, 0);
    if (!window.confirm(
      `Factura ${devolviendo.numero_documento}\nDisponible: ${disponibles} unidad(es)\nCuarentena: ${cuarentena} unidad(es)\n\n` +
      "Confirma solamente mercadería recibida y verificada físicamente."
    )) return;

    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("registrar_devolucion_venta_xml", {
      p_documento_id: devolviendo.id,
      p_items: items,
      p_motivo: motivoDevolucion.trim(),
      p_idempotency_key: crypto.randomUUID(),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { mensaje?: string; numero?: string } | null;
    setMsg({ tipo: "ok", texto: `${resultado?.mensaje ?? "Devolución aplicada."}${resultado?.numero ? ` Documento ${resultado.numero}.` : ""}` });
    setDevolviendo(null); setSaldoDevolucion([]); setItemsDevolucion({}); setMotivoDevolucion("");
    await cargarDatos();
  }

  async function revertirImportacion(documento: DocumentoVenta) {
    const motivo = window.prompt(
      `Motivo de la reversión técnica de ${documento.numero_documento}:\n\n` +
      "Úsala solo si el XML se importó por error. El sistema bloqueará la operación si existen movimientos posteriores o devoluciones."
    )?.trim();
    if (!motivo) return;
    if (!window.confirm(
      `Se creará una reversa compensatoria de ${documento.unidades_inventario} unidades.\n\n` +
      "No reemplaza una devolución de cliente ni una anulación ante el SRI. ¿Confirmas?"
    )) return;
    setProcesando(true); setMsg(null);
    const { data, error } = await supabase.rpc("admin_revertir_importacion_venta_xml", {
      p_documento_id: documento.id,
      p_motivo: motivo,
      p_idempotency_key: crypto.randomUUID(),
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { mensaje?: string } | null;
    setMsg({ tipo: "ok", texto: resultado?.mensaje ?? "Importación revertida con movimiento compensatorio." });
    await cargarDatos();
  }

  function estadoStock(documento: DocumentoVenta) {
    const etiquetas: Record<DocumentoVenta["anulacion_stock_estado"], string> = {
      sin_anulacion: "Sin devolución",
      sin_retorno: "Anulada · retorno pendiente",
      devuelto_parcial: "Devolución parcial",
      devuelto_total: "Devuelta totalmente",
      reversion_tecnica: "Importación revertida",
      reversion_tecnica_legacy: "Reversa histórica",
    };
    return etiquetas[documento.anulacion_stock_estado] ?? documento.anulacion_stock_estado;
  }

  function sugerencias(numeroLinea: number) {
    const consulta = normalizar(busquedas[numeroLinea]);
    if (!consulta) return [];
    const yaUsados = new Set(lineas[numeroLinea]?.asignaciones.map((a) => a.productoId) ?? []);
    return productos.filter((producto) => {
      if (yaUsados.has(producto.id)) return false;
      const texto = normalizar(`${producto.sku} ${producto.nombre} ${producto.talla ?? ""} ${producto.color ?? ""}`);
      return texto.includes(consulta);
    }).slice(0, 12);
  }

  function productosRecordados(linea: LineaFacturaSri) {
    if (!factura) return [];
    const externos = [linea.codigoPrincipal, linea.codigoAuxiliar]
      .filter((codigo): codigo is string => Boolean(codigo) && codigo!.toUpperCase() !== "N/A")
      .map((codigo) => normalizar(codigo));
    const ids = new Set<string>();
    productos.forEach((producto) => {
      if (externos.includes(normalizar(producto.sku))) ids.add(producto.id);
    });
    codigos.forEach((codigo) => {
      if (codigo.emisor_ruc === factura.emisorRuc && externos.includes(normalizar(codigo.codigo_externo))) ids.add(codigo.producto_id);
    });
    const asignados = new Set(lineas[linea.numeroLinea]?.asignaciones.map((a) => a.productoId) ?? []);
    return productos.filter((producto) => ids.has(producto.id) && !asignados.has(producto.id));
  }

  const productosCatalogo = useMemo(() => {
    const consulta = normalizar(busquedaCatalogo);
    const palabras = consulta.split(/\s+/).filter(Boolean);
    return productos.filter((producto) => {
      if (!consulta) return true;
      const texto = normalizar(`${producto.sku} ${producto.nombre} ${producto.talla ?? ""} ${producto.color ?? ""}`);
      return palabras.every((palabra) =>
        texto.includes(palabra) || (palabra.endsWith("s") && texto.includes(palabra.slice(0, -1)))
      );
    }).slice(0, 300);
  }, [busquedaCatalogo, productos]);

  return (
    <>
      <div className="header-row">
        <div><h2 style={{ color: "#1f3864", margin: 0 }}>Ventas desde XML</h2><p className="conteo">Concilia facturas autorizadas del SRI con el catálogo y descuenta el inventario una sola vez.</p></div>
      </div>
      {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}
      <div className="tabs">
        {puedeImportar && <button className={`tab ${tab === "importar" ? "activo" : ""}`} onClick={() => setTab("importar")}>Importar XML</button>}
        <button className={`tab ${tab === "historial" ? "activo" : ""}`} onClick={() => setTab("historial")}>Historial aplicado</button>
      </div>

      {tab === "importar" && puedeImportar && <>
        <section className="card carga-xml">
          <h3 style={{ marginTop: 0 }}>1. Cargar factura autorizada</h3>
          <p className="conteo">El archivo se interpreta en este navegador. Se conserva su huella de seguridad y los datos operativos, no el XML completo ni los datos del cliente.</p>
          <label className="selector-archivo-xml">
            <span>{cargando ? "Preparando catálogo…" : procesando ? "Procesando…" : factura ? "Cambiar archivo XML" : "Seleccionar archivo XML"}</span>
            <input type="file" accept=".xml,text/xml,application/xml" onChange={leerArchivo} disabled={procesando || cargando} />
          </label>
        </section>

        {factura && <>
          <section className="card resumen-factura-xml">
            <div className="header-row"><h3 style={{ margin: 0 }}>2. Revisar factura</h3><span className="badge estado-aplicado">SRI AUTORIZADO</span></div>
            <div className="grid-resumen-xml">
              <div><small>Documento</small><strong>{factura.numeroDocumento}</strong></div>
              <div><small>Emisor</small><strong>{factura.razonSocialEmisor}</strong><span>RUC {factura.emisorRuc}</span></div>
              <div><small>Emisión</small><strong>{factura.fechaEmision}</strong></div>
              <div><small>Total</small><strong>{dinero.format(factura.importeTotal)}</strong></div>
            </div>
            {emisores.length === 0 && ["admin", "control"].includes(perfil.rol) && <p className="info-box">Este será el primer emisor habilitado: <strong>{factura.razonSocialEmisor} · {factura.emisorRuc}</strong>. Confirma que corresponda al facturador oficial de Boman Sport.</p>}
            {validacionCodigo?.tipo === "oficial" && <div className="success" style={{ marginTop: 12 }}>
              Numeración validada: establecimiento {factura.establecimiento} · punto de emisión {factura.puntoEmision}.
            </div>}
            {validacionCodigo?.tipo === "equivalencia" && <div className="info-box" style={{ marginTop: 12, borderColor: "#d97706" }}>
              <strong>Novedad conocida del facturador:</strong> el XML dice {factura.establecimiento}-{factura.puntoEmision}, pero corresponde a <strong>{validacionCodigo.equivalencia.establecimiento_oficial} · {validacionCodigo.equivalencia.establecimiento_nombre} / punto {validacionCodigo.equivalencia.punto_emision_oficial}</strong>.
              <div>{validacionCodigo.equivalencia.motivo}</div>
              <label className="opcion-destacada compacta" style={{ marginTop: 8 }}>
                <input type="checkbox" checked={codigoConfirmado} onChange={(e) => setCodigoConfirmado(e.target.checked)} />
                Revisé la equivalencia y confirmo que esta venta corresponde a {validacionCodigo.equivalencia.almacen ?? "la ubicación configurada"}.
              </label>
            </div>}
            {validacionCodigo?.tipo === "pendiente" && <div className="info-box" style={{ marginTop: 12, borderColor: "#dc2626" }}>
              <strong>Numeración todavía no clasificada:</strong> el XML contiene {factura.establecimiento}-{factura.puntoEmision}. Puedes continuar sin bloquear la carga, pero primero selecciona el almacén correcto y documenta la novedad.
              <div className="field" style={{ marginTop: 8 }}>
                <label>Motivo o explicación</label>
                <input value={codigoNota} onChange={(e) => setCodigoNota(e.target.value)} placeholder="Ej.: el facturador usa 001-006 para identificar Puyo" />
              </div>
              <label className="opcion-destacada compacta">
                <input type="checkbox" checked={codigoConfirmado} onChange={(e) => setCodigoConfirmado(e.target.checked)} />
                Revisé el XML y confirmo manualmente su ubicación antes de descontar inventario.
              </label>
            </div>}
            <div className="field"><label>Almacén que realizó la venta</label><select value={almacenId} onChange={(e) => setAlmacenId(e.target.value)}><option value="">Seleccionar…</option>{almacenesDisponibles.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}</select></div>
          </section>

          <section className="card">
            <h3 style={{ marginTop: 0 }}>3. Relacionar productos</h3>
            <div className="info-box"><strong>¿Qué significa asignación masiva?</strong> Abre una línea del XML, marca juntos todos los SKU o tallas que le corresponden y agrégalos en una sola acción. Puedes repartir el total por igual como punto de partida y después corregir las cantidades reales.</div>
            <div className="lista-lineas-xml">{factura.lineas.map((linea) => {
              const estado = lineas[linea.numeroLinea] ?? { afectaInventario: true, asignaciones: [] };
              const totalAsignado = estado.asignaciones.reduce((suma, a) => suma + Number(a.cantidad || 0), 0);
              const completa = !estado.afectaInventario || totalAsignado === linea.cantidad;
              return <article className="linea-factura-xml" key={linea.numeroLinea}>
                <div className="linea-factura-cabecera">
                  <div><strong>{linea.numeroLinea}. {linea.descripcion}</strong><span>Código: {linea.codigoPrincipal ?? linea.codigoAuxiliar ?? "Sin código"} · XML: {linea.cantidad} unidad(es)</span></div>
                  <span className={`estado-distribucion ${completa ? "completa" : "pendiente"}`}>{estado.afectaInventario ? `${totalAsignado}/${linea.cantidad}` : "No inventariable"}</span>
                </div>
                <label className="opcion-destacada compacta"><input type="checkbox" checked={!estado.afectaInventario} onChange={(e) => cambiarAfectacion(linea.numeroLinea, !e.target.checked)} /> Es servicio u otro concepto que no descuenta inventario</label>
                {estado.afectaInventario && <>
                  {productosRecordados(linea).length > 0 && <div className="recordados-xml"><span>Coincidencias por código:</span>{productosRecordados(linea).map((producto) => <button className="secondary" type="button" key={producto.id} onClick={() => agregarProducto(linea.numeroLinea, producto.id)}>{producto.sku} · {producto.talla ?? producto.color ?? producto.nombre}</button>)}</div>}
                  <div className="acciones-masivas-xml"><button type="button" onClick={() => abrirSelectorCatalogo(linea)}>Seleccionar varios del catálogo</button>{estado.asignaciones.length > 1 && <button className="secondary" type="button" onClick={() => repartirLineaPorIgual(linea.numeroLinea)}>Repartir {linea.cantidad} por igual</button>}<span>{estado.asignaciones.length} producto(s) seleccionado(s)</span></div>
                  <div className="asignaciones-xml">{estado.asignaciones.map((a) => {
                    const producto = productos.find((p) => p.id === a.productoId);
                    return <div className="asignacion-xml" key={a.productoId}>
                      <div><strong>{producto?.sku}</strong><span>{producto?.nombre} {producto?.talla ? `· Talla ${producto.talla}` : ""} {producto?.color ? `· ${producto.color}` : ""}</span><small>Stock: {stock[a.productoId] ?? 0}</small></div>
                      <input aria-label="Cantidad asignada" type="number" min={1} step={1} value={a.cantidad} onChange={(e) => actualizarCantidad(linea.numeroLinea, a.productoId, e.target.value)} />
                      <button className="peligro" type="button" onClick={() => quitarProducto(linea.numeroLinea, a.productoId)}>Quitar</button>
                    </div>;
                  })}</div>
                  <div className="buscador-producto-caja buscador-xml">
                    <input value={busquedas[linea.numeroLinea] ?? ""} onChange={(e) => setBusquedas({ ...busquedas, [linea.numeroLinea]: e.target.value })} placeholder="Buscar por SKU, nombre, talla o color…" />
                    {(busquedas[linea.numeroLinea] ?? "").trim() && <div className="sugerencias-documento">{sugerencias(linea.numeroLinea).map((producto) => <button type="button" key={producto.id} onClick={() => agregarProducto(linea.numeroLinea, producto.id)}><strong>{producto.sku}</strong><span>{producto.nombre} {producto.talla ?? ""} {producto.color ?? ""}</span><small>Stock {stock[producto.id] ?? 0}</small></button>)}{!sugerencias(linea.numeroLinea).length && <div className="sugerencias-vacio">No se encontraron productos.</div>}</div>}
                  </div>
                </>}
              </article>;
            })}</div>
          </section>

          <section className="card">
            <h3 style={{ marginTop: 0 }}>4. Aplicar al inventario</h3>
            <div className="field"><label>Nota interna (opcional)</label><textarea rows={2} value={nota} onChange={(e) => setNota(e.target.value)} placeholder="Ej: Cierre de ventas del local" /></div>
            {errores.length > 0 ? <div className="error"><strong>Falta completar:</strong><ul>{errores.map((error) => <li key={error}>{error}</li>)}</ul></div> : <div className="success">La factura está lista. Se descontarán {Object.values(totalesProducto).reduce((s, n) => s + n, 0)} unidades.</div>}
            <button disabled={procesando || errores.length > 0} onClick={aplicarFactura}>{procesando ? "Aplicando…" : "Confirmar y descontar inventario"}</button>
          </section>
        </>}
      </>}

      {tab === "historial" && <section className="card">
        <h3 style={{ marginTop: 0 }}>Facturas aplicadas</h3>
        <div className="info-box" style={{ marginBottom: 12 }}><strong>V20 separa tres hechos:</strong> anulación fiscal, devolución física de mercadería y reversión técnica de una importación errónea. Solo las dos últimas pueden modificar stock y dejan un movimiento compensatorio.</div>
        {cargando ? <div className="vacio">Cargando…</div> : <div className="tabla-scroll"><table><thead><tr><th>Factura</th><th>Emisor</th><th>Fecha venta</th><th>Almacén</th><th className="num">Unidades</th><th className="num">Total</th><th>Aplicada por</th><th>Importada</th><th>Estado fiscal</th><th>Estado stock</th><th>Acciones</th></tr></thead><tbody>{historial.map((doc) => <tr key={doc.id} className={doc.anulado ? "fila-anulada" : ""}><td><strong>{doc.numero_documento}</strong></td><td>{doc.razon_social_emisor}</td><td>{doc.fecha_emision}</td><td>{doc.almacen?.nombre ?? "-"}</td><td className="num">{doc.unidades_inventario}</td><td className="num">{dinero.format(Number(doc.importe_total))}</td><td>{doc.creador?.nombre_completo ?? "-"}</td><td>{fecha(doc.created_at)}</td><td>{doc.anulado ? <span className="badge anulado" title={`${doc.motivo_anulacion ?? ""} · ${doc.anulador?.nombre_completo ?? ""} · ${doc.anulado_at ? fecha(doc.anulado_at) : ""}`}>ANULADA</span> : <span className="badge ok">VIGENTE</span>}</td><td><span className={`badge ${doc.anulacion_stock_estado === "devuelto_total" ? "ok" : doc.anulacion_stock_estado.includes("reversion") ? "anulado" : "estado-pendiente_revision"}`}>{estadoStock(doc)}</span></td><td><div className="acciones-documento">{puedeImportar && !["devuelto_total", "reversion_tecnica", "reversion_tecnica_legacy"].includes(doc.anulacion_stock_estado) && <button className="secondary" disabled={procesando} onClick={() => abrirDevolucion(doc)}>Registrar devolución</button>}{perfil.rol === "admin" && !doc.anulado && <button className="peligro" disabled={procesando} onClick={() => anularFactura(doc)}>Anular fiscalmente</button>}{perfil.rol === "admin" && !["devuelto_parcial", "devuelto_total", "reversion_tecnica", "reversion_tecnica_legacy"].includes(doc.anulacion_stock_estado) && <button className="chip-limpiar" disabled={procesando} onClick={() => revertirImportacion(doc)}>Reversión técnica</button>}{doc.anulado && <small>{doc.motivo_anulacion}</small>}</div></td></tr>)}{!historial.length && <tr><td colSpan={11} className="vacio">Todavía no hay facturas XML aplicadas.</td></tr>}</tbody></table></div>}
      </section>}

      {devolviendo && <div className="modal-operativo" role="dialog" aria-modal="true" aria-label="Registrar devolución de venta">
        <div className="modal-contenido ancho">
          <div className="header-row"><div><h3 style={{ margin: 0 }}>Devolución física · {devolviendo.numero_documento}</h3><p className="conteo">Almacén receptor: {devolviendo.almacen?.nombre ?? "-"}</p></div><button className="chip-limpiar" type="button" onClick={() => setDevolviendo(null)}>Cerrar</button></div>
          <div className="info-box"><strong>Inspecciona antes de registrar:</strong> usa “Disponible” solo si el producto puede volver a venderse. Producto dañado, usado, incompleto o dudoso debe ir a cuarentena.</div>
          <div className="tabla-scroll"><table><thead><tr><th>Producto</th><th className="num">Vendido</th><th className="num">Ya devuelto</th><th className="num">Pendiente</th><th className="num">Recibido ahora</th><th>Destino</th></tr></thead><tbody>{saldoDevolucion.map((linea) => {
            const item = itemsDevolucion[linea.producto_id] ?? { cantidad: "0", destinoEstado: "disponible" as const };
            return <tr key={linea.producto_id}><td><strong>{linea.sku}</strong><div className="conteo">{linea.producto}</div></td><td className="num">{linea.vendido}</td><td className="num">{linea.devuelto}</td><td className="num">{linea.pendiente}</td><td className="num"><input type="number" min={0} max={linea.pendiente} step={1} value={item.cantidad} onChange={(e) => setItemsDevolucion({ ...itemsDevolucion, [linea.producto_id]: { ...item, cantidad: e.target.value } })} style={{ width: 90 }} /></td><td><select value={item.destinoEstado} onChange={(e) => setItemsDevolucion({ ...itemsDevolucion, [linea.producto_id]: { ...item, destinoEstado: e.target.value as ItemDevolucion["destinoEstado"] } })}><option value="disponible">Disponible para venta</option><option value="cuarentena">Cuarentena / inspección</option></select></td></tr>;
          })}</tbody></table></div>
          <div className="field"><label>Motivo, comprobante o referencia *</label><textarea rows={3} value={motivoDevolucion} onChange={(e) => setMotivoDevolucion(e.target.value)} placeholder="Ej.: devolución del cliente, nota de crédito N.º…, prendas verificadas por…" /></div>
          <div className="acciones-documento"><button disabled={procesando} onClick={registrarDevolucion}>{procesando ? "Registrando…" : "Confirmar recepción física"}</button><button className="secondary" disabled={procesando} onClick={() => setDevolviendo(null)}>Cancelar</button></div>
        </div>
      </div>}

      {selectorLinea != null && factura && <div className="modal-operativo" role="dialog" aria-modal="true" aria-label="Seleccionar productos del catálogo">
        <div className="modal-contenido ancho selector-catalogo-xml">
          <div className="header-row"><div><h3 style={{ margin: 0 }}>Seleccionar productos</h3><p className="conteo">Línea {selectorLinea}: {factura.lineas.find((l) => l.numeroLinea === selectorLinea)?.descripcion} · Cantidad XML: <strong>{factura.lineas.find((l) => l.numeroLinea === selectorLinea)?.cantidad}</strong></p></div><button className="chip-limpiar" type="button" onClick={() => setSelectorLinea(null)}>Cerrar</button></div>
          <div className="field"><label>Buscar en el catálogo</label><input autoFocus value={busquedaCatalogo} onChange={(e) => setBusquedaCatalogo(e.target.value)} placeholder="SKU, producto, talla o color" /></div>
          <div className="resumen-seleccion-xml"><strong>{seleccionCatalogo.size} seleccionados</strong><span>Marca todos los productos internos que forman parte de esta línea.</span></div>
          <div className="catalogo-productos-xml">{productosCatalogo.map((producto) => <label key={producto.id} className={seleccionCatalogo.has(producto.id) ? "seleccionado" : ""}><input type="checkbox" checked={seleccionCatalogo.has(producto.id)} onChange={(e) => alternarProductoCatalogo(producto.id, e.target.checked)} /><strong>{producto.sku}</strong><span>{producto.nombre}</span><small>{producto.talla ? `Talla ${producto.talla}` : ""} {producto.color ?? ""}</small><b>Stock {stock[producto.id] ?? 0}</b></label>)}{!productosCatalogo.length && <div className="vacio">No se encontraron productos con ese filtro.</div>}</div>
          <div className="info-box">El reparto por igual es únicamente una ayuda inicial. Debes corregirlo si la factura agrupa cantidades distintas por talla o color.</div>
          <div className="acciones-documento"><button type="button" disabled={!seleccionCatalogo.size} onClick={() => guardarSeleccionCatalogo(true)}>Agregar y repartir por igual</button><button className="secondary" type="button" disabled={!seleccionCatalogo.size} onClick={() => guardarSeleccionCatalogo(false)}>Agregar para ajustar manualmente</button><button className="chip-limpiar" type="button" onClick={() => setSeleccionCatalogo(new Set())}>Limpiar selección</button></div>
        </div>
      </div>}
    </>
  );
}
