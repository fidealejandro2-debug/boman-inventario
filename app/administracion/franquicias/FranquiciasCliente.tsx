"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Franquicia = {
  id: string;
  grupo_id: string;
  empresa_id: string;
  almacen_id: string;
  codigo: string;
  nombre: string;
  ciudad: string | null;
  activo: boolean;
};

type Empresa = { id: string; razon_social: string; ruc: string; grupo_id: string };
type Almacen = { id: string; nombre: string; tipo: string };

const VACIO = {
  id: "",
  empresa_id: "",
  almacen_id: "",
  codigo: "",
  nombre: "",
  ciudad: "",
  activo: true,
};

export default function FranquiciasCliente() {
  const supabase = createClient();
  const [filas, setFilas] = useState<Franquicia[]>([]);
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [almacenes, setAlmacenes] = useState<Almacen[]>([]);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [form, setForm] = useState({ ...VACIO });
  const [mostrar, setMostrar] = useState(false);

  async function cargar() {
    setCargando(true);
    const [f, e, a] = await Promise.all([
      supabase.from("franquicias").select("*").order("nombre"),
      supabase
        .from("empresas")
        .select("id, razon_social, ruc, grupo_id")
        .eq("activo", true)
        .order("razon_social"),
      supabase
        .from("almacenes")
        .select("id, nombre, tipo")
        .eq("activo", true)
        .order("nombre"),
    ]);
    if (f.error) setError(f.error.message);
    else setFilas((f.data as Franquicia[]) ?? []);
    if (!e.error) setEmpresas((e.data as Empresa[]) ?? []);
    if (!a.error) setAlmacenes((a.data as Almacen[]) ?? []);
    setCargando(false);
  }

  useEffect(() => {
    cargar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Un almacén solo puede pertenecer a una franquicia: la base tiene un
  // unique sobre almacen_id, así que aquí ya se ocultan los ocupados.
  const almacenesLibres = almacenes.filter(
    (a) => !filas.some((f) => f.almacen_id === a.id && f.id !== form.id)
  );

  async function guardar() {
    if (!form.empresa_id) return setError("Elige la empresa titular.");
    if (!form.almacen_id) return setError("Elige el almacén del local.");
    if (!form.codigo.trim() || !form.nombre.trim())
      return setError("El código y el nombre son obligatorios.");

    const empresa = empresas.find((e) => e.id === form.empresa_id);
    if (!empresa) return setError("La empresa seleccionada ya no está disponible.");

    setGuardando(true);
    setError(null);
    const { error } = await supabase.rpc("admin_guardar_franquicia_v42", {
      p_franquicia_id: form.id || null,
      p_grupo_id: empresa.grupo_id,
      p_empresa_id: form.empresa_id,
      p_almacen_id: form.almacen_id,
      p_codigo: form.codigo,
      p_nombre: form.nombre,
      p_ciudad: form.ciudad || null,
      p_activo: form.activo,
    });
    setGuardando(false);
    if (error) return setError(error.message);
    setAviso(form.id ? "Franquicia actualizada." : "Franquicia creada.");
    setForm({ ...VACIO });
    setMostrar(false);
    cargar();
  }

  function editar(f: Franquicia) {
    setForm({
      id: f.id,
      empresa_id: f.empresa_id,
      almacen_id: f.almacen_id,
      codigo: f.codigo,
      nombre: f.nombre,
      ciudad: f.ciudad ?? "",
      activo: f.activo,
    });
    setMostrar(true);
    setError(null);
  }

  if (cargando) return <p className="ayuda">Cargando franquicias…</p>;

  return (
    <div className="card">
      <h2>Franquicias</h2>
      <p className="ayuda">
        Cada franquicia es un local aislado: su usuario solo ve el stock de{" "}
        <strong>su almacén</strong> y su propia caja. La vinculación se hace por almacén,
        así que un almacén no puede pertenecer a dos franquicias.
      </p>

      {error && <p className="error">{error}</p>}
      {aviso && <p className="aviso">{aviso}</p>}

      {!empresas.length && (
        <p className="aviso">
          No hay empresas activas visibles. Registra primero el RUC en Grupo y empresas.
        </p>
      )}

      <div className="filtros">
        <button
          onClick={() => {
            setForm({ ...VACIO });
            setMostrar(!mostrar);
            setError(null);
          }}
        >
          {mostrar ? "Cancelar" : "Nueva franquicia"}
        </button>
      </div>

      {mostrar && (
        <div className="card-interna">
          <h4>{form.id ? "Editar franquicia" : "Nueva franquicia"}</h4>
          <div className="form-grid">
            <label>
              Empresa titular
              <select
                value={form.empresa_id}
                onChange={(e) => setForm({ ...form, empresa_id: e.target.value })}
              >
                <option value="">Elegir…</option>
                {empresas.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.razon_social} · {e.ruc}
                  </option>
                ))}
              </select>
              <small>El RUC bajo el que opera el local.</small>
            </label>
            <label>
              Almacén del local
              <select
                value={form.almacen_id}
                onChange={(e) => setForm({ ...form, almacen_id: e.target.value })}
              >
                <option value="">Elegir…</option>
                {almacenesLibres.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.nombre} ({a.tipo})
                  </option>
                ))}
              </select>
              <small>
                Solo se listan los almacenes que aún no pertenecen a otra franquicia.
              </small>
            </label>
            <label>
              Código
              <input
                type="text"
                placeholder="Ej. FQ-PUYO"
                value={form.codigo}
                onChange={(e) => setForm({ ...form, codigo: e.target.value })}
              />
            </label>
            <label>
              Nombre
              <input
                type="text"
                value={form.nombre}
                onChange={(e) => setForm({ ...form, nombre: e.target.value })}
              />
            </label>
            <label>
              Ciudad
              <input
                type="text"
                value={form.ciudad}
                onChange={(e) => setForm({ ...form, ciudad: e.target.value })}
              />
            </label>
            <label className="check-inline">
              <input
                type="checkbox"
                checked={form.activo}
                onChange={(e) => setForm({ ...form, activo: e.target.checked })}
              />{" "}
              Activa
            </label>
          </div>
          <button onClick={guardar} disabled={guardando}>
            {guardando ? "Guardando…" : form.id ? "Guardar cambios" : "Crear franquicia"}
          </button>
        </div>
      )}

      <div className="tabla-scroll">
        <table>
          <thead>
            <tr>
              <th>Código</th>
              <th>Nombre</th>
              <th>Ciudad</th>
              <th>Empresa</th>
              <th>Almacén</th>
              <th>Estado</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {filas.map((f) => (
              <tr key={f.id} className={f.activo ? "" : "fila-anulada"}>
                <td>
                  <strong>{f.codigo}</strong>
                </td>
                <td>{f.nombre}</td>
                <td>{f.ciudad ?? "—"}</td>
                <td>
                  {empresas.find((e) => e.id === f.empresa_id)?.razon_social ?? "—"}
                </td>
                <td>{almacenes.find((a) => a.id === f.almacen_id)?.nombre ?? "—"}</td>
                <td>
                  <span className={`badge ${f.activo ? "ok" : "cero"}`}>
                    {f.activo ? "activa" : "inactiva"}
                  </span>
                </td>
                <td>
                  <button className="btn-mini secondary" onClick={() => editar(f)}>
                    Editar
                  </button>
                </td>
              </tr>
            ))}
            {!filas.length && (
              <tr>
                <td colSpan={7} className="vacio">
                  Todavía no hay franquicias. Crea la primera para habilitar su panel.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <p className="ayuda">
        Después de crear la franquicia, asigna su almacén al usuario en{" "}
        <strong>Administración → Usuarios</strong> con el rol{" "}
        <em>franquiciado</em> o <em>vendedor de franquicia</em>, y habilita sus permisos
        en <strong>Permisos por rol</strong>.
      </p>
    </div>
  );
}
