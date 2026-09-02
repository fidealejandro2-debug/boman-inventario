"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { dinero, soloFecha } from "./lib";

const MESES = [
  "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
];

type Real = {
  rol_linea_id: string;
  anio: number;
  mes: number;
  estado_periodo: string;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  area: string | null;
  fecha_ingreso_real: string;
  afiliado: boolean;
  empresa_afiliacion: string | null;
  empresa_pagadora: string | null;
  ruc_pagador: string | null;
  dias_laborados: number;
  dias_vacaciones: number;
  dias_ausencia_sin_sueldo: number;
  horas_extra_50: number;
  horas_extra_100: number;
  sueldo_proporcional_real: number;
  valor_horas_extra: number;
  comisiones: number;
  bonos: number;
  vacaciones_pagadas: number;
  decimo_tercero_mensualizado: number;
  decimo_cuarto_mensualizado: number;
  fondos_reserva_pagados: number;
  otros_ingresos: number;
  total_ingresos_real: number;
  aporte_personal: number;
  anticipos_cuota: number;
  multas: number;
  prestamos_iess: number;
  prestamos_empresa: number;
  retencion_judicial: number;
  otros_descuentos: number;
  total_egresos: number;
  neto_real: number;
};

type Declarado = {
  dias_afiliados: number;
  sueldo_declarado: number;
  sueldo_proporcional_declarado: number;
  total_ingresos_declarado: number;
  aporte_personal: number;
  neto_declarado: number;
  empresa_afiliacion: string;
  ruc_afiliador: string;
};

type Beneficios = {
  mensualiza_decimo_tercero: boolean;
  mensualiza_decimo_cuarto: boolean;
  region: string;
  detalle_decimo_tercero: string;
  detalle_decimo_cuarto: string;
  acumulado_decimo_tercero: number;
  acumulado_decimo_cuarto: number;
};

type Novedad = {
  rol_linea_id: string;
  grupo: "ingreso" | "descuento" | "informativo";
  tipo: string;
  etiqueta: string;
  fecha: string | null;
  cantidad: number | null;
  monto: number | null;
  detalle: string | null;
  nota: string | null;
  orden: number;
};

type Fila = { concepto: string; cantidad?: string; valor: number };

const dia = (f: string | null) =>
  f ? f.slice(8, 10) + "/" + f.slice(5, 7) : "";

/** "Multa (11/07) 5,00$ LIMPIEZA AREA" — como se lee en el Excel. */
function frase(n: Novedad) {
  const partes = [n.etiqueta];
  if (n.fecha) partes.push("(" + dia(n.fecha) + ")");
  if (n.monto) partes.push(Number(n.monto).toFixed(2).replace(".", ",") + "$");
  if (n.detalle) partes.push(n.detalle);
  return partes.join(" ");
}

export default function RolImpresion({
  rolLineaId,
  onCerrar,
}: {
  rolLineaId: string;
  onCerrar: () => void;
}) {
  const supabase = createClient();
  const [real, setReal] = useState<Real | null>(null);
  const [declarado, setDeclarado] = useState<Declarado | null>(null);
  const [novedades, setNovedades] = useState<Novedad[]>([]);
  const [beneficios, setBeneficios] = useState<Beneficios | null>(null);
  const [version, setVersion] = useState<"real" | "declarado">("real");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let vivo = true;
    (async () => {
      const [r, d, n, b] = await Promise.all([
        supabase.from("vista_rol_impresion_v31").select("*").eq("rol_linea_id", rolLineaId).maybeSingle(),
        supabase.from("vista_rol_declarado_v31").select("*").eq("rol_linea_id", rolLineaId).maybeSingle(),
        supabase.from("vista_rol_novedades_v52").select("*").eq("rol_linea_id", rolLineaId)
          .order("orden").order("fecha"),
        supabase.from("vista_rol_beneficios_v56").select("*").eq("rol_linea_id", rolLineaId).maybeSingle(),
      ]);
      if (!vivo) return;
      if (r.error) return setError(r.error.message);
      if (!r.data) return setError("La línea del rol ya no existe.");
      setReal(r.data as Real);
      setDeclarado((d.data as Declarado) ?? null);
      setNovedades((n.data as Novedad[]) ?? []);
      // Si v56 aun no esta instalada, el bloque de beneficios no sale y el
      // resto del comprobante se imprime igual.
      setBeneficios((b.data as Beneficios) ?? null);
    })();
    return () => { vivo = false; };
  }, [supabase, rolLineaId]);

  if (error) return <p className="error">No se pudo cargar el rol: {error}</p>;
  if (!real) return <p className="ayuda">Preparando el comprobante…</p>;

  const declaradoActivo = version === "declarado" && declarado !== null;
  const periodo = `${MESES[real.mes - 1]} ${real.anio}`;
  const base = declaradoActivo ? declarado!.sueldo_declarado : null;

  const ingresos: Fila[] = declaradoActivo
    ? [{
        concepto: "Sueldo (a recibir)",
        cantidad: String(declarado!.dias_afiliados),
        valor: declarado!.sueldo_proporcional_declarado,
      }]
    : [
        { concepto: "Sueldo (a recibir)", valor: real.sueldo_proporcional_real },
        {
          concepto: "Horas Suplementarias",
          cantidad: real.horas_extra_50 || real.horas_extra_100
            ? String(Number(real.horas_extra_50) + Number(real.horas_extra_100))
            : undefined,
          valor: real.valor_horas_extra,
        },
        { concepto: "Comisiones", valor: real.comisiones },
        { concepto: "Bonos", valor: real.bonos },
        { concepto: "Vacaciones pagadas", valor: real.vacaciones_pagadas },
        { concepto: "Décimo tercero", valor: real.decimo_tercero_mensualizado },
        { concepto: "Décimo cuarto", valor: real.decimo_cuarto_mensualizado },
        { concepto: "Fondos de reserva", valor: real.fondos_reserva_pagados },
        { concepto: "Otros ingresos", valor: real.otros_ingresos },
      ].filter((f) => Number(f.valor) !== 0);

  const descuentos: Fila[] = declaradoActivo
    ? [{ concepto: "Aporte personal IESS", valor: declarado!.aporte_personal }]
    : [
        { concepto: "Aporte personal IESS", valor: real.aporte_personal },
        { concepto: "Anticipos", valor: real.anticipos_cuota },
        { concepto: "Descuentos Varios", valor: real.otros_descuentos },
        { concepto: "Multas / Sanciones", valor: real.multas },
        { concepto: "Préstamos IESS", valor: real.prestamos_iess },
        { concepto: "Préstamos empresa", valor: real.prestamos_empresa },
        { concepto: "Retención judicial", valor: real.retencion_judicial },
      ].filter((f) => Number(f.valor) !== 0);

  const totalIngresos = declaradoActivo ? declarado!.total_ingresos_declarado : real.total_ingresos_real;
  const totalDescuentos = declaradoActivo ? declarado!.aporte_personal : real.total_egresos;
  const neto = declaradoActivo ? declarado!.neto_declarado : real.neto_real;
  const diasTrab = declaradoActivo ? declarado!.dias_afiliados : real.dias_laborados;

  // Se agrupa por tipo, como en el Excel: los atrasos juntos, las multas
  // juntas, separados por barra. Leer "Multa, Multa, Atraso, Multa" cuesta.
  const porTipo = new Map<string, Novedad[]>();
  for (const n of novedades) {
    if (!porTipo.has(n.etiqueta)) porTipo.set(n.etiqueta, []);
    porTipo.get(n.etiqueta)!.push(n);
  }
  const observaciones = [...porTipo.values()]
    .map((grupo) => grupo.map(frase).join(", "))
    .join(" | ");

  // Filas vacías para que el bloque conserve la altura del formato impreso.
  const relleno = (n: number) => Array.from({ length: Math.max(0, n) }, (_, i) => i);

  return (
    <>
      <div className="no-imprimir filtros">
        <button onClick={() => window.print()}>Imprimir</button>
        <div className="tabs" style={{ margin: 0 }}>
          <button className={`tab ${version === "real" ? "activo" : ""}`} onClick={() => setVersion("real")}>
            Rol real
          </button>
          <button
            className={`tab ${version === "declarado" ? "activo" : ""}`}
            onClick={() => setVersion("declarado")}
            disabled={!declarado}
            title={declarado ? "" : "Esta persona no está afiliada: no tiene rol declarado"}
          >
            Rol declarado (IESS)
          </button>
        </div>
        <button className="secondary" onClick={onCerrar}>Volver</button>
      </div>

      {real.estado_periodo !== "cerrado" && (
        <p className="aviso no-imprimir">
          El período todavía está <strong>{real.estado_periodo}</strong>. Los valores
          pueden cambiar hasta el cierre; imprime para revisión, no para firma.
        </p>
      )}

      <article className="rol-hoja">
        <div className="rol-marca">
          <span className="rol-logo-b">B</span>
          <span className="rol-logo-txt">BOMAN</span>
        </div>

        <div className="rol-titulo">
          ROL DE PAGO {declaradoActivo ? "INDIVIDUAL · IESS" : "INDIVIDUAL"}
        </div>

        <table className="rol-datos">
          <tbody>
            <tr>
              <th>Período:</th>
              <td>{periodo}</td>
              <th className="der">N° Empleado:</th>
              <td className="num azul">{real.identificacion}</td>
            </tr>
            <tr>
              <th className="azul">EMPLEADO:</th>
              <td className="nombre">{real.nombre_completo}</td>
              <th className="der">Días trab.:</th>
              <td className="num">{diasTrab}</td>
            </tr>
          </tbody>
        </table>

        <table className="rol-tabla">
          <thead>
            <tr className="rol-verde">
              <th>INGRESOS</th>
              <th className="col-cant">CANT.</th>
              <th className="col-valor">VALOR USD</th>
            </tr>
          </thead>
          <tbody>
            {ingresos.map((f) => (
              <tr key={f.concepto}>
                <td>
                  {f.concepto}
                  {f.concepto.startsWith("Sueldo") && base ? (
                    <span className="rol-base">Base: {dinero(base)}</span>
                  ) : null}
                </td>
                <td className="num azul">{f.cantidad ?? ""}</td>
                <td className="num">{dinero(f.valor)}</td>
              </tr>
            ))}
            {relleno(6 - ingresos.length).map((i) => (
              <tr key={"vi" + i}><td>&nbsp;</td><td /><td className="num">$0,00</td></tr>
            ))}
            <tr className="rol-verde total">
              <td colSpan={2}>TOTAL INGRESOS</td>
              <td className="num">{dinero(totalIngresos)}</td>
            </tr>
          </tbody>
        </table>

        <table className="rol-tabla">
          <thead>
            <tr className="rol-rojo">
              <th colSpan={2}>DESCUENTOS</th>
              <th className="col-valor">VALOR USD</th>
            </tr>
          </thead>
          <tbody>
            {descuentos.map((f) => (
              <tr key={f.concepto}>
                <td colSpan={2}>{f.concepto}</td>
                <td className="num">{dinero(f.valor)}</td>
              </tr>
            ))}
            {relleno(5 - descuentos.length).map((i) => (
              <tr key={"vd" + i}><td colSpan={2}>&nbsp;</td><td className="num">$0,00</td></tr>
            ))}
            <tr className="rol-rojo total">
              <td colSpan={2}>TOTAL DESCUENTOS</td>
              <td className="num">{dinero(totalDescuentos)}</td>
            </tr>
            <tr className="rol-azul total">
              <td colSpan={2}>NETO A PAGAR</td>
              <td className="num">{dinero(neto)}</td>
            </tr>
          </tbody>
        </table>

        {beneficios && (
          <table className="rol-tabla">
            <thead>
              <tr className="rol-verde">
                <th colSpan={2}>BENEFICIOS DE LEY</th>
                <th className="col-valor">ACUMULADO {real.anio}</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td colSpan={2}>
                  Décimo tercera remuneración
                  <small>{beneficios.detalle_decimo_tercero}</small>
                </td>
                <td className="num">
                  {beneficios.mensualiza_decimo_tercero
                    ? "—"
                    : dinero(beneficios.acumulado_decimo_tercero)}
                </td>
              </tr>
              <tr>
                <td colSpan={2}>
                  Décimo cuarta remuneración
                  <small>{beneficios.detalle_decimo_cuarto}</small>
                </td>
                <td className="num">
                  {beneficios.mensualiza_decimo_cuarto
                    ? "—"
                    : dinero(beneficios.acumulado_decimo_cuarto)}
                </td>
              </tr>
            </tbody>
          </table>
        )}

        <div className="rol-obs-titulo">OBSERVACIONES:</div>
        <div className="rol-obs">
          {observaciones || "Sin novedades registradas en el período."}
        </div>

        {novedades.length > 0 && (
          <table className="rol-detalle">
            <thead>
              <tr>
                <th>Novedad</th>
                <th>Fecha</th>
                <th>Detalle</th>
                <th className="num">Valor</th>
              </tr>
            </thead>
            <tbody>
              {novedades.map((n, i) => (
                <tr key={i}>
                  <td>{n.etiqueta}</td>
                  <td>{n.fecha ? soloFecha(n.fecha) : "—"}</td>
                  <td>
                    {n.detalle ?? "—"}
                    {n.nota ? <small>{n.nota}</small> : null}
                  </td>
                  <td className="num">{n.monto ? dinero(n.monto) : "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        <div className="rol-firma-titulo">FIRMA EMPLEADO:</div>
        <table className="rol-firma">
          <tbody>
            <tr>
              <td>
                <div className="rol-linea-firma" />
                {real.nombre_completo}
              </td>
              <td className="rol-ci">C.I. / Fecha:</td>
            </tr>
          </tbody>
        </table>

        <div className="rol-pie">
          {real.nombre_completo}
          <span>
            {declaradoActivo
              ? `${declarado!.empresa_afiliacion} · RUC ${declarado!.ruc_afiliador}`
              : real.empresa_pagadora ?? ""}
          </span>
        </div>
      </article>
    </>
  );
}
