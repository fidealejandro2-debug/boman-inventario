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
  ruc_afiliador: string | null;
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
  rol_linea_id: string;
  anio: number;
  mes: number;
  identificacion: string;
  nombre_completo: string;
  cargo: string | null;
  empresa_afiliacion: string;
  ruc_afiliador: string;
  fecha_afiliacion: string | null;
  dias_laborados: number;
  dias_afiliados: number;
  sueldo_declarado: number;
  sueldo_proporcional_declarado: number;
  total_ingresos_declarado: number;
  aporte_personal: number;
  neto_declarado: number;
  aporte_patronal: number;
  provision_decimo_tercero: number;
  provision_decimo_cuarto: number;
  provision_vacaciones: number;
  provision_fondos_reserva: number;
  costo_empleador_declarado: number;
};

type Rubro = {
  rol_linea_id: string;
  codigo: string;
  nombre: string;
  tipo: string;
  cantidad: number | null;
  valor: number;
  descripcion_extra: string | null;
};

type Fila = { etiqueta: string; valor: number; detalle?: string };

/** Solo se imprime lo que tiene valor: un rol lleno de ceros no se lee. */
function conValor(filas: Fila[]) {
  return filas.filter((f) => Number(f.valor) !== 0);
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
  const [rubros, setRubros] = useState<Rubro[]>([]);
  const [version, setVersion] = useState<"real" | "declarado">("real");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let vivo = true;
    (async () => {
      const [r, d, ru] = await Promise.all([
        supabase.from("vista_rol_impresion_v31").select("*").eq("rol_linea_id", rolLineaId).maybeSingle(),
        supabase.from("vista_rol_declarado_v31").select("*").eq("rol_linea_id", rolLineaId).maybeSingle(),
        supabase.from("vista_rol_rubros_v31").select("*").eq("rol_linea_id", rolLineaId).order("codigo"),
      ]);
      if (!vivo) return;
      if (r.error) return setError(r.error.message);
      if (!r.data) return setError("La línea del rol ya no existe.");
      setReal(r.data as Real);
      setDeclarado((d.data as Declarado) ?? null);
      setRubros((ru.data as Rubro[]) ?? []);
    })();
    return () => {
      vivo = false;
    };
  }, [supabase, rolLineaId]);

  if (error) return <p className="error">No se pudo cargar el rol: {error}</p>;
  if (!real) return <p className="ayuda">Preparando el comprobante…</p>;

  const periodo = `${MESES[real.mes - 1]} ${real.anio}`;
  const mostrandoDeclarado = version === "declarado" && declarado;

  const ingresosReales = conValor([
    { etiqueta: "Sueldo del período", valor: real.sueldo_proporcional_real,
      detalle: `${real.dias_laborados} días laborados` },
    { etiqueta: "Horas extra", valor: real.valor_horas_extra,
      detalle: `${real.horas_extra_50} h al 50% · ${real.horas_extra_100} h al 100%` },
    { etiqueta: "Comisiones", valor: real.comisiones },
    { etiqueta: "Bonos", valor: real.bonos },
    { etiqueta: "Vacaciones pagadas", valor: real.vacaciones_pagadas,
      detalle: real.dias_vacaciones ? `${real.dias_vacaciones} días` : undefined },
    { etiqueta: "Décimo tercero mensualizado", valor: real.decimo_tercero_mensualizado },
    { etiqueta: "Décimo cuarto mensualizado", valor: real.decimo_cuarto_mensualizado },
    { etiqueta: "Fondos de reserva", valor: real.fondos_reserva_pagados },
    { etiqueta: "Otros ingresos", valor: real.otros_ingresos },
    ...rubros.filter((r) => r.tipo === "ingreso").map((r) => ({
      etiqueta: r.nombre, valor: Number(r.valor), detalle: r.descripcion_extra ?? undefined,
    })),
  ]);

  const egresosReales = conValor([
    { etiqueta: "Aporte personal IESS", valor: real.aporte_personal },
    { etiqueta: "Anticipos", valor: real.anticipos_cuota },
    { etiqueta: "Multas", valor: real.multas },
    { etiqueta: "Préstamos IESS", valor: real.prestamos_iess },
    { etiqueta: "Préstamos de la empresa", valor: real.prestamos_empresa },
    { etiqueta: "Retención judicial", valor: real.retencion_judicial },
    { etiqueta: "Otros descuentos", valor: real.otros_descuentos },
    ...rubros.filter((r) => r.tipo === "egreso").map((r) => ({
      etiqueta: r.nombre, valor: Number(r.valor), detalle: r.descripcion_extra ?? undefined,
    })),
  ]);

  const ingresosDeclarados = declarado
    ? conValor([
        { etiqueta: "Sueldo declarado del período", valor: declarado.sueldo_proporcional_declarado,
          detalle: `${declarado.dias_afiliados} días afiliados sobre ${dinero(declarado.sueldo_declarado)} mensuales` },
      ])
    : [];
  const egresosDeclarados = declarado
    ? conValor([{ etiqueta: "Aporte personal IESS", valor: declarado.aporte_personal }])
    : [];

  const ingresos = mostrandoDeclarado ? ingresosDeclarados : ingresosReales;
  const egresos = mostrandoDeclarado ? egresosDeclarados : egresosReales;
  const totalIngresos = mostrandoDeclarado ? declarado!.total_ingresos_declarado : real.total_ingresos_real;
  const totalEgresos = mostrandoDeclarado ? declarado!.aporte_personal : real.total_egresos;
  const neto = mostrandoDeclarado ? declarado!.neto_declarado : real.neto_real;

  return (
    <>
      <div className="no-imprimir filtros">
        <button onClick={() => window.print()}>Imprimir</button>
        <div className="tabs" style={{ margin: 0 }}>
          <button
            className={`tab ${version === "real" ? "activo" : ""}`}
            onClick={() => setVersion("real")}
          >
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
        <button className="secondary" onClick={onCerrar}>
          Volver
        </button>
      </div>

      {real.estado_periodo !== "cerrado" && (
        <p className="aviso no-imprimir">
          El período todavía está <strong>{real.estado_periodo}</strong>. Los valores
          pueden cambiar hasta el cierre; imprime para revisión, no para firma.
        </p>
      )}

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
                  {mostrandoDeclarado ? "ROL DE PAGOS — IESS" : "ROL DE PAGOS"}
                </div>
                <div className="dth-t2">{periodo}</div>
              </td>
              <td className="dth-meta">
                <div>Código: {mostrandoDeclarado ? "BOM-TH-RP-02" : "BOM-TH-RP-01"}</div>
                <div>Versión: v01</div>
                <div>Proceso: Gestión de Talento Humano</div>
              </td>
            </tr>
          </tbody>
        </table>

        <table className="dth-datos">
          <tbody>
            <tr>
              <th>Trabajador</th>
              <td>{real.nombre_completo}</td>
              <th>Cédula</th>
              <td>{real.identificacion}</td>
            </tr>
            <tr>
              <th>Cargo</th>
              <td>{real.cargo ?? "—"}</td>
              <th>Área</th>
              <td>{real.area ?? "—"}</td>
            </tr>
            {mostrandoDeclarado ? (
              <tr>
                <th>Empleador afiliante</th>
                <td>
                  {declarado!.empresa_afiliacion}
                  <small> · RUC {declarado!.ruc_afiliador}</small>
                </td>
                <th>Afiliado desde</th>
                <td>{soloFecha(declarado!.fecha_afiliacion)}</td>
              </tr>
            ) : (
              <tr>
                <th>Paga</th>
                <td>
                  {real.empresa_pagadora ?? "—"}
                  {real.ruc_pagador ? <small> · RUC {real.ruc_pagador}</small> : null}
                </td>
                <th>Ingreso</th>
                <td>{soloFecha(real.fecha_ingreso_real)}</td>
              </tr>
            )}
            <tr>
              <th>Período</th>
              <td>{periodo}</td>
              <th>Días</th>
              <td>
                {mostrandoDeclarado
                  ? `${declarado!.dias_afiliados} afiliados`
                  : `${real.dias_laborados} laborados` +
                    (real.dias_ausencia_sin_sueldo
                      ? ` · ${real.dias_ausencia_sin_sueldo} sin sueldo`
                      : "")}
              </td>
            </tr>
          </tbody>
        </table>

        <div className="rol-columnas">
          <table className="rol-tabla">
            <thead>
              <tr>
                <th colSpan={2}>INGRESOS</th>
              </tr>
            </thead>
            <tbody>
              {ingresos.map((f) => (
                <tr key={f.etiqueta}>
                  <td>
                    {f.etiqueta}
                    {f.detalle ? <small>{f.detalle}</small> : null}
                  </td>
                  <td className="num">{dinero(f.valor)}</td>
                </tr>
              ))}
              {!ingresos.length && (
                <tr>
                  <td colSpan={2} className="vacio">Sin ingresos registrados</td>
                </tr>
              )}
              <tr className="rol-total">
                <td>Total ingresos</td>
                <td className="num">{dinero(totalIngresos)}</td>
              </tr>
            </tbody>
          </table>

          <table className="rol-tabla">
            <thead>
              <tr>
                <th colSpan={2}>DESCUENTOS</th>
              </tr>
            </thead>
            <tbody>
              {egresos.map((f) => (
                <tr key={f.etiqueta}>
                  <td>
                    {f.etiqueta}
                    {f.detalle ? <small>{f.detalle}</small> : null}
                  </td>
                  <td className="num">{dinero(f.valor)}</td>
                </tr>
              ))}
              {!egresos.length && (
                <tr>
                  <td colSpan={2} className="vacio">Sin descuentos</td>
                </tr>
              )}
              <tr className="rol-total">
                <td>Total descuentos</td>
                <td className="num">{dinero(totalEgresos)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <table className="rol-neto">
          <tbody>
            <tr>
              <td>NETO A RECIBIR</td>
              <td className="num">{dinero(neto)}</td>
            </tr>
          </tbody>
        </table>

        {mostrandoDeclarado && (
          <table className="rol-tabla">
            <thead>
              <tr>
                <th colSpan={2}>COSTO DEL EMPLEADOR (no se descuenta al trabajador)</th>
              </tr>
            </thead>
            <tbody>
              <tr><td>Aporte patronal</td><td className="num">{dinero(declarado!.aporte_patronal)}</td></tr>
              <tr><td>Provisión décimo tercero</td><td className="num">{dinero(declarado!.provision_decimo_tercero)}</td></tr>
              <tr><td>Provisión décimo cuarto</td><td className="num">{dinero(declarado!.provision_decimo_cuarto)}</td></tr>
              <tr><td>Provisión vacaciones</td><td className="num">{dinero(declarado!.provision_vacaciones)}</td></tr>
              <tr><td>Provisión fondos de reserva</td><td className="num">{dinero(declarado!.provision_fondos_reserva)}</td></tr>
              <tr className="rol-total">
                <td>Costo total</td>
                <td className="num">{dinero(declarado!.costo_empleador_declarado)}</td>
              </tr>
            </tbody>
          </table>
        )}

        <p className="dth-declara">
          Declaro haber recibido de conformidad el valor neto detallado en este rol de
          pagos correspondiente a {periodo}, y que los rubros que lo componen
          corresponden a lo efectivamente trabajado y acordado.
        </p>

        <table className="dth-firmas">
          <tbody>
            <tr>
              <td>
                <div className="dth-linea-firma" />
                {real.nombre_completo}
                <small>C.C. {real.identificacion} · Trabajador</small>
              </td>
              <td>
                <div className="dth-linea-firma" />
                Talento Humano
                <small>
                  {mostrandoDeclarado
                    ? declarado!.empresa_afiliacion
                    : real.empresa_pagadora ?? "Boman Sport"}
                </small>
              </td>
            </tr>
          </tbody>
        </table>
      </article>
    </>
  );
}
