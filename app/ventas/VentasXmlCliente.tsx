"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Perfil } from "@/lib/getPerfil";
import { fecha } from "@/lib/utils";
import { calcularHashXml, parsearFacturaSri, type FacturaSri, type LineaFacturaSri } from "@/lib/xmlFacturaSri";

type Almacen = { id: string; nombre: string; tipo: string };
type Producto = { id: string; sku: string; nombre: string; talla: string | null; color: string | null };
type CodigoAprendido = { emisor_ruc: string; codigo_externo: string; producto_id: string; usos: number };
type Establecimiento = { emisor_ruc: string; establecimiento: string; punto_emision: string; almacen_id: string };
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
  almacen: { nombre: string } | null;
  creador: { nombre_completo: string } | null;
};

const normalizar = (valor: string | null | undefined) => (valor ?? "").trim().toLocaleLowerCase("es");
const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });

export default function VentasXmlCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const puedeImportar = ["admin", "control", "tienda"].includes(perfil.rol);
  const rolGlobal = ["admin", "control", "gerencia"].includes(perfil.rol);
  const [tab, setTab] = useState<"importar" | "historial">(puedeImportar ? "importar" : "historial");
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [permitidos, setPermitidos] = useState<string[]>([]);
  const [productos, setProductos] = useState<Producto[]>([]);
  const [codigos, setCodigos] = useState<CodigoAprendido[]>([]);
  const [establecimientos, setEstablecimientos] = useState<Establecimiento[]>([]);
  const [emisores, setEmisores] = useState<string[]>([]);
  const [historial, setHistorial] = useState<DocumentoVenta[]>([]);
  const [factura, setFactura] = useState<FacturaSri | null>(null);
  const [archivoNombre, setArchivoNombre] = useState("");
  const [archivoHash, setArchivoHash] = useState("");
  const [almacenId, setAlmacenId] = useState(perfil.entidad_id ?? "");
  const [lineas, setLineas] = useState<Record<number, EstadoLinea>>({});
  const [busquedas, setBusquedas] = useState<Record<number, string>>({});
  const [stock, setStock] = useState<Record<string, number>>({});
  const [nota, setNota] = useState("");
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  async function cargarDatos() {
    setCargando(true);
    const [a, pa, p, c, e, em, h] = await Promise.all([
      supabase.from("almacenes").select("id, nombre, tipo").eq("activo", true).order("nombre"),
      supabase.from("perfil_almacenes").select("almacen_id").eq("perfil_id", perfil.id),
      supabase.from("productos").select("id, sku, nombre, talla, color").eq("activo", true).order("nombre"),
      supabase.from("producto_codigos_facturacion").select("emisor_ruc, codigo_externo, producto_id, usos"),
      supabase.from("establecimiento_almacen_facturacion").select("emisor_ruc, establecimiento, punto_emision, almacen_id"),
      supabase.from("emisores_facturacion").select("ruc").eq("activo", true),
      supabase.from("documentos_venta_xml").select(`
        id, numero_documento, razon_social_emisor, fecha_emision, importe_total,
        unidades_inventario, created_at,
        almacen:almacenes!documentos_venta_xml_almacen_id_fkey(nombre),
        creador:perfiles!documentos_venta_xml_creado_por_fkey(nombre_completo)
      `).order("created_at", { ascending: false }).limit(150),
    ]);
    const error = a.error ?? pa.error ?? p.error ?? c.error ?? e.error ?? em.error ?? h.error;
    if (error) setMsg({ tipo: "error", texto: `No se pudo cargar Ventas XML. Verifica que la migración v13 esté instalada: ${error.message}` });
    setAlmacenes((a.data ?? []) as Almacen[]);
    setPermitidos((pa.data ?? []).map((fila: any) => fila.almacen_id));
    setProductos((p.data ?? []) as Producto[]);
    setCodigos((c.data ?? []) as CodigoAprendido[]);
    setEstablecimientos((e.data ?? []) as Establecimiento[]);
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
      if (mapeo) setAlmacenId(mapeo.almacen_id);
      else if (almacenesDisponibles.length === 1) setAlmacenId(almacenesDisponibles[0].id);
      setFactura(nueva);
      setArchivoNombre(archivo.name.slice(0, 255));
      setArchivoHash(hash);
      setLineas(estadoInicial(nueva));
      setBusquedas({});
      setNota("");
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

  const totalesProducto = useMemo(() => {
    const totales: Record<string, number> = {};
    Object.values(lineas).forEach((linea) => linea.asignaciones.forEach((a) => {
      totales[a.productoId] = (totales[a.productoId] ?? 0) + Number(a.cantidad || 0);
    }));
    return totales;
  }, [lineas]);

  const errores = useMemo(() => {
    if (!factura) return [];
    const lista: string[] = [];
    if (!almacenId) lista.push("Selecciona el almacén que realizó la venta.");
    if (emisores.length > 0 && !emisores.includes(factura.emisorRuc)) lista.push("El RUC emisor no está habilitado en el sistema.");
    if (emisores.length === 0 && !["admin", "control"].includes(perfil.rol)) lista.push("Administración o Control deben confirmar el primer RUC emisor.");
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
  }, [factura, almacenId, emisores, lineas, perfil.rol, productos, stock, totalesProducto]);

  async function aplicarFactura() {
    if (!factura || errores.length) return;
    const unidades = Object.values(totalesProducto).reduce((suma, cantidad) => suma + cantidad, 0);
    if (!window.confirm(`Se descontarán ${unidades} unidades del inventario.\n\nFactura: ${factura.numeroDocumento}\nAlmacén: ${almacenes.find((a) => a.id === almacenId)?.nombre}\n\n¿Confirmas la aplicación definitiva?`)) return;
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
    const { data, error } = await supabase.rpc("aplicar_factura_venta_xml", {
      p_documento: documento, p_almacen_id: almacenId, p_asignaciones: asignaciones, p_nota: nota || null,
    });
    setProcesando(false);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { mensaje?: string; numero_documento?: string } | null;
    setMsg({ tipo: "ok", texto: resultado?.mensaje ?? "Factura aplicada correctamente." });
    setFactura(null); setLineas({}); setArchivoNombre(""); setArchivoHash(""); setNota("");
    setTab("historial");
    await cargarDatos();
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
            <div className="field"><label>Almacén que realizó la venta</label><select value={almacenId} onChange={(e) => setAlmacenId(e.target.value)}><option value="">Seleccionar…</option>{almacenesDisponibles.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}</select></div>
          </section>

          <section className="card">
            <h3 style={{ marginTop: 0 }}>3. Relacionar productos</h3>
            <p className="conteo">Cada línea inventariable debe quedar distribuida exactamente. La equivalencia confirmada se recordará para próximas facturas.</p>
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
        {cargando ? <div className="vacio">Cargando…</div> : <div className="tabla-scroll"><table><thead><tr><th>Factura</th><th>Emisor</th><th>Fecha venta</th><th>Almacén</th><th className="num">Unidades</th><th className="num">Total</th><th>Aplicada por</th><th>Importada</th></tr></thead><tbody>{historial.map((doc) => <tr key={doc.id}><td><strong>{doc.numero_documento}</strong></td><td>{doc.razon_social_emisor}</td><td>{doc.fecha_emision}</td><td>{doc.almacen?.nombre ?? "-"}</td><td className="num">{doc.unidades_inventario}</td><td className="num">{dinero.format(Number(doc.importe_total))}</td><td>{doc.creador?.nombre_completo ?? "-"}</td><td>{fecha(doc.created_at)}</td></tr>)}{!historial.length && <tr><td colSpan={8} className="vacio">Todavía no hay facturas XML aplicadas.</td></tr>}</tbody></table></div>}
      </section>}
    </>
  );
}
