"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { dinero, soloFecha, ETIQUETA_NOVEDAD } from "./lib";

type Impresion = {
  novedad_id: string;
  referencia: string;
  tipo: string;
  estado: string;
  fecha_hechos: string;
  fecha_emision: string | null;
  empresa: string;
  ruc: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  area: string | null;
  fecha_ingreso_real: string;
  asunto: string;
  hechos: string;
  base_reglamento: string | null;
  base_legal: string | null;
  descargo_empleado: string | null;
  resolucion: string | null;
  genera_descuento: boolean;
  monto_descuento: number | null;
  evidencias: number;
  sanciones_ultimo_anio: number;
};

export default function NovedadImpresion({
  novedadId,
  onCerrar,
}: {
  novedadId: string;
  onCerrar: () => void;
}) {
  const supabase = createClient();
  const [doc, setDoc] = useState<Impresion | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data, error } = await supabase
        .from("vista_novedad_impresion_v28")
        .select("*")
        .eq("novedad_id", novedadId)
        .single();
      if (error) setError(error.message);
      else setDoc(data as Impresion);
    })();
  }, [supabase, novedadId]);

  if (error) return <p className="error">No se pudo cargar el documento: {error}</p>;
  if (!doc) return <p className="ayuda">Preparando documento…</p>;

  const titulo = (ETIQUETA_NOVEDAD[doc.tipo] ?? doc.tipo).toUpperCase();

  return (
    <>
      <div className="no-imprimir filtros">
        <button onClick={() => window.print()}>Imprimir</button>
        <button className="secondary" onClick={onCerrar}>
          Volver
        </button>
      </div>

      <article className="documento-imprimible">
        <header>
          <h1>{titulo}</h1>
          <p className="doc-ref">
            N.º {doc.referencia} · {doc.empresa} · RUC {doc.ruc}
          </p>
          <p className="doc-ref">
            Ambato, {soloFecha(doc.fecha_emision ?? doc.fecha_hechos)}
          </p>
        </header>

        <section>
          <h2>Datos del trabajador</h2>
          <dl className="doc-datos">
            <div>
              <dt>Nombre</dt>
              <dd>{doc.nombre_completo}</dd>
            </div>
            <div>
              <dt>Cédula</dt>
              <dd>{doc.identificacion}</dd>
            </div>
            <div>
              <dt>Cargo</dt>
              <dd>{doc.cargo ?? "—"}</dd>
            </div>
            <div>
              <dt>Área</dt>
              <dd>{doc.area ?? "—"}</dd>
            </div>
            <div>
              <dt>Fecha de ingreso</dt>
              <dd>{soloFecha(doc.fecha_ingreso_real)}</dd>
            </div>
            <div>
              <dt>Fecha de los hechos</dt>
              <dd>{soloFecha(doc.fecha_hechos)}</dd>
            </div>
          </dl>
        </section>

        <section>
          <h2>Asunto</h2>
          <p>{doc.asunto}</p>
        </section>

        <section>
          <h2>Hechos</h2>
          <p className="doc-parrafo">{doc.hechos}</p>
        </section>

        {(doc.base_reglamento || doc.base_legal) && (
          <section>
            <h2>Fundamento</h2>
            {doc.base_reglamento && (
              <p>
                <strong>Reglamento interno:</strong> {doc.base_reglamento}
              </p>
            )}
            {doc.base_legal && (
              <p>
                <strong>Base legal:</strong> {doc.base_legal}
              </p>
            )}
          </section>
        )}

        {doc.genera_descuento && (
          <section>
            <h2>Sanción económica</h2>
            <p>
              Se aplica una multa de <strong>{dinero(doc.monto_descuento)}</strong>,
              descontable de la remuneración conforme al reglamento interno vigente.
            </p>
          </section>
        )}

        {doc.descargo_empleado && (
          <section>
            <h2>Descargo del trabajador</h2>
            <p className="doc-parrafo">{doc.descargo_empleado}</p>
          </section>
        )}

        {doc.resolucion && (
          <section>
            <h2>Resolución</h2>
            <p className="doc-parrafo">{doc.resolucion}</p>
          </section>
        )}

        {!doc.descargo_empleado && (
          <section>
            <h2>Descargo</h2>
            <p className="ayuda-doc">
              El trabajador puede presentar su descargo por escrito dentro del plazo
              previsto en el reglamento interno.
            </p>
            <div className="doc-lineas-descargo">
              <span />
              <span />
              <span />
            </div>
          </section>
        )}

        <section className="doc-firmas">
          <div>
            <span className="linea-firma" />
            <p>Por el empleador</p>
            <p className="doc-ref">{doc.empresa}</p>
          </div>
          <div>
            <span className="linea-firma" />
            <p>Recibí conforme</p>
            <p className="doc-ref">
              {doc.nombre_completo} · C.I. {doc.identificacion}
            </p>
          </div>
        </section>

        <footer className="doc-pie">
          <p>
            Documento {doc.referencia} generado por el sistema de nómina.
            {doc.evidencias > 0 && ` Adjunta ${doc.evidencias} evidencia(s).`}
            {doc.sanciones_ultimo_anio > 1 &&
              ` El trabajador registra ${doc.sanciones_ultimo_anio} sanciones en los últimos 12 meses.`}
          </p>
        </footer>
      </article>
    </>
  );
}
