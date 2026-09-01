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

type Formato = {
  codigo: string;
  titulo: string;
  subtitulo: string;
  /** Párrafo de apertura: fija el tono del documento. */
  intro: string;
  /** Cómo se llama la sección donde van los hechos. */
  seccionHechos: string;
  /** Qué se espera en adelante. Vacío cuando el documento no exige conducta. */
  expectativas: string[];
  /** Consecuencia de reincidir. Vacío en los que no sancionan. */
  advertencia: string;
  /** Texto que firma el trabajador. */
  declaracion: string;
  /** Frase de cierre. Solo donde acompaña, no en los de mayor gravedad. */
  lema: string;
  /** Si corresponde ofrecerle presentar descargo. */
  pideDescargo: boolean;
};

// Cada tipo de novedad tiene su propio codigo del sistema de gestion de
// calidad y su propio lenguaje: un memorando informa, un acta se acuerda
// entre las partes, una solicitud de visto bueno abre un tramite ante la
// autoridad. Compartir un texto generico entre todos los volvia
// indistinguibles y, en los graves, hasta contradictorios.
const FORMATO: Record<string, Formato> = {
  llamado_atencion: {
    codigo: "BOM-TH-LA-01",
    titulo: "COMUNICACIÓN DE LLAMADO DE ATENCIÓN",
    subtitulo: "Amonestación Por Escrito — Primera Instancia",
    intro:
      "BOMAN valora profundamente la presencia y el aporte de cada colaborador/a. Este llamado de atención no es una sanción: es una herramienta de acompañamiento institucional. Entendemos que diversas circunstancias pueden afectar el desempeño; sin embargo, el cumplimiento de lo acordado es un compromiso compartido que impacta en el bienestar del equipo y en la continuidad de los procesos productivos.",
    seccionHechos: "SITUACIONES OBSERVADAS",
    expectativas: [
      "Corregir la situación observada a partir de la fecha de suscripción de este documento.",
      "Comunicar anticipadamente a la Jefatura cualquier circunstancia excepcional que pueda afectar el cumplimiento.",
      "Mantener un desempeño sin novedades durante el período de seguimiento de 30 días.",
    ],
    advertencia:
      "De persistir la situación, se procederá con la emisión de una amonestación escrita como segunda instancia.",
    declaracion:
      "declaro haber recibido, leído y comprendido este llamado de atención, y me comprometo a corregir la situación observada y a comunicar oportunamente cualquier circunstancia que afecte su cumplimiento.",
    lema:
      "« Este documento es un acto de cuidado, no de sanción. BOMAN cree en su potencial y quiere que usted continúe creciendo con nosotros. »",
    pideDescargo: true,
  },

  amonestacion_escrita: {
    codigo: "BOM-TH-AE-01",
    titulo: "AMONESTACIÓN ESCRITA",
    subtitulo: "Amonestación Por Escrito — Segunda Instancia",
    intro:
      "Habiéndose comunicado previamente al colaborador/a la necesidad de corregir su conducta, y persistiendo la situación observada, BOMAN emite la presente amonestación escrita. Este documento constituye una sanción disciplinaria y se incorpora al expediente laboral del colaborador/a.",
    seccionHechos: "HECHOS QUE MOTIVAN LA AMONESTACIÓN",
    expectativas: [
      "Cesar de inmediato la conducta observada.",
      "Sujetarse a un período de seguimiento de 30 días con evaluación de la Jefatura.",
    ],
    advertencia:
      "La reiteración de esta conducta habilita a la empresa a solicitar el visto bueno ante la Inspectoría del Trabajo, conforme al Art. 172 del Código del Trabajo.",
    declaracion:
      "declaro haber recibido, leído y comprendido la presente amonestación escrita, y quedo notificado/a de las consecuencias que acarrea su reiteración.",
    lema: "",
    pideDescargo: true,
  },

  memorando: {
    codigo: "BOM-TH-ME-01",
    titulo: "MEMORANDO",
    subtitulo: "Comunicación Interna de Talento Humano",
    intro:
      "Por medio del presente memorando, BOMAN comunica formalmente al colaborador/a la información y las disposiciones que se detallan a continuación, para su conocimiento y cumplimiento.",
    seccionHechos: "CONTENIDO DE LA COMUNICACIÓN",
    expectativas: [],
    advertencia: "",
    declaracion:
      "declaro haber recibido y leído el presente memorando, y quedo enterado/a de su contenido.",
    lema: "",
    pideDescargo: false,
  },

  acta_compromiso: {
    codigo: "BOM-TH-AC-01",
    titulo: "ACTA DE COMPROMISO",
    subtitulo: "Acuerdo de Mejora — Talento Humano",
    intro:
      "Reunidas las partes, y con el ánimo de resolver de común acuerdo la situación que se detalla, se suscribe la presente acta de compromiso. Este documento recoge acuerdos aceptados voluntariamente por el colaborador/a y por la empresa.",
    seccionHechos: "ANTECEDENTES Y ACUERDOS",
    expectativas: [
      "Cumplir los acuerdos aquí recogidos en los plazos convenidos.",
      "Someterse a las reuniones de seguimiento que acuerden las partes.",
    ],
    advertencia:
      "El incumplimiento de los acuerdos aquí suscritos faculta a la empresa a continuar con el procedimiento disciplinario que corresponda.",
    declaracion:
      "suscribo la presente acta de compromiso de manera libre y voluntaria, declarando conocer y aceptar los acuerdos que en ella constan.",
    lema:
      "« Los acuerdos que se construyen entre las partes son los que mejor se sostienen en el tiempo. »",
    pideDescargo: false,
  },

  felicitacion: {
    codigo: "BOM-TH-FE-01",
    titulo: "RECONOCIMIENTO",
    subtitulo: "Felicitación por Desempeño",
    intro:
      "BOMAN reconoce y agradece el aporte del colaborador/a. El presente documento deja constancia formal de un desempeño que la organización valora, y se incorpora a su expediente como antecedente favorable.",
    seccionHechos: "MOTIVO DEL RECONOCIMIENTO",
    expectativas: [],
    advertencia: "",
    declaracion: "declaro haber recibido el presente reconocimiento.",
    lema:
      "« El trabajo bien hecho merece ser nombrado. Gracias por su compromiso con BOMAN. »",
    pideDescargo: false,
  },

  sancion_economica: {
    codigo: "BOM-TH-SE-01",
    titulo: "SANCIÓN ECONÓMICA",
    subtitulo: "Multa Prevista en el Reglamento Interno",
    intro:
      "BOMAN impone al colaborador/a la sanción económica que se detalla, prevista en el Reglamento Interno de Trabajo legalmente aprobado por el Ministerio del Trabajo. Conforme al Art. 44 literal b) del Código del Trabajo, solo procede la multa contemplada en dicho reglamento.",
    seccionHechos: "HECHOS QUE MOTIVAN LA SANCIÓN",
    expectativas: [
      "Cesar de inmediato la conducta sancionada.",
      "Sujetarse al período de seguimiento que determine la Jefatura.",
    ],
    advertencia:
      "La reiteración de la conducta faculta a la empresa a aplicar las medidas disciplinarias adicionales previstas en el Reglamento Interno.",
    declaracion:
      "declaro haber recibido, leído y comprendido la presente sanción económica, y quedo notificado/a del descuento que se aplicará sobre mi remuneración.",
    lema: "",
    pideDescargo: true,
  },

  solicitud_visto_bueno: {
    codigo: "BOM-TH-VB-01",
    titulo: "NOTIFICACIÓN DE SOLICITUD DE VISTO BUENO",
    subtitulo: "Trámite ante la Inspectoría del Trabajo",
    intro:
      "BOMAN notifica al colaborador/a que, agotadas las instancias disciplinarias previas y persistiendo la causal que se detalla, ha resuelto solicitar el visto bueno ante la Inspectoría del Trabajo, conforme al Art. 172 del Código del Trabajo.",
    seccionHechos: "CAUSAL INVOCADA Y HECHOS",
    expectativas: [],
    advertencia:
      "Presentada la solicitud, el Inspector del Trabajo notificará al colaborador/a y le concederá dos días para contestar, conforme al Art. 183 del Código del Trabajo. La resolución del visto bueno corresponde exclusivamente a la autoridad.",
    declaracion:
      "declaro haber sido notificado/a de la decisión de la empresa de solicitar el visto bueno ante la Inspectoría del Trabajo, y de que podré ejercer mi defensa ante dicha autoridad.",
    lema: "",
    pideDescargo: false,
  },
};

const FORMATO_GENERICO: Formato = {
  codigo: "BOM-TH-GE-01",
  titulo: "COMUNICACIÓN DE TALENTO HUMANO",
  subtitulo: "Gestión de Talento Humano",
  intro:
    "Por medio del presente documento, BOMAN comunica formalmente al colaborador/a la situación que se detalla a continuación.",
  seccionHechos: "DETALLE",
  expectativas: [],
  advertencia: "",
  declaracion: "declaro haber recibido, leído y comprendido el presente documento.",
  lema: "",
  pideDescargo: true,
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
    ...FORMATO_GENERICO,
    titulo: (ETIQUETA_NOVEDAD[doc.tipo] ?? doc.tipo).toUpperCase(),
  };

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
          {fmt.intro}
        </p>

        {/* Asunto y hechos */}
        <div className="dth-banda">ASUNTO</div>
        <p className="dth-p">{doc.asunto}</p>

        <div className="dth-banda">{fmt.seccionHechos}</div>
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

        {fmt.expectativas.length > 0 && (
          <>
            <p className="dth-espera">
              <strong>
                {doc.tipo === "acta_compromiso"
                  ? "Las partes acuerdan:"
                  : "BOMAN espera en lo sucesivo:"}
              </strong>
            </p>
            <ul className="dth-lista">
              {fmt.expectativas.map((e) => (
                <li key={e}>{e}</li>
              ))}
            </ul>
          </>
        )}

        {fmt.advertencia && <p className="dth-adv">{fmt.advertencia}</p>}

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

        {!doc.descargo_empleado && fmt.pideDescargo && (
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

        <div className="dth-banda">
          {doc.tipo === "acta_compromiso"
            ? "DECLARACIÓN DE LAS PARTES"
            : doc.tipo === "memorando" || doc.tipo === "felicitacion"
            ? "CONSTANCIA DE RECEPCIÓN"
            : "DECLARACIÓN DE RECEPCIÓN Y COMPROMISO"}
        </div>
        <p className="dth-declara">
          Yo, <strong>{doc.nombre_completo}</strong>, con cédula {doc.identificacion},{" "}
          {fmt.declaracion}
        </p>

        {fmt.lema && <p className="dth-lema">{fmt.lema}</p>}

        <div className="dth-banda">
          {doc.tipo === "acta_compromiso"
            ? "FIRMAS DE ACUERDO"
            : doc.tipo === "memorando" || doc.tipo === "felicitacion"
            ? "FIRMAS"
            : "FIRMAS DE ACEPTACIÓN Y CONFORMIDAD"}
        </div>
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
