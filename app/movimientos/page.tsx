export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";
import MovimientoForm from "./MovimientoForm";

export default async function MovimientosPage() {
  const perfil = await getPerfilActual();
  const supabase = createClient();

  const { data: movimientos } = await supabase
    .from("movimientos")
    .select("tipo, cantidad, nota, created_at, productos(nombre, sku), entidades(nombre), entidad_destino:entidad_destino_id(nombre), perfiles(nombre_completo)")
    .order("created_at", { ascending: false })
    .limit(50);

  const { data: productos } = await supabase.from("productos").select("id, sku, nombre").eq("activo", true).order("nombre");
  const { data: entidades } = await supabase.from("entidades").select("id, nombre").eq("activo", true);

  const puedeRegistrar = perfil.rol === "admin" || perfil.rol === "bodega" || perfil.rol === "logistica";

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <h2 style={{ color: "#1f3864" }}>Movimientos</h2>

        {puedeRegistrar && (
          <MovimientoForm
            perfil={perfil}
            productos={productos ?? []}
            entidades={entidades ?? []}
          />
        )}

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Historial</h3>
          <table>
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Tipo</th>
                <th>Producto</th>
                <th>Entidad</th>
                <th>Destino</th>
                <th>Cant.</th>
                <th>Usuario</th>
                <th>Nota</th>
              </tr>
            </thead>
            <tbody>
              {(movimientos ?? []).map((m: any, i: number) => (
                <tr key={i}>
                  <td>{new Date(m.created_at).toLocaleString("es-EC")}</td>
                  <td><span className={`badge ${m.tipo}`}>{m.tipo.replace("_", " ")}</span></td>
                  <td>{m.productos?.nombre} ({m.productos?.sku})</td>
                  <td>{m.entidades?.nombre}</td>
                  <td>{m.entidad_destino?.nombre ?? "-"}</td>
                  <td>{m.cantidad}</td>
                  <td>{m.perfiles?.nombre_completo}</td>
                  <td style={{ maxWidth: 200 }}>{m.nota ?? "-"}</td>
                </tr>
              ))}
              {(!movimientos || movimientos.length === 0) && (
                <tr><td colSpan={8} style={{ textAlign: "center", color: "#9ca3af" }}>Sin movimientos aún.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
