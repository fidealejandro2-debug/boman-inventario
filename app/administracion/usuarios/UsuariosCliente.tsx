"use client";

import { useEffect, useMemo, useState } from "react";
import { fecha } from "@/lib/utils";

type Rol = "admin" | "bodega" | "logistica" | "gerencia";
type Almacen = { id: string; nombre: string; tipo: string; activo: boolean };
type Usuario = {
  id: string;
  email: string;
  nombre_completo: string;
  rol: Rol;
  entidad_id: string | null;
  activo: boolean;
  confirmado: boolean;
  ultimo_acceso: string | null;
  created_at: string;
};

const ROLES: { valor: Rol; etiqueta: string }[] = [
  { valor: "admin", etiqueta: "Administrador" },
  { valor: "bodega", etiqueta: "Bodega" },
  { valor: "logistica", etiqueta: "Logística" },
  { valor: "gerencia", etiqueta: "Gerencia" },
];

const NUEVO = {
  email: "",
  nombre_completo: "",
  rol: "bodega" as Rol,
  entidad_id: "",
};

export default function UsuariosCliente({ usuarioActualId }: { usuarioActualId: string }) {
  const [usuarios, setUsuarios] = useState<Usuario[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [mostrarInvitacion, setMostrarInvitacion] = useState(false);
  const [nuevo, setNuevo] = useState({ ...NUEVO });
  const [editando, setEditando] = useState<string | null>(null);
  const [edicion, setEdicion] = useState<Partial<Usuario>>({});
  const [busqueda, setBusqueda] = useState("");
  const [msg, setMsg] = useState<{ tipo: "error" | "ok"; texto: string } | null>(null);

  async function peticion(url: string, opciones?: RequestInit) {
    const response = await fetch(url, opciones);
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error ?? "No se pudo completar la operación.");
    return data;
  }

  async function cargar() {
    setCargando(true);
    try {
      const data = await peticion("/api/admin/usuarios");
      setUsuarios(data.usuarios ?? []);
      setAlmacenes(data.almacenes ?? []);
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudieron cargar los usuarios." });
    } finally {
      setCargando(false);
    }
  }

  useEffect(() => { cargar(); }, []);

  const filtrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    if (!q) return usuarios;
    return usuarios.filter((usuario) =>
      usuario.nombre_completo.toLowerCase().includes(q) ||
      usuario.email.toLowerCase().includes(q) ||
      usuario.rol.toLowerCase().includes(q) ||
      (almacenes.find((a) => a.id === usuario.entidad_id)?.nombre ?? "").toLowerCase().includes(q)
    );
  }, [usuarios, almacenes, busqueda]);

  async function invitar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    if (nuevo.rol === "bodega" && !nuevo.entidad_id) {
      setMsg({ tipo: "error", texto: "Un usuario de bodega debe tener un almacén asignado." });
      return;
    }

    setGuardando(true);
    try {
      const data = await peticion("/api/admin/usuarios", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...nuevo,
          entidad_id: ["admin", "gerencia"].includes(nuevo.rol) ? null : nuevo.entidad_id || null,
        }),
      });
      setMsg({ tipo: "ok", texto: data.mensaje ?? "Invitación enviada." });
      setNuevo({ ...NUEVO });
      setMostrarInvitacion(false);
      await cargar();
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo enviar la invitación." });
    } finally {
      setGuardando(false);
    }
  }

  function editar(usuario: Usuario) {
    setEditando(usuario.id);
    setEdicion({
      nombre_completo: usuario.nombre_completo,
      rol: usuario.rol,
      entidad_id: usuario.entidad_id,
      activo: usuario.activo,
    });
    setMsg(null);
  }

  async function guardar(usuario: Usuario) {
    setMsg(null);
    setGuardando(true);
    try {
      await peticion("/api/admin/usuarios", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          id: usuario.id,
          nombre_completo: edicion.nombre_completo,
          rol: edicion.rol,
          entidad_id: ["admin", "gerencia"].includes(String(edicion.rol)) ? null : edicion.entidad_id || null,
          activo: edicion.activo,
        }),
      });
      setEditando(null);
      setMsg({ tipo: "ok", texto: "Usuario actualizado." });
      await cargar();
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo actualizar el usuario." });
    } finally {
      setGuardando(false);
    }
  }

  return (
    <>
      <div className="header-row">
        <div>
          <h2 style={{ color: "#1f3864", margin: 0 }}>Administración de usuarios</h2>
          <div className="conteo" style={{ marginTop: 4 }}>{usuarios.length} usuario(s) registrado(s)</div>
        </div>
        <button onClick={() => setMostrarInvitacion((valor) => !valor)}>
          {mostrarInvitacion ? "Cancelar" : "+ Invitar usuario"}
        </button>
      </div>

      {msg && <div className={msg.tipo === "error" ? "error" : "success"} style={{ marginBottom: 14 }}>{msg.texto}</div>}

      {mostrarInvitacion && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Invitar nuevo usuario</h3>
          <p className="conteo">Recibirá un correo para establecer su contraseña.</p>
          <form onSubmit={invitar}>
            <div className="grid-2">
              <div className="field">
                <label>Nombre completo</label>
                <input required value={nuevo.nombre_completo}
                  onChange={(e) => setNuevo({ ...nuevo, nombre_completo: e.target.value })} style={{ width: "100%" }} />
              </div>
              <div className="field">
                <label>Correo electrónico</label>
                <input required type="email" value={nuevo.email}
                  onChange={(e) => setNuevo({ ...nuevo, email: e.target.value })} style={{ width: "100%" }} />
              </div>
              <div className="field">
                <label>Rol</label>
                <select value={nuevo.rol} onChange={(e) => setNuevo({ ...nuevo, rol: e.target.value as Rol, entidad_id: "" })} style={{ width: "100%" }}>
                  {ROLES.map((rol) => <option key={rol.valor} value={rol.valor}>{rol.etiqueta}</option>)}
                </select>
              </div>
              {!['admin', 'gerencia'].includes(nuevo.rol) && (
                <div className="field">
                  <label>Almacén asignado</label>
                  <select value={nuevo.entidad_id} onChange={(e) => setNuevo({ ...nuevo, entidad_id: e.target.value })} style={{ width: "100%" }}>
                    <option value="">Todos los almacenes (acceso global)</option>
                    {almacenes.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}
                  </select>
                </div>
              )}
            </div>
            <button type="submit" disabled={guardando}>{guardando ? "Enviando..." : "Enviar invitación"}</button>
          </form>
        </div>
      )}

      <div className="card">
        <div className="filtros">
          <div className="field buscador">
            <label>Buscar</label>
            <input value={busqueda} onChange={(e) => setBusqueda(e.target.value)}
              placeholder="Nombre, correo, rol o almacén..." />
          </div>
        </div>

        {cargando ? <div className="vacio">Cargando usuarios...</div> : (
          <div className="tabla-scroll">
            <table>
              <thead>
                <tr><th>Usuario</th><th>Rol</th><th>Almacén</th><th>Estado</th><th>Último acceso</th><th>Acciones</th></tr>
              </thead>
              <tbody>
                {filtrados.map((usuario) => {
                  const estaEditando = editando === usuario.id;
                  const rolEdicion = (edicion.rol ?? usuario.rol) as Rol;
                  return (
                    <tr key={usuario.id}>
                      <td>
                        {estaEditando ? (
                          <input value={String(edicion.nombre_completo ?? "")}
                            onChange={(e) => setEdicion({ ...edicion, nombre_completo: e.target.value })} />
                        ) : <strong>{usuario.nombre_completo}</strong>}
                        <div className="conteo">{usuario.email || "Sin correo disponible"}</div>
                      </td>
                      <td>
                        {estaEditando ? (
                          <select value={rolEdicion} onChange={(e) => setEdicion({ ...edicion, rol: e.target.value as Rol, entidad_id: null })}>
                            {ROLES.map((rol) => <option key={rol.valor} value={rol.valor}>{rol.etiqueta}</option>)}
                          </select>
                        ) : ROLES.find((r) => r.valor === usuario.rol)?.etiqueta}
                      </td>
                      <td>
                        {estaEditando && !['admin', 'gerencia'].includes(rolEdicion) ? (
                          <select value={edicion.entidad_id ?? ""} onChange={(e) => setEdicion({ ...edicion, entidad_id: e.target.value || null })}>
                            <option value="">Todos (acceso global)</option>
                            {almacenes.map((a) => <option key={a.id} value={a.id}>{a.nombre}</option>)}
                          </select>
                        ) : ['admin', 'gerencia'].includes(estaEditando ? rolEdicion : usuario.rol)
                          ? "Todos"
                          : almacenes.find((a) => a.id === usuario.entidad_id)?.nombre ?? "Todos"}
                      </td>
                      <td>
                        {estaEditando ? (
                          <label style={{ fontWeight: 500, whiteSpace: "nowrap" }}>
                            <input type="checkbox" checked={Boolean(edicion.activo)}
                              disabled={usuario.id === usuarioActualId}
                              onChange={(e) => setEdicion({ ...edicion, activo: e.target.checked })} style={{ marginRight: 5 }} />
                            Activo
                          </label>
                        ) : (
                          <span className={`badge ${usuario.activo ? "ok" : "cero"}`}>{usuario.activo ? "Activo" : "Inactivo"}</span>
                        )}
                      </td>
                      <td className="conteo">
                        {usuario.ultimo_acceso ? fecha(usuario.ultimo_acceso) : usuario.confirmado ? "Sin ingresos" : "Invitación pendiente"}
                      </td>
                      <td style={{ whiteSpace: "nowrap" }}>
                        {estaEditando ? (
                          <>
                            <button disabled={guardando} onClick={() => guardar(usuario)} style={{ marginRight: 6 }}>Guardar</button>
                            <button className="chip-limpiar" onClick={() => setEditando(null)}>Cancelar</button>
                          </>
                        ) : (
                          <button className="secondary" onClick={() => editar(usuario)}>Editar</button>
                        )}
                      </td>
                    </tr>
                  );
                })}
                {!filtrados.length && <tr><td colSpan={6} className="vacio">No hay usuarios con ese filtro.</td></tr>}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
