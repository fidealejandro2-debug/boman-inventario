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

// Cada tipo de novedad usa su propio codigo del sistema de gestion de
// calidad, igual que el formato en papel que ya usa Talento Humano.
const FORMATO: Record<string, { codigo: string; titulo: string; subtitulo: string }> = {
  llamado_atencion: {
    codigo: "BOM-TH-LA-01",
    titulo: "COMUNICACIÓN DE LLAMADO DE ATENCIÓN",
    subtitulo: "Amonestación Por Escrito — Primera Instancia",
  },
  amonestacion_escrita: {
    codigo: "BOM-TH-AE-01",
    titulo: "AMONESTACIÓN ESCRITA",
    subtitulo: "Amonestación Por Escrito — Segunda Instancia",
  },
  memorando: {
    codigo: "BOM-TH-ME-01",
    titulo: "MEMORANDO",
    subtitulo: "Comunicación Interna de Talento Humano",
  },
  acta_compromiso: {
    codigo: "BOM-TH-AC-01",
    titulo: "ACTA DE COMPROMISO",
    subtitulo: "Acuerdo de Mejora — Talento Humano",
  },
  felicitacion: {
    codigo: "BOM-TH-FE-01",
    titulo: "RECONOCIMIENTO",
    subtitulo: "Felicitación por Desempeño",
  },
  sancion_economica: {
    codigo: "BOM-TH-SE-01",
    titulo: "SANCIÓN ECONÓMICA",
    subtitulo: "Multa Prevista en el Reglamento Interno",
  },
  solicitud_visto_bueno: {
    codigo: "BOM-TH-VB-01",
    titulo: "SOLICITUD DE VISTO BUENO",
    subtitulo: "Trámite ante la Inspectoría del Trabajo",
  },
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

  const fmt = FORMATO[doc.tipo] ?? {
    codigo: "BOM-TH-GE-01",
    titulo: (ETIQUETA_NOVEDAD[doc.tipo] ?? doc.tipo).toUpperCase(),
    subtitulo: "Gestión de Talento Humano",
  };
  const esFelicitacion = doc.tipo === "felicitacion";

  return (
    <>
      <div className="no-imprimir filtros">
        <button onClick={() => window.print()}>Imprimir</button>
        <button className="secondary" onClick={onCerrar}>
          Volver
        </button>
      </div>

      <article className="doc-th">
        {/* Encabezado institucional */}
        <table className="doc-th-cab">
          <tbody>
            <tr>
              <td className="dth-logo">
                <span className="dth-marca">BOMAN</span>
                <span className="dth-marca-sub">SPORT</span>
              </td>
              <td className="dth-titulo">
                <div className="dth-t1">{fmt.titulo}</div>
                <div className="dth-t2">{fmt.subtitulo}</div>
              </td>
              <td className="dth-meta">
                <div>Código: {fmt.codigo}</div>
                <div>Versión: v01</div>
                <div>Proceso: Gestión de Talento Humano</div>
              </td>
            </tr>
            <tr className="dth-cab2">
              <td>
                <strong>Fecha de emisión:</strong>{" "}
                {soloFecha(doc.fecha_emision ?? doc.fecha_hechos)}
              </td>
              <td>N.º {doc.referencia}</td>
              <td className="dth-conf">■ CONFIDENCIAL</td>
            </tr>
          </tbody>
        </table>

        {/* Datos del colaborador */}
        <div className="dth-banda">DATOS DEL COLABORADOR/A</div>
        <table className="dth-datos">
          <tbody>
            <tr>
              <th>Nombres y Apellidos:</th>
              <td>{doc.nombre_completo}</td>
            </tr>
            <tr>
              <th>Cédula de Identidad:</th>
              <td>{doc.identificacion}</td>
            </tr>
            <tr>
              <th>Cargo / Área:</th>
              <td>
                {doc.cargo ?? "—"}
                {doc.area ? ` / ${doc.area}` : ""}
              </td>
            </tr>
            <tr>
              <th>Fecha de ingreso:</th>
              <td>{soloFecha(doc.fecha_ingreso_real)}</td>
            </tr>
            <tr>
              <th>Empresa:</th>
              <td>
                {doc.empresa} · RUC {doc.ruc}
              </td>
            </tr>
          </tbody>
        </table>

        <p className="dth-intro">
          <strong>Estimado/a colaborador/a,</strong>
          <br />
          {esFelicitacion
            ? "BOMAN reconoce y agradece su aporte. Este documento deja constancia formal de un desempeño que la organización valora y quiere destacar."
            : "BOMAN valora profundamente la presencia y el aporte de cada colaborador/a. Este documento no es una sanción: es una herramienta de acompañamiento institucional, y busca dejar constancia de una situación que conviene corregir para el bienestar del equipo y la continuidad de los procesos productivos."}
        </p>

        {/* Asunto y hechos */}
        <div className="dth-banda">ASUNTO</div>
        <p className="dth-p">{doc.asunto}</p>

        <div className="dth-banda">
          {esFelicitacion ? "MOTIVO DEL RECONOCIMIENTO" : "SITUACIONES OBSERVADAS"}
        </div>
        <p className="dth-p dth-pre">{doc.hechos}</p>
        <p className="dth-fecha-hechos">
          Fecha de los hechos: <strong>{soloFecha(doc.fecha_hechos)}</strong>
        </p>

        {(doc.base_reglamento || doc.base_legal) && (
          <>
            <div className="dth-banda">DISPOSICIONES INSTITUCIONALES RELACIONADAS</div>
            <ul className="dth-lista">
              {doc.base_reglamento && (
                <li>
                  Reglamento Interno de Trabajo de BOMAN — {doc.base_reglamento}
                </li>
              )}
              {doc.base_legal && <li>Base legal: {doc.base_legal}</li>}
              <li>
                Código de Ética Institucional de BOMAN — principio de respeto y
                compromiso con los compañeros y la organización.
              </li>
            </ul>
          </>
        )}

        {doc.genera_descuento && (
          <>
            <div className="dth-banda">SANCIÓN ECONÓMICA</div>
            <p className="dth-p">
              Se aplica una multa de <strong>{dinero(doc.monto_descuento)}</strong>,
              descontable de la remuneración conforme al Reglamento Interno de Trabajo
              legalmente aprobado.
            </p>
          </>
        )}

        {!esFelicitacion && (
          <>
            <p className="dth-espera">
              <strong>BOMAN espera en lo sucesivo:</strong>
            </p>
            <ul className="dth-lista">
              <li>
                Corregir la situación observada a partir de la fecha de suscripción de
                este documento.
              </li>
              <li>
                Comunicar anticipadamente a la Jefatura cualquier circunstancia
                excepcional que pueda afectar el cumplimiento.
              </li>
              <li>
                Mantener un desempeño sin novedades durante el período de seguimiento de
                30 días.
              </li>
            </ul>
            <p className="dth-adv">
              De persistir la situación, se procederá con la emisión de una nueva
              amonestación escrita y, de ser necesario, las medidas disciplinarias
              previstas en el Reglamento Interno y en el Código del Trabajo.
            </p>
          </>
        )}

        {doc.descargo_empleado && (
          <>
            <div className="dth-banda">DESCARGO DEL TRABAJADOR</div>
            <p className="dth-p dth-pre">{doc.descargo_empleado}</p>
          </>
        )}

        {doc.resolucion && (
          <>
            <div className="dth-banda">RESOLUCIÓN</div>
            <p className="dth-p dth-pre">{doc.resolucion}</p>
          </>
        )}

        {!doc.descargo_empleado && !esFelicitacion && (
          <>
            <div className="dth-banda">DESCARGO</div>
            <p className="dth-nota">
              El trabajador puede presentar su descargo por escrito dentro del plazo
              previsto en el Reglamento Interno.
            </p>
            <div className="dth-lineas">
              <span />
              <span />
              <span />
            </div>
          </>
        )}

        <div className="dth-banda">DECLARACIÓN DE RECEPCIÓN Y COMPROMISO</div>
        <p className="dth-declara">
          Yo, <strong>{doc.nombre_completo}</strong>, con cédula {doc.identificacion},
          declaro haber recibido, leído y comprendido el presente documento
          {esFelicitacion
            ? "."
            : ", y me comprometo a corregir la situación observada y a comunicar oportunamente cualquier circunstancia que afecte su cumplimiento."}
        </p>

        {!esFelicitacion && (
          <p className="dth-lema">
            « Este documento es un acto de cuidado, no de sanción. BOMAN cree en su
            potencial y quiere que usted continúe creciendo con nosotros. »
          </p>
        )}

        <div className="dth-banda">FIRMAS DE ACEPTACIÓN Y CONFORMIDAD</div>
        <table className="dth-firmas">
          <tbody>
            <tr>
              <th>COLABORADOR/A</th>
              <th>JEFATURA ADMINISTRATIVA</th>
              <th>AUXILIAR DE TALENTO HUMANO</th>
            </tr>
            <tr>
              <td>
                <span className="dth-linea-firma" />
                <div className="dth-firma-pie">Firma</div>
                <div className="dth-firma-nom">
                  {doc.nombre_completo}
                  <br />
                  C.I. {doc.identificacion}
                </div>
              </td>
              <td>
                <span className="dth-linea-firma" />
                <div className="dth-firma-pie">Firma</div>
                <div className="dth-firma-nom">{doc.empresa}</div>
              </td>
              <td>
                <span className="dth-linea-firma" />
                <div className="dth-firma-pie">Firma</div>
                <div className="dth-firma-nom">Talento Humano</div>
              </td>
            </tr>
          </tbody>
        </table>

        <div className="dth-pie">
          Documento de uso interno y confidencial | BOMAN | {fmt.codigo} v01
          {doc.evidencias > 0 && ` | Adjunta ${doc.evidencias} evidencia(s)`}
          {doc.sanciones_ultimo_anio > 1 &&
            ` | ${doc.sanciones_ultimo_anio} sanciones en los últimos 12 meses`}
        </div>
      </article>
    </>
  );
}
