"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { fecha as fmtFecha } from "@/lib/utils";
import type { Franquicia } from "./FranquiciaCliente";

type AlertaFranquicia = {
  documento_id: string;
  numero: string;
  tipo_alerta: "solicitud_aprobada" | "transferencia_despachada" | "pendiente_recepcion";
  estado: string;
  titulo: string;
  detalle: string;
  prioridad: string;
  updated_at: string;
};

const TIPOS = [
  { id: "solicitud_aprobada", etiqueta: "Solicitudes aprobadas" },
  { id: "transferencia_despachada", etiqueta: "Despachadas" },
  { id: "pendiente_recepcion", etiqueta: "Pendientes de recibir" },
] as const;

export default function AlertasFranquicia({ franquicia }: { franquicia: Franquicia }) {
  const supabase = useMemo(() => createClient(), []);
  const [alertas, setAlertas] = useState<AlertaFranquicia[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    const { data, error } = await supabase
      .from("vista_alertas_franquicia_v47")
      .select("documento_id, numero, tipo_alerta, estado, titulo, detalle, prioridad, updated_at")
      .eq("franquicia_id", franquicia.id)
      .order("updated_at", { ascending: false });
    if (error) setError(error.message);
    else {
      setError(null);
      setAlertas((data as AlertaFranquicia[]) ?? []);
    }
    setCargando(false);
  }, [franquicia.id, supabase]);

  useEffect(() => {
    cargar();
    const timer = window.setInterval(cargar, 60_000);
    return () => window.clearInterval(timer);
  }, [cargar]);

  const cantidades = useMemo(
    () =>
      Object.fromEntries(
        TIPOS.map((tipo) => [
          tipo.id,
          alertas.filter((alerta) => alerta.tipo_alerta === tipo.id).length,
        ])
      ),
    [alertas]
  );

  if (cargando && !alertas.length) return <p className="ayuda">Cargando alertas...</p>;

  return (
    <>
      {error && <p className="error">No se pudieron cargar las alertas: {error}</p>}

      <div className="kpis">
        {TIPOS.map((tipo) => (
          <div key={tipo.id} className={`kpi ${cantidades[tipo.id] ? "alerta" : ""}`}>
            <span className="valor">{cantidades[tipo.id] ?? 0}</span>
            <span className="label">{tipo.etiqueta}</span>
          </div>
        ))}
      </div>

      <div className="filtros">
        <p className="ayuda">
          Se actualizan automaticamente cada minuto segun el estado de Operaciones.
        </p>
        <button className="secondary" onClick={cargar} disabled={cargando}>
          {cargando ? "Actualizando..." : "Actualizar"}
        </button>
        <Link href="/operaciones">Abrir Operaciones</Link>
      </div>

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Documento</th>
              <th>Alerta</th>
              <th>Detalle</th>
              <th>Estado</th>
              <th>Prioridad</th>
              <th>Actualizada</th>
            </tr>
          </thead>
          <tbody>
            {alertas.map((alerta) => (
              <tr key={`${alerta.tipo_alerta}-${alerta.documento_id}`}>
                <td><strong>{alerta.numero}</strong></td>
                <td>{alerta.titulo}</td>
                <td>{alerta.detalle}</td>
                <td><span className={`badge estado-${alerta.estado}`}>{alerta.estado}</span></td>
                <td>{alerta.prioridad}</td>
                <td>{fmtFecha(alerta.updated_at)}</td>
              </tr>
            ))}
            {!alertas.length && (
              <tr>
                <td colSpan={6} className="vacio">
                  No hay solicitudes aprobadas ni mercaderia pendiente de recibir.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
