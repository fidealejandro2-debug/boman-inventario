export const dynamic = "force-dynamic";

import { createClient } from "@/lib/supabase/server";
import { getPerfilActual } from "@/lib/getPerfil";
import { redirect } from "next/navigation";
import Navbar from "@/components/Navbar";
import ProductoForm from "./ProductoForm";

export default async function ProductosPage() {
  const perfil = await getPerfilActual();
  if (perfil.rol !== "admin") redirect("/dashboard");

  const supabase = createClient();
  const { data: productos } = await supabase
    .from("productos")
    .select("sku, nombre, categoria, talla, color, activo")
    .order("nombre");

  return (
    <>
      <Navbar perfil={perfil} />
      <div className="container">
        <h2 style={{ color: "#1f3864" }}>Productos</h2>

        <ProductoForm />

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Catálogo</h3>
          <table>
            <thead>
              <tr>
                <th>SKU</th>
                <th>Nombre</th>
                <th>Categoría</th>
                <th>Talla</th>
                <th>Color</th>
                <th>Estado</th>
              </tr>
            </thead>
            <tbody>
              {(productos ?? []).map((p: any, i: number) => (
                <tr key={i}>
                  <td>{p.sku}</td>
                  <td>{p.nombre}</td>
                  <td>{p.categoria}</td>
                  <td>{p.talla ?? "-"}</td>
                  <td>{p.color ?? "-"}</td>
                  <td>{p.activo ? "Activo" : "Inactivo"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
