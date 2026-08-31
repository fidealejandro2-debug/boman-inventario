// Subida y consulta de documentos del expediente.
//
// El bucket 'expedientes' es privado (v26). La ruta debe ser exactamente
// `empleados/<empleado_id>/<archivo>`: registrar_documento_empleado_v26
// rechaza cualquier otra forma, incluidas las subcarpetas.

import { createClient } from "@/lib/supabase/client";

export const BUCKET = "expedientes";

export const TIPOS_DOCUMENTO: { valor: string; etiqueta: string }[] = [
  { valor: "hoja_vida", etiqueta: "Hoja de vida" },
  { valor: "cedula", etiqueta: "Cédula" },
  { valor: "papeleta_votacion", etiqueta: "Papeleta de votación" },
  { valor: "contrato", etiqueta: "Contrato" },
  { valor: "adendum", etiqueta: "Adendum" },
  { valor: "titulo", etiqueta: "Título" },
  { valor: "certificado_laboral", etiqueta: "Certificado laboral" },
  { valor: "certificado_medico", etiqueta: "Certificado médico" },
  { valor: "antecedentes", etiqueta: "Antecedentes" },
  { valor: "firma", etiqueta: "Firma" },
  { valor: "foto", etiqueta: "Foto" },
  { valor: "aviso_entrada_iess", etiqueta: "Aviso de entrada IESS" },
  { valor: "acta_finiquito", etiqueta: "Acta de finiquito" },
  { valor: "carga_familiar", etiqueta: "Carga familiar" },
  { valor: "otro", etiqueta: "Otro" },
];

export const ETIQUETA_DOCUMENTO: Record<string, string> = Object.fromEntries(
  TIPOS_DOCUMENTO.map((t) => [t.valor, t.etiqueta])
);

export const TAMANO_MAXIMO = 10 * 1024 * 1024; // 10 MB

export type DocumentoEmpleado = {
  id: string;
  empleado_id: string;
  tipo: string;
  nombre: string;
  storage_path: string;
  mime: string | null;
  tamano_bytes: number | null;
  fecha_emision: string | null;
  fecha_caducidad: string | null;
  activo: boolean;
  motivo_baja: string | null;
  created_at: string;
};

export function tamanoLegible(bytes: number | null): string {
  if (!bytes) return "—";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

// Conserva la extensión y descarta el resto del nombre original: el nombre
// legible se guarda aparte, en la fila.
function rutaSegura(empleadoId: string, archivo: File): string {
  const ext = archivo.name.includes(".")
    ? archivo.name.split(".").pop()!.toLowerCase().replace(/[^a-z0-9]/g, "")
    : "bin";
  const id =
    typeof crypto !== "undefined" && crypto.randomUUID
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return `empleados/${empleadoId}/${id}.${ext || "bin"}`;
}

/**
 * Sube el archivo al bucket privado y registra su metadata.
 * Si el registro falla, borra el archivo recién subido para no dejar
 * huérfanos en el bucket.
 */
export async function subirDocumento(params: {
  empleadoId: string;
  archivo: File;
  tipo: string;
  nombre: string;
  fechaEmision?: string | null;
  fechaCaducidad?: string | null;
}): Promise<{ documentoId?: string; error?: string }> {
  const { empleadoId, archivo, tipo, nombre } = params;

  if (archivo.size > TAMANO_MAXIMO) {
    return { error: `El archivo supera los ${TAMANO_MAXIMO / 1024 / 1024} MB.` };
  }
  if (!nombre.trim()) return { error: "Ponle un nombre al documento." };

  const supabase = createClient();
  const path = rutaSegura(empleadoId, archivo);

  const { error: errSubida } = await supabase.storage
    .from(BUCKET)
    .upload(path, archivo, { contentType: archivo.type || undefined, upsert: false });
  if (errSubida) return { error: `No se pudo subir el archivo: ${errSubida.message}` };

  const { data, error } = await supabase.rpc("registrar_documento_empleado_v26", {
    p_empleado_id: empleadoId,
    p_tipo: tipo,
    p_nombre: nombre.trim(),
    p_storage_path: path,
    p_mime: archivo.type || null,
    p_tamano_bytes: archivo.size,
    p_fecha_emision: params.fechaEmision || null,
    p_fecha_caducidad: params.fechaCaducidad || null,
  });

  if (error) {
    // Sin fila que lo referencie, el archivo solo estorbaría en el bucket.
    await supabase.storage.from(BUCKET).remove([path]);
    return { error: error.message };
  }
  return { documentoId: data as string };
}

/** URL firmada de corta duración: el bucket nunca se expone público. */
export async function urlDocumento(path: string, segundos = 120) {
  const supabase = createClient();
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(path, segundos);
  return { url: data?.signedUrl, error: error?.message };
}

export async function documentosDe(empleadoId: string, soloActivos = true) {
  const supabase = createClient();
  let q = supabase
    .from("empleado_documentos")
    .select("*")
    .eq("empleado_id", empleadoId)
    .order("created_at", { ascending: false });
  if (soloActivos) q = q.eq("activo", true);
  const { data, error } = await q;
  return { documentos: (data as DocumentoEmpleado[]) ?? [], error: error?.message };
}
