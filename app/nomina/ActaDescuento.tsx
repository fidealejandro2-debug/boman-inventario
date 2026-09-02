"use client";

import { dinero, soloFecha } from "./lib";

/**
 * Acta que el trabajador firma para pedir un anticipo o autorizar un descuento.
 * Es el papel que despues se escanea y se sube como respaldo: por eso el
 * sistema lo genera con los mismos datos que ya tiene registrados, en vez de
 * que alguien lo redacte a mano y termine sin coincidir con el descuento real.
 */
export type DatosActa = {
  clase: "anticipo" | "descuento";
  empleado: string;
  identificacion: string;
  empresa: string;
  fecha: string;
  monto: number;
  cuotas: number;
  montoCuota: number;
  fechaPrimeraCuota: string;
  concepto: string;
  origen?: string;
};

const ORIGEN_TEXTO: Record<string, string> = {
  anticipo: "anticipo de remuneracion",
  prestamo_iess: "prestamo del IESS",
  prestamo_quirografario: "prestamo quirografario",
  prestamo_hipotecario: "prestamo hipotecario",
  prestamo_empresa: "prestamo concedido por la empresa",
  multa: "sancion economica",
  judicial: "retencion judicial",
  uniforme: "entrega de uniformes",
  consumo_interno: "consumo interno",
  otro: "concepto autorizado",
};

export default function ActaDescuento({
  datos,
  onCerrar,
}: {
  datos: DatosActa;
  onCerrar: () => void;
}) {
  const esAnticipo = datos.clase === "anticipo";
  const concepto = esAnticipo
    ? "anticipo de remuneracion"
    : ORIGEN_TEXTO[datos.origen ?? "otro"] ?? "concepto autorizado";

  const hoy = new Date().toLocaleDateString("es-EC", {
    day: "2-digit", month: "long", year: "numeric",
  });

  return (
    <>
      <div className="no-imprimir filtros">
        <button onClick={() => window.print()}>Imprimir acta</button>
        <button className="secondary" onClick={onCerrar}>Volver</button>
      </div>

      <p className="ayuda no-imprimir">
        Imprime, hazla firmar y súbela al expediente. Mientras no esté cargada, el
        registro figura como <strong>respaldo pendiente</strong>.
      </p>

      <article className="doc-th">
        <table className="doc-th-cab">
          <tbody>
            <tr>
              <td className="dth-logo">
                <span className="dth-marca">BOMAN</span>
                <span className="dth-marca-sub">SPORT</span>
              </td>
              <td className="dth-titulo">
                <div className="dth-t1">
                  {esAnticipo
                    ? "SOLICITUD Y AUTORIZACIÓN DE ANTICIPO"
                    : "AUTORIZACIÓN DE DESCUENTO"}
                </div>
                <div className="dth-t2">Gestión de Talento Humano</div>
              </td>
              <td className="dth-meta">
                <div>Código: {esAnticipo ? "BOM-TH-AN-01" : "BOM-TH-DE-01"}</div>
                <div>Versión: v01</div>
                <div>Fecha: {hoy}</div>
              </td>
            </tr>
          </tbody>
        </table>

        <table className="doc-th-datos">
          <tbody>
            <tr>
              <th>Trabajador</th>
              <td>{datos.empleado}</td>
              <th>Cédula</th>
              <td>{datos.identificacion}</td>
            </tr>
            <tr>
              <th>Empleador</th>
              <td>{datos.empresa}</td>
              <th>Fecha</th>
              <td>{soloFecha(datos.fecha)}</td>
            </tr>
          </tbody>
        </table>

        <p className="doc-th-parrafo">
          Yo, <strong>{datos.empleado}</strong>, portador de la cédula de ciudadanía
          N° <strong>{datos.identificacion}</strong>, trabajador de{" "}
          <strong>{datos.empresa}</strong>, por medio del presente documento{" "}
          {esAnticipo ? (
            <>
              <strong>solicito</strong> se me conceda un anticipo de mi remuneración por
              la suma de <strong>{dinero(datos.monto)}</strong>, por concepto de{" "}
              <em>{datos.concepto}</em>.
            </>
          ) : (
            <>
              <strong>autorizo expresamente</strong> a mi empleador a descontar de mi
              remuneración la suma de <strong>{dinero(datos.monto)}</strong>, por
              concepto de <em>{concepto}</em>: {datos.concepto}.
            </>
          )}
        </p>

        <table className="doc-th-tabla">
          <thead>
            <tr>
              <th colSpan={2}>CONDICIONES DE DESCUENTO</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Monto total</td>
              <td className="num">{dinero(datos.monto)}</td>
            </tr>
            <tr>
              <td>Número de cuotas</td>
              <td className="num">{datos.cuotas}</td>
            </tr>
            <tr>
              <td>Valor de cada cuota</td>
              <td className="num">{dinero(datos.montoCuota)}</td>
            </tr>
            <tr>
              <td>Primera cuota</td>
              <td className="num">{soloFecha(datos.fechaPrimeraCuota)}</td>
            </tr>
          </tbody>
        </table>

        <p className="doc-th-parrafo">
          {esAnticipo ? "Autorizo" : "Acepto"} que dicho valor sea descontado de mis
          remuneraciones en las cuotas detalladas, hasta su cancelación total. Declaro
          conocer que este descuento se aplica respetando los límites que establece el
          Código del Trabajo y que, de terminar la relación laboral antes de completarse,
          el saldo pendiente será liquidado en el acta de finiquito.
        </p>

        <p className="doc-th-parrafo pequena">
          Este documento se emite a solicitud del trabajador y constituye la
          autorización escrita exigida para efectuar descuentos sobre la remuneración.
        </p>

        <table className="doc-th-firmas">
          <tbody>
            <tr>
              <td>
                <div className="dth-linea" />
                {datos.empleado}
                <small>C.C. {datos.identificacion} · Trabajador</small>
              </td>
              <td>
                <div className="dth-linea" />
                Talento Humano
                <small>{datos.empresa}</small>
              </td>
            </tr>
          </tbody>
        </table>
      </article>
    </>
  );
}
