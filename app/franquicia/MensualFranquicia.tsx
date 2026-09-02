"use client";

import { useEffect, useMemo, useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import Aviso from "@/components/Aviso";
import type { Franquicia } from "./FranquiciaCliente";
import { dinero, mensajeError } from "./lib";

const MESES = [
  "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
];

type Mes = {
  mes: string;
  anio: number;
  numero_mes: number;
  ingresos: number;
  egresos: number;
  resultado_operativo: number;
  ingresos_por_venta: number;
  otros_ingresos: number;
  ingresos_efectivo: number;
  ingresos_transferencia: number;
  ingresos_tarjeta: number;
  ventas_registradas: number;
  ventas_anuladas: number;
  total_vendido: number;
  descuentos_otorgados: number;
  unidades_vendidas: number;
  dias_cerrados: number;
  dias_con_diferencia: number;
  diferencia_acumulada: number;
};

type Inventario = {
  prendas_con_stock: number;
  unidades: number;
  valor_a_precio_venta: number;
  prendas_bajo_minimo: number;
  prendas_sin_stock: number;
};

const etiquetaMes = (m: Mes) => `${MESES[m.numero_mes - 1]} ${m.anio}`;

export default function MensualFranquicia({
  franquicia,
}: {
  franquicia: Franquicia;
}) {
  const supabase = createClient();
  const [meses, setMeses] = useState<Mes[]>([]);
  const [inventario, setInventario] = useState<Inventario | null>(null);
  const [seleccionado, setSeleccionado] = useState("");
  const [cargando, setCargando] = useState(true);
  const [exportando, setExportando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let vivo = true;
    (async () => {
      const [r, i] = await Promise.all([
        supabase
          .from("vista_resumen_mensual_franquicia_v50")
          .select("*")
          .eq("franquicia_id", franquicia.id)
          .order("mes", { ascending: false })
          .limit(24),
        supabase
          .from("vista_inventario_valorizado_franquicia_v50")
          .select("*")
          .eq("franquicia_id", franquicia.id)
          .maybeSingle(),
      ]);
      if (!vivo) return;
      if (r.error) setError(r.error.message);
      const lista = (r.data as Mes[]) ?? [];
      setMeses(lista);
      setSeleccionado((actual) => actual || lista[0]?.mes || "");
      setInventario((i.data as Inventario) ?? null);
      setCargando(false);
    })();
    return () => {
      vivo = false;
    };
  }, [supabase, franquicia.id]);

  const mes = useMemo(
    () => meses.find((m) => m.mes === seleccionado) ?? null,
    [meses, seleccionado]
  );

  // La copia mensual es un libro con una hoja por tema, no un CSV suelto: es lo
  // que se archiva y lo que se le entrega al contador.
  async function exportar() {
    if (!mes) return;
    setExportando(true);
    setError(null);
    const desde = mes.mes;
    const hasta = new Date(mes.anio, mes.numero_mes, 0).toISOString().slice(0, 10);

    const [ventas, caja, stock, cierres] = await Promise.all([
      supabase
        .from("vista_ventas_franquicia_v47")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .gte("fecha", desde)
        .lte("fecha", hasta)
        .order("fecha"),
      supabase
        .from("vista_caja_franquicia_v42")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .gte("fecha", desde)
        .lte("fecha", hasta)
        .order("fecha"),
      supabase
        .from("vista_stock_operativo")
        .select("sku, producto, talla, color, stock_fisico, stock_disponible, precio, stock_minimo")
        .eq("almacen_id", franquicia.almacen_id)
        .order("producto"),
      supabase
        .from("franquicia_caja_cierres")
        .select("*")
        .eq("franquicia_id", franquicia.id)
        .gte("fecha", desde)
        .lte("fecha", hasta)
        .order("fecha"),
    ]);

    const fallo = ventas.error ?? caja.error ?? stock.error ?? cierres.error;
    if (fallo) {
      setExportando(false);
      return setError(mensajeError(fallo));
    }

    const resumen = [
      { Concepto: "Local", Valor: franquicia.nombre },
      { Concepto: "Período", Valor: etiquetaMes(mes) },
      { Concepto: "Ingresos", Valor: mes.ingresos },
      { Concepto: "  De ventas", Valor: mes.ingresos_por_venta },
      { Concepto: "  Otros ingresos", Valor: mes.otros_ingresos },
      { Concepto: "Egresos", Valor: mes.egresos },
      { Concepto: "Resultado operativo (caja)", Valor: mes.resultado_operativo },
      { Concepto: "", Valor: "" },
      { Concepto: "Cobrado en efectivo", Valor: mes.ingresos_efectivo },
      { Concepto: "Cobrado por transferencia", Valor: mes.ingresos_transferencia },
      { Concepto: "Cobrado con tarjeta", Valor: mes.ingresos_tarjeta },
      { Concepto: "", Valor: "" },
      { Concepto: "Ventas registradas", Valor: mes.ventas_registradas },
      { Concepto: "Ventas anuladas", Valor: mes.ventas_anuladas },
      { Concepto: "Unidades vendidas", Valor: mes.unidades_vendidas },
      { Concepto: "Descuentos otorgados", Valor: mes.descuentos_otorgados },
      { Concepto: "", Valor: "" },
      { Concepto: "Días cerrados", Valor: mes.dias_cerrados },
      { Concepto: "Días con diferencia de caja", Valor: mes.dias_con_diferencia },
      { Concepto: "Diferencia acumulada", Valor: mes.diferencia_acumulada },
      { Concepto: "", Valor: "" },
      { Concepto: "Inventario: unidades hoy", Valor: inventario?.unidades ?? 0 },
      {
        Concepto: "Inventario: valor a precio de venta",
        Valor: inventario?.valor_a_precio_venta ?? 0,
      },
      {
        Concepto: "El resultado es de caja",
        Valor: "No descuenta el costo de la mercadería, que se controla a nivel de grupo.",
      },
    ];

    const libro = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(resumen), "Resumen");
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(ventas.data ?? []), "Ventas");
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(caja.data ?? []), "Caja");
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(cierres.data ?? []), "Cierres");
    XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(stock.data ?? []), "Inventario");

    const nombre = `${franquicia.codigo}_${mes.anio}-${String(mes.numero_mes).padStart(2, "0")}.xlsx`;
    XLSX.writeFile(libro, nombre);
    setExportando(false);
  }

  if (cargando) return <p className="ayuda">Cargando el resumen mensual…</p>;

  return (
    <>
      <Aviso error={error} onCerrar={() => setError(null)} />

      {!meses.length ? (
        <p className="ayuda">
          Todavía no hay movimientos que resumir. El mes aparece aquí en cuanto el local
          registre su primera venta o movimiento de caja.
        </p>
      ) : (
        <>
          <div className="filtros">
            <label>
              Mes
              <select
                value={seleccionado}
                onChange={(e) => setSeleccionado(e.target.value)}
              >
                {meses.map((m) => (
                  <option key={m.mes} value={m.mes}>
                    {etiquetaMes(m)}
                  </option>
                ))}
              </select>
            </label>
            <button onClick={exportar} disabled={exportando || !mes}>
              {exportando ? "Preparando…" : "Descargar mes en Excel"}
            </button>
          </div>

          {mes && (
            <>
              <div className="kpis">
                <div className="kpi">
                  <span className="valor">{dinero(mes.ingresos)}</span>
                  <span className="label">Ingresos</span>
                </div>
                <div className="kpi">
                  <span className="valor">{dinero(mes.egresos)}</span>
                  <span className="label">Egresos</span>
                </div>
                <div className={`kpi ${mes.resultado_operativo < 0 ? "alerta" : ""}`}>
                  <span className="valor">{dinero(mes.resultado_operativo)}</span>
                  <span className="label">Resultado operativo</span>
                </div>
                <div className="kpi">
                  <span className="valor">{dinero(inventario?.valor_a_precio_venta ?? 0)}</span>
                  <span className="label">Inventario hoy</span>
                </div>
                <div className={`kpi ${mes.dias_con_diferencia ? "alerta" : ""}`}>
                  <span className="valor">{mes.dias_con_diferencia}</span>
                  <span className="label">Días con diferencia</span>
                </div>
              </div>

              <p className="ayuda">
                El resultado es de <strong>caja</strong>: lo que entró menos lo que salió
                del local. No descuenta el costo de la mercadería, que llega por
                transferencia y se controla a nivel de grupo.
              </p>

              <div className="card-interna">
                <h4>Cómo se cobró</h4>
                <div className="tabla-scroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Medio</th>
                        <th className="num">Cobrado</th>
                        <th className="num">Participación</th>
                      </tr>
                    </thead>
                    <tbody>
                      {[
                        ["Efectivo", mes.ingresos_efectivo],
                        ["Transferencia", mes.ingresos_transferencia],
                        ["Tarjeta", mes.ingresos_tarjeta],
                        [
                          "Otros",
                          mes.ingresos -
                            mes.ingresos_efectivo -
                            mes.ingresos_transferencia -
                            mes.ingresos_tarjeta,
                        ],
                      ]
                        .filter(([, v]) => Number(v) !== 0)
                        .map(([etiqueta, valor]) => (
                          <tr key={String(etiqueta)}>
                            <td>{etiqueta}</td>
                            <td className="num">{dinero(Number(valor))}</td>
                            <td className="num">
                              {mes.ingresos
                                ? `${((Number(valor) / mes.ingresos) * 100).toFixed(1)}%`
                                : "—"}
                            </td>
                          </tr>
                        ))}
                    </tbody>
                  </table>
                </div>
              </div>

              <div className="tabla-scroll">
                <table>
                  <thead>
                    <tr>
                      <th>Mes</th>
                      <th className="num">Ingresos</th>
                      <th className="num">Egresos</th>
                      <th className="num">Resultado</th>
                      <th className="num">Ventas</th>
                      <th className="num">Unidades</th>
                      <th className="num">Días cerrados</th>
                      <th className="num">Diferencia</th>
                    </tr>
                  </thead>
                  <tbody>
                    {meses.map((m) => (
                      <tr
                        key={m.mes}
                        className={m.mes === seleccionado ? "fila-activa" : ""}
                        onClick={() => setSeleccionado(m.mes)}
                        style={{ cursor: "pointer" }}
                      >
                        <td>{etiquetaMes(m)}</td>
                        <td className="num">{dinero(m.ingresos)}</td>
                        <td className="num">{dinero(m.egresos)}</td>
                        <td className="num">
                          <strong>{dinero(m.resultado_operativo)}</strong>
                        </td>
                        <td className="num">
                          {m.ventas_registradas}
                          {m.ventas_anuladas > 0 && (
                            <small> · {m.ventas_anuladas} anul.</small>
                          )}
                        </td>
                        <td className="num">{m.unidades_vendidas}</td>
                        <td className="num">{m.dias_cerrados}</td>
                        <td className="num">
                          {Math.abs(m.diferencia_acumulada) >= 0.01 ? (
                            <span className="badge bajo">{dinero(m.diferencia_acumulada)}</span>
                          ) : (
                            "—"
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </>
      )}
    </>
  );
}
