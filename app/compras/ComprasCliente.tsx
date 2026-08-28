"use client";

import { useEffect, useMemo, useState } from "react";
import LineasDocumentoEditor, {
  type LineaDocumentoEdicion,
  type ProductoDocumento,
} from "@/components/LineasDocumentoEditor";
import type { Perfil } from "@/lib/getPerfil";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { fecha } from "@/lib/utils";
import { createClient } from "@/lib/supabase/client";

type Empresa = { id: string; grupo_id: string; codigo: string; ruc: string; razon_social: string };
type Almacen = { id: string; nombre: string };
type Vinculo = {
  empresa_id: string; almacen_id: string; permite_compras: boolean; custodia_inventario: boolean;
};
type Proveedor = {
  id: string; grupo_id: string; tipo_identificacion: string; identificacion: string;
  razon_social: string; nombre_comercial: string | null; correo: string | null;
  telefono: string | null; direccion: string | null; activo: boolean;
};
type LineaCompra = LineaDocumentoEdicion & {
  costo_unitario: number; descuento_porcentaje: number; iva_porcentaje: number;
};
type OrdenLinea = {
  id: string; producto_id: string; cantidad_ordenada: number; cantidad_recibida: number;
  cantidad_no_conforme: number; costo_unitario: number; descuento_porcentaje: number;
  iva_porcentaje: number; total: number; observacion: string | null;
  producto: ProductoDocumento | null;
};
type AccionNoConforme = {
  id: string; accion: "liberar_disponible" | "devolver_proveedor" | "baja";
  cantidad: number; detalle: string; created_at: string;
};
type RecepcionLinea = {
  id: string; producto_id: string; cantidad_conforme: number; cantidad_no_conforme: number;
  producto: ProductoDocumento | null; acciones: AccionNoConforme[];
};
type Recepcion = {
  id: string; numero: string; estado: "aplicada" | "rectificada";
  documento_proveedor: string; nota: string | null; created_at: string;
  receptor: { nombre_completo: string } | null;
  lineas: RecepcionLinea[];
};
type Orden = {
  id: string; numero: string; empresa_id: string; proveedor_id: string; almacen_id: string;
  estado: string; fecha_orden: string; fecha_esperada: string | null; referencia: string | null;
  nota: string | null; subtotal: number; descuento: number; impuesto: number; total: number;
  created_at: string; empresa: { codigo: string; razon_social: string } | null;
  proveedor: { identificacion: string; razon_social: string } | null;
  almacen: { nombre: string } | null; creador: { nombre_completo: string } | null;
  aprobador: { nombre_completo: string } | null; lineas: OrdenLinea[]; recepciones: Recepcion[];
};
type FormularioProveedor = {
  id: string | null; tipo_identificacion: string; identificacion: string; razon_social: string;
  nombre_comercial: string; correo: string; telefono: string; direccion: string; activo: boolean;
};
type ValorRecepcion = { conforme: number; noConforme: number; observacion: string };

const dinero = new Intl.NumberFormat("es-EC", { style: "currency", currency: "USD" });
const ETIQUETAS: Record<string, string> = {
  pendiente_aprobacion: "Pendiente de aprobación", aprobada: "Aprobada",
  parcial: "Recepción parcial", recibida: "Recibida", rechazada: "Rechazada",
  anulada: "Anulada", cerrada_parcial: "Cerrada con recepción parcial",
};
const PROVEEDOR_VACIO: FormularioProveedor = {
  id: null, tipo_identificacion: "ruc", identificacion: "", razon_social: "",
  nombre_comercial: "", correo: "", telefono: "", direccion: "", activo: true,
};

export default function ComprasCliente({ perfil }: { perfil: Perfil }) {
  const supabase = createClient();
  const [tab, setTab] = useState<"ordenes" | "proveedores">("ordenes");
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [vinculos, setVinculos] = useState<Vinculo[]>([]);
  const [permitidos, setPermitidos] = useState<string[]>([]);
  const [proveedores, setProveedores] = useState<Proveedor[]>([]);
  const [productos, setProductos] = useState<ProductoDocumento[]>([]);
  const [ordenes, setOrdenes] = useState<Orden[]>([]);
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);
  const [mostrarOrden, setMostrarOrden] = useState(false);
  const [empresaId, setEmpresaId] = useState("");
  const [proveedorId, setProveedorId] = useState("");
  const [almacenId, setAlmacenId] = useState("");
  const [fechaEsperada, setFechaEsperada] = useState("");
  const [referencia, setReferencia] = useState("");
  const [nota, setNota] = useState("");
  const [lineas, setLineas] = useState<LineaCompra[]>([]);
  const [claveOrden, setClaveOrden] = useState(() => nuevaClaveIdempotencia());
  const [proveedorForm, setProveedorForm] = useState<FormularioProveedor | null>(null);
  const [recibiendo, setRecibiendo] = useState<Orden | null>(null);
  const [recepcion, setRecepcion] = useState<Record<string, ValorRecepcion>>({});
  const [documentoProveedor, setDocumentoProveedor] = useState("");
  const [notaRecepcion, setNotaRecepcion] = useState("");
  const [claveRecepcion, setClaveRecepcion] = useState(() => nuevaClaveIdempotencia());
  const [gestionandoNoConforme, setGestionandoNoConforme] = useState<{
    orden: Orden; recepcion: Recepcion; linea: RecepcionLinea;
  } | null>(null);
  const [accionNoConforme, setAccionNoConforme] = useState<"liberar_disponible" | "devolver_proveedor" | "baja">("liberar_disponible");
  const [cantidadNoConforme, setCantidadNoConforme] = useState(1);
  const [detalleNoConforme, setDetalleNoConforme] = useState("");
  const [claveNoConforme, setClaveNoConforme] = useState(() => nuevaClaveIdempotencia());

  const puedeGestionarProveedor = ["admin", "control"].includes(perfil.rol);
  const puedeCrear = ["admin", "control", "bodega"].includes(perfil.rol);
  const puedeAprobar = ["admin", "control"].includes(perfil.rol);
  const puedeRecibir = ["admin", "control", "bodega"].includes(perfil.rol);
  const rolGlobal = ["admin", "control", "gerencia"].includes(perfil.rol);

  async function cargar() {
    setCargando(true);
    const [e, a, v, pa, pr, p, o] = await Promise.all([
      supabase.from("empresas").select("id,grupo_id,codigo,ruc,razon_social").eq("activo", true).order("razon_social"),
      supabase.from("almacenes").select("id,nombre").eq("activo", true).order("nombre"),
      supabase.from("empresa_almacenes").select("empresa_id,almacen_id,permite_compras,custodia_inventario"),
      supabase.from("perfil_almacenes").select("almacen_id").eq("perfil_id", perfil.id),
      supabase.from("proveedores").select("id,grupo_id,tipo_identificacion,identificacion,razon_social,nombre_comercial,correo,telefono,direccion,activo").order("razon_social"),
      supabase.from("productos").select("id,sku,nombre,talla,color").eq("activo", true).order("nombre"),
      supabase.from("ordenes_compra").select(`
        id,numero,empresa_id,proveedor_id,almacen_id,estado,fecha_orden,fecha_esperada,
        referencia,nota,subtotal,descuento,impuesto,total,created_at,
        empresa:empresas!ordenes_compra_empresa_id_fkey(codigo,razon_social),
        proveedor:proveedores!ordenes_compra_proveedor_id_fkey(identificacion,razon_social),
        almacen:almacenes!ordenes_compra_almacen_id_fkey(nombre),
        creador:perfiles!ordenes_compra_creado_por_fkey(nombre_completo),
        aprobador:perfiles!ordenes_compra_aprobado_por_fkey(nombre_completo),
        lineas:orden_compra_lineas(id,producto_id,cantidad_ordenada,cantidad_recibida,
          cantidad_no_conforme,costo_unitario,descuento_porcentaje,iva_porcentaje,total,
          observacion,producto:productos(id,sku,nombre,talla,color)),
        recepciones:recepciones_compra(id,numero,estado,documento_proveedor,nota,created_at,
          receptor:perfiles!recepciones_compra_recibido_por_fkey(nombre_completo),
          lineas:recepcion_compra_lineas(id,producto_id,cantidad_conforme,cantidad_no_conforme,
            producto:productos(id,sku,nombre,talla,color),
            acciones:recepcion_compra_no_conformidad_acciones(id,accion,cantidad,detalle,created_at)))
      `).order("created_at", { ascending: false }).limit(250),
    ]);
    const error = e.error ?? a.error ?? v.error ?? pa.error ?? pr.error ?? p.error ?? o.error;
    if (error) setMsg({ tipo: "error", texto: `No se pudo cargar Compras. Verifica la migración v21: ${error.message}` });
    const empresasData = (e.data ?? []) as Empresa[];
    const vinculosData = (v.data ?? []) as Vinculo[];
    const permitidosData = (pa.data ?? []).map((fila: any) => fila.almacen_id as string);
    setEmpresas(empresasData); setAlmacenes((a.data ?? []) as Almacen[]);
    setVinculos(vinculosData); setPermitidos(permitidosData);
    setProveedores((pr.data ?? []) as Proveedor[]); setProductos((p.data ?? []) as ProductoDocumento[]);
    setOrdenes((o.data ?? []) as any as Orden[]);
    if (!empresaId && empresasData.length) setEmpresaId(empresasData[0].id);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, []);

  const almacenesCompra = useMemo(() => vinculos
    .filter((v) => v.empresa_id === empresaId && v.permite_compras && v.custodia_inventario)
    .map((v) => almacenes.find((a) => a.id === v.almacen_id))
    .filter((a): a is Almacen => Boolean(a))
    .filter((a) => rolGlobal || permitidos.includes(a.id) || a.id === perfil.entidad_id),
  [almacenes, empresaId, perfil.entidad_id, permitidos, rolGlobal, vinculos]);

  useEffect(() => {
    if (!almacenesCompra.some((a) => a.id === almacenId)) setAlmacenId(almacenesCompra[0]?.id ?? "");
  }, [almacenesCompra, almacenId]);

  function cambiarLineas(nuevas: LineaDocumentoEdicion[]) {
    setLineas(nuevas.map((linea) => {
      const anterior = lineas.find((actual) => actual.producto_id === linea.producto_id);
      return {
        ...linea,
        costo_unitario: anterior?.costo_unitario ?? 0,
        descuento_porcentaje: anterior?.descuento_porcentaje ?? 0,
        iva_porcentaje: anterior?.iva_porcentaje ?? 0,
      };
    }));
  }

  function cambiarCosto(productoId: string, cambio: Partial<LineaCompra>) {
    setLineas(lineas.map((linea) => linea.producto_id === productoId ? { ...linea, ...cambio } : linea));
  }

  const totalOrden = useMemo(() => lineas.reduce((total, l) => {
    const base = l.cantidad * l.costo_unitario * (1 - l.descuento_porcentaje / 100);
    return total + base * (1 + l.iva_porcentaje / 100);
  }, 0), [lineas]);

  async function crearOrden(evento: React.FormEvent) {
    evento.preventDefault(); setMsg(null);
    if (!empresaId || !proveedorId || !almacenId || !lineas.length) {
      setMsg({ tipo: "error", texto: "Selecciona empresa, proveedor, almacén y al menos un producto." }); return;
    }
    if (lineas.some((l) => l.cantidad <= 0 || l.costo_unitario < 0
      || l.descuento_porcentaje < 0 || l.descuento_porcentaje > 100
      || l.iva_porcentaje < 0 || l.iva_porcentaje > 100)) {
      setMsg({ tipo: "error", texto: "Revisa cantidades, costos, descuentos e impuestos." }); return;
    }
    setProcesando("nueva");
    const { data, error } = await supabase.rpc("crear_orden_compra_v21", {
      p_empresa_id: empresaId, p_proveedor_id: proveedorId, p_almacen_id: almacenId,
      p_items: lineas.map((l) => ({
        producto_id: l.producto_id, cantidad: l.cantidad, costo_unitario: l.costo_unitario,
        descuento_porcentaje: l.descuento_porcentaje, iva_porcentaje: l.iva_porcentaje,
        observacion: l.observacion || null,
      })),
      p_fecha_esperada: fechaEsperada || null, p_referencia: referencia.trim() || null,
      p_nota: nota.trim() || null, p_idempotency_key: claveOrden,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { numero?: string } | null;
    setMsg({ tipo: "ok", texto: `Orden ${resultado?.numero ?? ""} creada y enviada a aprobación.` });
    setMostrarOrden(false); setLineas([]); setFechaEsperada(""); setReferencia(""); setNota("");
    setClaveOrden(nuevaClaveIdempotencia());
    await cargar();
  }

  async function resolverOrden(orden: Orden, aprobar: boolean) {
    const texto = aprobar ? "Aprobación de compra verificada" : window.prompt("Motivo del rechazo:")?.trim();
    if (!aprobar && !texto) return;
    setProcesando(orden.id); setMsg(null);
    const { error } = await supabase.rpc("resolver_orden_compra_v21", {
      p_orden_id: orden.id, p_aprobar: aprobar, p_nota: texto || null,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: aprobar ? "Orden aprobada para recepción." : "Orden rechazada con trazabilidad." });
    await cargar();
  }

  async function cerrarSaldoOrden(orden: Orden) {
    const motivo = window.prompt(
      orden.estado === "parcial"
        ? "Motivo para cerrar definitivamente las unidades pendientes:"
        : "Motivo para anular esta orden aprobada sin recepción:"
    )?.trim();
    if (!motivo) return;
    setProcesando(orden.id); setMsg(null);
    const { error } = await supabase.rpc("cerrar_saldo_orden_compra_v21", {
      p_orden_id: orden.id, p_motivo: motivo,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: orden.estado === "parcial" ? "Saldo pendiente cerrado; las recepciones aplicadas se conservan." : "Orden anulada sin modificar stock." });
    await cargar();
  }

  function abrirRecepcion(orden: Orden) {
    const valores: Record<string, ValorRecepcion> = {};
    orden.lineas.forEach((l) => {
      valores[l.id] = { conforme: 0, noConforme: 0, observacion: "" };
    });
    setRecibiendo(orden); setRecepcion(valores); setDocumentoProveedor(""); setNotaRecepcion("");
    setClaveRecepcion(nuevaClaveIdempotencia()); setMsg(null);
  }

  async function guardarRecepcion() {
    if (!recibiendo) return;
    const items = recibiendo.lineas.flatMap((linea) => {
      const valor = recepcion[linea.id];
      const total = (valor?.conforme ?? 0) + (valor?.noConforme ?? 0);
      return total > 0 ? [{
        orden_linea_id: linea.id, cantidad_conforme: valor.conforme,
        cantidad_no_conforme: valor.noConforme, observacion: valor.observacion || null,
      }] : [];
    });
    if (!documentoProveedor.trim() || !items.length) {
      setMsg({ tipo: "error", texto: "Ingresa el documento del proveedor y al menos una cantidad recibida." }); return;
    }
    if (items.some((item) => item.cantidad_no_conforme > 0 && !String(item.observacion ?? notaRecepcion).trim())) {
      setMsg({ tipo: "error", texto: "Describe la evidencia de cada producto no conforme." }); return;
    }
    const excede = recibiendo.lineas.some((linea) => {
      const valor = recepcion[linea.id];
      return (valor?.conforme ?? 0) + (valor?.noConforme ?? 0)
        > linea.cantidad_ordenada - linea.cantidad_recibida - linea.cantidad_no_conforme;
    });
    if (excede) { setMsg({ tipo: "error", texto: "Una cantidad supera el saldo pendiente." }); return; }
    setProcesando(recibiendo.id);
    const { data, error } = await supabase.rpc("recibir_orden_compra_v21", {
      p_orden_id: recibiendo.id, p_items: items,
      p_documento_proveedor: documentoProveedor.trim(), p_nota: notaRecepcion.trim() || null,
      p_idempotency_key: claveRecepcion,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    const resultado = data as { numero?: string; estado_orden?: string } | null;
    setMsg({ tipo: "ok", texto: `Recepción ${resultado?.numero ?? ""} aplicada. Estado: ${ETIQUETAS[resultado?.estado_orden ?? ""] ?? resultado?.estado_orden}.` });
    setRecibiendo(null); await cargar();
  }

  async function rectificarRecepcion(orden: Orden, recepcionItem: Recepcion) {
    const motivo = window.prompt(
      `Rectificar ${recepcionItem.numero}. Describe el error y la evidencia (mínimo 10 caracteres):`
    )?.trim();
    if (!motivo) return;
    if (!window.confirm("Se retirará el stock conforme y la cuarentena de esta recepción mediante movimientos compensatorios. ¿Continuar?")) return;
    setProcesando(recepcionItem.id); setMsg(null);
    const { error } = await supabase.rpc("admin_rectificar_recepcion_compra_v21", {
      p_recepcion_id: recepcionItem.id, p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setMsg({ tipo: "ok", texto: `Recepción de ${orden.numero} rectificada con trazabilidad.` }); await cargar();
  }

  function abrirNoConforme(orden: Orden, recepcionItem: Recepcion, linea: RecepcionLinea) {
    const resuelto = linea.acciones.reduce((s, a) => s + a.cantidad, 0);
    const pendiente = linea.cantidad_no_conforme - resuelto;
    setGestionandoNoConforme({ orden, recepcion: recepcionItem, linea });
    setAccionNoConforme("liberar_disponible"); setCantidadNoConforme(Math.min(1, pendiente));
    setDetalleNoConforme(""); setClaveNoConforme(nuevaClaveIdempotencia()); setMsg(null);
  }

  async function resolverNoConforme() {
    if (!gestionandoNoConforme) return;
    const { linea } = gestionandoNoConforme;
    const pendiente = linea.cantidad_no_conforme - linea.acciones.reduce((s, a) => s + a.cantidad, 0);
    if (!Number.isInteger(cantidadNoConforme) || cantidadNoConforme <= 0 || cantidadNoConforme > pendiente) {
      setMsg({ tipo: "error", texto: "La cantidad debe ser entera y no superar el saldo en cuarentena." }); return;
    }
    if (detalleNoConforme.trim().length < 10) {
      setMsg({ tipo: "error", texto: "Registra al menos 10 caracteres de evidencia." }); return;
    }
    if (accionNoConforme === "baja" && !window.confirm("La baja retirará definitivamente estas unidades de cuarentena. ¿Confirmas la evidencia y disposición final?")) return;
    setProcesando(linea.id); setMsg(null);
    const { error } = await supabase.rpc("resolver_no_conformidad_compra_v21", {
      p_recepcion_linea_id: linea.id, p_accion: accionNoConforme,
      p_cantidad: cantidadNoConforme, p_detalle: detalleNoConforme.trim(),
      p_idempotency_key: claveNoConforme,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setGestionandoNoConforme(null);
    setMsg({ tipo: "ok", texto: accionNoConforme === "liberar_disponible" ? "Producto inspeccionado y liberado al stock disponible." : accionNoConforme === "devolver_proveedor" ? "Devolución al proveedor registrada y retirada de cuarentena." : "Baja de producto no conforme registrada." });
    await cargar();
  }

  function editarProveedor(proveedor?: Proveedor) {
    setProveedorForm(proveedor ? {
      id: proveedor.id, tipo_identificacion: proveedor.tipo_identificacion,
      identificacion: proveedor.identificacion, razon_social: proveedor.razon_social,
      nombre_comercial: proveedor.nombre_comercial ?? "", correo: proveedor.correo ?? "",
      telefono: proveedor.telefono ?? "", direccion: proveedor.direccion ?? "", activo: proveedor.activo,
    } : { ...PROVEEDOR_VACIO });
    setMsg(null);
  }

  async function guardarProveedor(evento: React.FormEvent) {
    evento.preventDefault();
    if (!proveedorForm || !empresas.length) return;
    const empresa = empresas.find((e) => e.id === empresaId) ?? empresas[0];
    setProcesando("proveedor"); setMsg(null);
    const { error } = await supabase.rpc("guardar_proveedor_v21", {
      p_proveedor_id: proveedorForm.id, p_grupo_id: empresa.grupo_id,
      p_tipo_identificacion: proveedorForm.tipo_identificacion,
      p_identificacion: proveedorForm.identificacion.trim(),
      p_razon_social: proveedorForm.razon_social.trim(),
      p_nombre_comercial: proveedorForm.nombre_comercial.trim() || null,
      p_correo: proveedorForm.correo.trim() || null, p_telefono: proveedorForm.telefono.trim() || null,
      p_direccion: proveedorForm.direccion.trim() || null, p_activo: proveedorForm.activo,
    });
    setProcesando(null);
    if (error) { setMsg({ tipo: "error", texto: error.message }); return; }
    setProveedorForm(null); setMsg({ tipo: "ok", texto: "Proveedor guardado para el grupo económico." }); await cargar();
  }

  return <>
    <div className="header-row"><div><h2 style={{ color: "#1f3864", margin: 0 }}>Compras multiempresa</h2><p className="conteo">Proveedor compartido, RUC comprador, aprobación, recepción parcial y cuarentena.</p></div>{puedeCrear && tab === "ordenes" && <button onClick={() => setMostrarOrden((v) => !v)}>{mostrarOrden ? "Cancelar" : "+ Nueva orden"}</button>}{puedeGestionarProveedor && tab === "proveedores" && <button onClick={() => editarProveedor()}>+ Nuevo proveedor</button>}</div>
    {msg && <div className={msg.tipo === "error" ? "error" : "success"}>{msg.texto}</div>}
    <div className="tabs"><button className={`tab ${tab === "ordenes" ? "activo" : ""}`} onClick={() => setTab("ordenes")}>Órdenes de compra</button><button className={`tab ${tab === "proveedores" ? "activo" : ""}`} onClick={() => setTab("proveedores")}>Proveedores ({proveedores.filter((p) => p.activo).length})</button></div>

    {tab === "ordenes" && <>
      {mostrarOrden && <form className="card" onSubmit={crearOrden} style={{ marginBottom: 14 }}><div className="grid-2"><div className="field"><label>RUC comprador *</label><select required value={empresaId} onChange={(e) => setEmpresaId(e.target.value)}><option value="">Seleccionar…</option>{empresas.map((e) => <option key={e.id} value={e.id}>{e.codigo} · {e.razon_social}</option>)}</select></div><div className="field"><label>Proveedor *</label><select required value={proveedorId} onChange={(e) => setProveedorId(e.target.value)}><option value="">Seleccionar…</option>{proveedores.filter((p) => p.activo).map((p) => <option key={p.id} value={p.id}>{p.identificacion} · {p.razon_social}</option>)}</select></div><div className="field"><label>Almacén receptor *</label><select required value={almacenId} onChange={(e) => setAlmacenId(e.target.value)}><option value="">Seleccionar…</option>{almacenesCompra.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}</select></div><div className="field"><label>Fecha esperada</label><input type="date" value={fechaEsperada} onChange={(e) => setFechaEsperada(e.target.value)} /></div><div className="field"><label>Cotización / referencia</label><input value={referencia} onChange={(e) => setReferencia(e.target.value)} /></div><div className="field"><label>Observaciones</label><input value={nota} onChange={(e) => setNota(e.target.value)} /></div></div><LineasDocumentoEditor productos={productos} lineas={lineas} onChange={cambiarLineas} />{lineas.length > 0 && <div className="tabla-scroll" style={{ marginTop: 12 }}><table><thead><tr><th>SKU</th><th className="num">Costo unitario</th><th className="num">Descuento %</th><th className="num">Impuesto %</th><th className="num">Total línea</th></tr></thead><tbody>{lineas.map((l) => { const producto = productos.find((p) => p.id === l.producto_id); const base = l.cantidad * l.costo_unitario * (1 - l.descuento_porcentaje / 100); return <tr key={l.producto_id}><td><strong>{producto?.sku}</strong></td><td className="num"><input type="number" min={0} step="0.0001" value={l.costo_unitario} onChange={(e) => cambiarCosto(l.producto_id, { costo_unitario: Number(e.target.value) || 0 })} style={{ width: 110 }} /></td><td className="num"><input type="number" min={0} max={100} step="0.01" value={l.descuento_porcentaje} onChange={(e) => cambiarCosto(l.producto_id, { descuento_porcentaje: Number(e.target.value) || 0 })} style={{ width: 80 }} /></td><td className="num"><input type="number" min={0} max={100} step="0.01" value={l.iva_porcentaje} onChange={(e) => cambiarCosto(l.producto_id, { iva_porcentaje: Number(e.target.value) || 0 })} style={{ width: 80 }} /></td><td className="num"><strong>{dinero.format(base * (1 + l.iva_porcentaje / 100))}</strong></td></tr>; })}</tbody></table></div>}<div className="header-row" style={{ marginTop: 14 }}><strong>Total estimado: {dinero.format(totalOrden)}</strong><div className="acciones-documento"><button disabled={procesando === "nueva" || !lineas.length}>{procesando === "nueva" ? "Creando…" : "Enviar a aprobación"}</button><button type="button" className="secondary" onClick={() => setMostrarOrden(false)}>Cancelar</button></div></div></form>}

      {cargando ? <div className="card"><div className="vacio">Cargando compras…</div></div> : <div className="lista-documentos">{ordenes.map((orden) => { const pendientes = orden.lineas.reduce((s, l) => s + l.cantidad_ordenada - l.cantidad_recibida - l.cantidad_no_conforme, 0); return <article className="card documento-operativo" key={orden.id}><div className="header-row"><div><strong className="numero-documento">{orden.numero}</strong><span className={`badge estado-${orden.estado}`}>{ETIQUETAS[orden.estado] ?? orden.estado}</span><div className="conteo">{fecha(orden.created_at)} · {orden.creador?.nombre_completo ?? "-"}</div></div><div style={{ textAlign: "right" }}><strong>{dinero.format(Number(orden.total))}</strong><div className="conteo">Pendientes: {pendientes} unidad(es)</div></div></div><div className="ruta-documento"><span>{orden.proveedor?.razon_social}<small> · {orden.proveedor?.identificacion}</small></span><b>→</b><span>{orden.empresa?.codigo} · {orden.almacen?.nombre}</span></div><div className="tabla-scroll"><table><thead><tr><th>SKU</th><th>Producto</th><th className="num">Ordenado</th><th className="num">Conforme</th><th className="num">Cuarentena</th><th className="num">Pendiente</th><th className="num">Costo</th></tr></thead><tbody>{orden.lineas.map((l) => <tr key={l.id}><td><strong>{l.producto?.sku}</strong></td><td>{l.producto?.nombre} {l.producto?.talla ?? ""}</td><td className="num">{l.cantidad_ordenada}</td><td className="num">{l.cantidad_recibida}</td><td className="num">{l.cantidad_no_conforme}</td><td className="num">{l.cantidad_ordenada - l.cantidad_recibida - l.cantidad_no_conforme}</td><td className="num">{dinero.format(Number(l.costo_unitario))}</td></tr>)}</tbody></table></div>{orden.recepciones.length > 0 && <details className="info-box" style={{ marginTop: 10 }}><summary><strong>Recepciones ({orden.recepciones.length})</strong></summary>{orden.recepciones.map((r) => <div key={r.id} className="header-row" style={{ borderTop: "1px solid #dbeafe", paddingTop: 8, marginTop: 8 }}><span><strong>{r.numero}</strong> · {r.documento_proveedor} · {fecha(r.created_at)} · {r.receptor?.nombre_completo}<br /><small>{r.lineas.reduce((s, l) => s + l.cantidad_conforme, 0)} conforme(s) · {r.lineas.reduce((s, l) => s + l.cantidad_no_conforme, 0)} en cuarentena · {r.estado}</small></span>{perfil.rol === "admin" && r.estado === "aplicada" && <button className="peligro" disabled={procesando === r.id} onClick={() => rectificarRecepcion(orden, r)}>Rectificar</button>}</div>)}</details>}<div className="acciones-documento">{orden.estado === "pendiente_aprobacion" && puedeAprobar && <><button disabled={procesando === orden.id} onClick={() => resolverOrden(orden, true)}>Aprobar</button><button className="peligro" disabled={procesando === orden.id} onClick={() => resolverOrden(orden, false)}>Rechazar</button></>}{["aprobada", "parcial"].includes(orden.estado) && puedeRecibir && <button disabled={procesando === orden.id} onClick={() => abrirRecepcion(orden)}>Registrar recepción</button>}{["aprobada", "parcial"].includes(orden.estado) && puedeAprobar && <button className="peligro" disabled={procesando === orden.id} onClick={() => cerrarSaldoOrden(orden)}>{orden.estado === "parcial" ? "Cerrar saldo pendiente" : "Anular orden"}</button>}</div></article>; })}{!ordenes.length && <div className="card"><div className="vacio">Todavía no existen órdenes de compra.</div></div>}</div>}
      {ordenes.some((orden) => orden.recepciones.some((r) => r.estado === "aplicada" && r.lineas.some((l) => l.cantidad_no_conforme > l.acciones.reduce((s, a) => s + a.cantidad, 0)))) && <section className="card" style={{ marginTop: 14 }}><h3 style={{ marginTop: 0 }}>No conformidades de proveedores pendientes</h3><div className="info-box">Las unidades siguen físicamente en cuarentena hasta registrar una disposición.</div>{ordenes.flatMap((orden) => orden.recepciones.flatMap((r) => r.estado !== "aplicada" ? [] : r.lineas.filter((l) => l.cantidad_no_conforme > l.acciones.reduce((s, a) => s + a.cantidad, 0)).map((l) => { const resuelto = l.acciones.reduce((s, a) => s + a.cantidad, 0); return <div className="header-row pendiente-control" key={l.id}><span><strong>{l.producto?.sku} · {l.producto?.nombre}</strong><small>{orden.numero} · {r.numero} · {l.cantidad_no_conforme - resuelto} unidad(es) pendientes</small></span>{["admin", "control"].includes(perfil.rol) && <button className="secondary" onClick={() => abrirNoConforme(orden, r, l)}>Gestionar disposición</button>}</div>; })))}</section>}
    </>}

    {tab === "proveedores" && <><div className="card"><div className="tabla-scroll"><table><thead><tr><th>Identificación</th><th>Proveedor</th><th>Contacto</th><th>Estado</th><th></th></tr></thead><tbody>{proveedores.map((p) => <tr key={p.id}><td><strong>{p.identificacion}</strong><div className="conteo">{p.tipo_identificacion}</div></td><td>{p.razon_social}<div className="conteo">{p.nombre_comercial}</div></td><td>{p.correo ?? "-"}<div className="conteo">{p.telefono}</div></td><td><span className={`badge ${p.activo ? "ok" : "cero"}`}>{p.activo ? "Activo" : "Inactivo"}</span></td><td>{puedeGestionarProveedor && <button className="secondary" onClick={() => editarProveedor(p)}>Editar</button>}</td></tr>)}{!proveedores.length && <tr><td colSpan={5} className="vacio">Registra el primer proveedor del grupo.</td></tr>}</tbody></table></div></div></>}

    {proveedorForm && <div className="modal-operativo" role="dialog" aria-modal="true"><form className="modal-contenido" onSubmit={guardarProveedor}><div className="header-row"><h3>{proveedorForm.id ? "Editar proveedor" : "Nuevo proveedor"}</h3><button type="button" className="chip-limpiar" onClick={() => setProveedorForm(null)}>Cerrar</button></div><div className="grid-2"><div className="field"><label>Tipo de identificación</label><select value={proveedorForm.tipo_identificacion} onChange={(e) => setProveedorForm({ ...proveedorForm, tipo_identificacion: e.target.value })}><option value="ruc">RUC</option><option value="cedula">Cédula</option><option value="pasaporte">Pasaporte</option><option value="exterior">Identificación exterior</option></select></div><div className="field"><label>Identificación *</label><input required value={proveedorForm.identificacion} onChange={(e) => setProveedorForm({ ...proveedorForm, identificacion: e.target.value.toUpperCase() })} /></div><div className="field"><label>Razón social *</label><input required value={proveedorForm.razon_social} onChange={(e) => setProveedorForm({ ...proveedorForm, razon_social: e.target.value })} /></div><div className="field"><label>Nombre comercial</label><input value={proveedorForm.nombre_comercial} onChange={(e) => setProveedorForm({ ...proveedorForm, nombre_comercial: e.target.value })} /></div><div className="field"><label>Correo</label><input type="email" value={proveedorForm.correo} onChange={(e) => setProveedorForm({ ...proveedorForm, correo: e.target.value })} /></div><div className="field"><label>Teléfono</label><input value={proveedorForm.telefono} onChange={(e) => setProveedorForm({ ...proveedorForm, telefono: e.target.value })} /></div></div><div className="field"><label>Dirección</label><textarea rows={2} value={proveedorForm.direccion} onChange={(e) => setProveedorForm({ ...proveedorForm, direccion: e.target.value })} /></div><label><input type="checkbox" checked={proveedorForm.activo} onChange={(e) => setProveedorForm({ ...proveedorForm, activo: e.target.checked })} /> Proveedor activo</label><div className="acciones-documento"><button disabled={procesando === "proveedor"}>{procesando === "proveedor" ? "Guardando…" : "Guardar proveedor"}</button><button type="button" className="secondary" onClick={() => setProveedorForm(null)}>Cancelar</button></div></form></div>}

    {recibiendo && <div className="modal-operativo" role="dialog" aria-modal="true"><div className="modal-contenido ancho"><div className="header-row"><div><h3 style={{ margin: 0 }}>Recibir {recibiendo.numero}</h3><span className="conteo">{recibiendo.proveedor?.razon_social} → {recibiendo.almacen?.nombre}</span></div><button className="chip-limpiar" onClick={() => setRecibiendo(null)}>Cerrar</button></div><div className="info-box"><strong>Recepción parcial permitida:</strong> conforme entra al disponible; no conforme entra a cuarentena; lo que no registres continúa pendiente en la orden.</div><div className="tabla-scroll"><table><thead><tr><th>Producto</th><th className="num">Pendiente</th><th className="num">Conforme</th><th className="num">No conforme</th><th>Evidencia / observación</th></tr></thead><tbody>{recibiendo.lineas.map((l) => { const pendiente = l.cantidad_ordenada - l.cantidad_recibida - l.cantidad_no_conforme; const valor = recepcion[l.id] ?? { conforme: 0, noConforme: 0, observacion: "" }; return <tr key={l.id}><td><strong>{l.producto?.sku}</strong><div>{l.producto?.nombre}</div></td><td className="num">{pendiente}</td><td className="num"><input type="number" min={0} max={pendiente} value={valor.conforme} onChange={(e) => setRecepcion({ ...recepcion, [l.id]: { ...valor, conforme: Number(e.target.value) || 0 } })} style={{ width: 80 }} /></td><td className="num"><input type="number" min={0} max={pendiente} value={valor.noConforme} onChange={(e) => setRecepcion({ ...recepcion, [l.id]: { ...valor, noConforme: Number(e.target.value) || 0 } })} style={{ width: 80 }} /></td><td><input value={valor.observacion} onChange={(e) => setRecepcion({ ...recepcion, [l.id]: { ...valor, observacion: e.target.value } })} placeholder={valor.noConforme ? "Obligatoria" : "Opcional"} /></td></tr>; })}</tbody></table></div><div className="grid-2"><div className="field"><label>Factura, guía o acta del proveedor *</label><input value={documentoProveedor} onChange={(e) => setDocumentoProveedor(e.target.value)} /></div><div className="field"><label>Nota general</label><input value={notaRecepcion} onChange={(e) => setNotaRecepcion(e.target.value)} /></div></div><div className="acciones-documento"><button disabled={procesando === recibiendo.id} onClick={guardarRecepcion}>{procesando === recibiendo.id ? "Aplicando…" : "Confirmar recepción física"}</button><button className="secondary" onClick={() => setRecibiendo(null)}>Cancelar</button></div></div></div>}
    {gestionandoNoConforme && <div className="modal-operativo" role="dialog" aria-modal="true"><div className="modal-contenido"><div className="header-row"><div><h3 style={{ margin: 0 }}>Disposición de producto no conforme</h3><span className="conteo">{gestionandoNoConforme.linea.producto?.sku} · {gestionandoNoConforme.orden.numero}</span></div><button className="chip-limpiar" onClick={() => setGestionandoNoConforme(null)}>Cerrar</button></div><div className="error-box">Saldo en cuarentena de esta recepción: <strong>{gestionandoNoConforme.linea.cantidad_no_conforme - gestionandoNoConforme.linea.acciones.reduce((s, a) => s + a.cantidad, 0)}</strong> unidad(es).</div><div className="field"><label>Disposición final</label><select value={accionNoConforme} onChange={(e) => setAccionNoConforme(e.target.value as typeof accionNoConforme)}><option value="liberar_disponible">Conforme tras inspección: liberar al disponible</option><option value="devolver_proveedor">Devolver físicamente al proveedor</option>{perfil.rol === "admin" && <option value="baja">Baja definitiva</option>}</select></div><div className="field"><label>Cantidad</label><input type="number" min={1} max={gestionandoNoConforme.linea.cantidad_no_conforme - gestionandoNoConforme.linea.acciones.reduce((s, a) => s + a.cantidad, 0)} value={cantidadNoConforme} onChange={(e) => setCantidadNoConforme(Number(e.target.value) || 0)} /></div><div className="field"><label>Evidencia de inspección, devolución o baja *</label><textarea rows={4} value={detalleNoConforme} onChange={(e) => setDetalleNoConforme(e.target.value)} placeholder="Acta, guía de devolución, revisión técnica, responsable y resultado…" /></div><div className="acciones-documento"><button className={accionNoConforme === "baja" ? "peligro" : undefined} disabled={procesando === gestionandoNoConforme.linea.id} onClick={resolverNoConforme}>{procesando === gestionandoNoConforme.linea.id ? "Registrando…" : "Confirmar disposición"}</button><button className="secondary" onClick={() => setGestionandoNoConforme(null)}>Cancelar</button></div></div></div>}
  </>;
}
