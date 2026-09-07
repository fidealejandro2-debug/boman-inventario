"use client";

import { useEffect, useMemo, useState } from "react";
import QRCode from "qrcode";
import JsBarcode from "jsbarcode";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { mostrarAvisoDialogo, pedirMotivoDialogo } from "@/components/Dialogo";

type Codigo = {
  id: string;
  codigo: string;
  tipo: "ean13" | "upca" | "code128" | "qr" | "proveedor" | "interno";
  descripcion: string | null;
  principal: boolean;
};

type Props = {
  producto: { id: string; sku: string; nombre: string; talla?: string | null; color?: string | null };
  onCerrar: () => void;
};

const TIPOS: Array<{ valor: Codigo["tipo"]; nombre: string }> = [
  { valor: "ean13", nombre: "EAN-13" },
  { valor: "upca", nombre: "UPC-A" },
  { valor: "code128", nombre: "Code 128" },
  { valor: "proveedor", nombre: "Código del proveedor" },
  { valor: "interno", nombre: "Código interno" },
  { valor: "qr", nombre: "QR alterno" },
];

function svgBarcode(codigo: string, tipo: Codigo["tipo"]) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  try {
    JsBarcode(svg, codigo, {
      format: tipo === "ean13" ? "EAN13" : tipo === "upca" ? "UPC" : "CODE128",
      displayValue: true,
      margin: 8,
      height: 55,
      fontSize: 14,
    });
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(svg))}`;
  } catch {
    return "";
  }
}

function escaparHtml(valor: unknown) {
  return String(valor ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

export default function EtiquetasProducto({ producto, onCerrar }: Props) {
  const supabase = useMemo(() => createClient(), []);
  const [codigos, setCodigos] = useState<Codigo[]>([]);
  const [imagenes, setImagenes] = useState<Record<string, string>>({});
  const [codigo, setCodigo] = useState("");
  const [tipo, setTipo] = useState<Codigo["tipo"]>("code128");
  const [descripcion, setDescripcion] = useState("");
  const [principal, setPrincipal] = useState(false);
  const [cantidad, setCantidad] = useState(1);
  const [cargando, setCargando] = useState(true);
  const [procesando, setProcesando] = useState(false);

  async function cargar() {
    setCargando(true);
    const { data, error } = await supabase
      .from("vista_codigos_productos_v91")
      .select("id,codigo,tipo,descripcion,principal")
      .eq("producto_id", producto.id)
      .order("principal", { ascending: false })
      .order("created_at");
    setCargando(false);
    if (error) return mostrarAvisoDialogo(error.message, "No se pudieron cargar los códigos", true);
    setCodigos((data ?? []) as Codigo[]);
  }

  useEffect(() => { void cargar(); }, [producto.id]);

  useEffect(() => {
    let vigente = true;
    void (async () => {
      const siguientes: Record<string, string> = {};
      for (const item of codigos) {
        siguientes[item.id] = item.tipo === "qr"
          ? await QRCode.toDataURL(item.codigo, { width: 220, margin: 1, errorCorrectionLevel: "M" })
          : svgBarcode(item.codigo, item.tipo);
      }
      if (vigente) setImagenes(siguientes);
    })();
    return () => { vigente = false; };
  }, [codigos]);

  async function guardar() {
    const valor = codigo.trim();
    if (valor.length < 3) return mostrarAvisoDialogo("Escribe un código de al menos 3 caracteres.");
    if (tipo === "ean13" && !/^\d{13}$/.test(valor)) return mostrarAvisoDialogo("EAN-13 exige exactamente 13 dígitos.");
    if (tipo === "upca" && !/^\d{12}$/.test(valor)) return mostrarAvisoDialogo("UPC-A exige exactamente 12 dígitos.");
    const motivo = await pedirMotivoDialogo("Motivo para agregar este código al producto:", 5);
    if (!motivo) return;
    setProcesando(true);
    const { error } = await supabase.rpc("guardar_codigo_producto_v91", {
      p_producto_id: producto.id,
      p_codigo_id: null,
      p_codigo: valor,
      p_tipo: tipo,
      p_descripcion: descripcion.trim() || null,
      p_principal: principal,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) return mostrarAvisoDialogo(error.message, "No se pudo guardar el código", true);
    setCodigo(""); setDescripcion(""); setPrincipal(false);
    await cargar();
  }

  async function archivar(item: Codigo) {
    const motivo = await pedirMotivoDialogo(`Motivo para retirar el código ${item.codigo}:`, 5);
    if (!motivo) return;
    setProcesando(true);
    const { error } = await supabase.rpc("archivar_codigo_producto_v91", {
      p_codigo_id: item.id,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setProcesando(false);
    if (error) return mostrarAvisoDialogo(error.message, "No se pudo retirar el código", true);
    await cargar();
  }

  function imprimir(item: Codigo) {
    const imagen = imagenes[item.id];
    if (!imagen) return void mostrarAvisoDialogo("La etiqueta todavía se está generando.");
    const copias = Math.min(100, Math.max(1, cantidad));
    const ventana = window.open("", "_blank");
    if (!ventana) return void mostrarAvisoDialogo("El navegador bloqueó la ventana de impresión. Habilita ventanas emergentes para este sitio.");
    ventana.opener = null;
    const skuSeguro = escaparHtml(producto.sku);
    const nombreSeguro = escaparHtml(producto.nombre);
    const detalleSeguro = escaparHtml([producto.talla, producto.color].filter(Boolean).join(" · "));
    const codigoSeguro = escaparHtml(item.codigo);
    const imagenSegura = escaparHtml(imagen);
    const etiquetas = Array.from({ length: copias }, () => `
      <article class="etiqueta"><strong>${skuSeguro}</strong><span>${nombreSeguro}</span>
      <small>${detalleSeguro}</small>
      <img src="${imagenSegura}" alt="${codigoSeguro}"><b>${codigoSeguro}</b></article>`).join("");
    ventana.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Etiquetas ${skuSeguro}</title>
      <style>@page{margin:7mm}body{font-family:Arial;margin:0;display:grid;grid-template-columns:repeat(3,1fr);gap:4mm}.etiqueta{height:45mm;border:1px dashed #aaa;padding:3mm;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;break-inside:avoid}.etiqueta strong{font-size:13px}.etiqueta span{font-size:10px;max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.etiqueta small{font-size:9px;color:#555}.etiqueta img{max-width:100%;height:24mm;object-fit:contain}.etiqueta b{font-size:9px}</style></head><body>${etiquetas}<script>onload=()=>{print();setTimeout(()=>close(),300)}<\/script></body></html>`);
    ventana.document.close();
  }

  const principalActual = codigos.find((item) => item.principal) ?? codigos[0];

  return <div className="modal-operativo" role="dialog" aria-modal="true" aria-label={`Etiquetas de ${producto.nombre}`} onMouseDown={(e) => { if (e.target === e.currentTarget) onCerrar(); }}>
    <div className="modal-contenido ancho">
      <div className="header-row"><div><h2 style={{ margin: 0 }}>{producto.sku} · Etiquetas</h2><p className="conteo">QR interno permanente y códigos alternos para lectores USB o Bluetooth.</p></div><button className="secondary" onClick={onCerrar}>Cerrar</button></div>
      <div className="grid-form">
        <div className="field"><label>Nuevo código</label><input value={codigo} onChange={(e) => setCodigo(e.target.value)} placeholder="Escanea o escribe el código" /></div>
        <div className="field"><label>Tipo</label><select value={tipo} onChange={(e) => setTipo(e.target.value as Codigo["tipo"])}>{TIPOS.map((t) => <option value={t.valor} key={t.valor}>{t.nombre}</option>)}</select></div>
        <div className="field"><label>Descripción</label><input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} placeholder="Ej. etiqueta del proveedor" /></div>
        <label className="field" style={{ justifyContent: "flex-end" }}><span><input type="checkbox" checked={principal} onChange={(e) => setPrincipal(e.target.checked)} /> Usar como etiqueta principal</span></label>
      </div>
      <button onClick={guardar} disabled={procesando}>Agregar código</button>

      {cargando ? <div className="vacio">Cargando códigos…</div> : <div className="etiquetas-codigos">
        {codigos.map((item) => <article className="etiqueta-codigo" key={item.id}>
          <div>{imagenes[item.id] ? <img src={imagenes[item.id]} alt={`Código ${item.codigo}`} /> : <span>Generando…</span>}</div>
          <section><strong>{item.principal ? "Principal · " : ""}{item.tipo.toUpperCase()}</strong><b>{item.codigo}</b><small>{item.descripcion || "Sin descripción"}</small></section>
          <div className="acciones-en-fila"><button className="secondary" onClick={() => imprimir(item)}>Imprimir</button><button className="chip-limpiar" disabled={procesando || item.codigo === `BOMAN:P:${producto.id}`} onClick={() => archivar(item)}>Retirar</button></div>
        </article>)}
        {!codigos.length && <div className="vacio">No hay códigos. Ejecuta primero la migración v91.</div>}
      </div>}
      {principalActual && <div className="acciones-documento"><div className="field"><label>Copias</label><input type="number" min={1} max={100} value={cantidad} onChange={(e) => setCantidad(Number(e.target.value) || 1)} style={{ width: 90 }} /></div><button onClick={() => imprimir(principalActual)}>Imprimir etiqueta principal</button></div>}
    </div>
  </div>;
}
