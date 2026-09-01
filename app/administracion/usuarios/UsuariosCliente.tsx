"use client";

import { useEffect, useMemo, useState } from "react";
import { fecha } from "@/lib/utils";

type Rol = "admin" | "bodega" | "logistica" | "gerencia" | "tienda" | "control" | "nomina" | "franquiciado" | "vendedor_franquicia";
type Almacen = { id: string; nombre: string; tipo: string; activo: boolean };
type Usuario = {
  id: string;
  email: string;
  nombre_completo: string;
  rol: Rol;
  entidad_id: string | null;
  almacen_ids: string[];
  configuracion_incompleta: boolean;
  activo: boolean;
  confirmado: boolean;
  ultimo_acceso: string | null;
  created_at: string;
};
type EnlaceAcceso = {
  email: string;
  enlace: string;
  tipo: "activacion" | "recuperacion";
};

const ROLES: { valor: Rol; etiqueta: string }[] = [
  { valor: "admin", etiqueta: "Administrador" },
  { valor: "bodega", etiqueta: "Bodega" },
  { valor: "logistica", etiqueta: "Logística" },
  { valor: "tienda", etiqueta: "Tienda" },
  { valor: "control", etiqueta: "Control" },
  { valor: "gerencia", etiqueta: "Gerencia" },
  { valor: "nomina", etiqueta: "Nómina" },
  { valor: "franquiciado", etiqueta: "Franquiciado" },
  { valor: "vendedor_franquicia", etiqueta: "Vendedor de franquicia" },
];

const ROLES_SIN_ALMACEN: Rol[] = ["admin", "control", "gerencia", "nomina"];
const ROLES_UN_SOLO_ALMACEN: Rol[] = ["franquiciado", "vendedor_franquicia"];

const NUEVO = {
  email: "",
  nombre_completo: "",
  rol: "bodega" as Rol,
  almacen_ids: [] as string[],
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
  const [enlaceAcceso, setEnlaceAcceso] = useState<EnlaceAcceso | null>(null);

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
      usuario.almacen_ids.some((id) => (almacenes.find((a) => a.id === id)?.nombre ?? "").toLowerCase().includes(q))
    );
  }, [usuarios, almacenes, busqueda]);

  async function invitar(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    if (!ROLES_SIN_ALMACEN.includes(nuevo.rol) && !nuevo.almacen_ids.length) {
      setMsg({ tipo: "error", texto: "Los usuarios operativos deben tener al menos un almacén asignado." });
      return;
    }
    if (ROLES_UN_SOLO_ALMACEN.includes(nuevo.rol) && nuevo.almacen_ids.length !== 1) {
      setMsg({ tipo: "error", texto: "Los usuarios de franquicia deben tener exactamente un local asignado." });
      return;
    }

    setGuardando(true);
    try {
      const data = await peticion("/api/admin/usuarios", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...nuevo,
          almacen_ids: ROLES_SIN_ALMACEN.includes(nuevo.rol) ? [] : nuevo.almacen_ids,
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
      almacen_ids: usuario.almacen_ids,
      activo: usuario.activo,
    });
    setMsg(null);
  }

  async function guardar(usuario: Usuario) {
    setMsg(null);
    const rol = (edicion.rol ?? usuario.rol) as Rol;
    const almacenIds = edicion.almacen_ids ?? [];
    if (!ROLES_SIN_ALMACEN.includes(rol) && Boolean(edicion.activo) && !almacenIds.length) {
      setMsg({ tipo: "error", texto: "Selecciona al menos un almacén antes de guardar." });
      return;
    }
    if (Boolean(edicion.activo) && ROLES_UN_SOLO_ALMACEN.includes(rol) && almacenIds.length !== 1) {
      setMsg({ tipo: "error", texto: "Los usuarios de franquicia deben tener exactamente un local asignado." });
      return;
    }
    setGuardando(true);
    try {
      const data = await peticion("/api/admin/usuarios", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          id: usuario.id,
          nombre_completo: edicion.nombre_completo,
          rol: edicion.rol,
          almacen_ids: ROLES_SIN_ALMACEN.includes(rol) ? [] : almacenIds,
          activo: edicion.activo,
        }),
      });
      setEditando(null);
      setMsg({ tipo: data.advertencia ? "error" : "ok", texto: data.advertencia ?? "Usuario actualizado." });
      await cargar();
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo actualizar el usuario." });
    } finally {
      setGuardando(false);
    }
  }

  async function enviarCambioClave(usuario: Usuario) {
    if (!window.confirm(`Se enviará un enlace seguro para cambiar la contraseña a ${usuario.email}.\n\n¿Deseas continuar?`)) return;
    setMsg(null);
    setGuardando(true);
    try {
      const data = await peticion("/api/admin/usuarios", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: usuario.id }),
      });
      setMsg({ tipo: "ok", texto: data.mensaje ?? "Enlace de cambio de contraseña enviado." });
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo enviar el cambio de contraseña." });
    } finally {
      setGuardando(false);
    }
  }

  async function reenviarInvitacion(usuario: Usuario) {
    if (!window.confirm(`La invitación anterior dejará de utilizarse y se enviará un enlace nuevo a ${usuario.email}.\n\n¿Deseas continuar?`)) return;
    setMsg(null);
    setGuardando(true);
    try {
      const data = await peticion("/api/admin/usuarios", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ accion: "reenviar_invitacion", id: usuario.id }),
      });
      setMsg({ tipo: "ok", texto: data.mensaje ?? "Invitación reenviada." });
      await cargar();
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo reenviar la invitación." });
    } finally {
      setGuardando(false);
    }
  }

  async function generarEnlaceAcceso(usuario: Usuario) {
    const finalidad = usuario.confirmado ? "cambiar su contraseña" : "activar su cuenta";
    if (!window.confirm(
      `Se generará un enlace personal y temporal para que ${usuario.email} pueda ${finalidad}.\n\nPodrás copiarlo o preparar un correo desde otro proveedor. ¿Deseas continuar?`
    )) return;

    setMsg(null);
    setEnlaceAcceso(null);
    setGuardando(true);
    try {
      const data = await peticion("/api/admin/usuarios", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ accion: "generar_enlace_acceso", id: usuario.id }),
      });
      const generado: EnlaceAcceso = {
        email: data.email,
        enlace: data.enlace,
        tipo: data.tipo,
      };
      setEnlaceAcceso(generado);
      try {
        await navigator.clipboard.writeText(generado.enlace);
        setMsg({ tipo: "ok", texto: `${data.mensaje} También se copió al portapapeles.` });
      } catch {
        setMsg({ tipo: "ok", texto: `${data.mensaje} Cópialo desde el recuadro inferior.` });
      }
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo generar el enlace seguro." });
    } finally {
      setGuardando(false);
    }
  }

  async function copiarEnlaceAcceso() {
    if (!enlaceAcceso) return;
    try {
      await navigator.clipboard.writeText(enlaceAcceso.enlace);
      setMsg({ tipo: "ok", texto: "Enlace copiado al portapapeles." });
    } catch {
      setMsg({ tipo: "error", texto: "El navegador no permitió copiar automáticamente. Selecciona el enlace y cópialo manualmente." });
    }
  }

  async function eliminarAcceso(usuario: Usuario) {
    if (!window.confirm(
      `Vas a eliminar el acceso de ${usuario.nombre_completo} (${usuario.email}).\n\nYa no podrá ingresar, pero sus movimientos y auditoría se conservarán. Podrás restaurarlo editando el usuario y marcándolo como activo.\n\n¿Confirmas la eliminación del acceso?`
    )) return;
    setMsg(null);
    setGuardando(true);
    try {
      const data = await peticion("/api/admin/usuarios", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: usuario.id }),
      });
      setMsg({
        tipo: data.advertencia ? "error" : "ok",
        texto: data.advertencia ?? data.mensaje ?? "Acceso eliminado.",
      });
      await cargar();
    } catch (error) {
      setMsg({ tipo: "error", texto: error instanceof Error ? error.message : "No se pudo eliminar el acceso." });
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

      {enlaceAcceso && (() => {
        const finalidad = enlaceAcceso.tipo === "activacion" ? "activar tu cuenta" : "crear una nueva contraseña";
        const asunto = enlaceAcceso.tipo === "activacion" ? "Activa tu acceso a Boman Sport" : "Cambia tu contraseña de Boman Sport";
        const cuerpo = `Hola,\n\nUtiliza este enlace personal para ${finalidad}:\n\n${enlaceAcceso.enlace}\n\nEl enlace es temporal y debe utilizarse una sola vez.`;
        const mailto = `mailto:${enlaceAcceso.email}?subject=${encodeURIComponent(asunto)}&body=${encodeURIComponent(cuerpo)}`;
        return <div className="enlace-acceso-panel" role="status">
          <div>
            <strong>{asunto}</strong>
            <p>Destinatario: {enlaceAcceso.email}. Trátalo como información confidencial.</p>
          </div>
          <div className="enlace-acceso-url">
            <input readOnly value={enlaceAcceso.enlace} onFocus={(e) => e.currentTarget.select()} aria-label="Enlace seguro generado" />
            <button type="button" onClick={copiarEnlaceAcceso}>Copiar enlace</button>
            <a className="boton-link" href={mailto}>Preparar correo</a>
            <button type="button" className="chip-limpiar" onClick={() => setEnlaceAcceso(null)}>Cerrar</button>
          </div>
          <small>El sistema no envió ningún correo y esta acción no consume la cuota SMTP.</small>
        </div>;
      })()}

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
                <select value={nuevo.rol} onChange={(e) => setNuevo({ ...nuevo, rol: e.target.value as Rol, almacen_ids: [] })} style={{ width: "100%" }}>
                  {ROLES.map((rol) => <option key={rol.valor} value={rol.valor}>{rol.etiqueta}</option>)}
                </select>
              </div>
              {!ROLES_SIN_ALMACEN.includes(nuevo.rol) && (
                <div className="field">
                  <label>Almacenes asignados</label>
                  <div className="selector-almacenes">
                    {almacenes.map((a) => <label key={a.id}><input type="checkbox" checked={nuevo.almacen_ids.includes(a.id)} onChange={(e) => setNuevo({ ...nuevo, almacen_ids: e.target.checked ? (ROLES_UN_SOLO_ALMACEN.includes(nuevo.rol) ? [a.id] : [...nuevo.almacen_ids, a.id]) : nuevo.almacen_ids.filter((id) => id !== a.id) })} /> {a.nombre}</label>)}
                  </div>
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
                          <select value={rolEdicion} onChange={(e) => setEdicion({ ...edicion, rol: e.target.value as Rol, entidad_id: null, almacen_ids: [] })}>
                            {ROLES.map((rol) => <option key={rol.valor} value={rol.valor}>{rol.etiqueta}</option>)}
                          </select>
                        ) : ROLES.find((r) => r.valor === usuario.rol)?.etiqueta}
                      </td>
                      <td>
                        {estaEditando && !ROLES_SIN_ALMACEN.includes(rolEdicion) ? (
                          <div className="selector-almacenes compacto">{almacenes.map((a) => { const ids = edicion.almacen_ids ?? []; return <label key={a.id}><input type="checkbox" checked={ids.includes(a.id)} onChange={(e) => setEdicion({ ...edicion, almacen_ids: e.target.checked ? (ROLES_UN_SOLO_ALMACEN.includes(rolEdicion) ? [a.id] : [...ids, a.id]) : ids.filter((id) => id !== a.id) })} /> {a.nombre}</label>; })}</div>
                        ) : ROLES_SIN_ALMACEN.includes(estaEditando ? rolEdicion : usuario.rol)
                          ? "Todos"
                          : usuario.almacen_ids.map((id) => almacenes.find((a) => a.id === id)?.nombre).filter(Boolean).join(", ") || "Sin asignación"}
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
                          <span className={`badge ${usuario.configuracion_incompleta ? "bajo" : usuario.activo ? "ok" : "cero"}`}>
                            {usuario.configuracion_incompleta ? "Falta almacén" : usuario.activo ? "Activo" : "Inactivo"}
                          </span>
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
                        ) : <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                          <button className="secondary" disabled={guardando} onClick={() => editar(usuario)}>Editar</button>
                          {usuario.confirmado
                            ? <button className="secondary" disabled={guardando || !usuario.activo || !usuario.email} onClick={() => enviarCambioClave(usuario)} title="Enviar enlace seguro al correo">Cambiar contraseña</button>
                            : <button className="secondary" disabled={guardando || !usuario.activo || !usuario.email} onClick={() => reenviarInvitacion(usuario)} title="Generar un enlace de activación nuevo">Reenviar invitación</button>}
                          <button className="secondary" disabled={guardando || !usuario.activo || !usuario.email} onClick={() => generarEnlaceAcceso(usuario)} title="Crear un enlace para enviarlo manualmente desde otro proveedor">
                            {usuario.confirmado ? "Generar enlace de clave" : "Generar enlace de activación"}
                          </button>
                          {usuario.id !== usuarioActualId && usuario.activo && <button className="peligro" disabled={guardando} onClick={() => eliminarAcceso(usuario)}>Eliminar acceso</button>}
                        </div>}
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
