"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { pedirTextoDialogo } from "@/components/Dialogo";

type FilaMatriz = {
  rol: string;
  permiso_codigo: string;
  modulo: string;
  nombre: string;
  descripcion: string;
  orden: number;
  permitido: boolean;
  configurable: boolean;
};

const ROLES = ["admin", "bodega", "logistica", "gerencia", "tienda", "control", "nomina", "franquiciado", "vendedor_franquicia"];
const ETIQUETAS_ROL: Record<string, string> = {
  admin: "Administrador",
  bodega: "Bodega",
  logistica: "Logística",
  gerencia: "Gerencia",
  tienda: "Tienda",
  control: "Control",
  nomina: "Nómina",
  franquiciado: "Franquiciado",
  vendedor_franquicia: "Vendedor de franquicia",
};

export default function PermisosCliente() {
  const supabase = createClient();
  const [filas, setFilas] = useState<FilaMatriz[]>([]);
  const [original, setOriginal] = useState<Record<string, boolean>>({});
  const [valores, setValores] = useState<Record<string, boolean>>({});
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);

  const clave = (rol: string, permiso: string) => `${rol}:${permiso}`;

  async function cargar() {
    setCargando(true);
    setError(null);
    const { data, error: consultaError } = await supabase
      .from("vista_matriz_permisos_v35")
      .select("*")
      .order("orden")
      .order("rol");
    setCargando(false);
    if (consultaError) return setError(consultaError.message);

    const nuevas = (data as FilaMatriz[]) ?? [];
    const mapa = Object.fromEntries(
      nuevas.map((f) => [clave(f.rol, f.permiso_codigo), f.permitido])
    );
    setFilas(nuevas);
    setOriginal(mapa);
    setValores(mapa);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const permisos = useMemo(() => {
    const unicos = new Map<string, FilaMatriz>();
    filas.forEach((f) => {
      if (!unicos.has(f.permiso_codigo)) unicos.set(f.permiso_codigo, f);
    });
    return [...unicos.values()].sort((a, b) => a.orden - b.orden);
  }, [filas]);

  const modulos = useMemo(
    () => [...new Set(permisos.map((p) => p.modulo))],
    [permisos]
  );

  function cambiosRol(rol: string) {
    return permisos.filter(
      (p) =>
        valores[clave(rol, p.permiso_codigo)] !==
        original[clave(rol, p.permiso_codigo)]
    ).length;
  }

  async function guardarRol(rol: string) {
    const cambios = cambiosRol(rol);
    if (!cambios) return;
    const motivo = await pedirTextoDialogo(`Motivo para cambiar ${cambios} permiso(s) de ${ETIQUETAS_ROL[rol]}:`, "Ajuste de responsabilidades del rol");
    if (motivo === null) return;
    if (!motivo.trim()) return setError("El motivo del cambio es obligatorio.");

    setGuardando(rol);
    setError(null);
    setMensaje(null);
    const { data, error: guardarError } = await supabase.rpc(
      "admin_guardar_permisos_rol_v35",
      {
        p_rol: rol,
        p_items: permisos.map((p) => ({
          permiso_codigo: p.permiso_codigo,
          permitido: Boolean(valores[clave(rol, p.permiso_codigo)]),
        })),
        p_motivo: motivo,
        p_idempotency_key: nuevaClaveIdempotencia(),
      }
    );
    setGuardando(null);
    if (guardarError) return setError(guardarError.message);

    const resultado = data as { mensaje?: string } | null;
    setMensaje(resultado?.mensaje ?? "Permisos actualizados.");
    await cargar();
  }

  if (cargando) return <div className="card"><p className="ayuda">Cargando permisos…</p></div>;

  return (
    <div className="card">
      <h2>Permisos por rol</h2>
      <p className="ayuda">
        Define qué módulos aparecen y pueden abrir los usuarios de cada rol. Las
        asignaciones de empresa y almacén siguen limitando la información visible.
      </p>
      <p className="aviso">
        Las reglas críticas no se pueden desactivar desde aquí: Administración conserva
        acceso total, nadie puede aprobar su propio conteo y las acciones sensibles
        mantienen sus validaciones internas.
      </p>

      {error && <p className="error">{error}</p>}
      {mensaje && <p className="ok">{mensaje}</p>}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Módulo / permiso</th>
              {ROLES.map((rol) => (
                <th key={rol} style={{ textAlign: "center" }}>
                  {ETIQUETAS_ROL[rol]}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {modulos.flatMap((modulo) => {
              const delModulo = permisos.filter((p) => p.modulo === modulo);
              return [
                <tr key={`modulo-${modulo}`}>
                  <th colSpan={ROLES.length + 1} style={{ background: "#eef3f8" }}>
                    {modulo}
                  </th>
                </tr>,
                ...delModulo.map((permiso) => (
                  <tr key={permiso.permiso_codigo}>
                    <td>
                      <strong>{permiso.nombre}</strong>
                      <div className="conteo">{permiso.descripcion}</div>
                    </td>
                    {ROLES.map((rol) => {
                      const id = clave(rol, permiso.permiso_codigo);
                      return (
                        <td key={rol} style={{ textAlign: "center" }}>
                          <input
                            type="checkbox"
                            aria-label={`${permiso.nombre} para ${ETIQUETAS_ROL[rol]}`}
                            checked={Boolean(valores[id])}
                            disabled={rol === "admin" || guardando !== null}
                            onChange={(e) =>
                              setValores({ ...valores, [id]: e.target.checked })
                            }
                          />
                        </td>
                      );
                    })}
                  </tr>
                )),
              ];
            })}
          </tbody>
        </table>
      </div>

      <div className="form-inline" style={{ marginTop: 16 }}>
        {ROLES.filter((rol) => rol !== "admin").map((rol) => {
          const cambios = cambiosRol(rol);
          return (
            <button
              key={rol}
              disabled={!cambios || guardando !== null}
              onClick={() => guardarRol(rol)}
            >
              {guardando === rol
                ? "Guardando…"
                : `Guardar ${ETIQUETAS_ROL[rol]}${cambios ? ` (${cambios})` : ""}`}
            </button>
          );
        })}
        <button
          className="secondary"
          disabled={guardando !== null}
          onClick={() => setValores(original)}
        >
          Descartar cambios
        </button>
      </div>
    </div>
  );
}
