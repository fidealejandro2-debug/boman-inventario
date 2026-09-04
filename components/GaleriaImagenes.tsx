"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { pedirTextoDialogo } from "@/components/Dialogo";

type Imagen = {
  id: string;
  storage_path: string;
  nombre_archivo: string;
  descripcion: string | null;
  es_portada: boolean;
  created_at: string;
  url?: string;
};

type Props = {
  entidadTipo: "producto" | "activo";
  entidadId: string;
  titulo: string;
  puedeEditar: boolean;
};

const LIMITE_BYTES = 5 * 1024 * 1024;
const TIPOS = ["image/jpeg", "image/png", "image/webp"];

async function cargarEnImagen(file: File) {
  const url = URL.createObjectURL(file);
  try {
    const imagen = new Image();
    await new Promise<void>((resolve, reject) => {
      imagen.onload = () => resolve();
      imagen.onerror = () => reject(new Error("No se pudo leer la imagen."));
      imagen.src = url;
    });
    return imagen;
  } finally {
    // Se revoca despues de que el navegador termino de decodificarla.
    URL.revokeObjectURL(url);
  }
}

async function optimizarFoto(file: File): Promise<File> {
  if (!file.type.startsWith("image/")) throw new Error(`${file.name} no es una imagen.`);
  const imagen = await cargarEnImagen(file);
  const escala = Math.min(1, 1800 / Math.max(imagen.naturalWidth, imagen.naturalHeight));
  const ancho = Math.max(1, Math.round(imagen.naturalWidth * escala));
  const alto = Math.max(1, Math.round(imagen.naturalHeight * escala));
  const canvas = document.createElement("canvas");
  canvas.width = ancho;
  canvas.height = alto;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("El navegador no pudo preparar la foto.");
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, ancho, alto);
  ctx.drawImage(imagen, 0, 0, ancho, alto);
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.82));
  if (!blob) throw new Error("No se pudo comprimir la foto.");

  // Conserva el original si ya es pequeno y la recompresion lo agrandaria.
  if (TIPOS.includes(file.type) && file.size <= LIMITE_BYTES && file.size <= blob.size) return file;
  const base = file.name.replace(/\.[^.]+$/, "") || "foto";
  return new File([blob], `${base}.jpg`, { type: "image/jpeg", lastModified: Date.now() });
}

export default function GaleriaImagenes({ entidadTipo, entidadId, titulo, puedeEditar }: Props) {
  const supabase = useMemo(() => createClient(), []);
  const camaraRef = useRef<HTMLInputElement>(null);
  const galeriaRef = useRef<HTMLInputElement>(null);
  const [imagenes, setImagenes] = useState<Imagen[]>([]);
  const [descripcion, setDescripcion] = useState("");
  const [cargando, setCargando] = useState(true);
  const [subiendo, setSubiendo] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);

  async function cargar() {
    setCargando(true);
    const { data, error: consultaError } = await supabase
      .from("imagenes_entidades")
      .select("id,storage_path,nombre_archivo,descripcion,es_portada,created_at")
      .eq("entidad_tipo", entidadTipo)
      .eq("entidad_id", entidadId)
      .eq("estado", "activa")
      .order("es_portada", { ascending: false })
      .order("created_at", { ascending: true });
    if (consultaError) {
      setError(consultaError.message);
      setImagenes([]);
      setCargando(false);
      return;
    }
    const filas = (data ?? []) as Imagen[];
    const firmadas = await Promise.all(filas.map(async (fila) => {
      const { data: firma } = await supabase.storage
        .from("imagenes-entidades")
        .createSignedUrl(fila.storage_path, 3600);
      return { ...fila, url: firma?.signedUrl };
    }));
    setImagenes(firmadas);
    setCargando(false);
  }

  useEffect(() => { cargar(); }, [entidadId, entidadTipo]);

  async function subirArchivos(files: FileList | null) {
    if (!files?.length) return;
    setSubiendo(true); setError(null); setMensaje(null);
    let completadas = 0;
    for (const original of Array.from(files).slice(0, 10)) {
      try {
        const archivo = await optimizarFoto(original);
        if (archivo.size > LIMITE_BYTES) throw new Error(`${original.name} supera 5 MB aun despues de comprimirla.`);
        const { data: preparada, error: prepararError } = await supabase.rpc("preparar_imagen_entidad_v80", {
          p_entidad_tipo: entidadTipo,
          p_entidad_id: entidadId,
          p_nombre_archivo: original.name,
          p_mime_type: archivo.type,
          p_tamano_bytes: archivo.size,
          p_descripcion: descripcion.trim() || null,
          p_es_portada: imagenes.length + completadas === 0,
          p_idempotency_key: nuevaClaveIdempotencia(),
        });
        if (prepararError) throw prepararError;
        const preparadaObj = preparada as { id: string; path: string };
        const { error: subidaError } = await supabase.storage
          .from("imagenes-entidades")
          .upload(preparadaObj.path, archivo, { contentType: archivo.type, upsert: false });
        if (subidaError) throw subidaError;
        const { error: confirmarError } = await supabase.rpc("confirmar_imagen_entidad_v80", {
          p_imagen_id: preparadaObj.id,
        });
        if (confirmarError) throw confirmarError;
        completadas += 1;
      } catch (e) {
        setError(e instanceof Error ? e.message : "No se pudo subir una de las fotos.");
        break;
      }
    }
    if (completadas) {
      setDescripcion("");
      setMensaje(`${completadas} foto(s) guardada(s).`);
      await cargar();
    }
    setSubiendo(false);
    if (camaraRef.current) camaraRef.current.value = "";
    if (galeriaRef.current) galeriaRef.current.value = "";
  }

  async function hacerPortada(imagen: Imagen) {
    setError(null); setMensaje(null);
    const { error: cambioError } = await supabase.rpc("establecer_portada_imagen_v80", {
      p_imagen_id: imagen.id,
    });
    if (cambioError) return setError(cambioError.message);
    setMensaje("Foto de portada actualizada.");
    await cargar();
  }

  async function archivar(imagen: Imagen) {
    const motivo = await pedirTextoDialogo("Motivo para retirar esta foto:", "Foto reemplazada");
    if (!motivo?.trim()) return;
    setError(null); setMensaje(null);
    const { error: archivoError } = await supabase.rpc("archivar_imagen_entidad_v80", {
      p_imagen_id: imagen.id,
      p_motivo: motivo.trim(),
    });
    if (archivoError) return setError(archivoError.message);
    setMensaje("Foto retirada de la galeria.");
    await cargar();
  }

  return <section style={{ marginTop: 14, borderTop: "1px solid #dbe3ee", paddingTop: 14 }}>
    <div className="header-row">
      <div><h3 style={{ margin: 0 }}>Fotos de {titulo}</h3><p className="conteo">Bucket privado · JPG, PNG o WebP · maximo 5 MB.</p></div>
      {puedeEditar && <div style={{ display: "flex", gap: 7, flexWrap: "wrap" }}>
        <button type="button" onClick={() => camaraRef.current?.click()} disabled={subiendo}>Tomar foto</button>
        <button type="button" className="secondary" onClick={() => galeriaRef.current?.click()} disabled={subiendo}>Elegir imagenes</button>
        <input ref={camaraRef} hidden type="file" accept="image/*" capture="environment" onChange={(e) => subirArchivos(e.target.files)} />
        <input ref={galeriaRef} hidden type="file" accept="image/jpeg,image/png,image/webp" multiple onChange={(e) => subirArchivos(e.target.files)} />
      </div>}
    </div>
    {puedeEditar && <div className="field" style={{ margin: "10px 0" }}><label>Descripcion opcional para las nuevas fotos</label><input value={descripcion} onChange={(e) => setDescripcion(e.target.value)} placeholder="Ej. Vista frontal, placa de serie o detalle del producto" /></div>}
    {error && <div className="error-box">{error}</div>}
    {mensaje && <div className="success-box">{mensaje}</div>}
    {subiendo && <div className="vacio">Optimizando y subiendo foto…</div>}
    {cargando ? <div className="vacio">Cargando fotos…</div> : imagenes.length ?
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(150px,1fr))", gap: 10, marginTop: 10 }}>
        {imagenes.map((imagen) => <article key={imagen.id} style={{ border: imagen.es_portada ? "2px solid #2e75b6" : "1px solid #dbe3ee", borderRadius: 10, overflow: "hidden", background: "#fff" }}>
          {imagen.url ? <a href={imagen.url} target="_blank" rel="noreferrer"><img src={imagen.url} alt={imagen.descripcion || titulo} style={{ width: "100%", height: 140, objectFit: "cover", display: "block" }} /></a> : <div className="vacio" style={{ height: 140 }}>Vista no disponible</div>}
          <div style={{ padding: 8 }}>
            <strong style={{ fontSize: 12 }}>{imagen.es_portada ? "Portada" : imagen.descripcion || "Foto"}</strong>
            {imagen.descripcion && imagen.es_portada && <small style={{ display: "block" }}>{imagen.descripcion}</small>}
            {puedeEditar && <div style={{ display: "flex", gap: 5, marginTop: 7, flexWrap: "wrap" }}>
              {!imagen.es_portada && <button type="button" className="secondary" style={{ padding: "4px 7px", fontSize: 11 }} onClick={() => hacerPortada(imagen)}>Portada</button>}
              <button type="button" className="chip-limpiar" style={{ padding: "4px 7px", fontSize: 11 }} onClick={() => archivar(imagen)}>Retirar</button>
            </div>}
          </div>
        </article>)}
      </div> : <div className="vacio">Todavia no hay fotos.</div>}
  </section>;
}
