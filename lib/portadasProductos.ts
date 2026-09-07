import type { SupabaseClient } from "@supabase/supabase-js";

export type PortadaProducto = {
  imagenId: string;
  storagePath: string;
  url: string;
  descripcion: string | null;
};

type FilaPortada = {
  producto_id: string;
  imagen_id: string;
  storage_path: string;
  descripcion: string | null;
};

/**
 * Firma las portadas por lotes. Así el inventario no hace una consulta y una
 * petición de Storage por cada renglón visible.
 */
export async function cargarPortadasProductos(
  supabase: SupabaseClient
): Promise<Map<string, PortadaProducto>> {
  const { data, error } = await supabase
    .from("vista_portadas_productos_v88")
    .select("producto_id,imagen_id,storage_path,descripcion");
  if (error) throw error;

  const filas = (data ?? []) as FilaPortada[];
  const resultado = new Map<string, PortadaProducto>();
  for (let inicio = 0; inicio < filas.length; inicio += 100) {
    const lote = filas.slice(inicio, inicio + 100);
    const { data: firmadas, error: errorFirma } = await supabase.storage
      .from("imagenes-entidades")
      .createSignedUrls(lote.map((fila) => fila.storage_path), 3600);
    if (errorFirma) throw errorFirma;

    const porPath = new Map(
      (firmadas ?? []).map((firma) => [firma.path, firma.signedUrl])
    );
    lote.forEach((fila) => {
      const url = porPath.get(fila.storage_path);
      if (!url) return;
      resultado.set(fila.producto_id, {
        imagenId: fila.imagen_id,
        storagePath: fila.storage_path,
        url,
        descripcion: fila.descripcion,
      });
    });
  }
  return resultado;
}
