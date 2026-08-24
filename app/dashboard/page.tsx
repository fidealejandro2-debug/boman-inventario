export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";

export default async function DashboardPage() {
  const perfil = await getPerfilActual();
  const supabase = createClient();

  const { data: inventario } = await supabase
    .from("inventario")
    .select("cantidad, productos(nombre, sku), almacenes(nombre)")
    .order("cantidad", { ascending: false })
    .limit(8);

  const { data: movimientos } = await supabase
    .from("movimientos")
    .select("tipo, cantidad, created_at, productos(nombre), almacenes(nombre), perfiles(nombre_completo)")
    .order("created_at", { ascending: false })
    .limit(8);

  const { count: totalProductos } = await supabase
    .from("productos")
    .select("*", { count: "exact", head: true })
    .eq("activo", true);

  const totalUnidades = (inventario ?? []).reduce((acc: number, r: any) => acc + r.cantidad, 0);

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <h2 style={{ color: "#1f3864" }}>Hola, {perfil.nombre_completo.split(" ")[0]}</h2>

        <div className="grid-2">
          <div className="card">
            <div style={{ fontSize: 13, color: "#6b7280" }}>Productos activos</div>
            <div style={{ fontSize: 32, fontWeight: 700, color: "#1f3864" }}>{totalProductos ?? 0}</div>
          </div>
          <div className="card">
            <div style={{ fontSize: 13, color: "#6b7280" }}>Unidades en stock (top 8 mostrado)</div>
            <div style={{ fontSize: 32, fontWeight: 700, color: "#1f3864" }}>{totalUnidades}</div>
          </div>
        </div>

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Últimos movimientos</h3>
          <table>
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Tipo</th>
                <th>Producto</th>
                <th>Almacén</th>
                <th>Cantidad</th>
                <th>Usuario</th>
              </tr>
            </thead>
            <tbody>
              {(movimientos ?? []).map((m: any, i: number) => (
                <tr key={i}>
                  <td>{new Date(m.created_at).toLocaleString("es-EC")}</td>
                  <td><span className={`badge ${m.tipo}`}>{m.tipo.replace("_", " ")}</span></td>
                  <td>{m.productos?.nombre}</td>
                  <td>{m.almacenes?.nombre}</td>
                  <td>{m.cantidad}</td>
                  <td>{m.perfiles?.nombre_completo}</td>
                </tr>
              ))}
              {(!movimientos || movimientos.length === 0) && (
                <tr><td colSpan={6} style={{ textAlign: "center", color: "#9ca3af" }}>Sin movimientos registrados aún.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
