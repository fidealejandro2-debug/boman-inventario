"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { nuevaClaveIdempotencia } from "@/lib/erp";
import { pedirTextoDialogo } from "@/components/Dialogo";

type Usuario = { id: string; nombre_completo: string; email: string; rol: string; activo: boolean };

type FilaMatriz = {
  perfil_id: string;
  permiso_codigo: string;
  modulo: string;
  nombre: string;
  descripcion: string;
  orden: number;
  permitido_por_rol: boolean;
  permitido_override: boolean | null;
};

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

// null = hereda del rol (sin excepción). true/false = excepción explícita.
type Override = boolean | null;

export default function PermisosPersonaCliente() {
  const supabase = createClient();
  const [usuarios, setUsuarios] = useState<Usuario[]>([]);
  const [busquedaPersona, setBusquedaPersona] = useState("");
  const [seleccionado, setSeleccionado] = useState<Usuario | null>(null);
  const [filas, setFilas] = useState<FilaMatriz[]>([]);
  const [original, setOriginal] = useState<Record<string, Override>>({});
  const [valores, setValores] = useState<Record<string, Override>>({});
  const [cargandoUsuarios, setCargandoUsuarios] = useState(true);
  const [cargandoMatriz, setCargandoMatriz] = useState(false);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mensaje, setMensaje] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/admin/usuarios")
      .then((r) => r.json())
      .then((d) => setUsuarios(((d.usuarios ?? []) as Usuario[]).filter((u) => u.rol !== "admin" && u.activo)))
      .catch((e) => setError(e instanceof Error ? e.message : "No se pudo cargar la lista de usuarios."))
      .finally(() => setCargandoUsuarios(false));
  }, []);

  const coincidencias = useMemo(() => {
    const q = busquedaPersona.trim().toLocaleLowerCase("es");
    if (!q) return usuarios;
    return usuarios.filter((u) => `${u.nombre_completo} ${u.email}`.toLocaleLowerCase("es").includes(q));
  }, [usuarios, busquedaPersona]);

  async function seleccionar(usuario: Usuario) {
    setSeleccionado(usuario);
    setCargandoMatriz(true);
    setError(null);
    setMensaje(null);
    const { data, error: consultaError } = await supabase
      .from("vista_matriz_permisos_usuario_v107")
      .select("*")
      .eq("perfil_id", usuario.id)
      .order("orden");
    setCargandoMatriz(false);
    if (consultaError) return setError(consultaError.message);

    const nuevas = (data as FilaMatriz[]) ?? [];
    const mapa = Object.fromEntries(nuevas.map((f) => [f.permiso_codigo, f.permitido_override]));
    setFilas(nuevas);
    setOriginal(mapa);
    setValores(mapa);
  }

  const modulos = useMemo(() => [...new Set(filas.map((f) => f.modulo))], [filas]);

  const cambios = useMemo(
    () => filas.filter((f) => valores[f.permiso_codigo] !== original[f.permiso_codigo]).length,
    [filas, valores, original]
  );

  async function guardar() {
    if (!seleccionado || !cambios) return;
    const motivo = await pedirTextoDialogo(
      `Motivo para cambiar ${cambios} permiso(s) individuales de ${seleccionado.nombre_completo}:`,
      "Excepción puntual acordada con el responsable del área"
    );
    if (motivo === null) return;
    if (!motivo.trim()) return setError("El motivo del cambio es obligatorio.");

    setGuardando(true);
    setError(null);
    setMensaje(null);
    const items = filas
      .filter((f) => valores[f.permiso_codigo] !== original[f.permiso_codigo])
      .map((f) => ({ permiso_codigo: f.permiso_codigo, permitido: valores[f.permiso_codigo] }));
    const { data, error: guardarError } = await supabase.rpc("admin_guardar_permisos_usuario_v107", {
      p_perfil_id: seleccionado.id,
      p_items: items,
      p_motivo: motivo,
      p_idempotency_key: nuevaClaveIdempotencia(),
    });
    setGuardando(false);
    if (guardarError) return setError(guardarError.message);

    const resultado = data as { mensaje?: string } | null;
    setMensaje(resultado?.mensaje ?? "Permisos actualizados.");
    await seleccionar(seleccionado);
  }

  return (
    <div className="card admin-workspace-card">
      <span className="eyebrow">ADMINISTRACIÓN</span><h1>Permisos por persona</h1>
      <p className="ayuda">
        Excepciones puntuales sobre el permiso que ya da el rol de esa persona. Sin excepción, se
        usa siempre el valor del rol (ver Permisos por rol).
      </p>
      <p className="aviso">No se pueden asignar excepciones a cuentas de Administrador: ya tienen acceso total por rol.</p>

      {error && <p className="error">{error}</p>}
      {mensaje && <p className="ok">{mensaje}</p>}

      <div className="form-inline" style={{ marginBottom: 16 }}>
        <input
          value={busquedaPersona}
          onChange={(e) => setBusquedaPersona(e.target.value)}
          placeholder="Buscar persona por nombre o correo…"
          aria-label="Buscar persona"
          style={{ minWidth: 260 }}
        />
      </div>

      {cargandoUsuarios ? (
        <p className="ayuda">Cargando personas…</p>
      ) : !seleccionado || busquedaPersona ? (
        <div className="tabla-scroll">
          <table>
            <thead><tr><th>Nombre</th><th>Correo</th><th>Rol</th><th></th></tr></thead>
            <tbody>
              {coincidencias.map((u) => (
                <tr key={u.id}>
                  <td>{u.nombre_completo}</td>
                  <td>{u.email}</td>
                  <td>{ETIQUETAS_ROL[u.rol] ?? u.rol}</td>
                  <td><button className="secondary" onClick={() => { setBusquedaPersona(""); void seleccionar(u); }}>Elegir</button></td>
                </tr>
              ))}
              {!coincidencias.length && <tr><td colSpan={4} className="conteo">Sin resultados.</td></tr>}
            </tbody>
          </table>
        </div>
      ) : null}

      {seleccionado && !busquedaPersona && (
        <>
          <div className="header-row" style={{ marginTop: 8 }}>
            <h3 style={{ margin: 0 }}>{seleccionado.nombre_completo} <span className="conteo">({ETIQUETAS_ROL[seleccionado.rol] ?? seleccionado.rol})</span></h3>
            <button className="secondary" onClick={() => setSeleccionado(null)}>Cambiar persona</button>
          </div>

          {cargandoMatriz ? (
            <p className="ayuda">Cargando permisos…</p>
          ) : (
            <>
              <div className="tabla-scroll">
                <table>
                  <thead><tr><th>Módulo / permiso</th><th>Da el rol</th><th>Excepción</th></tr></thead>
                  <tbody>
                    {modulos.flatMap((modulo) => {
                      const delModulo = filas.filter((f) => f.modulo === modulo);
                      return [
                        <tr key={`modulo-${modulo}`}>
                          <th colSpan={3} style={{ background: "#eef3f8" }}>{modulo}</th>
                        </tr>,
                        ...delModulo.map((f) => (
                          <tr key={f.permiso_codigo}>
                            <td><strong>{f.nombre}</strong><div className="conteo">{f.descripcion}</div></td>
                            <td style={{ textAlign: "center" }}>{f.permitido_por_rol ? "Sí" : "No"}</td>
                            <td style={{ textAlign: "center" }}>
                              <select
                                aria-label={`Excepción para ${f.nombre}`}
                                value={valores[f.permiso_codigo] === null ? "heredar" : valores[f.permiso_codigo] ? "conceder" : "denegar"}
                                disabled={guardando}
                                onChange={(e) => {
                                  const v = e.target.value;
                                  setValores({ ...valores, [f.permiso_codigo]: v === "heredar" ? null : v === "conceder" });
                                }}
                              >
                                <option value="heredar">Heredar del rol</option>
                                <option value="conceder">Conceder</option>
                                <option value="denegar">Denegar</option>
                              </select>
                            </td>
                          </tr>
                        )),
                      ];
                    })}
                  </tbody>
                </table>
              </div>

              <div className="form-inline" style={{ marginTop: 16 }}>
                <button disabled={!cambios || guardando} onClick={guardar}>
                  {guardando ? "Guardando…" : `Guardar excepciones${cambios ? ` (${cambios})` : ""}`}
                </button>
                <button className="secondary" disabled={guardando} onClick={() => setValores(original)}>Descartar cambios</button>
              </div>
            </>
          )}
        </>
      )}
    </div>
  );
}
