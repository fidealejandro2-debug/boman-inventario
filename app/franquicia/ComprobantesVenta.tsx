"use client";

// Pantalla de revisión: comprobantes de pago por transferencia de TODAS las
// tiendas propias y franquicias, en un solo lugar. Mismo patrón que
// app/conteos/ConteosCliente.tsx (gate de permiso en el server, un
// Promise.all acá, un booleano de "veo todo" por rol/permiso). La lectura
// de cada tabla base ya respeta RLS (vista_comprobantes_venta_pendientes_v150
// es security_invoker), así que aquí no hay que repetir la lógica de quién
// puede ver qué -si la vista devuelve la fila, este usuario puede verla.

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { dinero, mensajeError } from "./lib";
import { mostrarAvisoDialogo } from "@/components/Dialogo";

const BUCKET_COMPROBANTES_VENTA = "ventas-comprobantes";

type Fila = {
  origen: "tienda" | "franquicia";
  pago_id: string;
  venta_id: string;
  almacen_id: string;
  almacen_nombre: string;
  franquicia_id: string | null;
  franquicia_nombre: string | null;
  fecha: string;
  numero: number;
  detalle: string;
  monto: number;
  referencia: string | null;
  comprobante_storage_path: string | null;
  comprobante_nombre: string | null;
  comprobante_mime_type: string | null;
  created_at: string;
  creada_por_nombre: string | null;
};

export default function ComprobantesVenta() {
  const supabase = useMemo(() => createClient(), []);
  const [filas, setFilas] = useState<Fila[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busqueda, setBusqueda] = useState("");
  const [soloSinComprobante, setSoloSinComprobante] = useState(false);
  const [abriendo, setAbriendo] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      setCargando(true);
      const { data, error: fallo } = await supabase
        .from("vista_comprobantes_venta_pendientes_v150")
        .select("*")
        .order("fecha", { ascending: false })
        .order("created_at", { ascending: false })
        .limit(500);
      if (fallo) setError(mensajeError(fallo));
      else setFilas((data as Fila[]) ?? []);
      setCargando(false);
    })();
  }, [supabase]);

  const visibles = useMemo(() => {
    const q = busqueda.trim().toLocaleLowerCase("es");
    return filas.filter((f) => {
      if (soloSinComprobante && f.comprobante_storage_path) return false;
      if (!q) return true;
      return `${f.almacen_nombre} ${f.franquicia_nombre ?? ""} ${f.detalle} ${f.referencia ?? ""} ${f.creada_por_nombre ?? ""}`
        .toLocaleLowerCase("es").includes(q);
    });
  }, [filas, busqueda, soloSinComprobante]);

  async function abrir(f: Fila) {
    if (!f.comprobante_storage_path) return;
    setAbriendo(f.pago_id);
    const ventana = window.open("", "_blank");
    const { data, error: fallo } = await supabase.storage
      .from(BUCKET_COMPROBANTES_VENTA)
      .createSignedUrl(f.comprobante_storage_path, 300);
    setAbriendo(null);
    if (fallo || !data?.signedUrl) {
      ventana?.close();
      await mostrarAvisoDialogo(fallo?.message ?? "No se pudo abrir el comprobante.", "Error", true);
      return;
    }
    if (ventana) {
      ventana.opener = null;
      ventana.location.href = data.signedUrl;
    } else {
      await mostrarAvisoDialogo("El navegador bloqueó la nueva pestaña. Habilita ventanas emergentes para abrir el comprobante.", "Ventana bloqueada", true);
    }
  }

  const sinComprobante = filas.filter((f) => !f.comprobante_storage_path).length;

  return (
    <div className="card">
      <h2>Comprobantes de venta</h2>
      <p className="ayuda">
        Todos los pagos por transferencia registrados en Venta rápida (tiendas propias) y en
        Ventas de franquicia, con su comprobante adjunto. Las ventas nuevas ya exigen el
        comprobante; esta lista puede incluir alguna venta antigua sin él.
      </p>

      {error && <div className="error-box">{error}</div>}

      <div className="filtros">
        <label className="buscador">
          Buscar
          <input value={busqueda} onChange={(e) => setBusqueda(e.target.value)} placeholder="Local, franquicia, referencia, vendedor…" />
        </label>
        <label style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <input type="checkbox" checked={soloSinComprobante} onChange={(e) => setSoloSinComprobante(e.target.checked)} />
          Solo sin comprobante
        </label>
      </div>

      {sinComprobante > 0 && (
        <div className="info-box">{sinComprobante} transferencia(s) sin comprobante adjunto (anteriores a esta exigencia).</div>
      )}

      {cargando ? (
        <div className="vacio">Cargando…</div>
      ) : !visibles.length ? (
        <div className="vacio">No hay comprobantes que coincidan con la búsqueda.</div>
      ) : (
        <div className="tabla-scroll">
          <table>
            <thead>
              <tr>
                <th>Origen</th><th>Local</th><th>Fecha</th><th>Detalle</th>
                <th className="num">Monto</th><th>Referencia</th><th>Registrado por</th><th>Comprobante</th>
              </tr>
            </thead>
            <tbody>
              {visibles.map((f) => (
                <tr key={f.pago_id} className={!f.comprobante_storage_path ? "fila-alerta-suave" : ""}>
                  <td>{f.origen === "tienda" ? "Tienda propia" : "Franquicia"}</td>
                  <td>{f.almacen_nombre}{f.franquicia_nombre ? ` · ${f.franquicia_nombre}` : ""}</td>
                  <td>{f.fecha.split("-").reverse().join("/")}</td>
                  <td>{f.detalle}</td>
                  <td className="num">{dinero(f.monto)}</td>
                  <td>{f.referencia ?? "—"}</td>
                  <td>{f.creada_por_nombre ?? "—"}</td>
                  <td>
                    {f.comprobante_storage_path ? (
                      <button type="button" className="secondary btn-mini" onClick={() => abrir(f)} disabled={abriendo === f.pago_id}>
                        {abriendo === f.pago_id ? "Abriendo…" : "Ver"}
                      </button>
                    ) : (
                      <span className="badge bajo">Sin adjuntar</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
