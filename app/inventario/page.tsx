export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { getPerfilActual } from "@/lib/getPerfil";
import Navbar from "@/components/Navbar";

export default async function InventarioPage() {
  const perfil = await getPerfilActual();
  const supabase = createClient();

  const { data: inventario } = await supabase
    .from("inventario")
    .select("cantidad, productos(sku, nombre, categoria, talla, color), almacenes(nombre)")
    .order("cantidad", { ascending: false });

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <h2 style={{ color: "#1f3864" }}>Stock actual</h2>
        <div className="card">
          <table>
            <thead>
              <tr>
                <th>SKU</th>
                <th>Producto</th>
                <th>Categoría</th>
                <th>Talla</th>
                <th>Color</th>
                <th>Almacén</th>
                <th>Cantidad</th>
              </tr>
            </thead>
            <tbody>
              {(inventario ?? []).map((r: any, i: number) => (
                <tr key={i}>
                  <td>{r.productos?.sku}</td>
                  <td>{r.productos?.nombre}</td>
                  <td>{r.productos?.categoria}</td>
                  <td>{r.productos?.talla ?? "-"}</td>
                  <td>{r.productos?.color ?? "-"}</td>
                  <td>{r.almacenes?.nombre}</td>
                  <td style={{ fontWeight: 700 }}>{r.cantidad}</td>
                </tr>
              ))}
              {(!inventario || inventario.length === 0) && (
                <tr><td colSpan={7} style={{ textAlign: "center", color: "#9ca3af" }}>No hay stock registrado todavía.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
