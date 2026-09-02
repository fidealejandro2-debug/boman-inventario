"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { dinero, mensajeError } from "./lib";
import Aviso from "@/components/Aviso";

type Parametros = {
  anio: number;
  salario_basico_unificado: number;
  pct_aporte_personal: number;
  pct_aporte_patronal: number;
  pct_fondos_reserva: number;
  pct_iece: number;
  pct_secap: number;
  horas_jornada_semanal: number;
  tope_multa_pct: number;
  tope_descuento_total_pct: number;
};

const CAMPOS: { clave: keyof Parametros; etiqueta: string; ayuda?: string }[] = [
  { clave: "salario_basico_unificado", etiqueta: "Salario básico unificado", ayuda: "Base del décimo cuarto" },
  { clave: "pct_aporte_personal", etiqueta: "Aporte personal %", ayuda: "Descuento al trabajador" },
  { clave: "pct_aporte_patronal", etiqueta: "Aporte patronal %", ayuda: "Costo del empleador" },
  { clave: "pct_fondos_reserva", etiqueta: "Fondos de reserva %", ayuda: "Desde el mes 13 acumulado bajo el mismo RUC" },
  { clave: "pct_iece", etiqueta: "IECE %" },
  { clave: "pct_secap", etiqueta: "SECAP %" },
  { clave: "horas_jornada_semanal", etiqueta: "Horas de jornada semanal" },
  { clave: "tope_multa_pct", etiqueta: "Tope de multa %", ayuda: "Sobre la remuneración mensual" },
  { clave: "tope_descuento_total_pct", etiqueta: "Tope de descuentos %", ayuda: "Suma de todas las cuotas" },
];

export default function ParametrosTab({ esAdmin }: { esAdmin: boolean }) {
  const supabase = createClient();
  const [filas, setFilas] = useState<Parametros[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);

  const anioActual = new Date().getFullYear();
  const [motivo, setMotivo] = useState("");
  const [form, setForm] = useState<Record<string, string>>({
    anio: String(anioActual),
    salario_basico_unificado: "",
    pct_aporte_personal: "9.45",
    pct_aporte_patronal: "11.15",
    pct_fondos_reserva: "8.33",
    pct_iece: "0.50",
    pct_secap: "0.50",
    horas_jornada_semanal: "40",
    tope_multa_pct: "10",
    tope_descuento_total_pct: "50",
  });

  async function cargar() {
    setCargando(true);
    const { data, error } = await supabase
      .from("nomina_parametros")
      .select("*")
      .order("anio", { ascending: false });
    if (error) setError(error.message);
    else setFilas((data as Parametros[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function guardar() {
    if (!form.salario_basico_unificado)
      return setError("El salario básico unificado es obligatorio.");
    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("guardar_nomina_parametros_v32", {
      p_anio: Number(form.anio),
      p_salario_basico_unificado: Number(form.salario_basico_unificado),
      p_pct_aporte_personal: Number(form.pct_aporte_personal),
      p_pct_aporte_patronal: Number(form.pct_aporte_patronal),
      p_pct_fondos_reserva: Number(form.pct_fondos_reserva),
      p_pct_iece: Number(form.pct_iece),
      p_pct_secap: Number(form.pct_secap),
      p_horas_jornada_semanal: Number(form.horas_jornada_semanal),
      p_tope_multa_pct: Number(form.tope_multa_pct),
      p_tope_descuento_total_pct: Number(form.tope_descuento_total_pct),
      // Obligatorio si el año ya estaba cargado; se ignora en la carga inicial.
      p_motivo: motivo || null,
    });
    setGuardando(false);
    if (error) return setError(mensajeError(error));
    setAviso(`Parámetros del ${form.anio} guardados.`);
    cargar();
  }

  const faltaAnioActual = !cargando && !filas.some((f) => f.anio === anioActual);

  if (cargando) return <p className="ayuda">Cargando parámetros…</p>;

  return (
    <>
      <Aviso error={error} aviso={aviso} onCerrar={(cual) => (cual === "error" ? setError(null) : setAviso(null))} />
      {faltaAnioActual && (
        <p className="aviso">
          No hay parámetros cargados para {anioActual}. Sin ellos no se puede calcular
          ningún rol ni validar el tope de las multas.
        </p>
      )}

      <p className="ayuda">
        Los porcentajes cambian por normativa: por eso viven aquí y no en el código. El
        SBU es el valor vigente publicado para el año; un valor equivocado corrompe todos
        los décimos cuartos del ejercicio.
      </p>

      {esAdmin && (
        <div className="card-interna">
          <h4>Cargar o actualizar un año</h4>
          <div className="form-grid">
            <label>
              Año
              <input
                type="number"
                min="2020"
                max="2100"
                value={form.anio}
                onChange={(e) => setForm({ ...form, anio: e.target.value })}
              />
            </label>
            {CAMPOS.map((c) => (
              <label key={c.clave}>
                {c.etiqueta}
                <input
                  type="number"
                  step="0.01"
                  min="0"
                  value={form[c.clave] ?? ""}
                  onChange={(e) => setForm({ ...form, [c.clave]: e.target.value })}
                />
                {c.ayuda && <small>{c.ayuda}</small>}
              </label>
            ))}
            <label className="ancho-total">
              Motivo del cambio
              <input
                type="text"
                placeholder="Obligatorio si el año ya estaba cargado"
                value={motivo}
                onChange={(e) => setMotivo(e.target.value)}
              />
              <small>
                Un año con roles cerrados queda congelado: sus parámetros ya no se
                pueden tocar.
              </small>
            </label>
          </div>
          <button onClick={guardar} disabled={guardando}>
            {guardando ? "Guardando…" : "Guardar parámetros"}
          </button>
        </div>
      )}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Año</th>
              <th className="num">SBU</th>
              <th className="num">Personal</th>
              <th className="num">Patronal</th>
              <th className="num">Fondos</th>
              <th className="num">IECE</th>
              <th className="num">SECAP</th>
              <th className="num">Jornada</th>
              <th className="num">Tope multa</th>
              <th className="num">Tope descuentos</th>
            </tr>
          </thead>
          <tbody>
            {filas.map((f) => (
              <tr key={f.anio}>
                <td>
                  <strong>{f.anio}</strong>
                </td>
                <td className="num">{dinero(f.salario_basico_unificado)}</td>
                <td className="num">{f.pct_aporte_personal}%</td>
                <td className="num">{f.pct_aporte_patronal}%</td>
                <td className="num">{f.pct_fondos_reserva}%</td>
                <td className="num">{f.pct_iece}%</td>
                <td className="num">{f.pct_secap}%</td>
                <td className="num">{f.horas_jornada_semanal} h</td>
                <td className="num">{f.tope_multa_pct}%</td>
                <td className="num">{f.tope_descuento_total_pct}%</td>
              </tr>
            ))}
            {!filas.length && (
              <tr>
                <td colSpan={10} className="vacio">
                  Ningún año cargado todavía.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
