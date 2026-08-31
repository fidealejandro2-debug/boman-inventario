"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { hoyISO, mensajeError, soloFecha } from "./lib";

type Feriado = {
  fecha: string;
  nombre: string;
  tipo: "nacional" | "local";
  almacen_id: string | null;
};

type Almacen = { id: string; nombre: string; codigo: string };

// Plantilla revisable: la RPC solo la confirma cuando Nomina agrega una nota
// de control. Los feriados locales se cargan manualmente por almacen.
const NACIONALES_2026: Feriado[] = [
  { fecha: "2026-01-01", nombre: "Año Nuevo", tipo: "nacional", almacen_id: null },
  { fecha: "2026-02-16", nombre: "Carnaval", tipo: "nacional", almacen_id: null },
  { fecha: "2026-02-17", nombre: "Carnaval", tipo: "nacional", almacen_id: null },
  { fecha: "2026-04-03", nombre: "Viernes Santo", tipo: "nacional", almacen_id: null },
  { fecha: "2026-05-01", nombre: "Día del Trabajo", tipo: "nacional", almacen_id: null },
  { fecha: "2026-05-25", nombre: "Batalla del Pichincha (traslado)", tipo: "nacional", almacen_id: null },
  { fecha: "2026-08-10", nombre: "Primer Grito de Independencia", tipo: "nacional", almacen_id: null },
  { fecha: "2026-10-09", nombre: "Independencia de Guayaquil", tipo: "nacional", almacen_id: null },
  { fecha: "2026-11-02", nombre: "Día de Difuntos", tipo: "nacional", almacen_id: null },
  { fecha: "2026-11-03", nombre: "Independencia de Cuenca", tipo: "nacional", almacen_id: null },
  { fecha: "2026-12-25", nombre: "Navidad", tipo: "nacional", almacen_id: null },
];

export default function CalendarioFeriados({
  grupoId,
  puedeEscribir,
}: {
  grupoId: string;
  puedeEscribir: boolean;
}) {
  const supabase = createClient();
  const [anio, setAnio] = useState(Number(hoyISO().slice(0, 4)));
  const [estado, setEstado] = useState<"sin_calendario" | "borrador" | "confirmado">(
    "sin_calendario"
  );
  const [feriados, setFeriados] = useState<Feriado[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [nota, setNota] = useState("");
  const [nuevo, setNuevo] = useState<Feriado>({
    fecha: "",
    nombre: "",
    tipo: "nacional",
    almacen_id: null,
  });
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);

  async function cargar() {
    // Sin grupo no hay nada que consultar, pero hay que apagar el indicador:
    // arranca en true y salir con un return dejaba el "Cargando calendario…"
    // girando para siempre.
    if (!grupoId) {
      setCargando(false);
      return;
    }
    setCargando(true);
    setError(null);
    const [cal, dias, alm] = await Promise.all([
      supabase
        .from("feriados_anios")
        .select("estado, nota")
        .eq("grupo_id", grupoId)
        .eq("anio", anio)
        .maybeSingle(),
      supabase
        .from("feriados")
        .select("fecha, nombre, tipo, almacen_id")
        .eq("grupo_id", grupoId)
        .eq("anio", anio)
        .eq("activo", true)
        .order("fecha"),
      supabase
        .from("almacenes")
        .select("id, nombre, codigo")
        .eq("activo", true)
        .order("nombre"),
    ]);
    if (cal.error) setError(cal.error.message);
    else {
      setEstado((cal.data?.estado as typeof estado) ?? "sin_calendario");
      setNota((cal.data?.nota as string | null) ?? "");
    }
    if (dias.error) setError(dias.error.message);
    else setFeriados((dias.data as Feriado[]) ?? []);
    if (!alm.error) setAlmacenes((alm.data as Almacen[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    void cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [grupoId, anio]);

  function cargarPlantilla2026() {
    setFeriados(NACIONALES_2026.map((f) => ({ ...f })));
    setEstado("borrador");
    setMensaje("Plantilla 2026 cargada. Revísala y pulsa Confirmar calendario.");
  }

  function agregar() {
    setError(null);
    if (!nuevo.fecha || !nuevo.nombre.trim())
      return setError("Fecha y nombre del feriado son obligatorios.");
    if (!nuevo.fecha.startsWith(`${anio}-`))
      return setError(`La fecha debe pertenecer al año ${anio}.`);
    if (nuevo.tipo === "local" && !nuevo.almacen_id)
      return setError("El feriado local necesita una tienda o bodega.");
    if (
      feriados.some(
        (f) =>
          f.fecha === nuevo.fecha &&
          f.tipo === nuevo.tipo &&
          f.almacen_id === (nuevo.tipo === "nacional" ? null : nuevo.almacen_id)
      )
    ) return setError("Ese feriado ya está en la lista.");

    setFeriados(
      [...feriados, {
        ...nuevo,
        nombre: nuevo.nombre.trim(),
        almacen_id: nuevo.tipo === "nacional" ? null : nuevo.almacen_id,
      }].sort((a, b) => a.fecha.localeCompare(b.fecha))
    );
    setNuevo({ fecha: "", nombre: "", tipo: "nacional", almacen_id: null });
    setEstado("borrador");
  }

  async function guardar(confirmar: boolean) {
    if (!grupoId) return setError("No se encontró el grupo económico.");
    if (!feriados.length) return setError("Agrega al menos los feriados nacionales.");
    if (confirmar && !nota.trim())
      return setError("Escribe una nota indicando quién revisó el calendario.");

    setGuardando(true);
    setError(null);
    setMensaje(null);
    const { data, error: err } = await supabase.rpc("configurar_feriados_v27", {
      p_grupo_id: grupoId,
      p_anio: anio,
      p_items: feriados,
      p_confirmar: confirmar,
      p_nota: nota || null,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (err) return setError(mensajeError(err));
    const resultado = data as { confirmado?: boolean } | null;
    setMensaje(
      resultado?.confirmado
        ? `Calendario ${anio} confirmado. Ya puedes registrar ausencias.`
        : `Borrador ${anio} guardado.`
    );
    await cargar();
  }

  return (
    <details className="card-interna" open={estado !== "confirmado"}>
      <summary>
        <strong>Calendario de feriados</strong>{" "}
        <span className={`badge ${estado === "confirmado" ? "ok" : "bajo"}`}>
          {anio}: {estado === "sin_calendario" ? "sin crear" : estado}
        </span>
      </summary>

      <p className="ayuda">
        Las ausencias solo se calculan con un calendario confirmado. Revisa los días
        nacionales y agrega los feriados locales de cada tienda o bodega.
      </p>
      {error && <p className="error">{error}</p>}
      {mensaje && <p className="ok">{mensaje}</p>}

      <div className="filtros">
        <label>
          Año{" "}
          <input
            type="number"
            min="2020"
            max="2200"
            value={anio}
            onChange={(e) => setAnio(Number(e.target.value))}
          />
        </label>
        {puedeEscribir && anio === 2026 && !feriados.length && (
          <button onClick={cargarPlantilla2026}>Cargar nacionales 2026</button>
        )}
      </div>

      {cargando ? (
        <p className="ayuda">Cargando calendario…</p>
      ) : !grupoId ? (
        <p className="aviso">
          No se pudo determinar el grupo económico, así que el calendario de feriados
          no está disponible. Suele pasar cuando el usuario no tiene ninguna empresa
          activa asignada. Sin feriados cargados, los días hábiles de las ausencias se
          calculan como si no hubiera ninguno.
        </p>
      ) : (
        <>
          {puedeEscribir && (
            <div className="form-inline">
              <input
                type="date"
                value={nuevo.fecha}
                onChange={(e) => setNuevo({ ...nuevo, fecha: e.target.value })}
              />
              <input
                type="text"
                placeholder="Nombre del feriado"
                value={nuevo.nombre}
                onChange={(e) => setNuevo({ ...nuevo, nombre: e.target.value })}
              />
              <select
                value={nuevo.tipo}
                onChange={(e) =>
                  setNuevo({
                    ...nuevo,
                    tipo: e.target.value as Feriado["tipo"],
                    almacen_id: e.target.value === "nacional" ? null : nuevo.almacen_id,
                  })
                }
              >
                <option value="nacional">Nacional</option>
                <option value="local">Local</option>
              </select>
              {nuevo.tipo === "local" && (
                <select
                  value={nuevo.almacen_id ?? ""}
                  onChange={(e) => setNuevo({ ...nuevo, almacen_id: e.target.value || null })}
                >
                  <option value="">Tienda o bodega…</option>
                  {almacenes.map((a) => (
                    <option key={a.id} value={a.id}>{a.nombre}</option>
                  ))}
                </select>
              )}
              <button onClick={agregar}>Agregar</button>
            </div>
          )}

          <div className="tabla-scroll">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Feriado</th>
                  <th>Tipo</th>
                  <th>Tienda o bodega</th>
                  {puedeEscribir && <th></th>}
                </tr>
              </thead>
              <tbody>
                {feriados.map((f, i) => (
                  <tr key={`${f.fecha}-${f.tipo}-${f.almacen_id ?? "nacional"}`}>
                    <td>{soloFecha(f.fecha)}</td>
                    <td>{f.nombre}</td>
                    <td>{f.tipo === "nacional" ? "Nacional" : "Local"}</td>
                    <td>
                      {f.tipo === "nacional"
                        ? "Todo el grupo"
                        : almacenes.find((a) => a.id === f.almacen_id)?.nombre ?? "—"}
                    </td>
                    {puedeEscribir && (
                      <td>
                        <button
                          className="btn-mini secondary"
                          onClick={() => {
                            setFeriados(feriados.filter((_, n) => n !== i));
                            setEstado("borrador");
                          }}
                        >
                          Quitar
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
                {!feriados.length && (
                  <tr>
                    <td colSpan={puedeEscribir ? 5 : 4} className="vacio">
                      No existe calendario para {anio}.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          {puedeEscribir && feriados.length > 0 && (
            <div className="form-grid">
              <label className="ancho-total">
                Nota de revisión
                <input
                  type="text"
                  value={nota}
                  onChange={(e) => setNota(e.target.value)}
                  placeholder="Ej.: Revisado con calendario nacional y feriados locales 2026"
                />
              </label>
              <div className="filtros ancho-total">
                <button className="secondary" disabled={guardando} onClick={() => guardar(false)}>
                  Guardar borrador
                </button>
                <button disabled={guardando} onClick={() => guardar(true)}>
                  {guardando ? "Guardando…" : "Confirmar calendario"}
                </button>
              </div>
            </div>
          )}
        </>
      )}
    </details>
  );
}
